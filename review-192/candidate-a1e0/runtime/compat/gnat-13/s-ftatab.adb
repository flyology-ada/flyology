with Ada.Unchecked_Conversion;

package body System.Flyology.Task_Attribute_ABI is
   use type System.Tasking.Atomic_Address;

   --  GNAT 13 declares each task-attribute component as Atomic_Address and
   --  initializes an unused component to zero in System.Tasking. Keep the
   --  conversion private and reject any target where it is not size-preserving.
   pragma
     Compile_Time_Error
       (System.Tasking.Atomic_Address'Size /= System.Address'Size,
        "GNAT 13 task-attribute addresses must match System.Address size");

   function To_Address is new Ada.Unchecked_Conversion (System.Tasking.Atomic_Address, System.Address);
   function To_Atomic_Address is new Ada.Unchecked_Conversion (System.Address, System.Tasking.Atomic_Address);

   function Load (T : System.Tasking.Task_Id; Index : Integer) return System.Address is
   begin
      return To_Address (T.Attributes (Index));
   end Load;

   function Is_Null (T : System.Tasking.Task_Id; Index : Integer) return Boolean is
   begin
      --  Zero is the unused Attribute_Array sentinel in GNAT 13's s-taskin.ads.
      return T.Attributes (Index) = 0;
   end Is_Null;

   procedure Store (T : System.Tasking.Task_Id; Index : Integer; Value : System.Address) is
   begin
      T.Attributes (Index) := To_Atomic_Address (Value);
   end Store;
end System.Flyology.Task_Attribute_ABI;
