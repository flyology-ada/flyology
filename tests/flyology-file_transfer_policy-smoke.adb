procedure Flyology.File_Transfer_Policy.Smoke is
begin
   pragma Assert (Classify (0, 4, 32, 1, 8, 95) = Return_Progress);
   pragma Assert (Classify (0, 9, 0, 0, 8, 95) = Raise_Invalid_Completion);
   pragma Assert (Classify (0, 0, 0, 1, 8, 95) = Raise_Cancelled);
   pragma Assert (Classify (0, 0, 95, 0, 8, 95) = Use_Buffered_Fallback);
   pragma Assert (Classify (0, 0, 32, 0, 8, 95) = Raise_Socket_Error);
   pragma Assert (Classify (1, 0, 0, 0, 8, 95) = Use_Buffered_Fallback);
   pragma Assert (Classify (1, 1, 0, 0, 8, 95) = Raise_Invalid_Completion);
   pragma Assert (Classify (-1, 0, 0, 0, 8, 95) = Raise_Invalid_Completion);
end Flyology.File_Transfer_Policy.Smoke;
