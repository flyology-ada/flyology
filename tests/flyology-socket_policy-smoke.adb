procedure Flyology.Socket_Policy.Smoke is
begin
   pragma Assert (not Should_Enable_Datagram_Metadata (1));
   pragma Assert (Should_Enable_Datagram_Metadata (2));

   pragma Assert
     (Classify_Post_Accept_Failure (Peer_Address_Decode) = Fail_Listener);
   pragma Assert
     (Classify_Post_Accept_Failure (Descriptor_Configuration) =
        Discard_Accepted_Peer);

   pragma Assert
     (Classify_Received_Address
        (Address_Present          => False,
         Decode_Succeeded         => False,
         Decode_Error             => 0,
         Unsupported_Family_Error => 47) = Use_No_Endpoint);
   pragma Assert
     (Classify_Received_Address
        (Address_Present          => True,
         Decode_Succeeded         => True,
         Decode_Error             => 0,
         Unsupported_Family_Error => 47) = Use_Endpoint);
   pragma Assert
     (Classify_Received_Address
        (Address_Present          => True,
         Decode_Succeeded         => False,
         Decode_Error             => 47,
         Unsupported_Family_Error => 47) = Use_No_Endpoint);
   pragma Assert
     (Classify_Received_Address
        (Address_Present          => True,
         Decode_Succeeded         => False,
         Decode_Error             => 22,
         Unsupported_Family_Error => 47) = Fail_Receive);

   --  Distinct operating-system values keep their own classification.
   pragma Assert
     (Classify_Error
        (Error_Code                => 4,
         Would_Block_Error         => 35,
         Interrupted_Error         => 4,
         In_Progress_Error         => 36,
         Already_In_Progress_Error => 37,
         Already_Connected_Error   => 56,
         No_Buffer_Space_Error     => 55) = Interrupted);

   pragma Assert
     (Classify_Error
        (Error_Code                => 0,
         Would_Block_Error         => 35,
         Interrupted_Error         => 4,
         In_Progress_Error         => 36,
         Already_In_Progress_Error => 37,
         Already_Connected_Error   => 56,
         No_Buffer_Space_Error     => 55) = Success);

   --  An interrupted transfer restarts; the kernel performed no work.
   pragma Assert (Classify_IO_Error (Interrupted) = Retry_Operation);
   pragma Assert (Classify_IO_Error (Would_Block) = Wait_For_Ready);
   pragma Assert (Classify_IO_Error (In_Progress) = Fail_Operation);

   --  An interrupted connect is not a failure: POSIX keeps establishing the
   --  connection asynchronously, so the outcome is read from the pending
   --  socket error once the connection resolves.
   pragma Assert
     (Classify_Connect_Error (Interrupted) = Wait_For_Connection);
   pragma Assert
     (Classify_Connect_Error (In_Progress) = Wait_For_Connection);
   pragma Assert
     (Classify_Connect_Error (Already_In_Progress) = Wait_For_Connection);
   pragma Assert (Classify_Connect_Error (Already_Connected) = Connected);
   pragma Assert (Classify_Connect_Error (Would_Block) = Fail_Connect);
   pragma Assert (Classify_Connect_Error (No_Buffer_Space) = Fail_Connect);
   pragma Assert (Classify_Connect_Error (Other_Error) = Fail_Connect);
end Flyology.Socket_Policy.Smoke;
