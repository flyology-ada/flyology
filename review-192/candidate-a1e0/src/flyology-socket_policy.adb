package body Flyology.Socket_Policy
  with SPARK_Mode => On
is
   function Family_Code (IPv6 : Boolean) return C.int
   is (if IPv6 then 6 else 4);

   function Retry_IO_Immediately (Attempt : Positive) return Boolean
   is (Attempt < Immediate_IO_Retry_Limit);

   function Complete_Transfer_First (Data_First : Stream_Offset; Transferred : Natural) return Stream_Offset
   is (Data_First + Stream_Offset (Transferred));

   function Mode_Code (Datagram : Boolean) return C.int
   is (if Datagram then 2 else 1);

   function Should_Enable_Datagram_Metadata (Mode : C.int) return Boolean
   is (Mode = 2);

   function Classify_Post_Accept_Failure (Stage : Post_Accept_Failure_Stage) return Post_Accept_Failure_Action
   is (case Stage is
         when Peer_Address_Decode      => Fail_Listener,
         when Descriptor_Configuration => Discard_Accepted_Peer);

   function Classify_Received_Address
     (Address_Present          : Boolean;
      Decode_Succeeded         : Boolean;
      Decode_Error             : C.int;
      Unsupported_Family_Error : C.int) return Received_Address_Action is
   begin
      if not Address_Present then
         return Use_No_Endpoint;
      elsif Decode_Succeeded then
         return Use_Endpoint;
      elsif Decode_Error = Unsupported_Family_Error then
         return Use_No_Endpoint;
      else
         return Fail_Receive;
      end if;
   end Classify_Received_Address;

   function Classify_Error
     (Error_Code                : C.int;
      Would_Block_Error         : C.int;
      Interrupted_Error         : C.int;
      In_Progress_Error         : C.int;
      Already_In_Progress_Error : C.int;
      Already_Connected_Error   : C.int;
      No_Buffer_Space_Error     : C.int) return Error_Kind is
   begin
      if Error_Code = 0 then
         return Success;
      elsif Error_Code = Would_Block_Error then
         return Would_Block;
      elsif Error_Code = Interrupted_Error then
         return Interrupted;
      elsif Error_Code = In_Progress_Error then
         return In_Progress;
      elsif Error_Code = Already_In_Progress_Error then
         return Already_In_Progress;
      elsif Error_Code = Already_Connected_Error then
         return Already_Connected;
      elsif Error_Code = No_Buffer_Space_Error then
         return No_Buffer_Space;
      else
         return Other_Error;
      end if;
   end Classify_Error;

   function Classify_IO_Error (Kind : Error_Kind) return IO_Error_Action is
   begin
      case Kind is
         when Would_Block =>
            return Wait_For_Ready;

         when Interrupted =>
            return Retry_Operation;

         when others      =>
            return Fail_Operation;
      end case;
   end Classify_IO_Error;

   function Classify_Connect_Error (Kind : Error_Kind) return Connect_Error_Action is
   begin
      case Kind is
         when Interrupted | In_Progress | Already_In_Progress =>
            return Wait_For_Connection;

         when Already_Connected                               =>
            return Connected;

         when others                                          =>
            return Fail_Connect;
      end case;
   end Classify_Connect_Error;

end Flyology.Socket_Policy;
