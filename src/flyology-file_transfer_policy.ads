with Interfaces.C;

--  Internal, proved classification of lightweight file-transfer completions.
--  Positive progress is deliberately classified before cancellation because
--  those bytes have already been accepted by the socket and cannot be
--  retracted safely.
private package Flyology.File_Transfer_Policy
  with Preelaborate,
       SPARK_Mode
is
   package C renames Interfaces.C;

   use type C.int;
   use type C.long_long;

   type Completion_Action is
     (Return_Progress,
      Raise_Cancelled,
      Use_Buffered_Fallback,
      Raise_Socket_Error,
      Raise_Invalid_Completion);

   function Classify
     (Status              : C.int;
      Transferred         : C.long_long;
      Error_Code          : C.int;
      Cancelled           : C.int;
      Limit               : C.long_long;
      Not_Supported_Error : C.int) return Completion_Action
   with Pre => Limit > 0,
        Global => null,
        Contract_Cases =>
          (Status = 0
             and then Transferred > 0
             and then Transferred <= Limit =>
             Classify'Result = Return_Progress,
           Status = 0 and then Transferred > Limit =>
             Classify'Result = Raise_Invalid_Completion,
           Status = 0
             and then Transferred <= 0
             and then Cancelled /= 0 =>
             Classify'Result = Raise_Cancelled,
           Status = 0
             and then Transferred <= 0
             and then Cancelled = 0
             and then Error_Code = Not_Supported_Error =>
             Classify'Result = Use_Buffered_Fallback,
           Status = 0
             and then Transferred <= 0
             and then Cancelled = 0
             and then Error_Code /= 0
             and then Error_Code /= Not_Supported_Error =>
             Classify'Result = Raise_Socket_Error,
           Status = 1
             and then Transferred = 0
             and then Error_Code = 0
             and then Cancelled = 0 =>
             Classify'Result = Use_Buffered_Fallback,
           others =>
             Classify'Result = Raise_Invalid_Completion);

end Flyology.File_Transfer_Policy;
