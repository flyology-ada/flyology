--  A potentially blocking operation inside a protected action is an RM
--  9.5.1(8-18) bounded error. Flyology detects it in the lightweight lane,
--  because a suspended fiber keeps the object's pthread mutex held on its
--  event-loop thread and a same-group peer that contends for it would park the
--  only thread that could resume the holder. Native tasks keep GNAT's
--  undetected outcome, where the peer waits on the lock and then proceeds.
--
--  Flyology's own explicit migration is refused for the same reason and one
--  more: the mutex belongs to the source event-loop thread, so a migrated task
--  would later release it from a thread that does not own it.
with Ada.Exceptions;
with Ada.Real_Time;
with Flyology;
with Flyology.Execution_Groups;
with Flyology.Fairness;

procedure Protected_Action_Blocking_Smoke is
   use type Ada.Real_Time.Time;

   package Groups renames Flyology.Execution_Groups;

   use type Groups.Group_Id;

   --  The native holder stays inside its protected action for this long. Its
   --  peer contends far earlier, so the native lock wait is exercised rather
   --  than observed by coincidence.
   Hold_Span : constant Ada.Real_Time.Time_Span := Ada.Real_Time.Milliseconds (200);
   Peer_Lead : constant Ada.Real_Time.Time_Span := Ada.Real_Time.Milliseconds (20);

   --  Every lightweight task here is placed by its CPU aspect on Home_Group;
   --  Other_Group is a migration destination that no task of this test ever
   --  reaches.
   Home_CPU    : constant Groups.Group_Selecting_CPU := 1;
   Home_Group  : constant Groups.Group_Id := Groups.For_CPU (Home_CPU);
   Other_Group : constant Groups.Group_Id := 2;

   --  Which suspension point the holder reaches inside the protected action.
   --  Explicit_Migration names another group; Same_Group_Migration names the
   --  holder's own group, which outside a protected action is a no-op.
   type Suspension_Point is
     (Timed_Delay, Zero_Delay, Explicit_Yield, Explicit_Migration, Same_Group_Migration);

   --  The object under test. Hold deliberately suspends inside the protected
   --  action; Touch is the peer's external call on the same object.
   protected type Guarded_Object is
      procedure Hold (Point : Suspension_Point);
      procedure Touch;
      function Touches return Natural;
      function Left_Action_At return Ada.Real_Time.Time;
   private
      Count    : Natural := 0;
      Departed : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
   end Guarded_Object;

   --  Records what each participant observed. This object never carries a
   --  blocking protected action, so it stays usable in every case.
   protected Outcome is
      procedure Holder_Raised (Name : String);
      procedure Holder_Ran_On (Group : Groups.Group_Id);
      procedure Holder_Left_On (Group : Groups.Group_Id);
      procedure Peer_Ran_On (Group : Groups.Group_Id);
      procedure Peer_Completed (Attempted_At : Ada.Real_Time.Time);
      procedure Reset;
      function Exception_Name return String;
      function Holder_Group return Groups.Group_Id;
      function Holder_Final_Group return Groups.Group_Id;
      function Peer_Group return Groups.Group_Id;
      function Peer_Attempted_At return Ada.Real_Time.Time;
      function Peer_Finished return Boolean;
   private
      Name_Last    : Natural := 0;
      Raised_Name  : String (1 .. 64) := (others => ' ');
      Holder_On    : Groups.Group_Id := Groups.Group_Id'Last;
      Holder_Final : Groups.Group_Id := Groups.Group_Id'Last;
      Peer_On      : Groups.Group_Id := Groups.Group_Id'First;
      Attempt_Time : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Peer_Done    : Boolean := False;
   end Outcome;

   --  Releases the peer once the holder is about to enter its protected action.
   protected Gate is
      procedure Open;
      procedure Close;
      entry Wait;
   private
      Opened : Boolean := False;
   end Gate;

   protected body Guarded_Object is

      procedure Hold (Point : Suspension_Point) is
      begin
         --  The suspension below is the bounded error under test, so GNAT's
         --  syntactic diagnostic for it is expected and suppressed here only.
         --  The Migrate calls are not visible to that diagnostic at all.
         pragma Warnings (Off, "potentially blocking operation in protected operation");
         case Point is
            when Timed_Delay          =>
               delay Ada.Real_Time.To_Duration (Hold_Span);

            when Zero_Delay           =>
               delay 0.0;

            when Explicit_Yield       =>
               Flyology.Fairness.Yield_Now;

            when Explicit_Migration   =>
               Groups.Migrate (Other_Group);

            when Same_Group_Migration =>
               Groups.Migrate (Home_Group);
         end case;
         pragma Warnings (On, "potentially blocking operation in protected operation");
         Departed := Ada.Real_Time.Clock;
      end Hold;

      procedure Touch is
      begin
         Count := Count + 1;
      end Touch;

      function Touches return Natural
      is (Count);

      function Left_Action_At return Ada.Real_Time.Time
      is (Departed);

   end Guarded_Object;

   protected body Outcome is

      procedure Holder_Raised (Name : String) is
         Last : constant Natural := Natural'Min (Name'Length, Raised_Name'Length);
      begin
         Raised_Name (1 .. Last) := Name (Name'First .. Name'First + Last - 1);
         Name_Last := Last;
      end Holder_Raised;

      procedure Holder_Ran_On (Group : Groups.Group_Id) is
      begin
         Holder_On := Group;
      end Holder_Ran_On;

      procedure Holder_Left_On (Group : Groups.Group_Id) is
      begin
         Holder_Final := Group;
      end Holder_Left_On;

      procedure Peer_Ran_On (Group : Groups.Group_Id) is
      begin
         Peer_On := Group;
      end Peer_Ran_On;

      procedure Peer_Completed (Attempted_At : Ada.Real_Time.Time) is
      begin
         Attempt_Time := Attempted_At;
         Peer_Done := True;
      end Peer_Completed;

      procedure Reset is
      begin
         Name_Last := 0;
         Raised_Name := (others => ' ');
         Holder_On := Groups.Group_Id'Last;
         Holder_Final := Groups.Group_Id'Last;
         Peer_On := Groups.Group_Id'First;
         Attempt_Time := Ada.Real_Time.Time_First;
         Peer_Done := False;
      end Reset;

      function Exception_Name return String
      is (Raised_Name (1 .. Name_Last));

      function Holder_Group return Groups.Group_Id
      is (Holder_On);

      function Holder_Final_Group return Groups.Group_Id
      is (Holder_Final);

      function Peer_Group return Groups.Group_Id
      is (Peer_On);

      function Peer_Attempted_At return Ada.Real_Time.Time
      is (Attempt_Time);

      function Peer_Finished return Boolean
      is (Peer_Done);

   end Outcome;

   protected body Gate is

      procedure Open is
      begin
         Opened := True;
      end Open;

      procedure Close is
      begin
         Opened := False;
      end Close;

      entry Wait when Opened is
      begin
         null;
      end Wait;

   end Gate;

   --  One lightweight variant: the holder suspends inside the protected action
   --  while a same-group lightweight peer calls another operation of the same
   --  object.
   procedure Check_Lightweight (Point : Suspension_Point) is
      Object : Guarded_Object;
   begin
      Outcome.Reset;
      Gate.Close;

      declare
         task Holder
           with CPU => Home_CPU is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Holder;

         task Peer
           with CPU => Home_CPU is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Peer;

         task body Holder is
         begin
            Outcome.Holder_Ran_On (Groups.Current);
            Gate.Open;
            Object.Hold (Point);
         exception
            when Error : others =>
               Outcome.Holder_Raised (Ada.Exceptions.Exception_Name (Error));
               Outcome.Holder_Left_On (Groups.Current);
         end Holder;

         task body Peer is
         begin
            Outcome.Peer_Ran_On (Groups.Current);
            Gate.Wait;
            delay Ada.Real_Time.To_Duration (Peer_Lead);
            declare
               Attempted_At : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
            begin
               Object.Touch;
               Outcome.Peer_Completed (Attempted_At);
            end;
         end Peer;
      begin
         null;
      end;

      --  The holder detected the bounded error instead of deadlocking its
      --  execution group, and reported it as Program_Error.
      pragma Assert (Outcome.Exception_Name = "PROGRAM_ERROR");

      --  Both tasks shared one execution group, so a suspended holder would
      --  have parked the peer's event-loop thread too.
      pragma Assert (Outcome.Holder_Group = Home_Group);
      pragma Assert (Outcome.Holder_Group = Outcome.Peer_Group);

      --  The refusal preceded any movement: the holder handled the exception
      --  on the group it started on, so the lock it released was still owned
      --  by the thread that acquired it.
      pragma Assert (Outcome.Holder_Final_Group = Home_Group);

      --  The lock was released, so the peer's external call completed and the
      --  object counted it.
      pragma Assert (Outcome.Peer_Finished);
      pragma Assert (Object.Touches = 1);

      --  The environment task is always native. It would block on an orphaned
      --  mutex if the failed protected action had not been unwound.
      Object.Touch;
      pragma Assert (Object.Touches = 2);
   end Check_Lightweight;

   --  The native lane keeps stock GNAT behavior: neither task detects the
   --  bounded error. Expected names the exception the native holder observes
   --  from the operation itself, or is empty when the operation completes.
   --  When the operation keeps the holder inside the action for Hold_Span,
   --  the peer must also have contended before the holder left.
   procedure Check_Native (Point : Suspension_Point; Expected : String; Holds_For_Span : Boolean) is
      Object : Guarded_Object;
   begin
      Outcome.Reset;
      Gate.Close;

      declare
         task Holder is
            pragma Task_Info (Flyology.Native_Task);
         end Holder;

         task Peer is
            pragma Task_Info (Flyology.Native_Task);
         end Peer;

         task body Holder is
         begin
            Gate.Open;
            Object.Hold (Point);
         exception
            when Error : others =>
               Outcome.Holder_Raised (Ada.Exceptions.Exception_Name (Error));
         end Holder;

         task body Peer is
         begin
            Gate.Wait;
            delay Ada.Real_Time.To_Duration (Peer_Lead);
            declare
               Attempted_At : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
            begin
               Object.Touch;
               Outcome.Peer_Completed (Attempted_At);
            end;
         end Peer;
      begin
         null;
      end;

      --  The native holder saw exactly the operation's own outcome, never the
      --  lightweight lane's detection.
      pragma Assert (Outcome.Exception_Name = Expected);

      --  The peer waited on the lock and then proceeded; when the holder
      --  stayed inside the action, the peer contended before it left.
      pragma Assert (Outcome.Peer_Finished);
      if Holds_For_Span then
         pragma Assert (Outcome.Peer_Attempted_At < Object.Left_Action_At);
      end if;
      pragma Assert (Object.Touches = 1);

      Object.Touch;
      pragma Assert (Object.Touches = 2);
   end Check_Native;

begin
   for Point in Suspension_Point loop
      Check_Lightweight (Point);
   end loop;

   Check_Native (Timed_Delay, Expected => "", Holds_For_Span => True);

   --  A native task never migrates, so both migration variants keep raising
   --  the ordinary refusal inside a protected action as well.
   Check_Native
     (Explicit_Migration, Expected => "FLYOLOGY.EXECUTION_GROUPS.MIGRATION_ERROR", Holds_For_Span => False);
   Check_Native
     (Same_Group_Migration, Expected => "FLYOLOGY.EXECUTION_GROUPS.MIGRATION_ERROR", Holds_For_Span => False);
end Protected_Action_Blocking_Smoke;
