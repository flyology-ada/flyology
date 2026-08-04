package body Flyology.Wall_Clock_Testing is
   protected Control is
      procedure Set_Offset (Value : Duration);
      function Offset return Duration;
   private
      Current_Offset : Duration := 0.0;
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
      end Set_Offset;

      function Offset return Duration is (Current_Offset);
   end Control;

   procedure Set_Offset (Value : Duration) is
   begin
      Control.Set_Offset (Value);
   end Set_Offset;

   function Offset return Duration is (Control.Offset);
end Flyology.Wall_Clock_Testing;
