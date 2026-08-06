package body Flyology.HTTP.Client_Policy
  with SPARK_Mode => On
is

   function Validate_Upload
     (Has_Retained_Content : Boolean;
      Has_Source           : Boolean;
      Source_Length_Known  : Boolean;
      Source_Has_Content   : Boolean;
      Has_Trailers         : Boolean;
      Expect_Continue      : Boolean) return Upload_Validation_Action
   is
     (if Has_Retained_Content and then Has_Source then Reject_Mixed_Body
      elsif Has_Trailers
        and then (not Has_Source or else Source_Length_Known)
      then Reject_Trailer_Framing
      elsif Expect_Continue
        and then
          not (Has_Retained_Content
                 or else (Has_Source and then Source_Has_Content))
      then Reject_Empty_Expectation
      else Accept_Upload);

   function Classify_Pull
     (Length_Known : Boolean;
      Produced     : Body_Byte_Count;
      Remaining    : Body_Byte_Count;
      Finished     : Boolean) return Pull_Action
   is
     (if Produced = 0 and then not Finished then Reject_No_Progress
      elsif Length_Known and then Produced > Remaining then Reject_Too_Long
      elsif Length_Known
        and then Finished
        and then Produced < Remaining
      then Reject_Too_Short
      elsif Length_Known
        and then Produced = Remaining
        and then not Finished
      then Reject_Not_Finished
      else Accept_Pull);

   function Classify_Stale_Retry
     (Replay          : Replay_Kind;
      Was_Reused      : Boolean;
      Already_Retried : Boolean;
      Idempotent      : Boolean;
      Saw_Response    : Boolean;
      Source_Failed   : Boolean;
      Time_Remains    : Boolean) return Stale_Retry_Action
   is
     (if not Was_Reused
        or else Already_Retried
        or else not Idempotent
        or else Saw_Response
        or else Source_Failed
        or else not Time_Remains
        or else Replay = One_Shot_Stream
      then Propagate_Failure
      elsif Replay = Direct_Replay then Retry_Directly
      else Rewind_And_Retry);

   function Classify_Informational
     (Status           : Status_Code;
      Has_Body_Framing : Boolean;
      Accepted         : Informational_Count) return Informational_Action
   is
     (if Status = 101 then Reject_Upgrade
      elsif Has_Body_Framing then Reject_Informational_Framing
      elsif Accepted = Maximum_Informational_Responses
      then Reject_Informational_Excess
      elsif Status = 100 then Accept_Continue
      else Accept_Other_Informational);

   function Next_Informational_Count
     (Current : Informational_Count) return Informational_Count is
     (Current + 1);

   function Classify_Expectation_Response
     (Expectation_Sent : Boolean;
      Body_Sent        : Boolean;
      Already_Retried  : Boolean;
      Status           : Status_Code;
      Attempt_Allowed  : Boolean) return Expectation_Response_Action
   is
     (if Expectation_Sent
        and then not Body_Sent
        and then not Already_Retried
        and then Status = 417
        and then Attempt_Allowed
      then Retry_Without_Expectation
      else Return_Response);

   function Classify_Redirect
     (Enabled         : Boolean;
      Has_Location    : Boolean;
      Status          : Status_Code;
      Method_Is_Post  : Boolean;
      Method_Is_Head  : Boolean) return Redirect_Action
   is
     (if not Enabled
        or else not Has_Location
        or else Status not in 301 | 302 | 303 | 307 | 308
      then Return_Redirect_Response
      elsif Status = 303 and then Method_Is_Head
      then Follow_As_Head
      elsif Status = 303
        or else (Status in 301 | 302 and then Method_Is_Post)
      then Follow_As_Get
      else Follow_Preserving_Method);

end Flyology.HTTP.Client_Policy;
