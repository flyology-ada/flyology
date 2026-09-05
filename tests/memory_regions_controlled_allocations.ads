with Ada.Finalization;
with Flyology.Memory_Regions;
with System.Storage_Elements;

generic
   Pool : in out Flyology.Memory_Regions.Task_Pool;
   with procedure Note_Finalization (Value : Natural);
package Memory_Regions_Controlled_Allocations is
   type Tracked is new Ada.Finalization.Controlled with record
      Value : Natural := 0;
   end record;

   type Tracked_Access is access Tracked;
   for Tracked_Access'Storage_Pool use Pool;

   function Allocate
     (Region : Flyology.Memory_Regions.Region_Handle; Value : Natural)
      return Tracked_Access;

   type Byte_Array is
     array (System.Storage_Elements.Storage_Offset range <>) of Character;
   type Byte_Array_Access is access Byte_Array;
   for Byte_Array_Access'Storage_Pool use Pool;

   function Allocate_Buffer
     (Region : Flyology.Memory_Regions.Region_Handle;
      First  : System.Storage_Elements.Storage_Offset;
      Last   : System.Storage_Elements.Storage_Offset;
      Value  : Character) return Byte_Array_Access;

private
   overriding
   procedure Finalize (Item : in out Tracked);
end Memory_Regions_Controlled_Allocations;
