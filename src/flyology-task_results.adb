with Ada.Unchecked_Conversion;
with Interfaces.C;
with Flyology.Time_Math;

package body Flyology.Task_Results is
   package C renames Interfaces.C;

   use type C.int;
   use type C.size_t;
   use type C.unsigned;

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

end Flyology.Task_Results;
