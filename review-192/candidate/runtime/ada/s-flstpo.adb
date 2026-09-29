package body System.Flyology.Stack_Policy
  with SPARK_Mode
is
   function Usable_Bytes (Request, Page_Size, Guard_Size : Byte_Count) return Byte_Count is
      Remainder : Byte_Count;
      Aligned   : Byte_Count;
   begin
      if not Accepts (Request, Page_Size, Guard_Size) then
         return 0;
      end if;

      pragma Assert (Valid_Page (Page_Size));
      pragma Assert (Valid_Guard (Guard_Size));
      pragma Assert (Request <= Byte_Count'Last - 2 * Guard_Size - (Page_Size - 1));

      Remainder := Request mod Page_Size;
      pragma Assert (Remainder < Page_Size);
      if Remainder = 0 then
         return Request;
      end if;

      --  Drop the partial page, then restore it as a whole one. Accepts
      --  bounds the request one page below the mappable maximum, so the
      --  restored page cannot wrap.
      pragma Assert (Remainder <= Request);
      pragma Assert (Request <= Byte_Count'Last - Page_Size);
      Aligned := Request - Remainder;
      pragma Assert (Aligned <= Request);
      pragma Assert (Aligned <= Byte_Count'Last - Page_Size);
      return Aligned + Page_Size;
   end Usable_Bytes;

end System.Flyology.Stack_Policy;
