with System.Atomic_Primitives;

package body Flyology_Allocators.Atomics is
   package AP renames System.Atomic_Primitives;

   generic
      type Atomic_Type is mod <>;
   procedure Atomic_Store (Address : System.Address; Value : Atomic_Type; Model : AP.Mem_Model := AP.Seq_Cst);
   pragma Import (Intrinsic, Atomic_Store, "__atomic_store_n");

   procedure Atomic_Store_32 is new Atomic_Store (AP.uint32);

   function Supported return Boolean
   is (AP.Atomic_Always_Lock_Free (4));

   function Load_Acquire_U32 (Address : System.Address) return Interfaces.Unsigned_32
   is (Interfaces.Unsigned_32 (AP.Atomic_Load_32 (Address, AP.Acquire)));

   procedure Store_Release_U32 (Address : System.Address; Value : Interfaces.Unsigned_32) is
   begin
      Atomic_Store_32 (Address, AP.uint32 (Value), AP.Release);
   end Store_Release_U32;

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

end Flyology_Allocators.Atomics;
