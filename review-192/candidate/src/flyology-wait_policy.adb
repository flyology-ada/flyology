package body Flyology.Wait_Policy
  with SPARK_Mode
is
   function Classify (Result : C.int; Error_Code : C.int; Interrupted_Error : C.int) return Poll_Action is
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
     (Error_Code : C.int; Would_Block_Error : C.int; Interrupted_Error : C.int) return Error_Action is
   begin
      if Error_Code = Would_Block_Error then
         return Wait_For_Ready;
      elsif Error_Code = Interrupted_Error then
         return Retry_Operation;
      else
         return Fail_Operation;
      end if;
   end Classify_Error;

   function Classify_Accept_Error
     (Error_Code               : C.int;
      Would_Block_Error        : C.int;
      Interrupted_Error        : C.int;
      Connection_Aborted_Error : C.int;
      Protocol_Error           : C.int;
      Process_File_Limit_Error : C.int;
      System_File_Limit_Error  : C.int) return Accept_Error_Action is
   begin
      if Error_Code = Would_Block_Error then
         return Wait_For_Connection;
      elsif Error_Code = Interrupted_Error then
         return Retry_Accept;
      elsif Error_Code >= 0
        and then (Error_Code = Connection_Aborted_Error or else Error_Code = Protocol_Error)
      then
         return Retry_Transient;
      elsif Error_Code >= 0
        and then (Error_Code = Process_File_Limit_Error or else Error_Code = System_File_Limit_Error)
      then
         return Backoff_Descriptor_Pressure;
      else
         return Fail_Accept;
      end if;
   end Classify_Accept_Error;

end Flyology.Wait_Policy;
