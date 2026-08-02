with Ada.Finalization;
with GNAT.Sockets;
with Gnatevl.IO.Connections;
with System.Multiprocessors;

generic
   --  One Context object is shared by every concurrent Handle invocation and
   --  may also be observed by the Serve caller. Its mutable state must use
   --  protected operations, atomics, or another synchronization discipline.
   type Handler_Context (<>) is limited private;

   with procedure Handle
     (Context      : in out Handler_Context;
      Connection   : in out Gnatevl.IO.Connections.Connection;
      Peer         : GNAT.Sockets.Sock_Addr_Type;
      Cancellation : not null access
        Gnatevl.IO.Connections.Cancellation_Token);

   Handler_Model : Gnatevl.Execution_Model := Gnatevl.Project_Default;
   Handler_CPU   : System.Multiprocessors.CPU_Range :=
     System.Multiprocessors.Not_A_Specific_CPU;

package Gnatevl.IO.Structured_Servers is

   Server_Failed : exception;

   type Failure_Origin is (No_Failure, Handler_Callback, Admission_Loop);

   type Snapshot is record
      Running              : Boolean;
      Shutdown_Requested   : Boolean;
      Forced_Cancellation  : Boolean;
      Active_Handlers      : Natural;
      Accepted_Connections : Natural;
      Completed_Connections  : Natural;
      Cancelled_Connections  : Natural;
      Failures             : Natural;
      First_Failure        : Failure_Origin;
   end record;

   --  Capacity is both the maximum number of accepted connections and the
   --  eagerly created number of handler tasks, including while no connection
   --  is active. The handler task type is fixed by this generic instance: it
   --  is never converted between native and event-loop execution after
   --  activation. Handler_CPU uses the normal GNATEVL meaning: an explicit
   --  value selects an event group for evented handlers and retains stock Ada
   --  CPU semantics for native handlers; Not_A_Specific_CPU uses automatic
   --  event-loop pool placement or stock native placement.
   type Server (Capacity : Positive) is limited private;

   --  Take ownership of an already-bound, listening socket and serve until
   --  Request_Shutdown is called or a worker reports a failure. Listener is
   --  set to No_Socket after ownership transfers. The call is a structured
   --  task scope and does not return until every handler task has terminated.
   --
   --  Shutdown first stops admission and lets active handlers finish. If they
   --  have not drained after Drain_Timeout, their cancellation token and the
   --  connection manager are signalled. Infinite waits indefinitely; zero
   --  requests cancellation immediately. Cancellation is cooperative: a
   --  handler blocked in Gnatevl connection I/O wakes promptly, while
   --  arbitrary user CPU code must observe Cancellation.Requested itself.
   procedure Serve
     (Item          : aliased in out Server;
      Listener      : in out GNAT.Sockets.Socket_Type;
      Context       : aliased in out Handler_Context;
      Drain_Timeout : Duration := Infinite)
   with Pre => Drain_Timeout = Infinite or else Drain_Timeout >= 0.0;

   --  Idempotently stop new accepts. Active handlers are allowed to drain
   --  according to the Drain_Timeout of the concurrent Serve call.
   --  Requesting before the one allowed Serve call makes that call take and
   --  close the listener without admitting any connection.
   procedure Request_Shutdown (Item : in out Server);

   function Current (Item : Server) return Snapshot;

   --  Empty until a worker records a failure. The information is retained
   --  after Serve raises Server_Failed so callers can log it without keeping
   --  an exception occurrence whose lifetime is tied to a handler task.
   function First_Failure_Information (Item : Server) return String;

private
   use Gnatevl.IO.Connections;

   type Run_Phase is (Idle, Serving, Stop_Requested, Finished);

   protected type Lifecycle is
      procedure Begin_Serve (Expected : Positive);
      procedure Request_Stop (New_Request : out Boolean);
      entry Await_Stop;
      function Stop_Was_Requested return Boolean;

      procedure Handler_Started;
      procedure Handler_Completed
        (Cancelled : Boolean;
         Failed    : Boolean);
      procedure Worker_Finished;
      procedure Record_Failure
        (Origin      : Failure_Origin;
         Information : String);
      procedure Mark_Forced;
      procedure Finish_Serve;

      entry Await_All_Workers;
      function Read_Snapshot return Snapshot;
      function Failure_Information return String;
   private
      Phase                 : Run_Phase := Idle;
      Active                : Natural := 0;
      Accepted              : Natural := 0;
      Completed             : Natural := 0;
      Cancelled             : Natural := 0;
      Workers_Done          : Natural := 0;
      Expected_Workers      : Natural := 0;
      Failure_Total         : Natural := 0;
      Failure_Source        : Failure_Origin := No_Failure;
      Failure_Text_Length   : Natural := 0;
      Failure_Text          : String (1 .. 2_048) := (others => ' ');
      Forced                : Boolean := False;
   end Lifecycle;

   type Server (Capacity : Positive) is
     new Ada.Finalization.Limited_Controlled with record
      State       : Lifecycle;
      Accept_Stop : aliased Cancellation_Token;
      Handler_Stop : aliased Cancellation_Token;
   end record;

   overriding procedure Finalize (Item : in out Server);

end Gnatevl.IO.Structured_Servers;
