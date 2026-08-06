procedure Flyology.HTTP.Decoded_Path_Policy.Smoke is

   procedure Check (Value : String; Expected : Path_Disposition) is
   begin
      pragma Assert (Classify (Value) = Expected);
   end Check;

begin
   Check ("", Accept_Path);
   Check ("/", Accept_Path);
   Check ("*", Accept_Path);
   Check ("/.", Reject_Dot_Segment);
   Check ("/..", Reject_Dot_Segment);
   Check ("/./", Reject_Dot_Segment);
   Check ("/../", Reject_Dot_Segment);
   Check ("/users/./7", Reject_Dot_Segment);
   Check ("/assets/css/../site.css", Reject_Dot_Segment);
   Check (".", Reject_Dot_Segment);
   Check ("..", Reject_Dot_Segment);
   Check ("/users/alice.smith", Accept_Path);
   Check ("/assets/.../site.min.css", Accept_Path);
   Check ("/.hidden", Accept_Path);
   Check ("/name..suffix", Accept_Path);
end Flyology.HTTP.Decoded_Path_Policy.Smoke;
