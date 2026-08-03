with Ada.Finalization;
with GNAT.Sockets;
with Flyology.IO.Connections;
with System.Multiprocessors;

--  Runs a bounded set of handler tasks under one structured Serve call.
--
--  Example:
--
--     Server_Instance.Serve (Server, Listener, Context);
--
--  @formal Handler_Context Shared handler state with caller-defined safety
--  @formal Handle Per-connection callback invoked by a handler task
--  @formal Handler_Model Fixed lightweight or native handler designation
--  @formal Handler_CPU CPU aspect applied to every handler task
generic
   --  State shared by every concurrent Handle call. Mutable state must provide
   --  its own synchronization.
   type Handler_Context (<>) is limited private;

   --  Process one admitted connection. Handle owns no connection lifetime and
   --  should observe Cancellation during CPU-only work.
   --  @param Context Shared instance supplied to Serve
   --  @param Connection Open connection owned by its handler task
   --  @param Peer Accepted peer address
   --  @param Cancellation One-shot server cancellation source
   with procedure Handle
     (Context      : in out Handler_Context;
      Connection   : in out Flyology.IO.Connections.Connection;
      Peer         : GNAT.Sockets.Sock_Addr_Type;
      Cancellation : not null access
        Flyology.IO.Connections.Cancellation_Token);

   --  Fixed task designation for all handlers in this generic instance.
   Handler_Model : Flyology.Execution_Model := Flyology.Project_Default;
   --  CPU aspect for handlers. For lightweight tasks, 0 .. 127 selects a
   --  shared execution group; for native tasks it retains Ada CPU affinity.
   Handler_CPU   : System.Multiprocessors.CPU_Range :=
     System.Multiprocessors.Not_A_Specific_CPU;

package Flyology.IO.Structured_Servers is

   --  Raised by Serve after one or more handler or admission failures.
   Server_Failed : exception;

   --  Source of the first recorded failure.
   --  @enum No_Failure No failure has been recorded
   --  @enum Handler_Callback Handle or connection cleanup failed
   --  @enum Admission_Loop Accept or handler bookkeeping failed
   type Failure_Origin is (No_Failure, Handler_Callback, Admission_Loop);

   --  Atomic lifecycle snapshot returned by Current.
   --  @field Running Serve is active or draining
   --  @field Shutdown_Requested Admission has been stopped
   --  @field Forced_Cancellation Drain timeout required handler cancellation
   --  @field Active_Handlers Handlers currently processing a connection
   --  @field Accepted_Connections Cumulative accepted connections, saturating
   --  at Natural'Last
   --  @field Completed_Connections Cumulative normal callback completions,
   --  saturating at Natural'Last
   --  @field Cancelled_Connections Cumulative cancelled callbacks, saturating
   --  at Natural'Last
   --  @field Failures Cumulative admission, callback, or cleanup failures
   --  @field First_Failure Origin of the first failure
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

   --  One-shot server object. Capacity is both the admission limit and the
   --  number of handler tasks created eagerly by Serve. Handler designation is
   --  fixed at activation and cannot change. Serve, Request_Shutdown, and
   --  Current coordinate through protected state, but only one Serve is valid.
   --  Keep the object alive until Serve returns.
   --  @field Capacity Handler task count and connection admission limit
   type Server (Capacity : Positive) is limited private;

   --  Take sole closing ownership of Listener, set it to No_Socket, and serve
   --  until shutdown or failure. Transient aborted admissions are retried and
   --  descriptor exhaustion backs off without becoming a recorded failure;
   --  structural listener errors still fail the server. The call returns only
   --  after all handler tasks terminate. Shutdown first stops admission.
   --  Infinite waits indefinitely; zero forces cancellation immediately;
   --  other values are seconds. One deadline covers the drain. Connection I/O
   --  wakes on cancellation, while
   --  CPU-only Handle code must poll Cancellation.Requested cooperatively.
   --  Lightweight handlers suspend on event-loop I/O; native handlers block
   --  their threads.
   --  @param Item One-shot server kept alive for the call
   --  @param Listener Bound listening socket; transferred and always closed
   --  @param Context Shared handler context kept alive for the call
   --  @param Drain_Timeout Grace period before forced cancellation
   --  @exception Program_Error Listener, lifecycle, or wake source is invalid
   --  @exception Server_Failed A handler or admission failure was recorded
   --  @exception GNAT.Sockets.Socket_Error Listener shutdown or close fails
   --  @exception Tasking_Error Handler task activation fails
   procedure Serve
     (Item          : aliased in out Server;
      Listener      : in out GNAT.Sockets.Socket_Type;
      Context       : aliased in out Handler_Context;
      Drain_Timeout : Duration := Infinite)
   with Pre => Drain_Timeout = Infinite or else Drain_Timeout >= 0.0;

   --  Idempotently stop new accepts. Active handlers drain according to the
   --  concurrent Serve call. Calling before Serve causes that call to take and
   --  close Listener without admitting connections.
   --  @param Item Server whose admission loop should stop
   --  @exception Program_Error The shutdown wake source cannot be signalled
   procedure Request_Shutdown (Item : in out Server);

   --  Read one protected lifecycle snapshot. Safe during Serve.
   --  @param Item Server to observe
   --  @return Current counters and lifecycle flags
   function Current (Item : Server) return Snapshot;

   --  Return retained information for the first failure, or an empty string.
   --  The text remains available after Serve raises Server_Failed.
   --  @param Item Server to inspect
   --  @return First failure information, truncated to 2,048 characters
   function First_Failure_Information (Item : Server) return String;

private
   use Flyology.IO.Connections;

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

   --  Request shutdown and cancellation if Item is still serving.
   --  @param Item Server being finalized
   overriding procedure Finalize (Item : in out Server);

end Flyology.IO.Structured_Servers;
