procedure Flyology.Socket_Policy.Smoke is
begin
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
