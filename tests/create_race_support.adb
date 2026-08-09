with Interfaces.C;
with System;
with System.Flyology.Scheduler;

package body Create_Race_Support is

   package C renames Interfaces.C;

   use type C.int;
   use type C.size_t;

   Racing_Stack_Bytes : constant C.size_t := 512 * 1_024;

   Not_Attempted : constant C.int := 1;
   --  Distinct from both scheduler results so the exit check can tell "never
   --  ran" apart from "refused".

   Racing_Key : aliased C.int := 0;
   --  Stands in for the racing task's control block. The scheduler uses this
   --  address only as a registry key. The finalize race never dispatches it;
   --  the automatic-placement race runs the null wrapper before finalization.

   Target_Group : C.int := 0;
   pragma Atomic (Target_Group);

   Outcome : C.int := Not_Attempted;
   pragma Atomic (Outcome);

   Observed_Group : C.int := -1;
   pragma Atomic (Observed_Group);

   procedure Racing_Wrapper (T : System.Address);
   pragma Convention (C, Racing_Wrapper);

   procedure Racing_Create;
   pragma Convention (C, Racing_Create);

   function Racing_Result return C.int;
   pragma Convention (C, Racing_Result);

   type Thread_Entry is access procedure;
   pragma Convention (C, Thread_Entry);

   type Result_Query is access function return C.int;
   pragma Convention (C, Result_Query);

   function C_Start_Racer (Entry_Point : Thread_Entry) return C.int;
   pragma Import (C, C_Start_Racer, "flyology_test_start_create_racer");

   function C_Arm_Exit_Check (Query : Result_Query) return C.int;
   pragma Import
     (C, C_Arm_Exit_Check, "flyology_test_arm_create_race_exit_check");

   function C_Creator_Parked return C.int;
   pragma Import (C, C_Creator_Parked, "flyology_test_create_race_parked");

   procedure Racing_Wrapper (T : System.Address) is
      pragma Unreferenced (T);
   begin
      Observed_Group := System.Flyology.Scheduler.Current_Group;
   end Racing_Wrapper;

   procedure Racing_Create is
   begin
      Outcome :=
        System.Flyology.Scheduler.Create
          (T          => Racing_Key'Address,
           Stack_Size => Racing_Stack_Bytes,
           Priority   => C.int (System.Default_Priority),
           Wrapper    => Racing_Wrapper'Address,
           Group      => Target_Group);
   end Racing_Create;

   function Racing_Result return C.int is (Outcome);

   procedure Record_Target_Group is
   begin
      Target_Group := System.Flyology.Scheduler.Current_Group;
   end Record_Target_Group;

   function Arm_Exit_Check return Boolean is
     (C_Arm_Exit_Check (Racing_Result'Access) = 0);

   function Start_Racer return Boolean is
     (C_Start_Racer (Racing_Create'Access) = 0);

   function Start_Automatic_Racer return Boolean is
   begin
      Target_Group := -1;
      Outcome := Not_Attempted;
      Observed_Group := -1;
      return C_Start_Racer (Racing_Create'Access) = 0;
   end Start_Automatic_Racer;

   function Racer_Group return Integer is (Integer (Observed_Group));

   function Creator_Parked return Boolean is (C_Creator_Parked /= 0);

end Create_Race_Support;
