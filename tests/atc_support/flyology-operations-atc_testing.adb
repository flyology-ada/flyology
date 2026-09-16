with Ada.Exceptions;
with Ada.Text_IO; use Ada.Text_IO;
with Flyology.IO.Timers;
with Flyology.Operations.Drivers;
with System.Task_Primitives.Operations;

package body Flyology.Operations.ATC_Testing is
   package Timers renames Flyology.IO.Timers;
   package Drivers renames Flyology.Operations.Drivers;
   use type Interfaces.Unsigned_32;

   protected Cleanup is
      procedure Note;
      function Count return Natural;
   private
      Total : Natural := 0;
   end Cleanup;
   protected body Cleanup is
      procedure Note is
      begin
         Total := Total + 1;
      end Note;
      function Count return Natural is
      begin
         return Total;
      end Count;
   end Cleanup;

   protected type Boundary is
      entry Trigger;
      procedure Arm;
      function Completed return Boolean;
   private
      Armed : Boolean := False;
      Fired : Boolean := False;
   end Boundary;

   protected body Boundary is
      entry Trigger when Armed is
      begin
         Fired := True;
      end Trigger;
      procedure Arm is
      begin
         Armed := True;
      end Arm;
      function Completed return Boolean is
      begin
         return Fired;
      end Completed;
   end Boundary;

   type Test_Operation
     (Owner   : not null access Completion_Set'Class;
      Barrier : not null access Boundary)
   is new Operation (Owner) with record
      Child              : Timers.Timer_Operation (Owner);
      Composite          : Boolean := False;
      Throw              : Boolean := False;
      Entered            : Boolean := False;
      Returned           : Boolean := False;
      Rearm_First        : Boolean := False;
      Drive_Count        : Natural := 0;
      Log                : access Observation_Array := null;
      Gate_Slot          : Natural := 0;
      Transfer_Delivered : Boolean := False;
      Wait_Failed        : Boolean := False;
   end record;

   overriding
   procedure Drive (Item : in out Test_Operation; Event : Driver_Event);
   overriding
   procedure Request_Cancellation (Item : in out Test_Operation);

   procedure Capture (Item : Test_Operation; Index : Natural) is
      Set  : Completion_Set'Class renames Item.Owner.all;
      Root : Slot_Record renames Set.Slots (Operation_Id (Item.Slot));
      Gate : Slot_Record renames Set.Slots (Operation_Id (Item.Gate_Slot));

      function Result_Of (Slot : Slot_Record) return Observed_Outcome is
      begin
         if Slot.State /= Terminal then
            return No_Outcome;
         end if;
         case Slot.Result is
            when Succeeded =>
               return Success;

            when Cancelled =>
               return Cancelled_Outcome;

            when Failed    =>
               return Failed_Outcome;
         end case;
      end Result_Of;

      Child_State    : Observed_Child_State := Vacant;
      Child_Deadline : Boolean := False;
   begin
      if Item.Log = null then
         return;
      end if;
      if Item.Composite and then Is_Active (Item.Child) then
         Child_State := Pending;
         if Root.Child /= 0 then
            Child_Deadline :=
              Set.Slots (Operation_Id (Root.Child)).Has_Deadline;
         end if;
      elsif Item.Composite and then Is_Terminal (Item.Child) then
         Child_State := Terminal;
      end if;
      Item.Log (Index) :=
        (Reached         => True,
         Depth           => Set.Propagation_Batch_Depth,
         Stabilizing     => Set.Stabilizing_Dependents,
         Dirty           => Set.Dirty_Dependents /= 0,
         Source          =>
           (case Root.Source is
              when Immediate_Source  => Immediate,
              when Dependency_Source => Dependency,
              when others            => None),
         Deadline        => Root.Has_Deadline,
         Child           => Root.Child /= 0,
         Child_State     => Child_State,
         Child_Deadline  => Child_Deadline,
         Root_Terminal   => Root.State = Terminal,
         Gate_Terminal   => Gate.State = Terminal,
         Root_Outcome    => Result_Of (Root),
         Gate_Outcome    => Result_Of (Gate),
         Deferral        =>
           System.Task_Primitives.Operations.Self.Deferral_Level,
         Request_Pending =>
           Item.Barrier.Completed and then not Item.Transfer_Delivered,
         Delivered       => Item.Transfer_Delivered,
         Wait_Failed     => Item.Wait_Failed);
   end Capture;

   procedure Drive (Item : in out Test_Operation; Event : Driver_Event) is
      pragma Unreferenced (Event);
   begin
      Item.Entered := True;
      Item.Drive_Count := Item.Drive_Count + 1;
      if Item.Composite then
         Timers.Finish (Item.Child);
         Release (Item.Child);
      end if;
      if Item.Drive_Count = 1 then
         Capture (Item, 1);
      end if;
      if Item.Drive_Count = 1 then
         Item.Barrier.Arm;
         Capture (Item, 2);
      end if;
      Item.Returned := True;
      if Item.Throw then
         raise Constraint_Error with "ordinary exception control";
      end if;
      if Item.Rearm_First and then Item.Drive_Count = 1 then
         Drivers.Reschedule (Item);
      else
         Drivers.Complete (Item, Succeeded);
      end if;
      if Item.Drive_Count = 1 then
         Capture (Item, 3);
      end if;
   end Drive;

   procedure Request_Cancellation (Item : in out Test_Operation) is
   begin
      if Is_Active (Item.Child) then
         Cancel (Item.Child);
      end if;
      if Is_Terminal (Item.Child) then
         Consume (Item.Child);
         Release (Item.Child);
      end if;
      Cleanup.Note;
      Drivers.Complete (Item, Cancelled);
   end Request_Cancellation;

   procedure Run_Core (Scenario : String; Log : access Observation_Array) is
      Local_Log   : aliased Observation_Array;
      Set         : aliased Completion_Set (4);
      Barrier     : aliased Boundary;
      A           : aliased Test_Operation (Set'Access, Barrier'Access);
      Transferred : Boolean := False;
      Failed_Use  : Boolean := False;
   begin
      A.Composite :=
        Scenario = "stabilize"
        or else Scenario = "nested-stabilize"
        or else Scenario = "normal-stabilize"
        or else Scenario = "exception-stabilize";
      A.Rearm_First := Scenario = "rearm";
      A.Log := Local_Log'Unchecked_Access;
      A.Throw :=
        Scenario = "exception" or else Scenario = "exception-stabilize";
      Drivers.Start (A);
      if A.Composite then
         Timers.Sleep_For
           ((if Scenario = "stabilize" then 3_600.0 else 0.1), A.Child);
         Continue_After (A, A.Child);
      else
         Drivers.Reschedule (A);
      end if;
      declare
         G     : Gate_Operation :=
           Wait_For_Success (Set'Access, [Reference (A)]);
         Batch : Completion_Batch (4);
      begin
         A.Gate_Slot := G.Slot;
         Capture (A, 0);
         if Scenario = "batch"
           or else Scenario = "stabilize"
           or else Scenario = "nested-stabilize"
           or else Scenario = "rearm"
         then
            select
               Barrier.Trigger;
               Transferred := True;
            then abort
               if Scenario = "stabilize" then
                  --  Complete the child outside a wait batch. Its dependent
                  --  root runs under only Stabilize_Dependents' guard.
                  Drivers.Complete (A.Child, Succeeded);
               else
                  Wait_All (Set);
               end if;
            end select;
         else
            begin
               Wait_All (Set);
            exception
               when E : Constraint_Error =>
                  Put_Line
                    ("ordinary handler: "
                     & Ada.Exceptions.Exception_Message (E));
            end;
         end if;
         A.Transfer_Delivered := Transferred;
         Capture (A, 4);
         if Scenario = "rearm" then
            if Is_Terminal (A)
              or else Is_Terminal (G)
              or else Set.Slots (Operation_Id (A.Slot)).Source
                      /= Immediate_Source
            then
               raise Program_Error with "ATC lost the rearmed provider source";
            end if;
         end if;
         begin
            Wait_All (Set);
         exception
            when E : Operation_Error =>
               Failed_Use := True;
               Put_Line
                 ("surviving-set-use: "
                  & Ada.Exceptions.Exception_Message (E));
         end;
         A.Wait_Failed := Failed_Use;
         Capture (A, 5);
         if Scenario = "batch"
           or else Scenario = "stabilize"
           or else Scenario = "nested-stabilize"
           or else Scenario = "rearm"
         then
            if not Transferred
              or else not Barrier.Completed
              or else not A.Entered
            then
               raise Program_Error
                 with
                   "SETUP FAILURE: ATC missed requested owner drive boundary";
            elsif not A.Returned then
               raise Program_Error
                 with "ATC escaped before the owner driver returned";
            end if;
            if Failed_Use
              or else not Is_Terminal (G)
              or else Outcome (G) /= Succeeded
            then
               raise Program_Error
                 with "ATC left the surviving completion set inconsistent";
            end if;
            Cancel (A);
            Capture (A, 6);
            Finish (G, Batch);
            Consume (A);
            Drivers.Start (A);
            Drivers.Reschedule (A);
            A.Composite := False;
            Wait_All (Set);
            Consume (A);
            Put_Line
              ("PASS ATC retained a usable completion set and same-set restart");
         elsif Scenario = "exception" or else Scenario = "exception-stabilize"
         then
            if Set.Propagation_Batch_Depth /= 0
              or else Set.Stabilizing_Dependents
            then
               raise Program_Error
                 with "ordinary exception guard restoration failed";
            end if;
            Cancel (A);
            if not Is_Terminal (G) then
               raise Program_Error
                 with "ordinary exception propagation control failed";
            end if;
            Put_Line
              ("PASS ordinary exception restored guards and gate propagation");
         else
            if Failed_Use
              or else not Is_Terminal (G)
              or else Outcome (G) /= Succeeded
            then
               raise Program_Error with "normal completion control failed";
            end if;
            Finish (G, Batch);
            Consume (A);
            Drivers.Start (A);
            Drivers.Reschedule (A);
            A.Composite := False;
            Wait_All (Set);
            Consume (A);
            Put_Line ("PASS normal completion and same-set restart");
         end if;
      end;
      if Log /= null then
         Log.all := Local_Log;
      end if;
   end Run_Core;

   procedure Run (Scenario : String) is
   begin
      Run_Core (Scenario, null);
   end Run;

   procedure Run_Replay (Scenario : String; Observed : out Observation_Array)
   is
      Local : aliased Observation_Array;
   begin
      Run_Core (Scenario, Local'Access);
      Observed := Local;
   end Run_Replay;

   procedure Run_Abort is
      Before  : constant Natural := Cleanup.Count;
      Barrier : aliased Boundary;
   begin
      declare
         task Worker;
         task body Worker is
            Set : aliased Completion_Set (4);
            A   : aliased Test_Operation (Set'Access, Barrier'Access);
         begin
            Drivers.Start (A);
            Drivers.Arm_Deadline (A, 3_600.0);
            declare
               G : Gate_Operation :=
                 Wait_For_Success (Set'Access, [Reference (A)]);
            begin
               Barrier.Arm;
               Wait_All (Set);
               raise Program_Error
                 with "SETUP FAILURE: ordinary self-abort returned";
            end;
         end Worker;
      begin
         Barrier.Trigger;
         abort Worker;
      end;
      if Cleanup.Count /= Before + 1 then
         raise Program_Error
           with "ordinary abort failed exact-once cancellation cleanup";
      end if;
      Put_Line
        ("PASS ordinary task abort finalized pending provider exactly once and joined task master");
   end Run_Abort;
end Flyology.Operations.ATC_Testing;
