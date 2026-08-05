package body Flyology.Structured_Server_Policy
  with SPARK_Mode
is
   procedure Consume_After_Close_Attempt
     (Value : in out Interfaces.C.int)
   is
   begin
      Value := -1;
   end Consume_After_Close_Attempt;

   function Begin_Allowed
     (Phase         : Run_Phase;
      Serve_Started : Boolean) return Boolean
   is
     (Phase = Idle
      or else (Phase = Stop_Requested and then not Serve_Started));

   function Phase_After_Begin (Phase : Run_Phase) return Run_Phase is
     (if Phase = Idle then Serving else Stop_Requested);

   function Stop_Is_New (Phase : Run_Phase) return Boolean is
     (Phase in Idle | Serving);

   function Phase_After_Stop (Phase : Run_Phase) return Run_Phase is
     (if Phase in Idle | Serving then Stop_Requested else Phase);

   function Stop_Was_Requested (Phase : Run_Phase) return Boolean is
     (Phase in Stop_Requested | Finished);

   function Handler_Start_Allowed
     (Active   : Natural;
      Expected : Natural) return Boolean
   is
     (Active < Expected);

   function Worker_Finish_Allowed
     (Workers_Done : Natural;
      Expected     : Natural) return Boolean
   is
     (Workers_Done < Expected);

   function Serve_Finish_Allowed
     (Workers_Done : Natural;
      Expected     : Natural;
      Active       : Natural) return Boolean
   is
     (Workers_Done = Expected and then Active = 0);

   function Snapshot_Running
     (Serve_Started : Boolean;
      Phase         : Run_Phase) return Boolean
   is
     (Serve_Started and then Phase in Serving | Stop_Requested);

   function Snapshot_Shutdown (Phase : Run_Phase) return Boolean is
     (Phase in Stop_Requested | Finished);
end Flyology.Structured_Server_Policy;
