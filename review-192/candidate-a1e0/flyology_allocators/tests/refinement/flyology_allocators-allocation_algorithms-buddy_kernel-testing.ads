with Allocator_Refinement_Support;

package Flyology_Allocators.Allocation_Algorithms.Buddy_Kernel.Testing is
   procedure Capture (Item : View; Value : out Allocator_Refinement_Support.Snapshot);

   procedure Capture_Hints (Item : View; Value : out Allocator_Refinement_Support.Hint_Array);

   function Handle_Start (Item : View; Value : Allocation_Handle) return Natural;
end Flyology_Allocators.Allocation_Algorithms.Buddy_Kernel.Testing;
