package body Memory_Regions_Controlled_Allocations is

   function Allocate
     (Region : Flyology.Memory_Regions.Region_Handle; Value : Natural)
      return Tracked_Access
   is
      --  GNAT 13.2.2, 14.1.3, 14.2.1, and 15.1.2 drop Region from a controlled
      --  qualified-expression allocator. Keep the allocator and initialization
      --  separate until the compiler correction tracked by issue #22, closed by
      --  its reviewed compiler patch and O0/O2 regression matrix in PR #24:
      --  https://github.com/flyology-ada/gnat-patches/issues/22
      Object : constant Tracked_Access := new (Region) Tracked;
   begin
      Object.Value := Value;
      return Object;
   end Allocate;

   function Allocate_Buffer
     (Region : Flyology.Memory_Regions.Region_Handle;
      First  : System.Storage_Elements.Storage_Offset;
      Last   : System.Storage_Elements.Storage_Offset;
      Value  : Character) return Byte_Array_Access
   is
      Object : constant Byte_Array_Access :=
        new (Region) Byte_Array (First .. Last);
   begin
      Object.all := (others => Value);
      return Object;
   end Allocate_Buffer;

   overriding
   procedure Finalize (Item : in out Tracked) is
   begin
      Note_Finalization (Item.Value);
   end Finalize;

end Memory_Regions_Controlled_Allocations;
