package body Flyology.Wait_Policy
  with SPARK_Mode
is
   function Classify
     (Result            : C.int;
      Error_Code        : C.int;
      Interrupted_Error : C.int) return Poll_Action
   is
   begin
      if Result > 0 then
         return Return_Ready;
      elsif Result = 0 then
         return Return_Timeout;
      elsif Error_Code = Interrupted_Error then
         return Retry;
      else
         return Fail;
      end if;
   end Classify;

   function Classify_Error
     (Error_Code        : C.int;
      Would_Block_Error : C.int;
      Interrupted_Error : C.int) return Error_Action
   is
   begin
      if Error_Code = Would_Block_Error then
         return Wait_For_Ready;
      elsif Error_Code = Interrupted_Error then
         return Retry_Operation;
      else
         return Fail_Operation;
      end if;
   end Classify_Error;

end Flyology.Wait_Policy;
