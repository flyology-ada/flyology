with Create_Race_Support;
with Fault_Control;
with Flyology;
with Flyology.Execution_Groups;
with System.Multiprocessors;

procedure Pool_Reduction_Claim_Smoke is
   package Groups renames Flyology.Execution_Groups;

   use type Groups.Group_Id;
   use type Groups.Pool_Reduction_Phase;
   use type Groups.Pool_Reduction_Request_Result;

   Target_Size : constant Groups.Loop_Pool_Size := 1;
   Grown_Size  : constant Groups.Loop_Pool_Size := 3;

   protected Seed_Result is
      procedure Report (Value : Groups.Group_Id);
      function Group return Groups.Group_Id;
   private
      Last_Group : Groups.Group_Id := Groups.Default_Group;
   end Seed_Result;

   protected body Seed_Result is
      procedure Report (Value : Groups.Group_Id) is
      begin
         Last_Group := Value;
      end Report;

      function Group return Groups.Group_Id
      is (Last_Group);
   end Seed_Result;

   task type Seed_Worker with CPU => System.Multiprocessors.Not_A_Specific_CPU is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Seed_Worker;

   task body Seed_Worker is
   begin
      Seed_Result.Report (Groups.Current);
   end Seed_Worker;

   Status        : Groups.Pool_Reduction_Status;
   Parked        : Boolean := False;
   Claimed_Group : Integer := -1;
   Racing_Group  : Integer := -1;
begin
   if not Fault_Control.Enabled then
      raise Program_Error with "pool reduction claim test requires FLYOLOGY_TEST_FAULTS=1 runtime";
   end if;

   Groups.Grow_Configured_Pool (Grown_Size);
   if Groups.Configured_Pool_Size /= Grown_Size then
      raise Program_Error with "automatic pool did not grow for claim test";
   end if;

   --  Consume enough deterministic round-robin tickets that the foreign
   --  automatic creator below selects a group outside Target_Size.
   declare
      Worker : Seed_Worker;
      pragma Unreferenced (Worker);
   begin
      null;
   end;
   if Seed_Result.Group = Groups.Group_Id (Grown_Size - 1) then
      declare
         Worker : Seed_Worker;
         pragma Unreferenced (Worker);
      begin
         null;
      end;
   end if;

   Fault_Control.Reset;
   Fault_Control.Arm (Fault_Control.Automatic_Placement_Window, Count => 1);
   if not Create_Race_Support.Start_Automatic_Racer then
      raise Program_Error with "cannot start automatic placement racer";
   end if;
   for Attempt in 1 .. 5_000 loop
      Parked := Fault_Control.Automatic_Placement_Parked;
      exit when Parked;
      delay 0.001;
   end loop;
   if not Parked then
      raise Program_Error with "automatic creator never reached the placement-claim window";
   end if;

   Claimed_Group := Fault_Control.Automatic_Placement_Claim_Group;
   if Claimed_Group < Integer (Target_Size) or else Claimed_Group >= Integer (Grown_Size) then
      raise Program_Error
        with "parked creator did not select a removed automatic group:" & Integer'Image (Claimed_Group);
   end if;

   if Groups.Request_Pool_Reduction (Target_Size) /= Groups.Reduction_Started then
      raise Program_Error with "claim-bearing reduction did not start";
   end if;
   Status := Groups.Pool_Reduction;
   if Status.Phase /= Groups.Draining
     or else Status.Automatic_Tasks /= 0
     or else Status.Placement_Claims /= 1
     or else not Fault_Control.Automatic_Placement_Parked
   then
      raise Program_Error
        with
          "pre-cutover placement claim was not retained: phase="
          & Groups.Pool_Reduction_Phase'Image (Status.Phase)
          & " automatic="
          & Natural'Image (Status.Automatic_Tasks)
          & " claims="
          & Natural'Image (Status.Placement_Claims)
          & " selected="
          & Integer'Image (Claimed_Group);
   end if;

   Fault_Control.Release_Automatic_Placement;
   for Attempt in 1 .. 5_000 loop
      Racing_Group := Create_Race_Support.Racer_Group;
      exit when Racing_Group >= 0;
      delay 0.001;
   end loop;
   Status := Groups.Pool_Reduction;
   if Racing_Group /= Integer (Groups.Default_Group)
     or else Status.Phase /= Groups.Drained
     or else Status.Automatic_Tasks /= 0
     or else Status.Placement_Claims /= 0
   then
      raise Program_Error with "released creator did not drain safely";
   end if;
exception
   when others =>
      Fault_Control.Release_Automatic_Placement;
      raise;
end Pool_Reduction_Claim_Smoke;
