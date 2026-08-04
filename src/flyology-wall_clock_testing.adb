package body Flyology.Wall_Clock_Testing is
   protected Control is
      procedure Set_Offset (Value : Duration);
      function Offset return Duration;
   private
      Current_Offset : Duration := 0.0;
   end Control;

   protected body Control is
      procedure Set_Offset (Value : Duration) is
         --  GNAT 13 through 16 on Linux/x86-64 ICE in fold_convert_loc when
         --  optimization and -gnatVa generate a validity check for this
         --  protected Duration assignment. The public wrapper validates Value,
         --  so suppress only the redundant check in this protected operation.
         pragma Suppress (Validity_Check);
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
