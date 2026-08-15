with Interfaces;

package Allocator_Refinement_Support is
   Max_Blocks : constant := 32;

   type Canonical_Block_State is (Free_Block, Allocated_Block);

   type Block_Info is record
      Token      : Interfaces.Unsigned_32 := 0;
      Start      : Natural := 0;
      Size       : Positive := 1;
      State      : Canonical_Block_State := Free_Block;
      Generation : Interfaces.Unsigned_64 := 0;
   end record;

   type Block_Array is array (Positive range 1 .. Max_Blocks) of Block_Info;

   type Index_Info is record
      Start        : Natural := 0;
      Size         : Positive := 1;
      Class_First  : Integer := -1;
      Class_Second : Integer := -1;
   end record;

   type Index_Array is array (Positive range 1 .. Max_Blocks) of Index_Info;

   type TLSF_Map_Array is array (Natural range 0 .. 31) of
     Interfaces.Unsigned_32;

   type Snapshot is record
      Generation  : Interfaces.Unsigned_64 := 0;
      Block_Count : Natural range 0 .. Max_Blocks := 0;
      Blocks      : Block_Array;
      Index_Count : Natural range 0 .. Max_Blocks := 0;
      Index       : Index_Array;
      First_Map   : Interfaces.Unsigned_32 := 0;
      Second_Maps : TLSF_Map_Array := [others => 0];
   end record;

   type Hint_Array is array (Positive range 1 .. 8) of Integer;

   Empty_Hints : constant Hint_Array := [others => -1];
end Allocator_Refinement_Support;
