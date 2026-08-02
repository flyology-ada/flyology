with Interfaces.C;

private package Gnatevl.Wait_Policy
  with Preelaborate,
       SPARK_Mode
is
   package C renames Interfaces.C;

   use type C.int;

   type Poll_Action is (Return_Ready, Return_Timeout, Retry, Fail);
   type Error_Action is (Wait_For_Ready, Retry_Operation, Fail_Operation);

   function Classify
     (Result            : C.int;
      Error_Code        : C.int;
      Interrupted_Error : C.int) return Poll_Action
   with Post =>
     (if Result > 0 then
         Classify'Result = Return_Ready
      elsif Result = 0 then
         Classify'Result = Return_Timeout
      elsif Error_Code = Interrupted_Error then
         Classify'Result = Retry
      else
         Classify'Result = Fail);

   function Classify_Error
     (Error_Code        : C.int;
      Would_Block_Error : C.int;
      Interrupted_Error : C.int) return Error_Action
   with Post =>
     (if Error_Code = Would_Block_Error then
         Classify_Error'Result = Wait_For_Ready
      elsif Error_Code = Interrupted_Error then
         Classify_Error'Result = Retry_Operation
      else
         Classify_Error'Result = Fail_Operation);

end Gnatevl.Wait_Policy;
