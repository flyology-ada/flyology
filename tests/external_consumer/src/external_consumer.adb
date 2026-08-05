with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Text_IO;
with Flyology;
with Flyology.Cancellation;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with Flyology.IO.Timers;
with Flyology.Native_Executors;
with Flyology.Observability;
with Flyology.Worker_Pools;

procedure External_Consumer is
   Marker_Error : exception;

   type Structured_Context is limited null record;

   procedure Handle_Structured_Connection
     (Context      : in out Structured_Context;
      Connection   : in out Flyology.IO.Connections.Connection;
      Peer         : Flyology.IO.Sockets.Endpoint;
      Cancellation : not null access
        Flyology.IO.Connections.Cancellation_Token)
   is
      pragma Unreferenced (Context, Connection, Peer, Cancellation);
   begin
      null;
   end Handle_Structured_Connection;

   --  The generic body is compiled under this consumer project's switches,
   --  which deliberately define no Flyology test-hook symbols.
   package Structured_Consumer is new Flyology.IO.Structured_Servers
     (Handler_Context => Structured_Context,
      Handle          => Handle_Structured_Connection);
   pragma Unreferenced (Structured_Consumer);

   type Worker_Context is limited null record;

   procedure Process_Job
     (Context  : in out Worker_Context;
      Job      : Integer;
      Stopping : not null access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Context, Job, Stopping);
   begin
      null;
   end Process_Job;

   package Worker_Consumer is new Flyology.Worker_Pools
     (Job_Type       => Integer,
      Empty_Job      => 0,
      Worker_Context => Worker_Context,
      Process        => Process_Job);
   pragma Unreferenced (Worker_Consumer);

   procedure Execute_Native
     (Input    : Integer;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Integer)
   is
      pragma Unreferenced (Token, Deadline);
   begin
      Result := Input;
   end Execute_Native;

   package Native_Consumer is new Flyology.Native_Executors
     (Input_Type  => Integer,
      Result_Type => Integer,
      Execute     => Execute_Native);
   pragma Unreferenced (Native_Consumer);

   Expected_Lightweight : constant Boolean :=
     Ada.Command_Line.Argument_Count = 1
     and then Ada.Command_Line.Argument (1) = "lightweight";

   protected Observation is
      procedure Report (Lightweight : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Observation;

   protected body Observation is
      procedure Report (Lightweight : Boolean) is
      begin
         OK := Lightweight = Expected_Lightweight;
         Done := True;
      end Report;

      entry Wait when Done is
      begin
         null;
      end Wait;

      function Passed return Boolean is (OK);
   end Observation;

   task type Default_Worker (Model : Flyology.Execution_Model) is
      pragma Task_Info (Model);
   end Default_Worker;

   task body Default_Worker is
   begin
      Flyology.IO.Timers.Sleep_For (0.001);
      Observation.Report (Flyology.IO.Is_Lightweight_Task);
   end Default_Worker;

   type Default_Worker_Access is access Default_Worker;
   Snapshot : Flyology.Observability.Group_Snapshot;

   procedure Check_Lightweight_Exception is
      protected Outcome is
         procedure Report (Passed : Boolean);
         entry Wait;
         function Passed return Boolean;
      private
         Done : Boolean := False;
         OK   : Boolean := False;
      end Outcome;

      protected body Outcome is
         procedure Report (Passed : Boolean) is
         begin
            OK := Passed;
            Done := True;
         end Report;

         entry Wait when Done is
         begin
            null;
         end Wait;

         function Passed return Boolean is (OK);
      end Outcome;

      procedure Raise_Marker is
      begin
         raise Marker_Error with "external lightweight traceback marker";
      end Raise_Marker;
      pragma No_Inline (Raise_Marker);

      task Worker is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Worker;

      task body Worker is
      begin
         delay 0.0;
         Raise_Marker;
         Outcome.Report (False);
      exception
         when Error : Marker_Error =>
            Outcome.Report
              (Ada.Exceptions.Exception_Message (Error) =
                 "external lightweight traceback marker");
         when others =>
            Outcome.Report (False);
      end Worker;
   begin
      Outcome.Wait;
      if not Outcome.Passed then
         raise Program_Error with
           "external lightweight symbolic traceback failed";
      end if;
   end Check_Lightweight_Exception;
begin
   if Ada.Command_Line.Argument_Count /= 1
     or else
       (Ada.Command_Line.Argument (1) /= "native"
        and then Ada.Command_Line.Argument (1) /= "lightweight")
   then
      raise Program_Error with "expected native or lightweight argument";
   end if;

   if Flyology.IO.Is_Lightweight_Task then
      raise Program_Error with "environment task became lightweight";
   end if;

   if Flyology.Observability.Snapshot (0, Snapshot) then
      raise Program_Error with "event loop started before opt-in";
   end if;

   Check_Lightweight_Exception;

   declare
      Worker : constant Default_Worker_Access :=
        new Default_Worker (Flyology.Project_Default);
      pragma Unreferenced (Worker);
   begin
      Observation.Wait;
   end;

   if not Observation.Passed then
      raise Program_Error with "prepared project default was not honored";
   end if;

   if not Flyology.Observability.Snapshot (0, Snapshot) then
      raise Program_Error with "explicit lightweight task started no runtime";
   end if;

   Ada.Text_IO.Put_Line
     ("external Alire consumer: " & Ada.Command_Line.Argument (1) & " passed");
end External_Consumer;
