with Interfaces;
private with Flyology_Allocators.Layouts;
private with System;

--  Hybrid slab/span allocation inside fixed caller-owned bytes. Small
--  allocations use bitmap slots in classed runs; larger allocations reserve
--  contiguous runs. Stored metadata contains only fixed-width values. One
--  persisted nonblocking guard serializes metadata mutation across views.
--  @exclude

package Flyology_Allocators.Allocation_Algorithms.Slab_Span_Kernel is

   Minimum_Block_Limit : constant Positive := 16;

   --  Immutable allocator geometry.
   --  @field Usable_Capacity Managed payload bytes, an exact Run_Size multiple
   --  @field Minimum_Block_Size Smallest slot and payload alignment
   --  @field Run_Size Slab size and large-allocation span quantum
   type Configuration is record
      Usable_Capacity    : Positive;
      Minimum_Block_Size : Positive;
      Run_Size           : Positive;
   end record;

   function Configuration_Usable_Capacity (Value : Configuration) return Positive
   is (Value.Usable_Capacity);
   function Configuration_Minimum_Block_Size (Value : Configuration) return Positive
   is (Value.Minimum_Block_Size);

   type View is limited private;

   function Required_Storage (Configuration : Slab_Span_Kernel.Configuration) return Byte_Count;

   procedure Initialize
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Slab_Span_Kernel.Configuration;
      Instance_ID   : Interfaces.Unsigned_64);

   procedure Create_Or_Attach
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Slab_Span_Kernel.Configuration;
      Instance_ID   : Interfaces.Unsigned_64;
      Result        : out Open_Result);

   procedure Attach
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Slab_Span_Kernel.Configuration;
      Instance_ID   : Interfaces.Unsigned_64);

   procedure Detach (Item : in out View);
   function Is_Attached (Item : View) return Boolean;
   function Current_Metadata (Item : View) return Metadata;
   function Is_Poisoned (Item : View) return Boolean;
   procedure Poison (Region : Region_View; Location : Region_Offset);

   procedure Try_Allocate
     (Item           : in out View;
      Requested_Size : Positive;
      Value          : out Allocation_Handle;
      Result         : out Allocation_Result);

   procedure Try_Allocate
     (Item           : in out View;
      Requested_Size : Positive;
      Timeout        : Wait_Timeout;
      Value          : out Allocation_Handle;
      Result         : out Allocation_Result);

   procedure Release (Item : in out View; Value : Allocation_Handle);
   procedure Release (Item : in out View; Value : Allocation_Handle; Timeout : Wait_Timeout);

   function Block_Capacity (Item : View; Value : Allocation_Handle) return Byte_Count;

   procedure Attach_Allocation (Region : in out Region_View; Item : View; Value : Allocation_Handle);

   procedure Copy
     (Item          : View;
      Source        : Allocation_Handle;
      Source_Offset : Byte_Count;
      Target        : Allocation_Handle;
      Target_Offset : Byte_Count;
      Length        : Byte_Count);

   procedure Destroy (Item : in out View);

private
   type View is limited record
      Core               : Layouts.Local_View;
      Descriptor_Address : System.Address := System.Null_Address;
      Generation_Address : System.Address := System.Null_Address;
      Head_Address       : System.Address := System.Null_Address;
      Guard_Address      : System.Address := System.Null_Address;
      Counter_Address    : System.Address := System.Null_Address;
      Usable_Value       : Interfaces.Unsigned_32 := 0;
      Minimum_Value      : Interfaces.Unsigned_32 := 0;
      Run_Value          : Interfaces.Unsigned_32 := 0;
      Run_Count          : Interfaces.Unsigned_32 := 0;
      Units_Per_Run      : Interfaces.Unsigned_32 := 0;
      Class_Count        : Interfaces.Unsigned_32 := 0;
      Data_Offset        : Byte_Count := 0;
      Instance_Value     : Interfaces.Unsigned_64 := 0;
   end record;
end Flyology_Allocators.Allocation_Algorithms.Slab_Span_Kernel;
