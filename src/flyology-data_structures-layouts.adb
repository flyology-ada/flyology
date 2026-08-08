with Flyology.Data_Structures.Atomics;
with Flyology.Data_Structures.Storage;
with System.Storage_Elements;

package body Flyology.Data_Structures.Layouts is
   package Atomic renames Flyology.Data_Structures.Atomics;
   package Bytes renames Flyology.Data_Structures.Storage;
   package Native renames System.Storage_Elements;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Native.Integer_Address;
   use type Native.Storage_Offset;
   use type System.Address;

   Initializing : constant Interfaces.Unsigned_32 := 1;
   Ready        : constant Interfaces.Unsigned_32 := 2;
   Destroyed    : constant Interfaces.Unsigned_32 := 3;
   Locked         : constant Interfaces.Unsigned_32 := 4;
   Poisoned_State : constant Interfaces.Unsigned_32 := 5;

   State_Offset      : constant Byte_Count := 0;
   Version_Offset    : constant Byte_Count := 4;
   Magic_Offset      : constant Byte_Count := 8;
   Schema_Offset     : constant Byte_Count := 16;
   Extent_Offset     : constant Byte_Count := 24;
   Capacity_Offset   : constant Byte_Count := 32;
   Element_Offset    : constant Byte_Count := 36;
   Alignment_Offset  : constant Byte_Count := 40;
   Auxiliary_Offset  : constant Byte_Count := 44;
   Word_1_Offset     : constant Byte_Count := 48;
   Word_2_Offset     : constant Byte_Count := 56;

   function Checked_Add (Left, Right : Byte_Count) return Byte_Count is
   begin
      if Right > Byte_Count'Last - Left then
         raise Constraint_Error with "relocatable layout addition overflow";
      end if;
      return Left + Right;
   end Checked_Add;

   function Checked_Multiply (Left, Right : Byte_Count) return Byte_Count is
   begin
      if Left /= 0 and then Right > Byte_Count'Last / Left then
         raise Constraint_Error with
           "relocatable layout multiplication overflow";
      end if;
      return Left * Right;
   end Checked_Multiply;

   function Align_Up
     (Value, Alignment : Byte_Count) return Byte_Count
   is
      Remainder : Byte_Count;
   begin
      if Alignment = 0
        or else (Alignment and (Alignment - 1)) /= 0
      then
         raise Constraint_Error with "layout alignment is not a power of two";
      end if;
      Remainder := Value mod Alignment;
      return
        (if Remainder = 0 then Value
         else Checked_Add (Value, Alignment - Remainder));
   end Align_Up;

   function Capture
     (Region    : Region_View;
      Location  : Region_Offset;
      Extent    : Byte_Count;
      Alignment : Byte_Count) return Local_View
   is
      Address : System.Address;
   begin
      if Location = Null_Offset then
         raise Region_Error with "null structure location";
      end if;
      Address := Checked_Address
        (Region.Base, Region.Length_Value, Region.Attached,
         Location, Extent, Alignment);
      return
        (Base     => Address,
         Location => Location,
         Extent   => Extent,
         Attached => True);
   end Capture;

   function Address_At
     (Item      : Local_View;
      Relative  : Byte_Count;
      Extent    : Byte_Count;
      Alignment : Byte_Count := 1) return System.Address
   is
      Base_Value : Native.Integer_Address;
      At_Value   : Native.Integer_Address;
   begin
      if not Item.Attached or else Item.Base = System.Null_Address then
         raise Region_Error with "detached structure view";
      elsif Relative > Item.Extent
        or else Extent > Item.Extent - Relative
      then
         raise Layout_Error with "structure-relative extent is corrupt";
      elsif Extent = 0 then
         raise Region_Error with "zero-sized structure-relative slice";
      elsif Alignment = 0
        or else (Alignment and (Alignment - 1)) /= 0
      then
         raise Region_Error with "invalid structure-relative alignment";
      elsif Relative > Byte_Count (Native.Storage_Offset'Last) then
         raise Region_Error with "structure-relative offset is not native";
      end if;

      Base_Value := Native.To_Integer (Item.Base);
      if Relative > Byte_Count (Native.Integer_Address'Last - Base_Value) then
         raise Region_Error with "structure-relative address overflows";
      end if;
      At_Value := Base_Value + Native.Integer_Address (Relative);
      if At_Value mod Native.Integer_Address (Alignment) /= 0 then
         raise Region_Error with "structure-relative slice is misaligned";
      end if;
      return Item.Base + Native.Storage_Offset (Relative);
   end Address_At;

   procedure Write_Header
     (Item     : Local_View;
      Identity : Layout_Identity;
      Extent   : Byte_Count;
      Header   : Header_Values) is
   begin
      Bytes.Write_U32
        (Address_At (Item, Version_Offset, 4, 4), Identity.Version);
      Bytes.Write_U64
        (Address_At (Item, Magic_Offset, 8, 8), Identity.Magic);
      Bytes.Write_U64
        (Address_At (Item, Schema_Offset, 8, 8), Identity.Schema);
      Bytes.Write_U64
        (Address_At (Item, Extent_Offset, 8, 8),
         Interfaces.Unsigned_64 (Extent));
      Bytes.Write_U32
        (Address_At (Item, Capacity_Offset, 4, 4), Header.Capacity);
      Bytes.Write_U32
        (Address_At (Item, Element_Offset, 4, 4), Header.Element_Size);
      Bytes.Write_U32
        (Address_At (Item, Alignment_Offset, 4, 4), Header.Alignment);
      Bytes.Write_U32
        (Address_At (Item, Auxiliary_Offset, 4, 4), Header.Auxiliary);
      Bytes.Write_U64
        (Address_At (Item, Word_1_Offset, 8, 8), Header.Word_1);
      Bytes.Write_U64
        (Address_At (Item, Word_2_Offset, 8, 8), Header.Word_2);
   end Write_Header;

   procedure Begin_Initialize
     (Item           : out Local_View;
      Region         : Region_View;
      Location       : Region_Offset;
      Identity       : Layout_Identity;
      Extent         : Byte_Count;
      Header         : Header_Values;
      Base_Alignment : Byte_Count) is
   begin
      if not Atomic.Supported then
         raise Program_Error with
           "process-capable 32/64-bit atomics are unavailable";
      elsif Extent < Header_Size then
         raise Constraint_Error with "structure extent is smaller than header";
      end if;
      Item := Capture (Region, Location, Extent, Base_Alignment);
      Atomic.Store_Release_U32
        (Address_At (Item, State_Offset, 4, 4), Initializing);
      Write_Header (Item, Identity, Extent, Header);
   end Begin_Initialize;

   procedure Publish (Item : Local_View) is
   begin
      Atomic.Store_Release_U32
        (Address_At (Item, State_Offset, 4, 4), Ready);
   end Publish;

   procedure Invalidate_Nested
     (Item : Local_View; Relative : Byte_Count) is
   begin
      Atomic.Store_Release_U32
        (Address_At (Item, Relative, 4, 4), Initializing);
   end Invalidate_Nested;

   procedure Attach
     (Item           : out Local_View;
      Header         : out Header_Values;
      Region         : Region_View;
      Location       : Region_Offset;
      Identity       : Layout_Identity;
      Base_Alignment : Byte_Count)
   is
      Initial : constant Local_View :=
        Capture (Region, Location, Header_Size, Base_Alignment);
      Stored_Extent : Byte_Count;
   begin
      if not Atomic.Supported then
         raise Program_Error with
           "process-capable 32/64-bit atomics are unavailable";
      end if;

      declare
         State : constant Interfaces.Unsigned_32 := Atomic.Load_Acquire_U32
           (Address_At (Initial, State_Offset, 4, 4));
      begin
         if State = Locked then
            raise Busy_Error with "structure is being mutated";
         elsif State = Poisoned_State then
            raise Poison_Error with "structure is poisoned";
         elsif State /= Ready then
            raise Layout_Error with "structure initialization is incomplete";
         end if;
      end;

      if Bytes.Read_U32
        (Address_At (Initial, Version_Offset, 4, 4)) /= Identity.Version
      then
         raise Layout_Error with "unsupported structure layout version";
      elsif Bytes.Read_U64
        (Address_At (Initial, Magic_Offset, 8, 8)) /= Identity.Magic
      then
         raise Layout_Error with "structure magic does not match";
      elsif Bytes.Read_U64
        (Address_At (Initial, Schema_Offset, 8, 8)) /= Identity.Schema
      then
         raise Layout_Error with "structure schema does not match";
      end if;

      Stored_Extent := Byte_Count
        (Bytes.Read_U64 (Address_At (Initial, Extent_Offset, 8, 8)));
      Item := Capture (Region, Location, Stored_Extent, Base_Alignment);
      Header :=
        (Capacity => Bytes.Read_U32
           (Address_At (Item, Capacity_Offset, 4, 4)),
         Element_Size => Bytes.Read_U32
           (Address_At (Item, Element_Offset, 4, 4)),
         Alignment => Bytes.Read_U32
           (Address_At (Item, Alignment_Offset, 4, 4)),
         Auxiliary => Bytes.Read_U32
           (Address_At (Item, Auxiliary_Offset, 4, 4)),
         Word_1 => Bytes.Read_U64
           (Address_At (Item, Word_1_Offset, 8, 8)),
         Word_2 => Bytes.Read_U64
           (Address_At (Item, Word_2_Offset, 8, 8)));
   end Attach;

   procedure Require_Ready (Item : Local_View) is
      State : Interfaces.Unsigned_32;
   begin
      if not Item.Attached then
         raise Region_Error with "detached structure view";
      end if;
      State := Atomic.Load_Acquire_U32
        (Address_At (Item, State_Offset, 4, 4));
      if State = Locked then
         raise Busy_Error with "structure is being mutated";
      elsif State = Poisoned_State then
         raise Poison_Error with "structure is poisoned";
      elsif State /= Ready then
         raise Layout_Error with "structure is not active";
      end if;
   end Require_Ready;

   function Try_Acquire (Item : Local_View) return Lock_Result is
      Expected : Interfaces.Unsigned_32 := Ready;
   begin
      if not Item.Attached then
         raise Region_Error with "detached structure view";
      end if;
      if Atomic.Compare_Exchange_U32
        (Address_At (Item, State_Offset, 4, 4), Expected, Locked)
      then
         return Acquired;
      elsif Expected = Locked then
         return Busy;
      elsif Expected = Poisoned_State then
         return Poisoned;
      else
         raise Layout_Error with "structure is not active";
      end if;
   end Try_Acquire;

   procedure Release (Item : Local_View) is
      Expected : Interfaces.Unsigned_32 := Locked;
   begin
      if not Item.Attached then
         raise Region_Error with "detached structure view";
      end if;
      if Atomic.Compare_Exchange_U32
        (Address_At (Item, State_Offset, 4, 4), Expected, Ready)
      then
         return;
      elsif Expected = Poisoned_State then
         raise Poison_Error with "structure was poisoned while guarded";
      else
         raise Layout_Error with "structure guard is not owned";
      end if;
   end Release;

   procedure Poison (Item : Local_View) is
      Expected : Interfaces.Unsigned_32;
   begin
      if not Item.Attached then
         raise Region_Error with "detached structure view";
      end if;
      Expected := Atomic.Load_Acquire_U32
        (Address_At (Item, State_Offset, 4, 4));
      for Attempt in 1 .. 2 loop
         pragma Unreferenced (Attempt);
         if Expected = Poisoned_State then
            return;
         elsif Expected /= Ready and then Expected /= Locked then
            raise Layout_Error with "inactive structure cannot be poisoned";
         elsif Atomic.Compare_Exchange_U32
           (Address_At (Item, State_Offset, 4, 4), Expected, Poisoned_State)
         then
            return;
         end if;
      end loop;
      raise Busy_Error with "structure lifecycle changed while poisoning";
   end Poison;

   procedure Poison_At
     (Region         : Region_View;
      Location       : Region_Offset;
      Identity       : Layout_Identity;
      Base_Alignment : Byte_Count)
   is
      Item : constant Local_View :=
        Capture (Region, Location, Header_Size, Base_Alignment);
      State : constant Interfaces.Unsigned_32 := Atomic.Load_Acquire_U32
        (Address_At (Item, State_Offset, 4, 4));
   begin
      if State /= Ready
        and then State /= Locked
        and then State /= Poisoned_State
      then
         raise Layout_Error with
           "incomplete structure cannot be recovery-poisoned";
      elsif Bytes.Read_U32
        (Address_At (Item, Version_Offset, 4, 4)) /= Identity.Version
        or else Bytes.Read_U64
          (Address_At (Item, Magic_Offset, 8, 8)) /= Identity.Magic
        or else Bytes.Read_U64
          (Address_At (Item, Schema_Offset, 8, 8)) /= Identity.Schema
      then
         raise Layout_Error with "recovery poison identity does not match";
      end if;
      Poison (Item);
   end Poison_At;

   function Is_Poisoned (Item : Local_View) return Boolean is
   begin
      if not Item.Attached then
         raise Region_Error with "detached structure view";
      end if;
      return Atomic.Load_Acquire_U32
        (Address_At (Item, State_Offset, 4, 4)) = Poisoned_State;
   end Is_Poisoned;

   procedure Mark_Destroyed (Item : in out Local_View) is
      Expected : Interfaces.Unsigned_32 := Ready;
   begin
      if not Item.Attached then
         raise Region_Error with "detached structure view";
      elsif not Atomic.Compare_Exchange_U32
        (Address_At (Item, State_Offset, 4, 4), Expected, Destroyed)
      then
         if Expected = Locked then
            raise Busy_Error with "structure is being mutated";
         elsif Expected = Poisoned_State then
            raise Poison_Error with "structure is poisoned";
         else
            raise Layout_Error with "structure is not active";
         end if;
      end if;
      Detach (Item);
   end Mark_Destroyed;

   procedure Detach (Item : in out Local_View) is
   begin
      Item := (others => <>);
   end Detach;

end Flyology.Data_Structures.Layouts;
