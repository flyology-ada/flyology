package body Memory_Regions_Controlled_Allocations is

   function Allocate
     (Region : Flyology.Memory_Regions.Region_Handle; Value : Natural)
      return Tracked_Access
   is (new (Region) Tracked'(Ada.Finalization.Controlled with Value));

   function Allocate_Buffer
     (Region : Flyology.Memory_Regions.Region_Handle;
      First  : System.Storage_Elements.Storage_Offset;
      Last   : System.Storage_Elements.Storage_Offset;
      Value  : Character) return Byte_Array_Access
   is (new (Region) Byte_Array'(First .. Last => Value));

   overriding
   procedure Finalize (Item : in out Tracked) is
   begin
      Note_Finalization (Item.Value);
   end Finalize;

end Memory_Regions_Controlled_Allocations;
