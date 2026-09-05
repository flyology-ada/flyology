--  A potentially blocking operation inside a protected action is an RM
--  9.5.1(8-18) bounded error. Flyology detects it in the lightweight lane,
--  because a suspended fiber keeps the object's pthread mutex held on its
--  event-loop thread and a same-group peer that contends for it would park the
--  only thread that could resume the holder. Native tasks keep GNAT's
--  undetected outcome, where the peer waits on the lock and then proceeds.
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

   --  Which suspension point the holder reaches inside the protected action.
   type Suspension_Point is (Timed_Delay, Zero_Delay, Explicit_Yield);

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
      procedure Peer_Ran_On (Group : Groups.Group_Id);
      procedure Peer_Completed (Attempted_At : Ada.Real_Time.Time);
      procedure Reset;
      function Exception_Name return String;
      function Holder_Group return Groups.Group_Id;
      function Peer_Group return Groups.Group_Id;
      function Peer_Attempted_At return Ada.Real_Time.Time;
      function Peer_Finished return Boolean;
   private
      Name_Last    : Natural := 0;
      Raised_Name  : String (1 .. 64) := (others => ' ');
      Holder_On    : Groups.Group_Id := Groups.Group_Id'Last;
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
         pragma Warnings (Off, "potentially blocking operation in protected operation");
         case Point is
            when Timed_Delay    =>
               delay Ada.Real_Time.To_Duration (Hold_Span);

            when Zero_Delay     =>
               delay 0.0;

            when Explicit_Yield =>
               Flyology.Fairness.Yield_Now;
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
         Peer_On := Groups.Group_Id'First;
         Attempt_Time := Ada.Real_Time.Time_First;
         Peer_Done := False;
      end Reset;

      function Exception_Name return String
      is (Raised_Name (1 .. Name_Last));

      function Holder_Group return Groups.Group_Id
      is (Holder_On);

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
           with CPU => 1 is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Holder;

         task Peer
           with CPU => 1 is
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
      pragma Assert (Outcome.Holder_Group = Outcome.Peer_Group);

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
   --  bounded error, so the peer waits on the lock and proceeds once the
   --  holder leaves the protected action.
   procedure Check_Native is
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
            Object.Hold (Timed_Delay);
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

      --  No exception: the native holder completed its protected action.
      pragma Assert (Outcome.Exception_Name = "");

      --  The peer contended while the holder was still inside the protected
      --  action, and its own call ran only after the holder left.
      pragma Assert (Outcome.Peer_Finished);
      pragma Assert (Outcome.Peer_Attempted_At < Object.Left_Action_At);
      pragma Assert (Object.Touches = 1);

      Object.Touch;
      pragma Assert (Object.Touches = 2);
   end Check_Native;

begin
   for Point in Suspension_Point loop
      Check_Lightweight (Point);
   end loop;

   Check_Native;
end Protected_Action_Blocking_Smoke;
