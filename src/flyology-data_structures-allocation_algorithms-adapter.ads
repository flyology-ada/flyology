with Ada.Streams;
with Flyology_Allocators.Allocation_Algorithms.Contract;
with Interfaces;
private with Flyology.Data_Structures.Layouts;
private with Flyology_Allocators.Regions;

--  Adds Flyology's persisted identity, lifecycle, instance, and payload-view
--  policy around one standalone allocation algorithm. The nested allocator
--  owns only allocation metadata and block selection.
--  @exclude
generic
   Algorithm_Magic   : Interfaces.Unsigned_64;
   Algorithm_Version : Interfaces.Unsigned_32;
   Algorithm_Schema  : Interfaces.Unsigned_64;
   with package Algorithm is new
     Flyology_Allocators.Allocation_Algorithms.Contract (<>);
package Flyology.Data_Structures.Allocation_Algorithms.Adapter is
   --  @exclude

   Identity : constant Layout_Identity :=
     (Magic   => Algorithm_Magic,
      Version => Algorithm_Version,
      Schema  => Algorithm_Schema);
   Minimum_Block_Limit : constant Positive :=
     Algorithm.Minimum_Block_Limit;

   subtype Configuration is Algorithm.Configuration;
   type View is limited private;

   function Required_Storage
     (Configuration : Algorithm.Configuration) return Byte_Count;

   procedure Initialize
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Algorithm.Configuration;
      Instance_ID   : Interfaces.Unsigned_64);

   procedure Create_Or_Attach
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Algorithm.Configuration;
      Instance_ID   : Interfaces.Unsigned_64;
      Result        : out Open_Result);

   procedure Attach
     (Item          : out View;
      Region        : Region_View;
      Location      : Region_Offset;
      Configuration : Algorithm.Configuration;
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

   procedure Release
     (Item    : in out View;
      Value   : Allocation_Handle;
      Timeout : Wait_Timeout);

   function Block_Capacity
     (Item : View; Value : Allocation_Handle) return Byte_Count;

   procedure Attach_Allocation
     (Region : in out Region_View;
      Item   : View;
      Value  : Allocation_Handle);

   function Bind_Allocation
     (Item      : View;
      Value     : Allocation_Handle;
      Offset    : Byte_Count;
      Extent    : Byte_Count;
      Alignment : Byte_Count;
      Signature : Interfaces.Unsigned_64;
      Version   : Interfaces.Unsigned_32;
      Writable  : Boolean) return Immutable_Storage_View;

   procedure Read
     (Item   : View;
      Value  : Allocation_Handle;
      Offset : Byte_Count;
      Data   : out Ada.Streams.Stream_Element_Array);

   procedure Write
     (Item   : View;
      Value  : Allocation_Handle;
      Offset : Byte_Count;
      Data   : Ada.Streams.Stream_Element_Array);

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
      Core           : Layouts.Local_View;
      Inner_Region   : Flyology_Allocators.Regions.View;
      Inner          : Algorithm.View;
      Instance_Value : Interfaces.Unsigned_64 := 0;
      Usable_Value   : Interfaces.Unsigned_32 := 0;
      Minimum_Value  : Interfaces.Unsigned_32 := 0;
      Inner_Location : Byte_Count := 0;
   end record;
end Flyology.Data_Structures.Allocation_Algorithms.Adapter;
