with Flyology_Allocators.Atomics;
with Flyology_Allocators.Policy;
with Flyology_Allocators.Storage;
with System.Storage_Elements;

package body Flyology_Allocators.Layouts is
   package Atomic renames Flyology_Allocators.Atomics;
   package Policy renames Flyology_Allocators.Policy;
   package Bytes renames Flyology_Allocators.Storage;
   package Native renames System.Storage_Elements;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Native.Integer_Address;
   use type Native.Storage_Offset;
   use type System.Address;

   Initializing   : constant Policy.Lifecycle_Code := 1;
   Ready          : constant Policy.Lifecycle_Code := 2;
   Destroyed      : constant Policy.Lifecycle_Code := 3;
   Poisoned_State : constant Policy.Lifecycle_Code := 5;

   State_Offset         : constant Byte_Count := 0;
   Reserved_32_Offset   : constant Byte_Count := 4;
   Reserved_64_1_Offset : constant Byte_Count := 8;
   Reserved_64_2_Offset : constant Byte_Count := 16;
   Extent_Offset        : constant Byte_Count := 24;
   Capacity_Offset      : constant Byte_Count := 32;
   Element_Offset       : constant Byte_Count := 36;
   Alignment_Offset     : constant Byte_Count := 40;
   Auxiliary_Offset     : constant Byte_Count := 44;
   Word_1_Offset        : constant Byte_Count := 48;
   Word_2_Offset        : constant Byte_Count := 56;

   function Checked_Add (Left, Right : Byte_Count) return Byte_Count is
   begin
      if not Policy.Addition_Fits (Left, Right) then
         raise Constraint_Error with "relocatable layout addition overflow";
      end if;
      return Policy.Add (Left, Right);
   end Checked_Add;

   function Checked_Multiply (Left, Right : Byte_Count) return Byte_Count is
   begin
      if not Policy.Multiplication_Fits (Left, Right) then
         raise Constraint_Error with "relocatable layout multiplication overflow";
      end if;
      return Left * Right;
   end Checked_Multiply;

   function Align_Up (Value, Alignment : Byte_Count) return Byte_Count is
      Remainder : Byte_Count;
   begin
      if not Policy.Is_Power_Of_Two (Alignment) then
         raise Constraint_Error with "layout alignment is not a power of two";
      elsif not Policy.Alignment_Fits (Value, Alignment) then
         raise Constraint_Error with "aligned layout value overflows";
      end if;
      Remainder := Value mod Alignment;
      return (if Remainder = 0 then Value else Checked_Add (Value, Alignment - Remainder));
   end Align_Up;

   function Capture
     (Region : Region_View; Location : Region_Offset; Extent : Byte_Count; Alignment : Byte_Count)
      return Local_View
   is
      Address : System.Address;
   begin
      if Location = Null_Offset then
         raise Region_Error with "null structure location";
      end if;
      Address :=
        Checked_Address (Region.Base, Region.Length_Value, Region.Attached, Location, Extent, Alignment);
      return (Base => Address, Location => Location, Extent => Extent, Epoch_Value => 0, Attached => True);
   end Capture;

   function Address_At
     (Item : Local_View; Relative : Byte_Count; Extent : Byte_Count; Alignment : Byte_Count := 1)
      return System.Address
   is
      Base_Value : Native.Integer_Address;
      At_Value   : Native.Integer_Address;
   begin
      if not Item.Attached or else Item.Base = System.Null_Address then
         raise Region_Error with "detached structure view";
      elsif not Policy.Slice_Fits (Item.Extent, Relative, Extent) then
         if Extent = 0 then
            raise Region_Error with "zero-sized structure-relative slice";
         else
            raise Layout_Error with "structure-relative extent is corrupt";
         end if;
      elsif Alignment = 0 or else (Alignment and (Alignment - 1)) /= 0 then
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

   procedure Write_Header (Item : Local_View; Extent : Byte_Count; Header : Header_Values) is
   begin
      Bytes.Write_U32 (Address_At (Item, Reserved_32_Offset, 4, 4), 0);
      Bytes.Write_U64 (Address_At (Item, Reserved_64_1_Offset, 8, 8), 0);
      Bytes.Write_U64 (Address_At (Item, Reserved_64_2_Offset, 8, 8), 0);
      Bytes.Write_U64 (Address_At (Item, Extent_Offset, 8, 8), Interfaces.Unsigned_64 (Extent));
      Bytes.Write_U32 (Address_At (Item, Capacity_Offset, 4, 4), Header.Capacity);
      Bytes.Write_U32 (Address_At (Item, Element_Offset, 4, 4), Header.Element_Size);
      Bytes.Write_U32 (Address_At (Item, Alignment_Offset, 4, 4), Header.Alignment);
      Bytes.Write_U32 (Address_At (Item, Auxiliary_Offset, 4, 4), Header.Auxiliary);
      Bytes.Write_U64 (Address_At (Item, Word_1_Offset, 8, 8), Header.Word_1);
      Bytes.Write_U64 (Address_At (Item, Word_2_Offset, 8, 8), Header.Word_2);
   end Write_Header;

   procedure Begin_Initialize
     (Item           : out Local_View;
      Region         : Region_View;
      Location       : Region_Offset;
      Extent         : Byte_Count;
      Header         : Header_Values;
      Base_Alignment : Byte_Count)
   is
      Previous_State : Interfaces.Unsigned_32;
      Epoch_Value    : Policy.Epoch;
   begin
      if not Atomic.Supported then
         raise Program_Error with "required 32/64-bit atomics are unavailable";
      elsif Extent < Header_Size then
         raise Constraint_Error with "structure extent is smaller than header";
      end if;
      Item := Capture (Region, Location, Extent, Base_Alignment);
      Previous_State := Atomic.Load_Acquire_U32 (Address_At (Item, State_Offset, 4, 4));
      if Policy.Valid_State (Previous_State) then
         if not Policy.Epoch_Can_Advance (Previous_State) then
            raise Layout_Error with "structure initialization epoch is exhausted";
         end if;
         Epoch_Value := Policy.Next_Epoch (Policy.Epoch (Policy.State_Epoch (Previous_State)));
      else
         Epoch_Value := 1;
      end if;
      Item.Epoch_Value := Epoch_Value;
      Atomic.Store_Release_U32
        (Address_At (Item, State_Offset, 4, 4), Policy.Make_State (Epoch_Value, Initializing));
      Write_Header (Item, Extent, Header);
   end Begin_Initialize;

   procedure Try_Begin_Initialize
     (Item           : out Local_View;
      Result         : out Initialization_Claim;
      Region         : Region_View;
      Location       : Region_Offset;
      Extent         : Byte_Count;
      Header         : Header_Values;
      Base_Alignment : Byte_Count)
   is
      Candidate : Local_View;
      Expected  : Interfaces.Unsigned_32 := 0;
      Desired   : constant Interfaces.Unsigned_32 := Policy.Make_State (1, Initializing);
   begin
      Item := (others => <>);
      if not Atomic.Supported then
         raise Program_Error with "required 32/64-bit atomics are unavailable";
      elsif Extent < Header_Size then
         raise Constraint_Error with "structure extent is smaller than header";
      end if;

      Candidate := Capture (Region, Location, Extent, Base_Alignment);
      if Atomic.Compare_Exchange_U32 (Address_At (Candidate, State_Offset, 4, 4), Expected, Desired) then
         Candidate.Epoch_Value := 1;
         Write_Header (Candidate, Extent, Header);
         Item := Candidate;
         Result := Claimed_Virgin;
      elsif not Policy.Valid_State (Expected) then
         raise Layout_Error with "virgin lifecycle sentinel is nonzero or corrupt";
      elsif Policy.State_Lifecycle (Expected) = Ready then
         Result := Existing_Ready;
      elsif Policy.State_Lifecycle (Expected) = Initializing then
         Result := Claim_In_Progress;
      elsif Policy.State_Lifecycle (Expected) = Poisoned_State then
         raise Poison_Error with "structure is poisoned";
      else
         raise Layout_Error with "structure is destroyed or inactive";
      end if;
   end Try_Begin_Initialize;

   procedure Publish (Item : Local_View) is
   begin
      Atomic.Store_Release_U32
        (Address_At (Item, State_Offset, 4, 4), Policy.Make_State (Policy.Epoch (Item.Epoch_Value), Ready));
   end Publish;

   procedure Invalidate_Nested (Item : Local_View; Relative : Byte_Count) is
      Address        : constant System.Address := Address_At (Item, Relative, 4, 4);
      Previous_State : constant Interfaces.Unsigned_32 := Atomic.Load_Acquire_U32 (Address);
      Epoch_Value    : Policy.Epoch;
   begin
      if Policy.Valid_State (Previous_State) then
         if not Policy.Epoch_Can_Advance (Previous_State) then
            raise Layout_Error with "nested initialization epoch is exhausted";
         end if;
         Epoch_Value := Policy.Next_Epoch (Policy.Epoch (Policy.State_Epoch (Previous_State)));
      else
         Epoch_Value := 1;
      end if;
      Atomic.Store_Release_U32 (Address, Policy.Make_State (Epoch_Value, Initializing));
   end Invalidate_Nested;

   procedure Attach
     (Item           : out Local_View;
      Header         : out Header_Values;
      Region         : Region_View;
      Location       : Region_Offset;
      Base_Alignment : Byte_Count)
   is
      Initial       : constant Local_View := Capture (Region, Location, Header_Size, Base_Alignment);
      Stored_Extent : Byte_Count;
      Epoch_Value   : Policy.Epoch;
   begin
      if not Atomic.Supported then
         raise Program_Error with "required 32/64-bit atomics are unavailable";
      end if;

      declare
         State : constant Interfaces.Unsigned_32 :=
           Atomic.Load_Acquire_U32 (Address_At (Initial, State_Offset, 4, 4));
      begin
         if not Policy.Valid_State (State) then
            raise Layout_Error with "structure initialization is incomplete";
         elsif Policy.State_Lifecycle (State) = Poisoned_State then
            raise Poison_Error with "structure is poisoned";
         elsif Policy.State_Lifecycle (State) /= Ready then
            raise Layout_Error with "structure initialization is incomplete";
         end if;
         Epoch_Value := Policy.Epoch (Policy.State_Epoch (State));
      end;

      if Bytes.Read_U32 (Address_At (Initial, Reserved_32_Offset, 4, 4)) /= 0
        or else Bytes.Read_U64 (Address_At (Initial, Reserved_64_1_Offset, 8, 8)) /= 0
        or else Bytes.Read_U64 (Address_At (Initial, Reserved_64_2_Offset, 8, 8)) /= 0
      then
         raise Layout_Error with "allocator reserved header is corrupt";
      end if;

      Stored_Extent := Byte_Count (Bytes.Read_U64 (Address_At (Initial, Extent_Offset, 8, 8)));
      if Stored_Extent < Header_Size then
         raise Layout_Error with "stored structure extent is smaller than header";
      end if;
      Item := Capture (Region, Location, Stored_Extent, Base_Alignment);
      Item.Epoch_Value := Epoch_Value;
      Header :=
        (Capacity     => Bytes.Read_U32 (Address_At (Item, Capacity_Offset, 4, 4)),
         Element_Size => Bytes.Read_U32 (Address_At (Item, Element_Offset, 4, 4)),
         Alignment    => Bytes.Read_U32 (Address_At (Item, Alignment_Offset, 4, 4)),
         Auxiliary    => Bytes.Read_U32 (Address_At (Item, Auxiliary_Offset, 4, 4)),
         Word_1       => Bytes.Read_U64 (Address_At (Item, Word_1_Offset, 8, 8)),
         Word_2       => Bytes.Read_U64 (Address_At (Item, Word_2_Offset, 8, 8)));
   end Attach;

   procedure Require_Ready (Item : Local_View) is
      State    : Interfaces.Unsigned_32;
      Expected : Interfaces.Unsigned_32;
   begin
      if not Item.Attached then
         raise Region_Error with "detached structure view";
      end if;
      State := Atomic.Load_Acquire_U32 (Address_At (Item, State_Offset, 4, 4));
      if Item.Epoch_Value not in Policy.Epoch then
         raise Layout_Error with "structure view has no initialization epoch";
      end if;
      Expected := Policy.Make_State (Policy.Epoch (Item.Epoch_Value), Ready);
      if State = Policy.Make_State (Policy.Epoch (Item.Epoch_Value), Poisoned_State) then
         raise Poison_Error with "structure is poisoned";
      elsif State /= Expected then
         raise Layout_Error with "structure view is stale or inactive";
      end if;
   end Require_Ready;

   procedure Poison (Item : Local_View) is
      Expected                  : Interfaces.Unsigned_32;
      Ready_State, Poison_State : Interfaces.Unsigned_32;
   begin
      if not Item.Attached then
         raise Region_Error with "detached structure view";
      end if;
      if Item.Epoch_Value not in Policy.Epoch then
         raise Layout_Error with "structure view has no initialization epoch";
      end if;
      Ready_State := Policy.Make_State (Policy.Epoch (Item.Epoch_Value), Ready);
      Poison_State := Policy.Make_State (Policy.Epoch (Item.Epoch_Value), Poisoned_State);
      Expected := Atomic.Load_Acquire_U32 (Address_At (Item, State_Offset, 4, 4));
      for Attempt in 1 .. 2 loop
         pragma Unreferenced (Attempt);
         if Expected = Poison_State then
            return;
         elsif Expected /= Ready_State then
            raise Layout_Error with "stale or inactive structure cannot be poisoned";
         elsif Atomic.Compare_Exchange_U32 (Address_At (Item, State_Offset, 4, 4), Expected, Poison_State)
         then
            return;
         end if;
      end loop;
      raise Busy_Error with "structure lifecycle changed while poisoning";
   end Poison;

   procedure Poison_At (Region : Region_View; Location : Region_Offset; Base_Alignment : Byte_Count) is
      Item  : Local_View := Capture (Region, Location, Header_Size, Base_Alignment);
      State : Interfaces.Unsigned_32;
   begin
      if not Atomic.Supported then
         raise Program_Error with "required 32/64-bit atomics are unavailable";
      end if;
      State := Atomic.Load_Acquire_U32 (Address_At (Item, State_Offset, 4, 4));
      if not Policy.Valid_State (State)
        or else (Policy.State_Lifecycle (State) /= Ready
                 and then Policy.State_Lifecycle (State) /= Poisoned_State)
      then
         raise Layout_Error with "incomplete structure cannot be recovery-poisoned";
      end if;
      Item.Epoch_Value := Policy.State_Epoch (State);
      Poison (Item);
   end Poison_At;

   function Is_Poisoned (Item : Local_View) return Boolean is
      State : Interfaces.Unsigned_32;
   begin
      if not Item.Attached then
         raise Region_Error with "detached structure view";
      elsif Item.Epoch_Value not in Policy.Epoch then
         raise Layout_Error with "structure view has no initialization epoch";
      end if;
      State := Atomic.Load_Acquire_U32 (Address_At (Item, State_Offset, 4, 4));
      if not Policy.Valid_State (State) then
         raise Layout_Error with "structure lifecycle state is corrupt";
      elsif Policy.State_Epoch (State) /= Item.Epoch_Value then
         raise Layout_Error with "structure view is stale";
      elsif Policy.State_Lifecycle (State) = Poisoned_State then
         return True;
      elsif Policy.State_Lifecycle (State) /= Ready then
         raise Layout_Error with "structure is not active";
      end if;
      return False;
   end Is_Poisoned;

   procedure Mark_Destroyed (Item : in out Local_View) is
      Expected : Interfaces.Unsigned_32;
   begin
      if not Item.Attached then
         raise Region_Error with "detached structure view";
      elsif Item.Epoch_Value not in Policy.Epoch then
         raise Layout_Error with "structure view has no initialization epoch";
      else
         Expected := Policy.Make_State (Policy.Epoch (Item.Epoch_Value), Ready);
      end if;
      if not Atomic.Compare_Exchange_U32
               (Address_At (Item, State_Offset, 4, 4),
                Expected,
                Policy.Make_State (Policy.Epoch (Item.Epoch_Value), Destroyed))
      then
         if Expected = Policy.Make_State (Policy.Epoch (Item.Epoch_Value), Poisoned_State) then
            raise Poison_Error with "structure is poisoned";
         else
            raise Layout_Error with "structure is stale or not active";
         end if;
      end if;
      Detach (Item);
   end Mark_Destroyed;

   procedure Detach (Item : in out Local_View) is
   begin
      Item := (others => <>);
   end Detach;

end Flyology_Allocators.Layouts;
