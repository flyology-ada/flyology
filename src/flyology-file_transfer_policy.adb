package body Flyology.File_Transfer_Policy
  with SPARK_Mode
is
   function Classify
     (Status              : C.int;
      Transferred         : C.long_long;
      Error_Code          : C.int;
      Cancelled           : C.int;
      Limit               : C.long_long;
      Not_Supported_Error : C.int) return Completion_Action
   is
   begin
      if Status = 0
        and then Transferred > 0
        and then Transferred <= Limit
      then
         return Return_Progress;
      elsif Status = 0 and then Transferred > Limit then
         return Raise_Invalid_Completion;
      elsif Status = 0 and then Transferred <= 0 and then Cancelled /= 0 then
         return Raise_Cancelled;
      elsif Status = 0
        and then Transferred <= 0
        and then Cancelled = 0
        and then Error_Code = Not_Supported_Error
      then
         return Use_Buffered_Fallback;
      elsif Status = 0
        and then Transferred <= 0
        and then Cancelled = 0
        and then Error_Code /= 0
      then
         return Raise_Socket_Error;
      elsif Status = 1
        and then Transferred = 0
        and then Error_Code = 0
        and then Cancelled = 0
      then
         return Use_Buffered_Fallback;
      else
         return Raise_Invalid_Completion;
      end if;
   end Classify;

end Flyology.File_Transfer_Policy;
