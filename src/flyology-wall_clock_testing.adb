package body Flyology.Wall_Clock_Testing is
   protected Control is
      procedure Set_Offset (Value : Duration);
      function Offset return Duration;
   private
      Current_Offset : Duration := 0.0;
   end Control;

   protected body Control is
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
