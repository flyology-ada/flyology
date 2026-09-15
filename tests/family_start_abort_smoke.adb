with Ada.Command_Line;
with Ada.Real_Time;
with Flyology;
with Flyology.Supervision;
with Flyology.Supervision.Families;
with Flyology.Task_Lifecycle_Testing;

procedure Family_Start_Abort_Smoke is
   use Flyology.Supervision;
   use type Ada.Real_Time.Time;
   use type Flyology.Supervision.Generation;

   type Context is limited null record;

   procedure Run_Generation
     (State   : aliased in out Context;
      Input   : Positive;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result)
   is
      pragma Unreferenced (State, Input);
   begin
      Mark_Ready (Control);
      Result := (others => <>);
   end Run_Generation;

   Policy : constant Child_Specification :=
     (Restart           => Never,
      Impact            => Isolate_Child,
      Recovery          => Default_Recovery_Limits,
      Stopping          => Default_Stop_Policy,
      Readiness_Timeout => Ada.Real_Time.Seconds (1),
      Restart_Safe      => True,
      Task_Model        => Flyology.Native_Task,
      Has_Group         => False,
      Group             => 0);

   package Families is new
     Flyology.Supervision.Families
       (Request             => Positive,
        Application_Context => Context,
        Run_One_Generation  => Run_Generation,
        Policy              => Policy,
        First_Child_Id      => 42_000_000_000,
        Maximum_Children    => 1,
        Event_Capacity      => 8,
        Monitor_Capacity    => 1);

   package Testing renames Flyology.Task_Lifecycle_Testing;

   procedure Exercise
     (Committed, ATC : Boolean; Model : Flyology.Execution_Model; Close_During_Copy : Boolean := False)
   is
      State  : aliased Context;
      Item   : aliased Families.Family;
      Result : Supervisor_Result;
      Handle : Child_Handle;
      Point  : constant Testing.Barrier_Point :=
        (if Committed
         then Testing.Family_Start_Committed
         else Testing.Family_Start_Reserved);
      Copy_Rejected : Boolean := False with Atomic;

      protected Signal is
         entry Wait;
         procedure Send;
      private
         Sent : Boolean := False;
      end Signal;

      protected body Signal is
         entry Wait when Sent is
         begin
            null;
         end Wait;

         procedure Send is
         begin
            Sent := True;
         end Send;
      end Signal;

      task Owner is
         pragma Task_Info (Flyology.Native_Task);
         entry Start;
         entry Join;
      end Owner;

      task body Owner is
      begin
         accept Start;
         Families.Run (Item, State, Result);
         accept Join;
      end Owner;

      task Worker is
         pragma Task_Info (Model);
         entry Start;
      end Worker;

      task body Worker is
         Discard : Child_Handle;
      begin
         accept Start;
         if ATC then
            select
               Signal.Wait;
            then abort
               Families.Start (Item, 1, Discard);
            end select;
         else
            Families.Start (Item, 1, Discard);
         end if;
      exception
         when Program_Error =>
            if Close_During_Copy then
               Copy_Rejected := True;
            else
               raise;
            end if;
      end Worker;

      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      Testing.Reset;
      Testing.Arm (Testing.Family_Before_Take_Start);
      Owner.Start;
      Testing.Wait_Reached (Testing.Family_Before_Take_Start);
      Testing.Arm (Point);
      Worker.Start;
      Testing.Wait_Reached (Point);
      if Close_During_Copy then
         Families.Request_Shutdown (Item);
         Testing.Release (Point);
      elsif ATC then
         Signal.Send;
      else
         abort Worker;
      end if;
      --  Leave the barrier armed until interruption has finished; releasing it
      --  first could let an uncommitted Start complete instead of being aborted.
      while not Worker'Terminated loop
         if Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "interrupted Start did not terminate";
         end if;
         delay 0.001;
      end loop;
      Testing.Release (Point);

      if Close_During_Copy then
         if not Copy_Rejected then
            raise Program_Error with "closed admission did not reject the pending copy";
         end if;
      elsif Committed then
         --  The manager is still blocked. A committed generation must retain
         --  its queue entry and capacity even if Start never copied its handle out.
         declare
            Before   : constant Child_Snapshot :=
              Families.Current (Item, 42_000_000_000);
            Rejected : Boolean := False;
         begin
            begin
               Families.Start (Item, 2, Handle);
            exception
               when Constraint_Error =>
                  Rejected := True;
            end;
            if not Rejected
              or else Families.Current (Item, 42_000_000_000).Generation
                      /= Before.Generation
            then
               raise Program_Error
                 with "interruption rolled back a committed generation";
            end if;
         end;
      elsif Ada.Command_Line.Argument_Count = 0
        or else Ada.Command_Line.Argument (1) /= "shutdown"
      then
         --  The only slot must be available again, without resetting the family.
         Families.Start (Item, 2, Handle);
      end if;

      Families.Request_Shutdown (Item);
      Testing.Release (Testing.Family_Before_Take_Start);
      select
         Owner.Join;
      or
         delay 2.0;
         raise Program_Error
           with "interrupted Start prevented shutdown completion";
      end select;
      if Result.Outcome /= Shutdown_Completed then
         raise Program_Error with "interrupted Start changed shutdown outcome";
      end if;
      Testing.Reset;
   exception
      when others =>
         Testing.Reset;
         abort Worker;
         abort Owner;
         raise;
   end Exercise;
begin
   --  Separate baseline invocations demonstrate abort and ATC independently.
   for Lightweight in Boolean loop
      for ATC in Boolean loop
         if Ada.Command_Line.Argument_Count = 0
           or else Ada.Command_Line.Argument (1) = "shutdown"
           or else Ada.Command_Line.Argument (1)
                   = (if ATC then "atc" else "abort")
         then
            for Committed in Boolean loop
               Exercise
                 (Committed,
                  ATC,
                  (if Lightweight
                   then Flyology.Lightweight_Task
                   else Flyology.Native_Task));
            end loop;
         end if;
      end loop;
      if Ada.Command_Line.Argument_Count = 0 then
         Exercise
           (False,
            False,
            (if Lightweight then Flyology.Lightweight_Task else Flyology.Native_Task),
            Close_During_Copy => True);
      end if;
   end loop;
end Family_Start_Abort_Smoke;
