package body Flyology.Wall_Clock_Testing is
   protected Control is
      procedure Set_Offset (Value : Duration);
      function Offset return Duration;
      procedure Reset_Samples;
      procedure Note_Sample (Pause : out Boolean);
      entry Wait_For_Baseline;
      entry Wait_For_Offset;
   private
      Current_Offset   : Duration := 0.0;
      Sample_Count     : Natural := 0;
      Offset_Installed : Boolean := False;
   end Control;

   protected body Control is
      --  GNAT 13 through 16 on Linux/x86-64 mishandle validity checks while
      --  copying Duration values into and out of protected storage: optimized
      --  writes ICE in fold_convert_loc and reads can reject a valid negative
      --  offset as invalid data. Keep the suppression within the protected
      --  body; validity checks remain enabled on the public wrappers.
      pragma Suppress (Validity_Check);

      procedure Set_Offset (Value : Duration) is
      begin
         Current_Offset := Value;
         if Value /= 0.0 then
            Offset_Installed := True;
         end if;
      end Set_Offset;

      function Offset return Duration is (Current_Offset);

      procedure Reset_Samples is
      begin
         Sample_Count := 0;
         Offset_Installed := False;
      end Reset_Samples;

      procedure Note_Sample (Pause : out Boolean) is
      begin
         Sample_Count := Sample_Count + 1;
         Pause := Sample_Count = 2;
      end Note_Sample;

      entry Wait_For_Baseline when Sample_Count >= 2 is
      begin
         null;
      end Wait_For_Baseline;

      entry Wait_For_Offset when Offset_Installed is
      begin
         null;
      end Wait_For_Offset;
   end Control;

   procedure Set_Offset (Value : Duration) is
   begin
      Control.Set_Offset (Value);
   end Set_Offset;

   function Offset return Duration is (Control.Offset);

   procedure Reset_Samples is
   begin
      Control.Reset_Samples;
   end Reset_Samples;

   procedure Note_Sample is
      Pause : Boolean;
   begin
      Control.Note_Sample (Pause);
      if Pause then
         Control.Wait_For_Offset;
      end if;
   end Note_Sample;

   procedure Wait_For_Baseline is
   begin
      Control.Wait_For_Baseline;
   end Wait_For_Baseline;
end Flyology.Wall_Clock_Testing;
