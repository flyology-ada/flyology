with Interfaces.C;

--  Internal, proved lifecycle and ownership decisions for structured servers.
--  Task creation, failure text, cancellation sources, and system calls stay in
--  the generic server implementation that consumes these decisions.
private package Flyology.Structured_Server_Policy
  with Preelaborate,
       SPARK_Mode
is
   --  @exclude Internal proof policy, not part of the public API.

   use type Interfaces.C.int;

   --  Consume the listener descriptor token after one close attempt returns.
   --  This transition neither models close(2) nor interprets its result.
   --  @param Value Descriptor token whose closing ownership is consumed
   procedure Consume_After_Close_Attempt
     (Value : in out Interfaces.C.int)
   with Global => null,
        Pre    => Value /= Interfaces.C.int (-1),
        Post   => Value = Interfaces.C.int (-1);

   --  Lifecycle phase of one structured server invocation.
   --  @enum Idle Serve has not started
   --  @enum Serving Serve is admitting or draining connections
   --  @enum Stop_Requested Admission has stopped and handlers may be draining
   --  @enum Finished Serve reached its terminal state
   type Run_Phase is (Idle, Serving, Stop_Requested, Finished);

   --  Decide whether the one permitted Serve call may begin.
   --  @param Phase Current lifecycle phase
   --  @param Serve_Started Whether Serve has begun before
   --  @return True when Serve may begin
   function Begin_Allowed
     (Phase         : Run_Phase;
      Serve_Started : Boolean) return Boolean
   with Post => Begin_Allowed'Result =
     (Phase = Idle
      or else (Phase = Stop_Requested and then not Serve_Started));

   --  Select the lifecycle phase entered when Serve begins.
   --  @param Phase Idle or a shutdown requested before Serve
   --  @return Serving unless shutdown was already requested
   function Phase_After_Begin (Phase : Run_Phase) return Run_Phase
   with Pre  => Phase in Idle | Stop_Requested,
        Post => Phase_After_Begin'Result =
          (if Phase = Idle then Serving else Stop_Requested);

   --  Decide whether a shutdown request introduces a new state transition.
   --  @param Phase Current lifecycle phase
   --  @return True before shutdown has already been requested or completed
   function Stop_Is_New (Phase : Run_Phase) return Boolean
   with Post => Stop_Is_New'Result = (Phase in Idle | Serving);

   --  Select the lifecycle phase after a shutdown request.
   --  @param Phase Current lifecycle phase
   --  @return Stop_Requested from an active phase, otherwise Phase
   function Phase_After_Stop (Phase : Run_Phase) return Run_Phase
   with Post => Phase_After_Stop'Result =
     (if Phase in Idle | Serving then Stop_Requested else Phase);

   --  Report whether shutdown was requested during this lifecycle.
   --  @param Phase Current lifecycle phase
   --  @return True after a shutdown request, including the terminal phase
   function Stop_Was_Requested (Phase : Run_Phase) return Boolean
   with Post => Stop_Was_Requested'Result =
     (Phase in Stop_Requested | Finished);

   --  Check that starting another handler remains within capacity.
   --  @param Active Number of handlers currently active
   --  @param Expected Configured handler capacity
   --  @return True when another handler may start
   function Handler_Start_Allowed
     (Active   : Natural;
      Expected : Natural) return Boolean
   with Post => Handler_Start_Allowed'Result = (Active < Expected);

   --  Check that recording another worker completion remains within capacity.
   --  @param Workers_Done Number of workers already completed
   --  @param Expected Number of workers created for Serve
   --  @return True when another worker completion may be recorded
   function Worker_Finish_Allowed
     (Workers_Done : Natural;
      Expected     : Natural) return Boolean
   with Post => Worker_Finish_Allowed'Result = (Workers_Done < Expected);

   --  Check that Serve may enter its terminal phase.
   --  @param Workers_Done Number of workers completed
   --  @param Expected Number of workers created for Serve
   --  @param Active Number of handlers still processing connections
   --  @return True when every worker is done and no handler remains active
   function Serve_Finish_Allowed
     (Workers_Done : Natural;
      Expected     : Natural;
      Active       : Natural) return Boolean
   with Post => Serve_Finish_Allowed'Result =
     (Workers_Done = Expected and then Active = 0);

   --  Derive the Running field of a public server snapshot.
   --  @param Serve_Started Whether Serve has begun
   --  @param Phase Current lifecycle phase
   --  @return True while an initiated Serve call is active or draining
   function Snapshot_Running
     (Serve_Started : Boolean;
      Phase         : Run_Phase) return Boolean
   with Post => Snapshot_Running'Result =
     (Serve_Started and then Phase in Serving | Stop_Requested);

   --  Publish admission readiness only while the server remains in its
   --  serving phase after every worker has activated.
   --  @param Phase Current lifecycle phase after worker startup
   --  @return True only while admission may begin
   function Accepting_After_Worker_Start
     (Phase : Run_Phase) return Boolean
   with Post => Accepting_After_Worker_Start'Result = (Phase = Serving);

   --  Derive exact current admission readiness. A retained internal flag is
   --  masked by phase so a concurrent stop is visible immediately.
   --  @param Was_Marked Whether worker activation completed
   --  @param Phase Current lifecycle phase
   --  @return True only after activation and before shutdown
   function Snapshot_Accepting
     (Was_Marked : Boolean;
      Phase      : Run_Phase) return Boolean
   with Post => Snapshot_Accepting'Result =
     (Was_Marked and then Phase = Serving);

   --  Derive the Shutdown_Requested field of a public server snapshot.
   --  @param Phase Current lifecycle phase
   --  @return True once shutdown has been requested
   function Snapshot_Shutdown (Phase : Run_Phase) return Boolean
   with Post => Snapshot_Shutdown'Result =
     (Phase in Stop_Requested | Finished);
end Flyology.Structured_Server_Policy;
