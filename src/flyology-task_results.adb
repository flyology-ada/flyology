with Ada.Unchecked_Conversion;
with Flyology.Operations.Drivers;
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

   function Runtime_Retain_Monitor
     (Storage : System.Address) return System.Address;
   pragma Import
     (C, Runtime_Retain_Monitor,
      "flyology_runtime_task_result_monitor_retain");

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

   function Runtime_Subscribe_Monitor
     (Storage            : System.Address;
      Subscription_Node : System.Address;
      Node_Size          : C.size_t;
      Signal_Descriptor : C.int) return C.int;
   pragma Import
     (C, Runtime_Subscribe_Monitor,
      "flyology_runtime_task_result_monitor_subscribe");

   function Runtime_Unsubscribe_Monitor
     (Storage            : System.Address;
      Subscription_Node : System.Address;
      Node_Size          : C.size_t) return C.int;
   pragma Import
     (C, Runtime_Unsubscribe_Monitor,
      "flyology_runtime_task_result_monitor_unsubscribe");

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

   procedure Start_Scoped_Wait
     (Operation : in out Wait_Operation;
      Timeout   : Duration)
   is
      Read_Descriptor, Signal_Descriptor : C.int;
      Runtime_Code : C.int;

      procedure Retain_Failure;

      procedure Retain_Failure is
      begin
         Operation.Failure := Observation_Failure;
         Detach (Operation.Target);
         Flyology.Operations.Drivers.Complete
           (Operation, Flyology.Operations.Failed);
      end Retain_Failure;
   begin
      Operation.Subscription := (others => <>);
      Operation.Status := Not_Terminal;
      Operation.Result := Empty_Result;
      Operation.Failure := No_Failure;

      if Timeout = 0.0 then
         declare
            Observation : Task_Observation;
         begin
            begin
               Observation := Observe (Operation.Target);
            exception
               when others =>
                  Retain_Failure;
                  return;
            end;
            Operation.Status := Observation.Status;
            if Observation.Status = Terminal then
               Operation.Result := Observation.Result;
            end if;
            Detach (Operation.Target);
            Flyology.Operations.Drivers.Complete
              (Operation, Flyology.Operations.Succeeded);
         end;
         return;
      end if;

      Flyology.Operations.Drivers.Completion_Source
        (Operation, Read_Descriptor, Signal_Descriptor);
      Runtime_Code := Runtime_Subscribe_Monitor
        (Operation.Target.Storage,
         Operation.Subscription'Address,
         Subscription_Node'Size / 8,
         Signal_Descriptor);
      if Runtime_Code = 1 then
         declare
            Observation : Task_Observation;
         begin
            begin
               Observation := Observe (Operation.Target);
            exception
               when others =>
                  Retain_Failure;
                  return;
            end;
            if Observation.Status /= Terminal then
               Retain_Failure;
               return;
            end if;
            Operation.Status := Terminal;
            Operation.Result := Observation.Result;
            Detach (Operation.Target);
            Flyology.Operations.Drivers.Complete
              (Operation, Flyology.Operations.Succeeded);
         end;
      elsif Runtime_Code /= 0 then
         Operation.Failure := Subscription_Failure;
         Detach (Operation.Target);
         Flyology.Operations.Drivers.Complete
           (Operation, Flyology.Operations.Failed);
      else
         if Timeout > 0.0 then
            Flyology.Operations.Drivers.Arm_Deadline (Operation, Timeout);
         end if;
         Flyology.Operations.Drivers.Arm_Readiness
           (Operation, Read_Descriptor, False);
      end if;
   exception
      when others =>
         if Operation.Target.Storage /= System.Null_Address then
            Runtime_Code := Runtime_Unsubscribe_Monitor
              (Operation.Target.Storage,
               Operation.Subscription'Address,
               Subscription_Node'Size / 8);
            pragma Assert (Runtime_Code = 0);
            Detach (Operation.Target);
         end if;
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Start_Scoped_Wait;

   procedure Attach_Task
     (T         : Ada.Task_Identification.Task_Id;
      Operation : in out Wait_Operation)
   is
   begin
      if Attached (Operation.Target) then
         raise Program_Error with
           "task-result operation still retains a prior target";
      end if;
      Operation.Target.Storage := Runtime_Attach_Monitor (To_Address (T));
      if Operation.Target.Storage = System.Null_Address then
         Operation.Failure := Attach_Failure;
         raise Program_Error with
           "invalid or unsupported task-result operation identity";
      end if;
   end Attach_Task;

   procedure Attach_Monitor
     (Item      : Monitor'Class;
      Operation : in out Wait_Operation)
   is
   begin
      if Attached (Operation.Target) then
         raise Program_Error with
           "task-result operation still retains a prior target";
      elsif not Attached (Item) then
         raise Program_Error with "task-result source monitor is detached";
      end if;
      Operation.Target.Storage := Runtime_Retain_Monitor (Item.Storage);
      if Operation.Target.Storage = System.Null_Address then
         Operation.Failure := Attach_Failure;
         raise Program_Error with "task-result monitor retention failed";
      end if;
   end Attach_Monitor;

   procedure Wait
     (T         : Ada.Task_Identification.Task_Id;
      Timeout   : Duration := -1.0;
      Operation : in out Wait_Operation)
   is
   begin
      Flyology.Operations.Drivers.Start (Operation);
      Attach_Task (T, Operation);
      Start_Scoped_Wait (Operation, Timeout);
   exception
      when others =>
         Detach (Operation.Target);
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Wait;

   procedure Wait
     (Item      : Monitor'Class;
      Timeout   : Duration := -1.0;
      Operation : in out Wait_Operation)
   is
   begin
      Flyology.Operations.Drivers.Start (Operation);
      Attach_Monitor (Item, Operation);
      Start_Scoped_Wait (Operation, Timeout);
   exception
      when others =>
         Detach (Operation.Target);
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Wait;

   function Wait
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      T       : Ada.Task_Identification.Task_Id;
      Timeout : Duration := -1.0) return Wait_Operation
   is
   begin
      return Result : Wait_Operation (Set) do
         Wait (T, Timeout, Result);
      end return;
   end Wait;

   function Wait
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      Item    : Monitor'Class;
      Timeout : Duration := -1.0) return Wait_Operation
   is
   begin
      return Result : Wait_Operation (Set) do
         Wait (Item, Timeout, Result);
      end return;
   end Wait;

   overriding procedure Drive
     (Item  : in out Wait_Operation;
      Event : Flyology.Operations.Driver_Event)
   is
      Runtime_Code : C.int;
      Read_Descriptor, Signal_Descriptor : C.int;
      Observation : Task_Observation;
   begin
      case Event is
         when Flyology.Operations.Start_Operation =>
            raise Program_Error with
              "task-result operation was already started";
         when Flyology.Operations.Source_Ready =>
            begin
               Observation := Observe (Item.Target);
            exception
               when others =>
                  Runtime_Code := Runtime_Unsubscribe_Monitor
                    (Item.Target.Storage,
                     Item.Subscription'Address,
                     Subscription_Node'Size / 8);
                  pragma Assert (Runtime_Code = 0);
                  Item.Failure := Observation_Failure;
                  Detach (Item.Target);
                  Flyology.Operations.Drivers.Complete
                    (Item, Flyology.Operations.Failed);
                  return;
            end;
            if Observation.Status = Terminal then
               Item.Status := Terminal;
               Item.Result := Observation.Result;
               Runtime_Code := Runtime_Unsubscribe_Monitor
                 (Item.Target.Storage,
                  Item.Subscription'Address,
                  Subscription_Node'Size / 8);
               if Runtime_Code /= 0 then
                  Item.Failure := Subscription_Failure;
                  Detach (Item.Target);
                  Flyology.Operations.Drivers.Complete
                    (Item, Flyology.Operations.Failed);
                  return;
               end if;
               Detach (Item.Target);
               Flyology.Operations.Drivers.Complete
                 (Item, Flyology.Operations.Succeeded);
            else
               begin
                  Flyology.Operations.Drivers.Completion_Source
                    (Item, Read_Descriptor, Signal_Descriptor);
                  Flyology.Operations.Drivers.Arm_Readiness
                    (Item, Read_Descriptor, False);
               exception
                  when others =>
                     Runtime_Code := Runtime_Unsubscribe_Monitor
                       (Item.Target.Storage,
                        Item.Subscription'Address,
                        Subscription_Node'Size / 8);
                     pragma Assert (Runtime_Code = 0);
                     Item.Failure := Subscription_Failure;
                     Detach (Item.Target);
                     Flyology.Operations.Drivers.Complete
                       (Item, Flyology.Operations.Failed);
               end;
            end if;
         when Flyology.Operations.Deadline_Reached =>
            Runtime_Code := Runtime_Unsubscribe_Monitor
              (Item.Target.Storage,
               Item.Subscription'Address,
               Subscription_Node'Size / 8);
            if Runtime_Code /= 0 then
               Item.Failure := Subscription_Failure;
               Detach (Item.Target);
               Flyology.Operations.Drivers.Complete
                 (Item, Flyology.Operations.Failed);
               return;
            end if;
            begin
               Observation := Observe (Item.Target);
            exception
               when others =>
                  Item.Failure := Observation_Failure;
                  Detach (Item.Target);
                  Flyology.Operations.Drivers.Complete
                    (Item, Flyology.Operations.Failed);
                  return;
            end;
            Item.Status := Observation.Status;
            if Observation.Status = Terminal then
               Item.Result := Observation.Result;
            end if;
            Detach (Item.Target);
            Flyology.Operations.Drivers.Complete
              (Item, Flyology.Operations.Succeeded);
         when Flyology.Operations.Dependency_Changed
            | Flyology.Operations.Continue_Operation =>
            raise Program_Error with
              "task-result operation received a dependency event";
      end case;
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Wait_Operation)
   is
      Runtime_Code : C.int;
   begin
      if Attached (Item.Target) then
         Runtime_Code := Runtime_Unsubscribe_Monitor
           (Item.Target.Storage,
            Item.Subscription'Address,
            Subscription_Node'Size / 8);
         pragma Assert (Runtime_Code = 0);
         Detach (Item.Target);
      end if;
      Flyology.Operations.Drivers.Complete
        (Item, Flyology.Operations.Cancelled);
   end Request_Cancellation;

   procedure Finish
     (Operation   : in out Wait_Operation;
      Observation : out Task_Observation)
   is
      Terminal_State : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Operation);
      Status  : constant Observation_Status := Operation.Status;
      Result  : constant Task_Result := Operation.Result;
      Failure : constant Wait_Failure := Operation.Failure;
   begin
      Flyology.Operations.Consume (Operation);
      case Terminal_State is
         when Flyology.Operations.Succeeded =>
            if Status = Terminal then
               Observation := (Status => Terminal, Result => Result);
            else
               Observation := (Status => Not_Terminal);
            end if;
         when Flyology.Operations.Cancelled =>
            raise Operation_Cancelled;
         when Flyology.Operations.Failed =>
            case Failure is
               when Attach_Failure =>
                  raise Program_Error with
                    "task-result operation target attachment failed";
               when Subscription_Failure =>
                  raise Program_Error with
                    "task-result completion subscription failed";
               when Observation_Failure =>
                  raise Program_Error with
                    "task-result operation observation failed";
               when No_Failure =>
                  raise Program_Error with "task-result operation failed";
            end case;
      end case;
   end Finish;

   overriding procedure Finalize (Item : in out Monitor) is
   begin
      Detach (Item);
   end Finalize;

end Flyology.Task_Results;
