--  Internal, proved classification of poll and nonblocking-I/O results.
--
--  Example: `Action := Classify (Result, Errno, EINTR);`
with Interfaces.C;

private package Flyology.Wait_Policy
  with Preelaborate, SPARK_Mode
is
   package C renames Interfaces.C;

   use type C.int;

   type Poll_Action is (Return_Ready, Return_Timeout, Retry, Fail);
   type Error_Action is (Wait_For_Ready, Retry_Operation, Fail_Operation);
   type Accept_Error_Action is
     (Wait_For_Connection, Retry_Accept, Retry_Transient, Backoff_Descriptor_Pressure, Fail_Accept);

   function Classify (Result : C.int; Error_Code : C.int; Interrupted_Error : C.int) return Poll_Action
   with
     Post =>
       (if Result > 0
        then Classify'Result = Return_Ready
        elsif Result = 0
        then Classify'Result = Return_Timeout
        elsif Error_Code = Interrupted_Error
        then Classify'Result = Retry
        else Classify'Result = Fail);

   function Classify_Error
     (Error_Code : C.int; Would_Block_Error : C.int; Interrupted_Error : C.int) return Error_Action
   with
     Post =>
       (if Error_Code = Would_Block_Error
        then Classify_Error'Result = Wait_For_Ready
        elsif Error_Code = Interrupted_Error
        then Classify_Error'Result = Retry_Operation
        else Classify_Error'Result = Fail_Operation);

   function Classify_Accept_Error
     (Error_Code               : C.int;
      Would_Block_Error        : C.int;
      Interrupted_Error        : C.int;
      Connection_Aborted_Error : C.int;
      Protocol_Error           : C.int;
      Process_File_Limit_Error : C.int;
      System_File_Limit_Error  : C.int) return Accept_Error_Action
   with
     Post =>
       (if Error_Code = Would_Block_Error
        then Classify_Accept_Error'Result = Wait_For_Connection
        elsif Error_Code = Interrupted_Error
        then Classify_Accept_Error'Result = Retry_Accept
        elsif Error_Code >= 0
          and then (Error_Code = Connection_Aborted_Error or else Error_Code = Protocol_Error)
        then Classify_Accept_Error'Result = Retry_Transient
        elsif Error_Code >= 0
          and then (Error_Code = Process_File_Limit_Error or else Error_Code = System_File_Limit_Error)
        then Classify_Accept_Error'Result = Backoff_Descriptor_Pressure
        else Classify_Accept_Error'Result = Fail_Accept);

end Flyology.Wait_Policy;
