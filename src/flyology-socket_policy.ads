with Interfaces.C;

--  Internal, proved classification of socket ABI values and operation errors.
--
--  The operating-system constants remain inputs supplied by the C boundary;
--  this package proves every decision made from those values.
private package Flyology.Socket_Policy
  with Preelaborate,
       SPARK_Mode => On
is
   package C renames Interfaces.C;

   use type C.int;

   type Error_Kind is
     (Success,
      Would_Block,
      Interrupted,
      In_Progress,
      Already_In_Progress,
      Already_Connected,
      No_Buffer_Space,
      Other_Error);

   type IO_Error_Action is (Wait_For_Ready, Retry_Operation, Fail_Operation);
   Immediate_IO_Retry_Limit : constant Positive := 16;

   function Retry_IO_Immediately (Attempt : Positive) return Boolean
   with
     Global => null,
     Post =>
       Retry_IO_Immediately'Result =
         (Attempt < Immediate_IO_Retry_Limit);
   type Connect_Error_Action is (Wait_For_Connection, Connected, Fail_Connect);
   type Post_Accept_Failure_Stage is
     (Peer_Address_Decode, Descriptor_Configuration);
   type Post_Accept_Failure_Action is
     (Fail_Listener, Discard_Accepted_Peer);
   type Received_Address_Action is
     (Use_Endpoint, Use_No_Endpoint, Fail_Receive);

   function Family_Code (IPv6 : Boolean) return C.int
   with
     Global => null,
     Post => Family_Code'Result = (if IPv6 then 6 else 4);

   function Mode_Code (Datagram : Boolean) return C.int
   with
     Global => null,
     Post => Mode_Code'Result = (if Datagram then 2 else 1);

   function Should_Enable_Datagram_Metadata
     (Mode : C.int) return Boolean
   with
     Global => null,
     Post => Should_Enable_Datagram_Metadata'Result = (Mode = 2);

   function Classify_Post_Accept_Failure
     (Stage : Post_Accept_Failure_Stage) return Post_Accept_Failure_Action
   with
     Global => null,
     Contract_Cases =>
       (Stage = Peer_Address_Decode =>
          Classify_Post_Accept_Failure'Result = Fail_Listener,
        Stage = Descriptor_Configuration =>
          Classify_Post_Accept_Failure'Result = Discard_Accepted_Peer);

   function Classify_Received_Address
     (Address_Present          : Boolean;
      Decode_Succeeded         : Boolean;
      Decode_Error             : C.int;
      Unsupported_Family_Error : C.int) return Received_Address_Action
   with
     Global => null,
     Contract_Cases =>
       (not Address_Present =>
          Classify_Received_Address'Result = Use_No_Endpoint,
        Address_Present and then Decode_Succeeded =>
          Classify_Received_Address'Result = Use_Endpoint,
        Address_Present and then not Decode_Succeeded
          and then Decode_Error = Unsupported_Family_Error =>
            Classify_Received_Address'Result = Use_No_Endpoint,
        others =>
          Classify_Received_Address'Result = Fail_Receive);

   function Classify_Error
     (Error_Code                : C.int;
      Would_Block_Error        : C.int;
      Interrupted_Error        : C.int;
      In_Progress_Error        : C.int;
      Already_In_Progress_Error : C.int;
      Already_Connected_Error  : C.int;
      No_Buffer_Space_Error    : C.int) return Error_Kind
   with
     Global => null,
     Post =>
       (if Error_Code = 0 then
           Classify_Error'Result = Success
        elsif Error_Code = Would_Block_Error then
           Classify_Error'Result = Would_Block
        elsif Error_Code = Interrupted_Error then
           Classify_Error'Result = Interrupted
        elsif Error_Code = In_Progress_Error then
           Classify_Error'Result = In_Progress
        elsif Error_Code = Already_In_Progress_Error then
           Classify_Error'Result = Already_In_Progress
        elsif Error_Code = Already_Connected_Error then
           Classify_Error'Result = Already_Connected
        elsif Error_Code = No_Buffer_Space_Error then
           Classify_Error'Result = No_Buffer_Space
        else
           Classify_Error'Result = Other_Error);

   function Classify_IO_Error (Kind : Error_Kind) return IO_Error_Action
   with
     Global => null,
     Post =>
       (if Kind = Would_Block then
           Classify_IO_Error'Result = Wait_For_Ready
        elsif Kind = Interrupted then
           Classify_IO_Error'Result = Retry_Operation
        else
           Classify_IO_Error'Result = Fail_Operation);

   --  A connect attempt interrupted by a signal is not a failure: POSIX keeps
   --  the request alive and the connection continues to be established
   --  asynchronously, exactly like an attempt still in progress. Only the
   --  pending socket error observed after readiness decides the outcome.
   function Classify_Connect_Error
     (Kind : Error_Kind) return Connect_Error_Action
   with
     Global => null,
     Contract_Cases =>
       ((Kind in Interrupted | In_Progress | Already_In_Progress) =>
           Classify_Connect_Error'Result = Wait_For_Connection,
        Kind = Already_Connected =>
           Classify_Connect_Error'Result = Connected,
        others =>
           Classify_Connect_Error'Result = Fail_Connect);

end Flyology.Socket_Policy;
