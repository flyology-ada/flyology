with Flyology.Data_Structures.Atomics;
with Flyology.Data_Structures.Policy;
with Flyology.Data_Structures.Storage;
with Flyology.Data_Structures.Waits;
with Interfaces.C;

package body Flyology.Data_Structures.Rings.SPSC is
   package Atomic renames Flyology.Data_Structures.Atomics;
   package Policy renames Flyology.Data_Structures.Policy;
   package Bytes renames Flyology.Data_Structures.Storage;
   package Waiting renames Flyology.Data_Structures.Waits;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   Head_Offset : constant Byte_Count := 64;
   Tail_Offset : constant Byte_Count := 128;
   Slots_Offset : constant Byte_Count := 192;

   function U32 (Value : Positive) return Interfaces.Unsigned_32 is
   begin
      return Interfaces.Unsigned_32 (Value);
   end U32;

   procedure Geometry
     (Capacity     : Positive;
      Element_Size : Positive;
      Stride       : out Byte_Count;
      Extent       : out Byte_Count) is
   begin
      if not Policy.Is_Power_Of_Two (Byte_Count (Capacity))
      then
         raise Constraint_Error with "SPSC capacity must be a power of two";
      end if;
      Stride := Layouts.Align_Up (Byte_Count (Element_Size), 8);
      Extent := Layouts.Checked_Add
        (Slots_Offset,
         Layouts.Checked_Multiply (Byte_Count (Capacity), Stride));
   end Geometry;

   function Required_Storage
     (Capacity : Positive; Element_Size : Positive) return Byte_Count
   is
      Stride : Byte_Count;
      Extent : Byte_Count;
   begin
      Geometry (Capacity, Element_Size, Stride, Extent);
      return Extent;
   end Required_Storage;

   procedure Set_View
     (Item         : out View;
      Core         : Layouts.Local_View;
      Capacity     : Interfaces.Unsigned_32;
      Element_Size : Interfaces.Unsigned_32;
      Stride       : Byte_Count) is
   begin
      Item.Core := Core;
      Item.Capacity_Value := Capacity;
      Item.Element_Value := Element_Size;
      Item.Mask := Interfaces.Unsigned_64 (Capacity) - 1;
      Item.Stride := Stride;
      Item.Head_Address := Layouts.Address_At (Core, Head_Offset, 8, 8);
      Item.Tail_Address := Layouts.Address_At (Core, Tail_Offset, 8, 8);
   end Set_View;

   procedure Finish_Initialize
     (Item         : out View;
      Core         : Layouts.Local_View;
      Capacity     : Interfaces.Unsigned_32;
      Element_Size : Interfaces.Unsigned_32;
      Stride       : Byte_Count) is
   begin
      Set_View (Item, Core, Capacity, Element_Size, Stride);
      Atomic.Store_Release_U64 (Item.Head_Address, 0);
      Atomic.Store_Release_U64 (Item.Tail_Address, 0);
      Layouts.Publish (Item.Core);
   end Finish_Initialize;

   procedure Initialize
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Element_Size : Positive)
   is
      Stride : Byte_Count;
      Extent : Byte_Count;
      Core   : Layouts.Local_View;
   begin
      Detach (Item);
      Geometry (Capacity, Element_Size, Stride, Extent);
      Layouts.Begin_Initialize
        (Core, Region, Location, Identity, Extent,
         (Capacity     => U32 (Capacity),
          Element_Size => U32 (Element_Size),
          Alignment    => 8,
          Auxiliary    => 0,
          Word_1       => 0,
          Word_2       => 0),
         8);
      Finish_Initialize
        (Item, Core, U32 (Capacity), U32 (Element_Size), Stride);
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Initialize;

   procedure Create_Or_Attach
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Element_Size : Positive;
      Result       : out Open_Result)
   is
      Stride : Byte_Count;
      Extent : Byte_Count;
      Core   : Layouts.Local_View;
      Claim  : Layouts.Initialization_Claim;
   begin
      Detach (Item);
      Geometry (Capacity, Element_Size, Stride, Extent);
      Layouts.Try_Begin_Initialize
        (Core, Claim, Region, Location, Identity, Extent,
         (Capacity     => U32 (Capacity),
          Element_Size => U32 (Element_Size),
          Alignment    => 8,
          Auxiliary    => 0,
          Word_1       => 0,
          Word_2       => 0),
         8);
      case Claim is
         when Layouts.Claimed_Virgin =>
            Finish_Initialize
              (Item, Core, U32 (Capacity), U32 (Element_Size), Stride);
            Result := Initialized_New;
         when Layouts.Existing_Ready =>
            Attach (Item, Region, Location, Capacity, Element_Size);
            Result := Attached_Existing;
         when Layouts.Claim_In_Progress =>
            Result := Initialization_In_Progress;
      end case;
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Create_Or_Attach;

   procedure Attach
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Element_Size : Positive)
   is
      Core   : Layouts.Local_View;
      Header : Layouts.Header_Values;
      Stride : Byte_Count;
      Extent : Byte_Count;
      Head   : Interfaces.Unsigned_64;
      Tail   : Interfaces.Unsigned_64;
   begin
      Detach (Item);
      Geometry (Capacity, Element_Size, Stride, Extent);
      Layouts.Attach (Core, Header, Region, Location, Identity, 8);
      if Header.Capacity /= U32 (Capacity)
        or else Header.Element_Size /= U32 (Element_Size)
        or else Header.Alignment /= 8
        or else Header.Auxiliary /= 0
        or else Header.Word_1 /= 0
        or else Header.Word_2 /= 0
        or else Core.Extent /= Extent
      then
         raise Layout_Error with "SPSC ring configuration does not match";
      end if;
      Set_View (Item, Core, Header.Capacity, Header.Element_Size, Stride);
      Head := Atomic.Load_Acquire_U64
        (Item.Head_Address);
      Tail := Atomic.Load_Acquire_U64
        (Item.Tail_Address);
      if not Policy.Within_Capacity
        (Tail, Head, Item.Capacity_Value)
      then
         raise Layout_Error with "SPSC ring indices are corrupt";
      end if;
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Attach;

   procedure Detach (Item : in out View) is
   begin
      Layouts.Detach (Item.Core);
      Item.Capacity_Value := 0;
      Item.Element_Value := 0;
      Item.Mask := 0;
      Item.Stride := 0;
      Item.Head_Address := System.Null_Address;
      Item.Tail_Address := System.Null_Address;
   end Detach;

   function Is_Attached (Item : View) return Boolean is (Item.Core.Attached);

   procedure Poison (Region : Region_View; Location : Region_Offset) is
   begin
      Layouts.Poison_At (Region, Location, Identity, 8);
   end Poison;

   function Is_Poisoned (Item : View) return Boolean is
     (Layouts.Is_Poisoned (Item.Core));

   function Current_Metadata (Item : View) return Metadata is
   begin
      if not Item.Core.Attached then
         raise Region_Error with "detached SPSC ring view";
      end if;
      Layouts.Require_Ready (Item.Core);
      return
        (Capacity     => Item.Capacity_Value,
         Element_Size => Item.Element_Value,
         Extent       => Item.Core.Extent);
   end Current_Metadata;

   procedure Check_Length (Item : View; Length : Natural) is
   begin
      if not Item.Core.Attached then
         raise Region_Error with "detached SPSC ring view";
      elsif Byte_Count (Length) /= Byte_Count (Item.Element_Value) then
         raise Constraint_Error with "SPSC element length does not match";
      end if;
   end Check_Length;

   function Element_Address
     (Item : View; Position : Interfaces.Unsigned_64) return System.Address
   is
      Index : constant Byte_Count := Byte_Count
        (Policy.Masked_Index
           (Position, Policy.Positive_U32 (Item.Capacity_Value)));
      Relative : constant Byte_Count := Layouts.Checked_Add
        (Slots_Offset,
         Layouts.Checked_Multiply (Index, Item.Stride));
   begin
      return Layouts.Address_At
        (Item.Core, Relative, Byte_Count (Item.Element_Value), 1);
   end Element_Address;

   procedure Try_Push
     (Item   : in out View;
      Data   : Ada.Streams.Stream_Element_Array;
      Pushed : out Boolean)
   is
      Head : Interfaces.Unsigned_64;
      Tail : Interfaces.Unsigned_64;
   begin
      Check_Length (Item, Data'Length);
      Layouts.Require_Ready (Item.Core);
      Tail := Atomic.Load_Relaxed_U64
        (Item.Tail_Address);
      Head := Atomic.Load_Acquire_U64
        (Item.Head_Address);
      if not Policy.Within_Capacity
        (Tail, Head, Item.Capacity_Value)
      then
         raise Layout_Error with "SPSC ring indices are corrupt";
      elsif Tail - Head = Interfaces.Unsigned_64 (Item.Capacity_Value) then
         Pushed := False;
         return;
      end if;
      Bytes.Copy
        (Element_Address (Item, Tail), Data'Address,
         Interfaces.C.size_t (Data'Length));
      Atomic.Store_Release_U64
        (Item.Tail_Address, Tail + 1);
      Pushed := True;
   end Try_Push;

   procedure Push
     (Item    : in out View;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout)
   is
      Wait   : Waiting.Context := Waiting.Start (Timeout);
      Pushed : Boolean;
   begin
      loop
         Try_Push (Item, Data, Pushed);
         exit when Pushed;
         Waiting.Retry (Wait);
      end loop;
   end Push;

   procedure Try_Pop
     (Item   : in out View;
      Data   : out Ada.Streams.Stream_Element_Array;
      Popped : out Boolean)
   is
      Head : Interfaces.Unsigned_64;
      Tail : Interfaces.Unsigned_64;
   begin
      Check_Length (Item, Data'Length);
      Layouts.Require_Ready (Item.Core);
      Head := Atomic.Load_Relaxed_U64
        (Item.Head_Address);
      Tail := Atomic.Load_Acquire_U64
        (Item.Tail_Address);
      if not Policy.Within_Capacity
        (Tail, Head, Item.Capacity_Value)
      then
         raise Layout_Error with "SPSC ring indices are corrupt";
      elsif Tail = Head then
         Popped := False;
         return;
      end if;
      Bytes.Copy
        (Data'Address, Element_Address (Item, Head),
         Interfaces.C.size_t (Data'Length));
      Atomic.Store_Release_U64
        (Item.Head_Address, Head + 1);
      Popped := True;
   end Try_Pop;

   procedure Pop
     (Item    : in out View;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout)
   is
      Wait   : Waiting.Context := Waiting.Start (Timeout);
      Popped : Boolean;
   begin
      loop
         Try_Pop (Item, Data, Popped);
         exit when Popped;
         Waiting.Retry (Wait);
      end loop;
   end Pop;

   procedure Destroy (Item : in out View) is
      Head : Interfaces.Unsigned_64;
      Tail : Interfaces.Unsigned_64;
   begin
      Layouts.Require_Ready (Item.Core);
      Head := Atomic.Load_Acquire_U64
        (Item.Head_Address);
      Tail := Atomic.Load_Acquire_U64
        (Item.Tail_Address);
      if Head /= Tail then
         raise Program_Error with "cannot destroy a nonempty SPSC ring";
      end if;
      Layouts.Mark_Destroyed (Item.Core);
      Detach (Item);
   end Destroy;

end Flyology.Data_Structures.Rings.SPSC;
