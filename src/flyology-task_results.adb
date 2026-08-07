with Ada.Unchecked_Conversion;
with Interfaces.C;
with Flyology.Time_Math;
with System.Soft_Links;

package body Flyology.Task_Results is
   package C renames Interfaces.C;

   use type C.int;
   use type C.size_t;
   use type C.unsigned;
   use type System.Address;

   ABI_Version : constant C.unsigned := 1;

   type Runtime_Result is record
      Version                  : C.unsigned;
      Cause                    : C.int;
      Exception_Name_Length    : C.unsigned;
      Exception_Name_Truncated : C.int;
      Message_Length           : C.unsigned;
      Message_Truncated        : C.int;
      Exception_Name           : C.char_array
        (0 .. Exception_Name_Capacity - 1);
      Message                  : C.char_array
        (0 .. Exception_Message_Capacity - 1);
   end record with Convention => C;

   function Runtime_Observe_Task
     (T         : System.Address;
      Item      : System.Address;
      Item_Size : C.size_t) return C.int;
   pragma Import
     (C, Runtime_Observe_Task, "flyology_runtime_task_result_observe_task");

   function Runtime_Wait_Task
     (T                   : System.Address;
      Timeout_Nanoseconds : C.long_long) return C.int;
   pragma Import
     (C, Runtime_Wait_Task, "flyology_runtime_task_result_wait_task");

   function Runtime_Attach_Monitor
     (T : System.Address) return System.Address;
   pragma Import
     (C, Runtime_Attach_Monitor,
      "flyology_runtime_task_result_monitor_attach");

   procedure Runtime_Release_Monitor (Storage : System.Address);
   pragma Import
     (C, Runtime_Release_Monitor,
      "flyology_runtime_task_result_monitor_release");

   function Runtime_Observe_Monitor
     (Storage   : System.Address;
      Item      : System.Address;
      Item_Size : C.size_t) return C.int;
   pragma Import
     (C, Runtime_Observe_Monitor,
      "flyology_runtime_task_result_monitor_observe");

   function Runtime_Wait_Monitor
     (Storage             : System.Address;
      Timeout_Nanoseconds : C.long_long) return C.int;
   pragma Import
     (C, Runtime_Wait_Monitor,
      "flyology_runtime_task_result_monitor_wait");

   function To_Address is new Ada.Unchecked_Conversion
     (Ada.Task_Identification.Task_Id, System.Address);

   Empty_Result : constant Task_Result :=
     (Cause             => Normal_Completion,
      Exception_Name    => (Length => 0, Truncated => False,
                            Data => (others => ' ')),
      Exception_Message => (Length => 0, Truncated => False,
                            Data => (others => ' ')));

   function Convert (Raw : Runtime_Result) return Task_Result;

   function Convert (Raw : Runtime_Result) return Task_Result is
      Result : Task_Result := Empty_Result;
   begin
      if Raw.Version /= ABI_Version
        or else Raw.Exception_Name_Length > Exception_Name_Capacity
        or else Raw.Message_Length > Exception_Message_Capacity
        or else Raw.Exception_Name_Truncated not in 0 .. 1
        or else Raw.Message_Truncated not in 0 .. 1
      then
         raise Program_Error with "incompatible Flyology task-result ABI";
      end if;

      Result.Cause :=
        (case Raw.Cause is
            when 0 => Normal_Completion,
            when 1 => Abnormal_Completion,
            when 2 => Unhandled_Exception,
            when others =>
               raise Program_Error with
                 "incompatible Flyology task-result cause");
      Result.Exception_Name.Length := Natural (Raw.Exception_Name_Length);
      Result.Exception_Name.Truncated := Raw.Exception_Name_Truncated = 1;
      for Index in 1 .. Result.Exception_Name.Length loop
         Result.Exception_Name.Data (Index) := Character'Val
           (C.char'Pos (Raw.Exception_Name (C.size_t (Index - 1))));
      end loop;
      Result.Exception_Message.Length := Natural (Raw.Message_Length);
      Result.Exception_Message.Truncated := Raw.Message_Truncated = 1;
      for Index in 1 .. Result.Exception_Message.Length loop
         Result.Exception_Message.Data (Index) := Character'Val
           (C.char'Pos (Raw.Message (C.size_t (Index - 1))));
      end loop;
      return Result;
   end Convert;

   function Observe
     (T : Ada.Task_Identification.Task_Id) return Task_Observation
   is
      Raw    : aliased Runtime_Result;
      Status : C.int;
   begin
      Status := Runtime_Observe_Task
        (To_Address (T), Raw'Address, Runtime_Result'Size / 8);
      case Status is
         when 0 =>
            return (Status => Not_Terminal);
         when 1 =>
            return (Status => Terminal, Result => Convert (Raw));
         when others =>
            raise Program_Error with
              "invalid or unsupported task-result identity";
      end case;
   end Observe;

   function Wait
     (T       : Ada.Task_Identification.Task_Id;
      Timeout : Duration := -1.0) return Task_Observation
   is
      Runtime_Code : C.int;
      Result       : Task_Observation;
   begin
      Runtime_Code := Runtime_Wait_Task
        (To_Address (T), Flyology.Time_Math.To_Nanoseconds (Timeout));
      if Runtime_Code not in 0 .. 1 then
         raise Program_Error with "Flyology task-result wait failed";
      end if;

      --  Observe again after either wake or timeout. This makes a terminal
      --  publication that wins the timeout boundary visible to the caller.
      Result := Observe (T);
      if Runtime_Code = 1 and then Result.Status /= Terminal then
         raise Program_Error with "Flyology task-result wake was not terminal";
      end if;
      return Result;
   end Wait;

   procedure Attach
     (Item : in out Monitor;
      T    : Ada.Task_Identification.Task_Id) is
   begin
      if Item.Storage /= System.Null_Address then
         raise Program_Error with "task-result monitor is already attached";
      end if;

      --  Attaching increments the runtime sidecar reference before returning
      --  it. Keep abort deferred until Item owns that returned reference, or
      --  an abort delivered at the imported-call boundary could leak it.
      System.Soft_Links.Abort_Defer.all;
      begin
         Item.Storage := Runtime_Attach_Monitor (To_Address (T));
      exception
         when others =>
            System.Soft_Links.Abort_Undefer.all;
            raise;
      end;
      System.Soft_Links.Abort_Undefer.all;

      if Item.Storage = System.Null_Address then
         raise Program_Error with
           "invalid or unsupported task-result monitor identity";
      end if;
   end Attach;

   function Attached (Item : Monitor) return Boolean is
     (Item.Storage /= System.Null_Address);

   procedure Detach (Item : in out Monitor) is
      Storage : constant System.Address := Item.Storage;
   begin
      if Storage /= System.Null_Address then
         --  Clear Item and release its retained reference as one
         --  abort-deferred ownership transfer. Finalization can then call
         --  Detach idempotently even if the pending abort is delivered by
         --  Abort_Undefer.
         System.Soft_Links.Abort_Defer.all;
         begin
            Item.Storage := System.Null_Address;
            Runtime_Release_Monitor (Storage);
         exception
            when others =>
               System.Soft_Links.Abort_Undefer.all;
               raise;
         end;
         System.Soft_Links.Abort_Undefer.all;
      end if;
   end Detach;

   function Observe (Item : Monitor) return Task_Observation is
      Raw    : aliased Runtime_Result;
      Status : C.int;
   begin
      if Item.Storage = System.Null_Address then
         raise Program_Error with "task-result monitor is detached";
      end if;
      Status := Runtime_Observe_Monitor
        (Item.Storage, Raw'Address, Runtime_Result'Size / 8);
      case Status is
         when 0 =>
            return (Status => Not_Terminal);
         when 1 =>
            return (Status => Terminal, Result => Convert (Raw));
         when others =>
            raise Program_Error with "task-result monitor observation failed";
      end case;
   end Observe;

   function Wait
     (Item    : Monitor;
      Timeout : Duration := -1.0) return Task_Observation
   is
      Runtime_Code : C.int;
      Result       : Task_Observation;
   begin
      if Item.Storage = System.Null_Address then
         raise Program_Error with "task-result monitor is detached";
      end if;
      Runtime_Code := Runtime_Wait_Monitor
        (Item.Storage, Flyology.Time_Math.To_Nanoseconds (Timeout));
      if Runtime_Code not in 0 .. 1 then
         raise Program_Error with "task-result monitor wait failed";
      end if;

      Result := Observe (Item);
      if Runtime_Code = 1 and then Result.Status /= Terminal then
         raise Program_Error with
           "task-result monitor wake was not terminal";
      end if;
      return Result;
   end Wait;

   overriding procedure Finalize (Item : in out Monitor) is
   begin
      Detach (Item);
   end Finalize;

end Flyology.Task_Results;
