procedure Flyology.HTTP_Chunk_Encoding.Smoke is

   procedure Check (Value : Natural; Expected : String) is
   begin
      pragma Assert (Encode (Value) = Expected);
   end Check;

begin
   Check (0, "0");
   Check (15, "F");
   Check (16, "10");
   Check (255, "FF");
   Check (256, "100");
   Check (16#0FFF_FFFF#, "FFFFFFF");
   Check (16#1000_0000#, "10000000");
   Check (Natural'Last, "7FFFFFFF");
end Flyology.HTTP_Chunk_Encoding.Smoke;
