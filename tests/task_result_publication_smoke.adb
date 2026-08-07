with Ada.Text_IO;
with Fault_Control;
with Flyology;
with Flyology.Task_Results;
with System.Task_Info;

--  Terminal publication stores the task phase through the C atomic bridge and
--  Observe pairs that store with an acquire load. The pairing only holds when
--  the runtime actually asks for release ordering, so this test inspects the
--  memory order the bridge received rather than an incidental data race.
procedure Task_Result_Publication_Smoke is
   package Results renames Flyology.Task_Results;

   use type Results.Exit_Cause;
   use type Results.Observation_Status;

   function Model_Total return Natural is
      Total : Natural := 0;
   begin
      for Model in Fault_Control.Memory_Model loop
         Total := Total + Fault_Control.Atomic_Store_Model_Count (Model);
      end loop;
      return Total;
   end Model_Total;

   procedure Check_Only_Release_Stores (Context : String) is
      Release_Count : constant Natural :=
        Fault_Control.Atomic_Store_Model_Count (Fault_Control.Release);
   begin
      if Release_Count = 0 then
         raise Program_Error with
           Context & ": publication used no release store";
      end if;
      if Model_Total /= Release_Count then
         raise Program_Error with
           Context & ": atomic store used a memory order other than release";
      end if;
   end Check_Only_Release_Stores;

   generic
      Label : String;
      Model : System.Task_Info.Task_Info_Type;
   procedure Run_Lane;

   procedure Run_Lane is
      task type Subject is
         pragma Task_Info (Model);
      end Subject;

      task body Subject is
      begin
         null;
      end Subject;

      Observation : Results.Task_Observation;
   begin
      declare
         Item : Subject;
      begin
         Observation := Results.Wait (Item'Identity, Timeout => 5.0);
      end;
      if Observation.Status /= Results.Terminal
        or else Observation.Result.Cause /= Results.Normal_Completion
      then
         raise Program_Error with Label & " lane was not published";
      end if;
      Check_Only_Release_Stores (Label & " lane");
   end Run_Lane;

   procedure Run_Native is new Run_Lane
     (Label => "native", Model => Flyology.Native_Task);
   procedure Run_Lightweight is new Run_Lane
     (Label => "lightweight", Model => Flyology.Lightweight_Task);

begin
   if not Fault_Control.Enabled then
      raise Program_Error with
        "task-result publication test needs a fault-enabled runtime";
   end if;

   --  The native lane starts no event machinery, so the only atomic store the
   --  bridge sees in this window is the terminal publication itself.
   Fault_Control.Reset;
   Run_Native;

   Run_Lightweight;
   Check_Only_Release_Stores ("both lanes");

   Ada.Text_IO.Put_Line
     ("task result publication: terminal phase stores are release ordered");
end Task_Result_Publication_Smoke;
