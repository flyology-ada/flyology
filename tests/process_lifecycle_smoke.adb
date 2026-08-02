with Ada.Command_Line;
with Ada.Directories;
with Flyology;
with Flyology.Process_Lifecycle;
with Interfaces.C;
with Interfaces.C.Strings;
with System;

procedure Process_Lifecycle_Smoke is
   package C renames Interfaces.C;
   package Lifecycle renames Flyology.Process_Lifecycle;

   use type C.int;
   use type Lifecycle.Event_Runtime_State;
   use type System.Address;

   function Current_Thread return System.Address;
   pragma Import (C, Current_Thread, "pthread_self");

   function Arm_Exit_Check (State, Groups : C.int) return C.int;
   pragma Import
     (C, Arm_Exit_Check, "flyology_test_arm_exit_check");

   function Signal_Thread (Thread : System.Address) return C.int;
   pragma Import (C, Signal_Thread, "flyology_test_signal_thread");

   function Fork_Exec
     (Program : Interfaces.C.Strings.chars_ptr) return C.int;
   pragma Import (C, Fork_Exec, "flyology_test_fork_exec");

   protected Result is
      procedure Set_Thread (Value : System.Address);
      entry Wait (Value : out System.Address);
   private
      Ready  : Boolean := False;
      Thread : System.Address := System.Null_Address;
   end Result;

   protected body Result is
      procedure Set_Thread (Value : System.Address) is
      begin
         Thread := Value;
         Ready := True;
      end Set_Thread;

      entry Wait (Value : out System.Address) when Ready is
      begin
         Value := Thread;
      end Wait;
   end Result;

   task Lightweight is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Lightweight;

   task body Lightweight is
   begin
      Result.Set_Thread (Current_Thread);
      delay 0.01;
   end Lightweight;

   Event_Thread : System.Address;
   Program      : Interfaces.C.Strings.chars_ptr;
begin
   --  The task is activated before the statement part, so the runtime must
   --  already have left Dormant by the time these checks execute.
   Result.Wait (Event_Thread);
   if Event_Thread = System.Null_Address
     or else Lifecycle.State /= Lifecycle.Running
     or else Lifecycle.Created_Groups /= 1
   then
      raise Program_Error with "event runtime did not enter running state";
   end if;

   if Signal_Thread (Event_Thread) /= 0 then
      raise Program_Error with "signal interrupted event-loop progress";
   end if;

   Program := Interfaces.C.Strings.New_String
     (Ada.Directories.Compose
        (Ada.Directories.Containing_Directory
           (Ada.Command_Line.Command_Name),
         "process_exec_child_smoke"));
   if Fork_Exec (Program) /= 0 then
      Interfaces.C.Strings.Free (Program);
      raise Program_Error with "fork/exec lifecycle contract failed";
   end if;
   Interfaces.C.Strings.Free (Program);

   if Arm_Exit_Check (3, 0) /= 0 then
      raise Program_Error with "cannot register process-exit lifecycle check";
   end if;
end Process_Lifecycle_Smoke;
