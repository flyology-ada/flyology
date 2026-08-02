with Flyology;
with Flyology.Execution_Groups;

procedure Loop_Thread_Placement_Smoke is
   package Groups renames Flyology.Execution_Groups;

   use type Groups.Group_Id;
   use type Groups.Loop_Thread_Placement;
   use type Groups.Placement_Configuration_Result;
   use type Groups.Placement_State;

   Test_Group      : constant Groups.Group_Id := 7;
   Dedicated_Group : constant Groups.Group_Id := 128;
   Kind            : Groups.Loop_Thread_Placement;
   Value           : Groups.Placement_Value;

   protected Result is
      procedure Set (Passed : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Result;

   protected body Result is
      procedure Set (Passed : Boolean) is
      begin
         OK := Passed;
         Done := True;
      end Set;

      entry Wait when Done is
      begin
         null;
      end Wait;

      function Passed return Boolean is (OK);
   end Result;

   task type Worker with CPU => 7 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Worker;

   task body Worker is
      Reserved : Groups.Dedicated_Group_Id;
      OK       : Boolean := True;
   begin
      OK := Groups.Current = Test_Group;
      if Kind = Groups.Strict_CPU then
         OK := OK and Groups.Current_Processor = Integer (Value);
      else
         OK := OK and Groups.Current_Processor = Groups.No_Processor;
      end if;
      Reserved := Groups.Create_Dedicated;
      OK := OK and Groups.Group_Id (Reserved) = Dedicated_Group;
      Groups.Migrate (Reserved);
      OK := OK
        and Groups.Loop_Thread_Status (Dedicated_Group).State = Groups.Applied;
      Groups.Migrate (Test_Group);
      Result.Set (OK);
   exception
      when others =>
         Result.Set (False);
   end Worker;

   type Worker_Access is access Worker;
   Item : Worker_Access;
   pragma Unreferenced (Item);

   Before : Groups.Placement_Status;
   After  : Groups.Placement_Status;
begin
   if not Groups.Placement_Supported (Groups.No_Placement)
     or else Groups.Configure_Loop_Thread
       (Test_Group, Groups.No_Placement, 1) /= Groups.Invalid_Value
   then
      raise Program_Error with "invalid neutral placement policy result";
   end if;

   if Groups.Placement_Supported (Groups.Strict_CPU) then
      Kind := Groups.Strict_CPU;
      Value := 0;
      while Value < 4_096
        and then not Groups.Placement_Value_Available (Kind, Value)
      loop
         Value := Value + 1;
      end loop;
      if Value = 4_096 then
         raise Program_Error with "no available Linux processor";
      end if;
      if Groups.Placement_Supported (Groups.Advisory_Tag)
        or else Groups.Configure_Loop_Thread
          (1, Groups.Advisory_Tag, 1) /= Groups.Unsupported
        or else Groups.Placement_Value_Available
          (Kind, Groups.Placement_Value'Last)
      then
         raise Program_Error with "Linux placement capabilities are wrong";
      end if;
   elsif Groups.Placement_Supported (Groups.Advisory_Tag) then
      Kind := Groups.Advisory_Tag;
      Value := 42;
      if Groups.Placement_Supported (Groups.Strict_CPU)
        or else Groups.Configure_Loop_Thread
          (1, Groups.Strict_CPU, 0) /= Groups.Unsupported
        or else Groups.Placement_Value_Available (Kind, 0)
      then
         raise Program_Error with "Darwin placement capabilities are wrong";
      end if;
   else
      if Groups.Configure_Loop_Thread
          (1, Groups.Strict_CPU, 0) /= Groups.Unsupported
        or else Groups.Configure_Loop_Thread
          (1, Groups.Advisory_Tag, 1) /= Groups.Unsupported
      then
         raise Program_Error with "unsupported host accepted loop placement";
      end if;
      return;
   end if;

   Before := Groups.Loop_Thread_Status (Test_Group);
   if Before.State /= Groups.Not_Requested
     or else Groups.Configure_Loop_Thread (Test_Group, Kind, Value) /=
       Groups.Configured
     or else Groups.Configure_Loop_Thread (Test_Group, Kind, Value) /=
       Groups.Unchanged
     or else Groups.Configure_Loop_Thread (Dedicated_Group, Kind, Value) /=
       Groups.Configured
     or else Groups.Loop_Thread_Status (Test_Group).State /=
       Groups.Pending_Startup
   then
      raise Program_Error with "pre-start placement configuration failed";
   end if;

   begin
      Item := new Worker;
   exception
      when others =>
         After := Groups.Loop_Thread_Status (Test_Group);
         raise Program_Error with
           "loop startup failed: state=" & After.State'Image
           & " error=" & After.Error_Code'Image;
   end;
   Result.Wait;
   After := Groups.Loop_Thread_Status (Test_Group);
   if not Result.Passed
     or else After.Kind /= Kind
     or else After.Value /= Value
     or else After.State /= Groups.Applied
     or else After.Error_Code /= 0
     or else Groups.Configure_Loop_Thread (Test_Group, Kind, Value + 1) /=
       Groups.Group_Already_Started
     or else Groups.Configure_Loop_Thread
       (Test_Group, Groups.No_Placement) /= Groups.Group_Already_Started
   then
      raise Program_Error with "applied loop placement did not remain stable";
   end if;

   declare
      Race_Group : constant Groups.Group_Id := 8;

      protected Race is
         entry Start;
         procedure Release;
         procedure Configuration
           (Outcome : Groups.Placement_Configuration_Result);
         procedure Activation (Passed : Boolean);
         entry Wait;
         function Passed (State : Groups.Placement_State) return Boolean;
      private
         Released       : Boolean := False;
         Reports        : Natural := 0;
         Configure_Won  : Boolean := False;
         Configure_Lost : Boolean := False;
         Activation_OK  : Boolean := False;
      end Race;

      protected body Race is
         entry Start when Released is
         begin
            null;
         end Start;

         procedure Release is
         begin
            Released := True;
         end Release;

         procedure Configuration
           (Outcome : Groups.Placement_Configuration_Result)
         is
         begin
            Configure_Won := Outcome = Groups.Configured;
            Configure_Lost := Outcome = Groups.Group_Already_Started;
            Reports := Reports + 1;
         end Configuration;

         procedure Activation (Passed : Boolean) is
         begin
            Activation_OK := Passed;
            Reports := Reports + 1;
         end Activation;

         entry Wait when Reports = 2 is
         begin
            null;
         end Wait;

         function Passed (State : Groups.Placement_State) return Boolean is
         begin
            return Activation_OK
              and then
                ((Configure_Won and then State = Groups.Applied)
                 or else
                   (Configure_Lost
                    and then State = Groups.Not_Requested));
         end Passed;
      end Race;

      task Configurer is
         pragma Task_Info (Flyology.Native_Task);
      end Configurer;

      task body Configurer is
      begin
         Race.Start;
         Race.Configuration
           (Groups.Configure_Loop_Thread (Race_Group, Kind, Value));
      exception
         when others =>
            Race.Configuration (Groups.Runtime_Unavailable);
      end Configurer;

      task Starter is
         pragma Task_Info (Flyology.Native_Task);
      end Starter;

      task body Starter is
         task type Lightweight with CPU => 8 is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Lightweight;
         task body Lightweight is
         begin
            null;
         end Lightweight;
         type Lightweight_Access is access Lightweight;
         Lightweight_Item : Lightweight_Access;
         pragma Unreferenced (Lightweight_Item);
      begin
         Race.Start;
         Lightweight_Item := new Lightweight;
         Race.Activation (True);
      exception
         when others =>
            Race.Activation (False);
      end Starter;
   begin
      Race.Release;
      Race.Wait;
      if not Race.Passed (Groups.Loop_Thread_Status (Race_Group).State) then
         raise Program_Error with "placement/startup race was not atomic";
      end if;
   end;
end Loop_Thread_Placement_Smoke;
