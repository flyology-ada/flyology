with Interfaces.C;

--  Stack sizing kernel consumed by System.Flyology.Contexts. Stack sizes are
--  carried in the modular type size_t, where an oversized request wraps
--  instead of failing: rounding it up to a page can produce a smaller usable
--  size, and the arena stride and mapping length derived from it can reach
--  zero. Every function here is total, so the runtime may apply it directly
--  to a caller-supplied size and a host page size.
package System.Flyology.Stack_Policy
  with Preelaborate,
       SPARK_Mode
is
   package C renames Interfaces.C;

   use type C.size_t;

   subtype Byte_Count is C.size_t;

   --  A host page size stacks can be aligned to. The upper bound leaves room
   --  for one page of rounding beside two guards.
   function Valid_Page (Page_Size : Byte_Count) return Boolean
   is (Page_Size /= 0 and then Page_Size <= Byte_Count'Last / 8);

   --  A guard size an arena can place below every slot and above the last.
   function Valid_Guard (Guard_Size : Byte_Count) return Boolean
   is (Guard_Size /= 0 and then Guard_Size <= Byte_Count'Last / 8);

   --  True when an arena can carry Usable_Size: the per-slot stride is one
   --  guard above the usable size, and the mapping length of a single-slot
   --  arena is one guard above that stride. Both must remain representable.
   function Mappable
     (Usable_Size, Guard_Size : Byte_Count) return Boolean
   is (Usable_Size /= 0
       and then Valid_Guard (Guard_Size)
       and then Usable_Size <= Byte_Count'Last - 2 * Guard_Size);

   --  Largest request that can be rounded up to a mappable usable size.
   --  Zero rejects every request when the host page or guard is unusable.
   function Maximum_Request
     (Page_Size, Guard_Size : Byte_Count) return Byte_Count
   is (if Valid_Page (Page_Size) and then Valid_Guard (Guard_Size)
       then Byte_Count'Last - 2 * Guard_Size - (Page_Size - 1)
       else 0);

   --  True when Request has a representable stack sizing.
   function Accepts
     (Request, Page_Size, Guard_Size : Byte_Count) return Boolean
   is (Request /= 0
       and then Request <= Maximum_Request (Page_Size, Guard_Size));

   --  Round Request up to a whole number of pages. An accepted request keeps
   --  at least its requested bytes, grows by less than one page, and yields a
   --  mappable usable size; a rejected one yields zero, which no stack
   --  allocation accepts. Page alignment of the result holds by construction
   --  and is covered behaviorally rather than by these contracts: the modular
   --  remainder reasoning it needs does not discharge at the proof level this
   --  project runs.
   function Usable_Bytes
     (Request, Page_Size, Guard_Size : Byte_Count) return Byte_Count
   with Post =>
     (if Accepts (Request, Page_Size, Guard_Size)
      then Usable_Bytes'Result >= Request
        and then Usable_Bytes'Result - Request < Page_Size
        and then Mappable (Usable_Bytes'Result, Guard_Size)
      else Usable_Bytes'Result = 0);

end System.Flyology.Stack_Policy;
