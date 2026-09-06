package body System.Flyology.Task_Attribute_ABI is
   --  GNAT 14 through 16 store System.Address directly in Attribute_Array;
   --  keep these accesses typed so the GNAT 13 conversion cannot leak here.
   function Load (T : System.Tasking.Task_Id; Index : Integer) return System.Address is
   begin
      return T.Attributes (Index);
   end Load;

   function Is_Null (T : System.Tasking.Task_Id; Index : Integer) return Boolean is
   begin
      return T.Attributes (Index) = System.Null_Address;
   end Is_Null;

   procedure Store (T : System.Tasking.Task_Id; Index : Integer; Value : System.Address) is
   begin
      T.Attributes (Index) := Value;
   end Store;
end System.Flyology.Task_Attribute_ABI;
