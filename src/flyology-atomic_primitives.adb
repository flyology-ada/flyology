with System.Atomic_Primitives;

package body Flyology.Atomic_Primitives is
   package AP renames System.Atomic_Primitives;

   procedure Atomic_Store_Release_U32 (Address : System.Address; Value : Interfaces.Unsigned_32);
   pragma Import (C, Atomic_Store_Release_U32, "flyology_atomic_store_release_u32");

   procedure Atomic_Store_Release_U64 (Address : System.Address; Value : Interfaces.Unsigned_64);
   pragma Import (C, Atomic_Store_Release_U64, "flyology_atomic_store_release_u64");

   function Load_Acquire_U32 (Address : System.Address) return Interfaces.Unsigned_32
   is (Interfaces.Unsigned_32 (AP.Atomic_Load_32 (Address, AP.Acquire)));

   function Load_Acquire_U64 (Address : System.Address) return Interfaces.Unsigned_64
   is (Interfaces.Unsigned_64 (AP.Atomic_Load_64 (Address, AP.Acquire)));

   procedure Store_Release_U32 (Address : System.Address; Value : Interfaces.Unsigned_32) is
   begin
      Atomic_Store_Release_U32 (Address, Value);
   end Store_Release_U32;

   procedure Store_Release_U64 (Address : System.Address; Value : Interfaces.Unsigned_64) is
   begin
      Atomic_Store_Release_U64 (Address, Value);
   end Store_Release_U64;

   function Compare_Exchange_U32
     (Address : System.Address; Expected : in out Interfaces.Unsigned_32; Desired : Interfaces.Unsigned_32)
      return Boolean
   is
      Local  : aliased AP.uint32 := AP.uint32 (Expected);
      Result : Boolean;
   begin
      Result :=
        AP.Atomic_Compare_Exchange_32
          (Address,
           Local'Address,
           AP.uint32 (Desired),
           Weak          => False,
           Success_Model => AP.Acq_Rel,
           Failure_Model => AP.Acquire);
      Expected := Interfaces.Unsigned_32 (Local);
      return Result;
   end Compare_Exchange_U32;
end Flyology.Atomic_Primitives;
