private package Flyology.HTTP.Client_Policy
  with SPARK_Mode => On
is

   Maximum_Informational_Responses : constant Positive := 8;
   subtype Informational_Count is
     Natural range 0 .. Maximum_Informational_Responses;

   type Upload_Validation_Action is
     (Accept_Upload,
      Reject_Mixed_Body,
      Reject_Trailer_Framing,
      Reject_Empty_Expectation);

   function Validate_Upload
     (Has_Retained_Content : Boolean;
      Has_Source           : Boolean;
      Source_Length_Known  : Boolean;
      Source_Has_Content   : Boolean;
      Has_Trailers         : Boolean;
      Expect_Continue      : Boolean) return Upload_Validation_Action
   with
     Global         => null,
     Contract_Cases =>
       (Has_Retained_Content and then Has_Source =>
          Validate_Upload'Result = Reject_Mixed_Body,
        not (Has_Retained_Content and then Has_Source)
          and then Has_Trailers
          and then (not Has_Source or else Source_Length_Known) =>
            Validate_Upload'Result = Reject_Trailer_Framing,
        not (Has_Retained_Content and then Has_Source)
          and then
            not (Has_Trailers
                   and then (not Has_Source or else Source_Length_Known))
          and then Expect_Continue
          and then
            not (Has_Retained_Content
                   or else (Has_Source and then Source_Has_Content)) =>
            Validate_Upload'Result = Reject_Empty_Expectation,
        others => Validate_Upload'Result = Accept_Upload);

   subtype Body_Byte_Count is
     Long_Long_Integer range 0 .. Long_Long_Integer'Last;

   type Pull_Action is
     (Accept_Pull,
      Reject_No_Progress,
      Reject_Too_Long,
      Reject_Too_Short,
      Reject_Not_Finished);

   function Classify_Pull
     (Length_Known : Boolean;
      Produced     : Body_Byte_Count;
      Remaining    : Body_Byte_Count;
      Finished     : Boolean) return Pull_Action
   with
     Global => null,
     Pre    => not Length_Known or else Remaining > 0,
     Post =>
       Classify_Pull'Result =
         (if Produced = 0 and then not Finished then Reject_No_Progress
          elsif Length_Known and then Produced > Remaining
          then Reject_Too_Long
          elsif Length_Known
            and then Finished
            and then Produced < Remaining
          then Reject_Too_Short
          elsif Length_Known
            and then Produced = Remaining
            and then not Finished
          then Reject_Not_Finished
          else Accept_Pull)
       and then
         (if Classify_Pull'Result = Accept_Pull and then Length_Known
          then Produced <= Remaining
            and then (if Produced = Remaining then Finished));

   type Replay_Kind is
     (Direct_Replay, One_Shot_Stream, Rewindable_Stream);
   type Stale_Retry_Action is
     (Propagate_Failure, Retry_Directly, Rewind_And_Retry);
   subtype Retry_Attempt_Action is
     Stale_Retry_Action range Retry_Directly .. Rewind_And_Retry;

   function Classify_Stale_Retry
     (Replay          : Replay_Kind;
      Was_Reused      : Boolean;
      Already_Retried : Boolean;
      Idempotent      : Boolean;
      Saw_Response    : Boolean;
      Source_Failed   : Boolean;
      Time_Remains    : Boolean) return Stale_Retry_Action
   with
     Global         => null,
     Contract_Cases =>
       (not Was_Reused
          or else Already_Retried
          or else not Idempotent
          or else Saw_Response
          or else Source_Failed
          or else not Time_Remains =>
            Classify_Stale_Retry'Result = Propagate_Failure,
        Was_Reused
          and then not Already_Retried
          and then Idempotent
          and then not Saw_Response
          and then not Source_Failed
          and then Time_Remains
          and then Replay = One_Shot_Stream =>
            Classify_Stale_Retry'Result = Propagate_Failure,
        Was_Reused
          and then not Already_Retried
          and then Idempotent
          and then not Saw_Response
          and then not Source_Failed
          and then Time_Remains
          and then Replay = Direct_Replay =>
            Classify_Stale_Retry'Result = Retry_Directly,
        Was_Reused
          and then not Already_Retried
          and then Idempotent
          and then not Saw_Response
          and then not Source_Failed
          and then Time_Remains
          and then Replay = Rewindable_Stream =>
            Classify_Stale_Retry'Result = Rewind_And_Retry);

   type Informational_Action is
     (Accept_Continue,
      Accept_Other_Informational,
      Reject_Upgrade,
      Reject_Informational_Framing,
      Reject_Informational_Excess);

   function Classify_Informational
     (Status           : Status_Code;
      Has_Body_Framing : Boolean;
      Accepted         : Informational_Count) return Informational_Action
   with
     Global         => null,
     Pre            => Status in 100 .. 199,
     Contract_Cases =>
       (Status = 101 =>
          Classify_Informational'Result = Reject_Upgrade,
        Status /= 101 and then Has_Body_Framing =>
          Classify_Informational'Result = Reject_Informational_Framing,
        Status /= 101
          and then not Has_Body_Framing
          and then Accepted = Maximum_Informational_Responses =>
            Classify_Informational'Result = Reject_Informational_Excess,
        Status = 100
          and then not Has_Body_Framing
          and then Accepted < Maximum_Informational_Responses =>
            Classify_Informational'Result = Accept_Continue,
        (Status in 102 .. 199)
          and then not Has_Body_Framing
          and then Accepted < Maximum_Informational_Responses =>
            Classify_Informational'Result = Accept_Other_Informational);

   function Next_Informational_Count
     (Current : Informational_Count) return Informational_Count
   with
     Global => null,
     Pre    => Current < Maximum_Informational_Responses,
     Post   => Next_Informational_Count'Result = Current + 1;

   type Expectation_Response_Action is
     (Return_Response, Retry_Without_Expectation);

   function Classify_Expectation_Response
     (Expectation_Sent : Boolean;
      Body_Sent        : Boolean;
      Already_Retried  : Boolean;
      Status           : Status_Code;
      Attempt_Allowed  : Boolean) return Expectation_Response_Action
   with
     Global         => null,
     Contract_Cases =>
       (Expectation_Sent
          and then not Body_Sent
          and then not Already_Retried
          and then Status = 417
          and then Attempt_Allowed =>
            Classify_Expectation_Response'Result =
              Retry_Without_Expectation,
        others =>
          Classify_Expectation_Response'Result = Return_Response);

end Flyology.HTTP.Client_Policy;
