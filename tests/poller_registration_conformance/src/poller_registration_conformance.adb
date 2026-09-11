with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Fault_Control;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology_TLA.Command_Line;
with Flyology_TLA.Replay;
with Flyology_TLA.Traces;
with Poller_Registration_Ownership_Model;

procedure Poller_Registration_Conformance is
   package Model renames Poller_Registration_Ownership_Model;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Strings.Unbounded;
   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Model.Input_Command_Type;

   Backlog_Count : constant Positive := 64;

   type Runner_Request_Kind is (Replacement_Run, Stop_Run);

   --  Strict duplicate validation retains decoded name bytes from every simultaneously open
   --  object. The deepest step needs root (23) + step (40) + expected (12) + state (327) = 402
   --  decoded name bytes; its 34 simultaneous members remain below the default object-name limit.
   Limits : constant Flyology_TLA.Traces.Load_Limits :=
     (Maximum_File_Bytes   => 1_000_000,
      Maximum_Steps        => 8,
      Maximum_JSON_Depth   => 32,
      Maximum_Object_Names => 256,
      Maximum_Name_Bytes   => 512,
      Maximum_String_Bytes => 4_096,
      Maximum_Value_Bytes  => 32_768);

   protected Observation is
      procedure Reset;
      procedure Note_First_Return;
      procedure Note_Second_Return;
      procedure Start_Replacement;
      procedure Note_Replacement_Ready;
      procedure Proceed_Replacement;
      procedure Note_Replacement_Return;
      procedure Stop_Runner;
      entry Await_Runner_Request (Request : out Runner_Request_Kind);
      function First_Returned return Boolean;
      function Second_Returned return Boolean;
      function Replacement_Ready return Boolean;
      function Replacement_May_Proceed return Boolean;
      function Replacement_Returned return Boolean;
      function Runner_Stopped return Boolean;
   private
      First_Done           : Boolean := False;
      Second_Done          : Boolean := False;
      Replacement_Request  : Boolean := False;
      Replacement_Is_Ready : Boolean := False;
      Replacement_Proceed  : Boolean := False;
      Replacement_Done     : Boolean := False;
      Stop                 : Boolean := False;
   end Observation;

   protected body Observation is
      procedure Reset is
      begin
         First_Done := False;
         Second_Done := False;
         Replacement_Request := False;
         Replacement_Is_Ready := False;
         Replacement_Proceed := False;
         Replacement_Done := False;
         Stop := False;
      end Reset;

      procedure Note_First_Return is
      begin
         First_Done := True;
      end Note_First_Return;

      procedure Note_Second_Return is
      begin
         Second_Done := True;
      end Note_Second_Return;

      procedure Start_Replacement is
      begin
         Replacement_Request := True;
      end Start_Replacement;

      procedure Note_Replacement_Ready is
      begin
         Replacement_Is_Ready := True;
      end Note_Replacement_Ready;

      procedure Proceed_Replacement is
      begin
         Replacement_Proceed := True;
      end Proceed_Replacement;

      procedure Note_Replacement_Return is
      begin
         Replacement_Done := True;
      end Note_Replacement_Return;

      procedure Stop_Runner is
      begin
         Stop := True;
      end Stop_Runner;

      entry Await_Runner_Request (Request : out Runner_Request_Kind) when Replacement_Request or Stop is
      begin
         if Stop then
            Request := Stop_Run;
         else
            Request := Replacement_Run;
         end if;
      end Await_Runner_Request;

      function First_Returned return Boolean
      is (First_Done);

      function Second_Returned return Boolean
      is (Second_Done);

      function Replacement_Ready return Boolean
      is (Replacement_Is_Ready);

      function Replacement_May_Proceed return Boolean
      is (Replacement_Proceed);

      function Replacement_Returned return Boolean
      is (Replacement_Done);

      function Runner_Stopped return Boolean
      is (Stop);
   end Observation;

   task type Backlog_Waiter (Descriptor : Flyology.IO.Descriptor) is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Priority (10);
   end Backlog_Waiter;

   task body Backlog_Waiter is
   begin
      if Flyology.IO.Wait (Descriptor, Flyology.IO.For_Read, Flyology.IO.Infinite) then
         null;
      end if;
   end Backlog_Waiter;

   type Backlog_Waiter_Access is access Backlog_Waiter;
   type Backlog_Waiter_Array is array (Positive range <>) of Backlog_Waiter_Access;
   subtype Backlog_Waiters is Backlog_Waiter_Array (1 .. Backlog_Count);

   task type Target_Waiter
     (First_Descriptor  : Flyology.IO.Descriptor;
      Second_Descriptor : Flyology.IO.Descriptor)
   is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Priority (25);
   end Target_Waiter;

   task body Target_Waiter is
   begin
      if Flyology.IO.Wait (First_Descriptor, Flyology.IO.For_Read, Flyology.IO.Infinite) then
         Observation.Note_First_Return;
         if Flyology.IO.Wait (Second_Descriptor, Flyology.IO.For_Read, Flyology.IO.Infinite) then
            Observation.Note_Second_Return;
         end if;
      end if;
   end Target_Waiter;

   type Target_Waiter_Access is access Target_Waiter;

   task type Runner (Replacement_Descriptor : Flyology.IO.Descriptor) is
      pragma Task_Info (Flyology.Lightweight_Task);
      pragma Priority (30);
   end Runner;

   task body Runner is
      Request : Runner_Request_Kind;
   begin
      Observation.Await_Runner_Request (Request);
      case Request is
         when Replacement_Run =>
            Observation.Note_Replacement_Ready;
            while not Observation.Replacement_May_Proceed and then not Observation.Runner_Stopped loop
               null;
            end loop;
            if not Observation.Runner_Stopped
              and then Flyology.IO.Wait (Replacement_Descriptor, Flyology.IO.For_Read, Flyology.IO.Infinite)
            then
               Observation.Note_Replacement_Return;
            end if;

         when Stop_Run        =>
            null;
      end case;
   end Runner;

   type Runner_Access is access Runner;
   type Socket_Array is array (Positive range <>) of Sockets.Socket_Type;
   subtype Backlog_Sockets is Socket_Array (1 .. Backlog_Count);

   function Initial_State return Model.State_Type
   is (Phase                      => Model.State_Phase_Idle,
       Group_Lock_Held            => True,
       Loop_Writer                => False,
       Foreign_Writer             => False,
       Pending_Cancels            => 0,
       Target_Cancel_Queued       => False,
       Target_Waiting             => False,
       Target_Runnable            => False,
       Target_Live                => True,
       Wait_Generation            => 0,
       Cancel_Generation          => 0,
       Delivery_Source            => Model.State_Delivery_Source_None,
       Progress_Wake              => False,
       Stale_Cancellation         => False,
       Target_Released            => False,
       Kernel_Interest_Armed      => False,
       Replacement_Ready          => False,
       Replacement_Waiting        => False,
       Replacement_Delivered      => False,
       Replacement_Arm_Attempted  => False,
       Replacement_Arm_Suppressed => False,
       Last_Action                => Model.State_Last_Action_Init);

   type Registration_Adapter is new Model.Adapter with record
      Current      : Model.State_Type := Initial_State;
      Victims      : Backlog_Sockets;
      Victim_Peers : Backlog_Sockets;
      Target       : Sockets.Socket_Type;
      Target_Peer  : Sockets.Socket_Type;
      Second       : Sockets.Socket_Type;
      Second_Peer  : Sockets.Socket_Type;
      Waiters      : Backlog_Waiters := [others => null];
      Target_Task  : Target_Waiter_Access := null;
      Loop_Runner  : Runner_Access := null;
   end record;

   overriding
   procedure Reset
     (Self     : in out Registration_Adapter;
      Observed : out Model.State_Type;
      Status   : out Flyology_TLA.Replay.Adapter_Outcome);

   overriding
   procedure Apply
     (Self         : in out Registration_Adapter;
      Index        : Positive;
      Action       : String;
      Role         : String;
      Input        : Model.Input_Type;
      Model_Source : String;
      Observed     : out Model.Outcome_Type;
      State        : out Model.State_Type;
      Status       : out Flyology_TLA.Replay.Adapter_Outcome);

   procedure Await (Condition : not null access function return Boolean; Failure : String) is
      Limit : constant Ada.Real_Time.Time := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (3);
   begin
      while not Condition.all loop
         if Ada.Real_Time.Clock >= Limit then
            raise Program_Error with Failure;
         end if;
         delay 0.001;
      end loop;
   end Await;

   procedure Cleanup (Self : in out Registration_Adapter) is
      Limit : Ada.Real_Time.Time;
   begin
      Fault_Control.Release_Poller_Translation;
      Fault_Control.Release_Descriptor_Cancel_Budget;
      Observation.Stop_Runner;
      if Self.Loop_Runner /= null and then not Self.Loop_Runner'Terminated then
         abort Self.Loop_Runner.all;
      end if;
      if Self.Target_Task /= null and then not Self.Target_Task'Terminated then
         abort Self.Target_Task.all;
      end if;
      for Item of Self.Waiters loop
         if Item /= null and then not Item'Terminated then
            abort Item.all;
         end if;
      end loop;
      Limit := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (3);
      loop
         exit when
           (Self.Target_Task = null or else Self.Target_Task'Terminated)
           and then (Self.Loop_Runner = null or else Self.Loop_Runner'Terminated);
         exit when Ada.Real_Time.Clock >= Limit;
         delay 0.001;
      end loop;
      for Index in Self.Victims'Range loop
         if Sockets.Is_Open (Self.Victims (Index)) then
            Sockets.Close_Socket (Self.Victims (Index));
         end if;
         if Sockets.Is_Open (Self.Victim_Peers (Index)) then
            Sockets.Close_Socket (Self.Victim_Peers (Index));
         end if;
      end loop;
      if Sockets.Is_Open (Self.Target) then
         Sockets.Close_Socket (Self.Target);
      end if;
      if Sockets.Is_Open (Self.Target_Peer) then
         Sockets.Close_Socket (Self.Target_Peer);
      end if;
      if Sockets.Is_Open (Self.Second) then
         Sockets.Close_Socket (Self.Second);
      end if;
      if Sockets.Is_Open (Self.Second_Peer) then
         Sockets.Close_Socket (Self.Second_Peer);
      end if;
      Fault_Control.Reset;
   end Cleanup;

   procedure Reset
     (Self     : in out Registration_Adapter;
      Observed : out Model.State_Type;
      Status   : out Flyology_TLA.Replay.Adapter_Outcome) is
   begin
      if Self.Target_Task /= null or else Self.Loop_Runner /= null then
         Cleanup (Self);
      end if;
      Self.Current := Initial_State;
      Observed := Self.Current;
      Status := (Succeeded => True, Detail => Null_Unbounded_String);
   end Reset;

   procedure Apply
     (Self         : in out Registration_Adapter;
      Index        : Positive;
      Action       : String;
      Role         : String;
      Input        : Model.Input_Type;
      Model_Source : String;
      Observed     : out Model.Outcome_Type;
      State        : out Model.State_Type;
      Status       : out Flyology_TLA.Replay.Adapter_Outcome)
   is
      function All_Registered return Boolean
      is (Fault_Control.Calls (Fault_Control.Poller_Watch) >= Backlog_Count + 1);

      function Translation_Parked return Boolean
      is (Fault_Control.Poller_Translation_Parked);

      function All_Cancels_Queued return Boolean
      is (Fault_Control.Descriptor_Cancel_Queued_Count = Backlog_Count + 1);

      function Budget_Parked return Boolean
      is (Fault_Control.Descriptor_Cancel_Budget_Parked);

      function Replacement_Ready return Boolean
      is (Observation.Replacement_Ready);

      function Replacement_Watch_Registered return Boolean
      is (Fault_Control.Calls (Fault_Control.Poller_Watch) >= Backlog_Count + 2);

      function Replacement_Returned return Boolean
      is (Observation.Replacement_Returned);

      function Runner_Terminated return Boolean
      is (Self.Loop_Runner /= null and then Self.Loop_Runner'Terminated);

      function Remaining_Cancel_Processed return Boolean
      is (Fault_Control.Descriptor_Cancel_Processed_Count = Backlog_Count + 1);

      function Target_Terminated return Boolean
      is (Self.Target_Task /= null and then Self.Target_Task'Terminated);

      function All_Terminated return Boolean is
      begin
         if not Target_Terminated then
            return False;
         end if;
         for Item of Self.Waiters loop
            if Item /= null and then not Item'Terminated then
               return False;
            end if;
         end loop;
         return True;
      end All_Terminated;

      procedure Set_Outcome is
      begin
         Observed :=
           (Pending               => Model.Outcome_Pending_Type (Self.Current.Pending_Cancels),
            Queued                => Self.Current.Target_Cancel_Queued,
            Foreign_Mutation      => Self.Current.Foreign_Writer,
            Target_Runnable       => Self.Current.Target_Runnable,
            Target_Released       => Self.Current.Target_Released,
            Kernel_Armed          => Self.Current.Kernel_Interest_Armed,
            Replacement_Waiting   => Self.Current.Replacement_Waiting,
            Replacement_Delivered => Self.Current.Replacement_Delivered,
            Arm_Suppressed        => Self.Current.Replacement_Arm_Suppressed);
      end Set_Outcome;

      procedure Fail (Detail : String) is
      begin
         Set_Outcome;
         State := Self.Current;
         Status := (Succeeded => False, Detail => To_Unbounded_String (Detail));
      end Fail;

      Payload : constant Ada.Streams.Stream_Element_Array := [1 => 73];
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      if Role /= "poller-registration" or else Action /= Model_Source then
         Fail ("unexpected trace metadata");
         return;
      end if;

      case Input.Command is
         when Model.Input_Command_Begin_Wait_Batch    =>
            if Index /= 1 or else Action /= "PollerRegistrationOwnership!BeginWaitBatch" then
               Fail ("unexpected BeginWaitBatch step");
               return;
            end if;
            Observation.Reset;
            Fault_Control.Reset;
            Fault_Control.Arm (Fault_Control.Poller_Translation_Pause);
            Fault_Control.Arm (Fault_Control.Descriptor_Cancel_Budget_Pause);
            for Socket_Index in Self.Victims'Range loop
               Sockets.Create_Socket_Pair (Self.Victims (Socket_Index), Self.Victim_Peers (Socket_Index));
            end loop;
            Sockets.Create_Socket_Pair (Self.Target, Self.Target_Peer);
            Sockets.Create_Socket_Pair (Self.Second, Self.Second_Peer);
            Self.Loop_Runner := new Runner (Sockets.Native_Descriptor (Self.Target));
            for Waiter_Index in Self.Waiters'Range loop
               Self.Waiters (Waiter_Index) :=
                 new Backlog_Waiter (Sockets.Native_Descriptor (Self.Victims (Waiter_Index)));
            end loop;
            Self.Target_Task :=
              new Target_Waiter
                    (Sockets.Native_Descriptor (Self.Target), Sockets.Native_Descriptor (Self.Second));
            Await (All_Registered'Access, "65 descriptor waiters did not reach the poller");
            Sockets.Send_Socket (Self.Target_Peer, Payload, Last);
            if Last /= Payload'Last then
               raise Program_Error with "readiness signal was short";
            end if;
            Await (Translation_Parked'Access, "event loop did not reach poller translation");
            Self.Current :=
              (Phase                      => Model.State_Phase_Translating,
               Group_Lock_Held            => False,
               Loop_Writer                => True,
               Foreign_Writer             => False,
               Pending_Cancels            => 0,
               Target_Cancel_Queued       => False,
               Target_Waiting             => True,
               Target_Runnable            => False,
               Target_Live                => True,
               Wait_Generation            => 1,
               Cancel_Generation          => 0,
               Delivery_Source            => Model.State_Delivery_Source_Readiness,
               Progress_Wake              => False,
               Stale_Cancellation         => False,
               Target_Released            => False,
               Kernel_Interest_Armed      => True,
               Replacement_Ready          => False,
               Replacement_Waiting        => False,
               Replacement_Delivered      => False,
               Replacement_Arm_Attempted  => False,
               Replacement_Arm_Suppressed => False,
               Last_Action                => Model.State_Last_Action_Begin_Wait_Batch);

         when Model.Input_Command_Foreign_Wake        =>
            if Index /= 2 or else Action /= "PollerRegistrationOwnership!ForeignWake" then
               Fail ("unexpected ForeignWake step");
               return;
            end if;
            for Item of Self.Waiters loop
               abort Item.all;
            end loop;
            abort Self.Target_Task.all;
            Await (All_Cancels_Queued'Access, "foreign wakes did not queue all cancellations");
            Self.Current.Foreign_Writer := Fault_Control.Poller_Cancel_During_Translation_Count /= 0;
            Self.Current.Pending_Cancels := 65;
            Self.Current.Target_Cancel_Queued := True;
            Self.Current.Target_Waiting := True;
            Self.Current.Cancel_Generation := 1;
            Self.Current.Progress_Wake := True;
            Self.Current.Last_Action := Model.State_Last_Action_Foreign_Wake;

         when Model.Input_Command_Drain_Budget        =>
            if Index /= 3 or else Action /= "PollerRegistrationOwnership!DrainBudget" then
               Fail ("unexpected DrainBudget step");
               return;
            end if;
            --  Ready the lightweight runner while poller translation is
            --  paused with the group lock released. The later budget pause
            --  holds that lock, so its release path must not perform a
            --  protected wake that tries to acquire the same lock.
            Observation.Start_Replacement;
            Fault_Control.Release_Poller_Translation;
            Await (Budget_Parked'Access, "event loop did not stop after cancellation budget");
            if Fault_Control.Descriptor_Cancel_Processed_Count /= Backlog_Count then
               Fail ("bounded drain did not process exactly 64 cancellations");
               return;
            end if;
            Self.Current.Phase := Model.State_Phase_Budget_Drained;
            Self.Current.Group_Lock_Held := True;
            Self.Current.Loop_Writer := False;
            Self.Current.Pending_Cancels := 1;
            Self.Current.Kernel_Interest_Armed := False;
            Self.Current.Last_Action := Model.State_Last_Action_Drain_Budget;

         when Model.Input_Command_Deliver_Target      =>
            if Index /= 4 or else Action /= "PollerRegistrationOwnership!DeliverTarget" then
               Fail ("unexpected DeliverTarget step");
               return;
            end if;
            Fault_Control.Release_Descriptor_Cancel_Budget;
            Await (Replacement_Ready'Access, "ready replacement did not run after retained readiness");
            if Fault_Control.Descriptor_Cancel_Processed_Count /= Backlog_Count then
               Fail ("remaining cancellation drained before replacement dispatch");
               return;
            end if;
            Self.Current.Phase := Model.State_Phase_Selected_Retained;
            Self.Current.Replacement_Ready := True;
            Self.Current.Last_Action := Model.State_Last_Action_Deliver_Target;

         when Model.Input_Command_Start_Replacement   =>
            if Index /= 5 or else Action /= "PollerRegistrationOwnership!StartReplacement" then
               Fail ("unexpected StartReplacement step");
               return;
            end if;
            Observation.Proceed_Replacement;
            Await
              (Replacement_Watch_Registered'Access, "replacement wait did not rearm the consumed one-shot");
            Self.Current.Phase := Model.State_Phase_Replacement_Waiting;
            Self.Current.Kernel_Interest_Armed := True;
            Self.Current.Replacement_Ready := False;
            Self.Current.Replacement_Waiting := True;
            Self.Current.Replacement_Arm_Attempted := True;
            Self.Current.Replacement_Arm_Suppressed := False;
            Self.Current.Last_Action := Model.State_Last_Action_Start_Replacement;

         when Model.Input_Command_Drain_Remaining     =>
            if Index /= 6 or else Action /= "PollerRegistrationOwnership!DrainRemaining" then
               Fail ("unexpected DrainRemaining step");
               return;
            end if;
            Await
              (Remaining_Cancel_Processed'Access, "event loop did not consume the remaining cancellation");
            Await (All_Terminated'Access, "descriptor waiters did not terminate");
            Self.Current.Phase := Model.State_Phase_Replacement_Drained;
            Self.Current.Pending_Cancels := 0;
            Self.Current.Target_Cancel_Queued := False;
            Self.Current.Target_Waiting := False;
            Self.Current.Target_Runnable := True;
            Self.Current.Progress_Wake := False;
            Self.Current.Target_Released := Target_Terminated;
            Self.Current.Last_Action := Model.State_Last_Action_Drain_Remaining;
            if Fault_Control.Poller_Cancel_During_Translation_Count /= 0
              or else Fault_Control.Descriptor_Cancel_Processed_Count /= Backlog_Count + 1
              or else Observation.First_Returned
              or else Observation.Second_Returned
            then
               Fail ("runtime violated cancellation ownership after the bounded drain");
               return;
            end if;

         when Model.Input_Command_Deliver_Replacement =>
            if Index /= 7 or else Action /= "PollerRegistrationOwnership!DeliverReplacement" then
               Fail ("unexpected DeliverReplacement step");
               return;
            end if;
            Await (Replacement_Returned'Access, "replacement waiter did not receive retained readiness");
            Observation.Stop_Runner;
            Await (Runner_Terminated'Access, "replacement runner did not terminate");
            Self.Current.Phase := Model.State_Phase_Done;
            Self.Current.Replacement_Waiting := False;
            Self.Current.Replacement_Delivered := True;
            Self.Current.Last_Action := Model.State_Last_Action_Deliver_Replacement;
      end case;

      Set_Outcome;
      State := Self.Current;
      Status := (Succeeded => True, Detail => Null_Unbounded_String);
      if Index = 7 then
         Cleanup (Self);
      end if;
   exception
      when Error : others =>
         Cleanup (Self);
         Observed :=
           (Pending               => 0,
            Queued                => False,
            Foreign_Mutation      => True,
            Target_Runnable       => False,
            Target_Released       => False,
            Kernel_Armed          => False,
            Replacement_Waiting   => False,
            Replacement_Delivered => False,
            Arm_Suppressed        => True);
         State := Self.Current;
         Status :=
           (Succeeded => False, Detail => To_Unbounded_String (Ada.Exceptions.Exception_Information (Error)));
   end Apply;

begin
   if not Fault_Control.Enabled then
      raise Program_Error with "poller conformance requires FLYOLOGY_TEST_FAULTS=1 runtime";
   end if;
   declare
      Config : Flyology_TLA.Command_Line.Configuration := Flyology_TLA.Command_Line.Parse (Limits);
   begin
      if Flyology_TLA.Command_Line.Help_Requested (Config) then
         Flyology_TLA.Command_Line.Put_Help;
         return;
      end if;
      declare
         Trace   : constant Flyology_TLA.Traces.Trace := Flyology_TLA.Command_Line.Load (Config);
         Adapter : Registration_Adapter;
         Result  : Flyology_TLA.Replay.Replay_Result;
      begin
         Model.Run (Adapter, Trace, Flyology_TLA.Command_Line.Limits (Config), Result);
         Flyology_TLA.Command_Line.Report (Config, Result);
         Flyology_TLA.Command_Line.Set_Exit_Status (Result);
      end;
   end;
exception
   when Error : Flyology_TLA.Command_Line.Usage_Error =>
      Flyology_TLA.Command_Line.Fail (Ada.Exceptions.Exception_Message (Error), Show_Help => True);
   when Error : others =>
      Flyology_TLA.Command_Line.Fail (Ada.Exceptions.Exception_Information (Error));
end Poller_Registration_Conformance;
