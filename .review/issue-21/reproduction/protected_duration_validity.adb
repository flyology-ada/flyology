--  { dg-do run }
--  { dg-options "-O2 -gnatVa" }

with Ada.Text_IO; use Ada.Text_IO;

procedure Protected_Duration_Validity is
   protected Control is
      procedure Set (Value : Duration);
      function Get return Duration;
   private
      Current : Duration := 0.0;
   end Control;

   protected body Control is
      procedure Set (Value : Duration) is
      begin
         Current := Value;
      end Set;

      function Get return Duration is
      begin
         return Current;
      end Get;
   end Control;
begin
   Control.Set (-1.0);
   if Control.Get /= -1.0 then
      raise Program_Error with "protected Duration round trip failed";
   end if;
   Put_Line ("PASS protected Duration validity");
end Protected_Duration_Validity;
