--  Internal, proved lifecycle decisions for structured servers. Task
--  creation, failure text, cancellation sources, and listener ownership stay
--  in the generic server implementation that consumes these decisions.
private package Flyology.Structured_Server_Policy
  with Preelaborate,
       SPARK_Mode
is
   type Run_Phase is (Idle, Serving, Stop_Requested, Finished);

   function Begin_Allowed
     (Phase         : Run_Phase;
      Serve_Started : Boolean) return Boolean
   with Post => Begin_Allowed'Result =
     (Phase = Idle
      or else (Phase = Stop_Requested and then not Serve_Started));

   function Phase_After_Begin (Phase : Run_Phase) return Run_Phase
   with Pre  => Phase in Idle | Stop_Requested,
        Post => Phase_After_Begin'Result =
          (if Phase = Idle then Serving else Stop_Requested);

   function Stop_Is_New (Phase : Run_Phase) return Boolean
   with Post => Stop_Is_New'Result = (Phase in Idle | Serving);

   function Phase_After_Stop (Phase : Run_Phase) return Run_Phase
   with Post => Phase_After_Stop'Result =
     (if Phase in Idle | Serving then Stop_Requested else Phase);

   function Stop_Was_Requested (Phase : Run_Phase) return Boolean
   with Post => Stop_Was_Requested'Result =
     (Phase in Stop_Requested | Finished);

   function Handler_Start_Allowed
     (Active   : Natural;
      Expected : Natural) return Boolean
   with Post => Handler_Start_Allowed'Result = (Active < Expected);

   function Worker_Finish_Allowed
     (Workers_Done : Natural;
      Expected     : Natural) return Boolean
   with Post => Worker_Finish_Allowed'Result = (Workers_Done < Expected);

   function Serve_Finish_Allowed
     (Workers_Done : Natural;
      Expected     : Natural;
      Active       : Natural) return Boolean
   with Post => Serve_Finish_Allowed'Result =
     (Workers_Done = Expected and then Active = 0);

   function Snapshot_Running
     (Serve_Started : Boolean;
      Phase         : Run_Phase) return Boolean
   with Post => Snapshot_Running'Result =
     (Serve_Started and then Phase in Serving | Stop_Requested);

   function Snapshot_Shutdown (Phase : Run_Phase) return Boolean
   with Post => Snapshot_Shutdown'Result =
     (Phase in Stop_Requested | Finished);
end Flyology.Structured_Server_Policy;
