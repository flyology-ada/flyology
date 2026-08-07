package body Flyology.Worker_Pool_Policy
  with SPARK_Mode
is
   function Begin_Allowed (Begun : Boolean) return Boolean is (not Begun);

   function Teardown_Allowed (Claimed : Boolean) return Boolean is (Claimed);

   procedure Teardown_Closes_Join_Barrier (Workers_Done : Natural) is
      pragma Unreferenced (Workers_Done);
   begin
      null;
   end Teardown_Closes_Join_Barrier;

   function Job_Start_Allowed
     (Running  : Boolean;
      Active   : Natural;
      Expected : Natural) return Boolean
   is
     (Running and then Active < Expected);

   function Active_After_Start
     (Active   : Natural;
      Expected : Positive) return Positive
   is
     (Active + 1);

   function Job_Completion_Allowed (Active : Natural) return Boolean is
     (Active > 0);

   function Active_After_Completion (Active : Positive) return Natural is
     (Active - 1);

   function Classify_Completion
     (Cancelled : Boolean;
      Failed    : Boolean) return Completion_Action
   is
     (if Cancelled then Count_Cancelled
      elsif Failed then Count_Neither
      else Count_Completed);

   function Worker_Finish_Allowed
     (Running      : Boolean;
      Workers_Done : Natural;
      Expected     : Natural) return Boolean
   is
     (Running and then Workers_Done < Expected);

   function Workers_After_Finish
     (Workers_Done : Natural;
      Expected     : Positive) return Positive
   is
     (Workers_Done + 1);

   function All_Workers_Done
     (Workers_Done : Natural;
      Expected     : Natural) return Boolean
   is
     (Expected > 0 and then Workers_Done = Expected);

   function Finish_Allowed
     (Running      : Boolean;
      Active       : Natural;
      Workers_Done : Natural;
      Expected     : Natural) return Boolean
   is
     (Running
      and then Active = 0
      and then Expected > 0
      and then Workers_Done = Expected);
end Flyology.Worker_Pool_Policy;
