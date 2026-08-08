with Flyology.Data_Structures.Atomics;
with Flyology.Data_Structures.Policy;
with Flyology.Data_Structures.Storage;
with System.Storage_Elements;

package body Flyology.Data_Structures.Dynamic.Hash_Maps is
   package Atomic renames Flyology.Data_Structures.Atomics;
   package Policy renames Flyology.Data_Structures.Policy;
   package Bytes renames Flyology.Data_Structures.Storage;
   package Native renames System.Storage_Elements;

   use type Arena_Provider.Allocation_Handle;
   use type Interfaces.Unsigned_32;
   use type Native.Storage_Offset;
   use type System.Address;

   Header_Extent : constant Byte_Count := 128;
   Guard_Offset : constant Byte_Count := 44;
   Count_Offset : constant Byte_Count := 56;
   Capacity_Offset : constant Byte_Count := 64;
   Current_Offset : constant Byte_Count := 72;
   Retired_Offset : constant Byte_Count := 88;
   Arena_Epoch_Offset : constant Byte_Count := 104;
   Reserved_32_Offset : constant Byte_Count := 108;
   Capacity_Check_Offset : constant Byte_Count := 112;
   Reserved_2_Offset : constant Byte_Count := 120;

   Capacity_Check_Mask : constant Interfaces.Unsigned_64 :=
     16#8E52_CA19_73B4_06DF#;

   function Capacity_Check
     (Capacity : Interfaces.Unsigned_64) return Interfaces.Unsigned_64 is
     (Capacity xor Capacity_Check_Mask);

   Slot_State_Offset : constant Byte_Count := 0;
   Slot_Reserved_Offset : constant Byte_Count := 4;
   Hash_Offset : constant Byte_Count := 8;
   Entry_Data_Offset : constant Byte_Count := 16;

   Empty_State : constant Interfaces.Unsigned_32 := 0;
   Occupied_State : constant Interfaces.Unsigned_32 := 1;
   Deleted_State : constant Interfaces.Unsigned_32 := 2;
   Unlocked : constant Interfaces.Unsigned_32 := 0;
   Locked : constant Interfaces.Unsigned_32 := 1;

   type Table_View is record
      Base     : System.Address := System.Null_Address;
      Extent   : Byte_Count := 0;
      Capacity : Interfaces.Unsigned_32 := 0;
   end record;

   function Required_Storage return Byte_Count is (Header_Extent);

   function Storage_Alignment return Byte_Count is
     (Byte_Count'Max
        (8, Byte_Count'Max
           (Byte_Count (Key.Alignment), Byte_Count (Element.Alignment))));

   function Field_At
     (Address : System.Address; Offset : Native.Storage_Offset)
      return System.Address is
     (Address + Offset);
   pragma Inline_Always (Field_At);

   function Read_Handle (Address : System.Address)
      return Arena_Provider.Allocation_Handle is
     ((Token      => Bytes.Read_U64 (Address),
       Generation => Bytes.Read_U64 (Field_At (Address, 8))));

   procedure Write_Handle
     (Address : System.Address; Value : Arena_Provider.Allocation_Handle) is
   begin
      Bytes.Write_U64 (Address, Value.Token);
      Bytes.Write_U64 (Field_At (Address, 8), Value.Generation);
   end Write_Handle;

   procedure Slot_Geometry
     (Key_Offset, Value_Offset, Stride : out Byte_Count) is
   begin
      Key_Offset := Layouts.Align_Up
        (Entry_Data_Offset, Byte_Count (Key.Alignment));
      Value_Offset := Layouts.Align_Up
        (Layouts.Checked_Add (Key_Offset, Byte_Count (Key.Size)),
         Byte_Count (Element.Alignment));
      Stride := Layouts.Align_Up
        (Layouts.Checked_Add (Value_Offset, Byte_Count (Element.Size)),
         Storage_Alignment);
   end Slot_Geometry;

   procedure Validate_Configuration
      (Arena            : Arena_Provider.View;
      Initial_Capacity : Positive;
      Metadata         : out Arena_Provider.Metadata;
      Key_Offset       : out Byte_Count;
      Value_Offset     : out Byte_Count;
      Stride           : out Byte_Count)
   is
      Initial_Bytes : Byte_Count;
   begin
      if Initial_Capacity < 2
        or else not Policy.Is_Power_Of_Two (Byte_Count (Initial_Capacity))
      then
         raise Constraint_Error with
           "dynamic-map initial capacity must be a power of two at least two";
      end if;
      Metadata := Arena_Provider.Current_Metadata (Arena);
      if Key.Signature = 0
        or else Key.Version = 0
        or else Element.Signature = 0
        or else Element.Version = 0
        or else Key.Alignment not in 1 | 2 | 4 | 8 | 16 | 32 | 64
        or else Element.Alignment not in 1 | 2 | 4 | 8 | 16 | 32 | 64
        or else Metadata.Minimum_Block_Size <
          Interfaces.Unsigned_32 (Storage_Alignment)
      then
         raise Constraint_Error with
           "arena cannot satisfy the immutable map element contract";
      end if;
      Slot_Geometry (Key_Offset, Value_Offset, Stride);
      Initial_Bytes := Layouts.Checked_Multiply
        (Byte_Count (Initial_Capacity), Stride);
      if Initial_Bytes > Byte_Count (Metadata.Usable_Capacity) then
         raise Constraint_Error with
           "dynamic-map initial table does not fit the arena";
      end if;
   end Validate_Configuration;

   procedure Set_View
     (Item             : out View;
      Core             : Layouts.Local_View;
      Initial_Capacity : Interfaces.Unsigned_32;
      Key_Size         : Interfaces.Unsigned_32;
      Value_Size       : Interfaces.Unsigned_32;
      Arena_ID         : Interfaces.Unsigned_64;
      Arena_Epoch      : Interfaces.Unsigned_32;
      Key_Offset       : Byte_Count;
      Value_Offset     : Byte_Count;
      Stride           : Byte_Count) is
   begin
      Item.Core := Core;
      Item.Guard_Address := Layouts.Address_At (Core, Guard_Offset, 4, 4);
      Item.Count_Address := Layouts.Address_At (Core, Count_Offset, 8, 8);
      Item.Capacity_Address := Layouts.Address_At
        (Core, Capacity_Offset, 8, 8);
      Item.Capacity_Check_Address := Layouts.Address_At
        (Core, Capacity_Check_Offset, 8, 8);
      Item.Current_Address := Layouts.Address_At
        (Core, Current_Offset, 16, 8);
      Item.Retired_Address := Layouts.Address_At
        (Core, Retired_Offset, 16, 8);
      Item.Initial_Value := Initial_Capacity;
      Item.Key_Value := Key_Size;
      Item.Value_Value := Value_Size;
      Item.Arena_ID_Value := Arena_ID;
      Item.Arena_Epoch_Value := Arena_Epoch;
      Item.Key_Offset := Key_Offset;
      Item.Value_Offset := Value_Offset;
      Item.Stride := Stride;
   end Set_View;

   procedure Detach (Item : in out View) is
   begin
      Layouts.Detach (Item.Core);
      Item.Guard_Address := System.Null_Address;
      Item.Count_Address := System.Null_Address;
      Item.Capacity_Address := System.Null_Address;
      Item.Capacity_Check_Address := System.Null_Address;
      Item.Current_Address := System.Null_Address;
      Item.Retired_Address := System.Null_Address;
      Item.Initial_Value := 0;
      Item.Key_Value := 0;
      Item.Value_Value := 0;
      Item.Arena_ID_Value := 0;
      Item.Arena_Epoch_Value := 0;
      Item.Key_Offset := 0;
      Item.Value_Offset := 0;
      Item.Stride := 0;
   end Detach;

   procedure Finish_Initialize
     (Item             : out View;
      Core             : Layouts.Local_View;
      Initial_Capacity : Interfaces.Unsigned_32;
      Key_Size         : Interfaces.Unsigned_32;
      Value_Size       : Interfaces.Unsigned_32;
      Arena_ID         : Interfaces.Unsigned_64;
      Arena_Epoch      : Interfaces.Unsigned_32;
      Key_Offset       : Byte_Count;
      Value_Offset     : Byte_Count;
      Stride           : Byte_Count) is
   begin
      Set_View
        (Item, Core, Initial_Capacity, Key_Size, Value_Size, Arena_ID,
         Arena_Epoch, Key_Offset, Value_Offset, Stride);
      Bytes.Write_U64 (Item.Capacity_Address, 0);
      Bytes.Write_U64 (Item.Capacity_Check_Address, Capacity_Check (0));
      Write_Handle (Item.Current_Address, Arena_Provider.Null_Allocation);
      Write_Handle (Item.Retired_Address, Arena_Provider.Null_Allocation);
      Bytes.Write_U32
        (Layouts.Address_At (Core, Arena_Epoch_Offset, 4, 4), Arena_Epoch);
      Bytes.Write_U32
        (Layouts.Address_At (Core, Reserved_32_Offset, 4, 4), 0);
      Bytes.Write_U64
        (Layouts.Address_At (Core, Reserved_2_Offset, 8, 8), 0);
      Layouts.Publish (Item.Core);
   end Finish_Initialize;

   procedure Initialize
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive)
   is
      Metadata : Arena_Provider.Metadata;
      Key_Offset, Value_Offset, Stride : Byte_Count;
      Core : Layouts.Local_View;
   begin
      Validate_Configuration
        (Arena, Initial_Capacity, Metadata,
         Key_Offset, Value_Offset, Stride);
      Detach (Item);
      Layouts.Begin_Initialize
        (Core, Region, Location, Identity, Header_Extent,
         (Capacity     => Interfaces.Unsigned_32 (Initial_Capacity),
          Element_Size => Interfaces.Unsigned_32 (Key.Size),
          Alignment    => Interfaces.Unsigned_32 (Element.Size),
          Auxiliary    => Unlocked,
          Word_1       => Metadata.Instance_ID,
          Word_2       => 0),
         8);
      Finish_Initialize
         (Item, Core, Interfaces.Unsigned_32 (Initial_Capacity),
         Interfaces.Unsigned_32 (Key.Size),
         Interfaces.Unsigned_32 (Element.Size), Metadata.Instance_ID,
         Metadata.Incarnation, Key_Offset, Value_Offset, Stride);
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Initialize;

   procedure Create_Or_Attach
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive;
      Result           : out Open_Result)
   is
      Metadata : Arena_Provider.Metadata;
      Key_Offset, Value_Offset, Stride : Byte_Count;
      Core : Layouts.Local_View;
      Claim : Layouts.Initialization_Claim;
   begin
      Validate_Configuration
        (Arena, Initial_Capacity, Metadata,
         Key_Offset, Value_Offset, Stride);
      Detach (Item);
      Layouts.Try_Begin_Initialize
        (Core, Claim, Region, Location, Identity, Header_Extent,
         (Capacity     => Interfaces.Unsigned_32 (Initial_Capacity),
          Element_Size => Interfaces.Unsigned_32 (Key.Size),
          Alignment    => Interfaces.Unsigned_32 (Element.Size),
          Auxiliary    => Unlocked,
          Word_1       => Metadata.Instance_ID,
          Word_2       => 0),
         8);
      case Claim is
         when Layouts.Claimed_Virgin =>
            Finish_Initialize
              (Item, Core, Interfaces.Unsigned_32 (Initial_Capacity),
               Interfaces.Unsigned_32 (Key.Size),
               Interfaces.Unsigned_32 (Element.Size), Metadata.Instance_ID,
               Metadata.Incarnation, Key_Offset, Value_Offset, Stride);
            Result := Initialized_New;
         when Layouts.Existing_Ready =>
            Attach
              (Item, Region, Location, Arena, Initial_Capacity);
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

   procedure Require_Arena (Item : View; Arena : Arena_Provider.View) is
      Metadata : constant Arena_Provider.Metadata :=
        Arena_Provider.Current_Metadata (Arena);
   begin
      if Metadata.Instance_ID /= Item.Arena_ID_Value
        or else Metadata.Incarnation /= Item.Arena_Epoch_Value
      then
         raise Layout_Error with
           "dynamic map is attached to another arena incarnation";
      end if;
   end Require_Arena;

   function Table_Bytes
     (Item : View; Capacity : Interfaces.Unsigned_64) return Byte_Count is
     (Layouts.Checked_Multiply (Byte_Count (Capacity), Item.Stride));

   procedure Attach_Table
     (Item     : View;
      Arena    : Arena_Provider.View;
      Handle   : Arena_Provider.Allocation_Handle;
      Capacity : Interfaces.Unsigned_64;
      Table    : out Table_View)
   is
      Region : Region_View;
      Required : Byte_Count;
   begin
      Table := (others => <>);
      if Handle = Arena_Provider.Null_Allocation then
         if Capacity /= 0 then
            raise Layout_Error with "dynamic-map table has no allocation";
         end if;
         return;
      elsif Capacity < 2
        or else Capacity > Interfaces.Unsigned_64 (Natural'Last)
        or else not Policy.Is_Power_Of_Two (Byte_Count (Capacity))
      then
         raise Layout_Error with "dynamic-map table capacity is corrupt";
      end if;
      Required := Table_Bytes (Item, Capacity);
      Arena_Provider.Attach_Allocation (Region, Arena, Handle);
      if Region.Length_Value < Required
        or else Region.Base = System.Null_Address
      then
         raise Layout_Error with "dynamic-map allocation is too small";
      end if;
      Table :=
        (Base     => Region.Base,
         Extent   => Required,
         Capacity => Interfaces.Unsigned_32 (Capacity));
   exception
      when Handle_Error =>
         raise Layout_Error with "dynamic-map allocation handle is stale";
   end Attach_Table;

   function Slot_Address
     (Item : View; Table : Table_View; Index : Interfaces.Unsigned_64)
      return System.Address
   is
      Relative : Byte_Count;
   begin
      if Table.Base = System.Null_Address
        or else Index >= Interfaces.Unsigned_64 (Table.Capacity)
      then
         raise Layout_Error with "dynamic-map entry index is corrupt";
      end if;
      Relative := Layouts.Checked_Multiply (Byte_Count (Index), Item.Stride);
      if Relative > Table.Extent
        or else Item.Stride > Table.Extent - Relative
        or else Relative > Byte_Count (Native.Storage_Offset'Last)
      then
         raise Layout_Error with "dynamic-map entry extent is corrupt";
      end if;
      return Table.Base + Native.Storage_Offset (Relative);
   end Slot_Address;
   pragma Inline_Always (Slot_Address);

   function Slot_Field
     (Item : View; Slot : System.Address;
      Offset, Extent : Byte_Count) return System.Address is
   begin
      if Offset > Item.Stride or else Extent > Item.Stride - Offset
        or else Offset > Byte_Count (Native.Storage_Offset'Last)
      then
         raise Layout_Error with "dynamic-map field extent is corrupt";
      end if;
      return Slot + Native.Storage_Offset (Offset);
   end Slot_Field;
   pragma Inline_Always (Slot_Field);

   function Key_Binding
     (Item : View; Slot : System.Address; Writable : Boolean)
      return Immutable_Storage_View is
     (Base      => Slot_Field
        (Item, Slot, Item.Key_Offset, Byte_Count (Key.Size)),
      Extent    => Byte_Count (Key.Size),
      Signature => Key.Signature,
      Version   => Key.Version,
      Writable  => Writable);

   function Value_Binding
     (Item : View; Slot : System.Address; Writable : Boolean)
      return Immutable_Storage_View is
     (Base      => Slot_Field
        (Item, Slot, Item.Value_Offset, Byte_Count (Element.Size)),
      Extent    => Byte_Count (Element.Size),
      Signature => Element.Signature,
      Version   => Element.Version,
      Writable  => Writable);

   function Stored_Key_Hash
     (Item : View; Slot : System.Address) return Interfaces.Unsigned_64
   is
      Reference : Key.Const_Ref;
   begin
      Key.Bind (Reference, Key_Binding (Item, Slot, False));
      return Key.Hash (Reference);
   end Stored_Key_Hash;

   procedure Validate_Table
     (Item : View; Table : Table_View; Expected_Count : Interfaces.Unsigned_64)
   is
      Occupied : Interfaces.Unsigned_64 := 0;
      State, Candidate_State : Interfaces.Unsigned_32;
      Stored_Hash, Candidate_Hash : Interfaces.Unsigned_64;
      Candidate : Interfaces.Unsigned_64;
      Slot, Candidate_Entry : System.Address;
      Reached : Boolean;
   begin
      for Index in Interfaces.Unsigned_64 range
        0 .. Interfaces.Unsigned_64 (Table.Capacity) - 1
      loop
         Slot := Slot_Address (Item, Table, Index);
         State := Bytes.Read_U32
           (Slot_Field (Item, Slot, Slot_State_Offset, 4));
         if Bytes.Read_U32
           (Slot_Field (Item, Slot, Slot_Reserved_Offset, 4)) /= 0
         then
            raise Layout_Error with
              "dynamic-map entry reserved field is corrupt";
         elsif State = Occupied_State then
            Occupied := Occupied + 1;
         elsif State /= Empty_State and then State /= Deleted_State then
            raise Layout_Error with "dynamic-map entry state is corrupt";
         end if;
      end loop;
      if Occupied /= Expected_Count then
         raise Layout_Error with "dynamic-map occupied count is corrupt";
      end if;

      for Index in Interfaces.Unsigned_64 range
        0 .. Interfaces.Unsigned_64 (Table.Capacity) - 1
      loop
         Slot := Slot_Address (Item, Table, Index);
         State := Bytes.Read_U32
           (Slot_Field (Item, Slot, Slot_State_Offset, 4));
         if State = Occupied_State then
            Stored_Hash := Bytes.Read_U64
              (Slot_Field (Item, Slot, Hash_Offset, 8));
            if Stored_Hash /= Stored_Key_Hash (Item, Slot) then
               raise Layout_Error with
                 "dynamic-map stored key hash is corrupt";
            end if;
            Reached := False;
            for Probe in Interfaces.Unsigned_64 range
              0 .. Interfaces.Unsigned_64 (Table.Capacity) - 1
            loop
               Candidate := Policy.Masked_Index
                 (Stored_Hash + Probe,
                  Policy.Positive_U32 (Table.Capacity));
               Candidate_Entry := Slot_Address (Item, Table, Candidate);
               Candidate_State := Bytes.Read_U32
                 (Slot_Field
                    (Item, Candidate_Entry, Slot_State_Offset, 4));
               if Candidate_State = Empty_State then
                  raise Layout_Error with
                    "dynamic-map entry is outside its probe chain";
               elsif Candidate = Index then
                  Reached := True;
                  exit;
               elsif Candidate_State = Occupied_State then
                  Candidate_Hash := Bytes.Read_U64
                    (Slot_Field (Item, Candidate_Entry, Hash_Offset, 8));
                  if Candidate_Hash = Stored_Hash then
                     declare
                        Candidate_Key : Key.Const_Ref;
                        Stored_Key    : Key.Const_Ref;
                     begin
                        Key.Bind
                          (Candidate_Key,
                           Key_Binding (Item, Candidate_Entry, False));
                        Key.Bind
                          (Stored_Key, Key_Binding (Item, Slot, False));
                        if Key.Equivalent (Candidate_Key, Stored_Key) then
                           raise Layout_Error with
                             "dynamic-map contains duplicate keys";
                        end if;
                     end;
                  end if;
               end if;
            end loop;
            if not Reached then
               raise Layout_Error with
                 "dynamic-map entry is outside its probe chain";
            end if;
         end if;
      end loop;
   end Validate_Table;

   procedure Attach
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive)
   is
      Metadata : Arena_Provider.Metadata;
      Key_Offset, Value_Offset, Stride : Byte_Count;
      Core : Layouts.Local_View;
      Header : Layouts.Header_Values;
      Arena_Epoch : Interfaces.Unsigned_32;
      Current_Capacity : Interfaces.Unsigned_64;
      Current, Retired : Arena_Provider.Allocation_Handle;
      Table, Retired_Table : Table_View;
   begin
      Validate_Configuration
        (Arena, Initial_Capacity, Metadata,
         Key_Offset, Value_Offset, Stride);
      Detach (Item);
      Layouts.Attach (Core, Header, Region, Location, Identity, 8);
      Arena_Epoch := Bytes.Read_U32
        (Layouts.Address_At (Core, Arena_Epoch_Offset, 4, 4));
      if Header.Capacity /= Interfaces.Unsigned_32 (Initial_Capacity)
        or else Header.Element_Size /= Interfaces.Unsigned_32 (Key.Size)
        or else Header.Alignment /= Interfaces.Unsigned_32 (Element.Size)
        or else Header.Word_1 /= Metadata.Instance_ID
        or else Arena_Epoch /= Metadata.Incarnation
        or else Core.Extent /= Header_Extent
      then
         raise Layout_Error with
           "dynamic-map creation parameters do not match";
      elsif Header.Auxiliary = Locked then
         raise Busy_Error with "dynamic-map guard is active";
      elsif Header.Auxiliary /= Unlocked
        or else Bytes.Read_U32
          (Layouts.Address_At (Core, Reserved_32_Offset, 4, 4)) /= 0
        or else Bytes.Read_U64
          (Layouts.Address_At (Core, Reserved_2_Offset, 8, 8)) /= 0
      then
         raise Layout_Error with "dynamic-map header is corrupt";
      end if;
      Set_View
        (Item, Core, Header.Capacity, Header.Element_Size, Header.Alignment,
         Header.Word_1, Arena_Epoch, Key_Offset, Value_Offset, Stride);
      Current_Capacity := Bytes.Read_U64 (Item.Capacity_Address);
      if Bytes.Read_U64 (Item.Capacity_Check_Address) /=
           Capacity_Check (Current_Capacity)
        or else Header.Word_2 > Current_Capacity
        or else Current_Capacity > Interfaces.Unsigned_64 (Natural'Last)
      then
         raise Layout_Error with "dynamic-map count is corrupt";
      end if;
      Current := Read_Handle (Item.Current_Address);
      Retired := Read_Handle (Item.Retired_Address);
      Attach_Table (Item, Arena, Current, Current_Capacity, Table);
      if Current = Arena_Provider.Null_Allocation
        and then Header.Word_2 /= 0
      then
         raise Layout_Error with "empty dynamic-map table has entries";
      elsif Current /= Arena_Provider.Null_Allocation then
         Validate_Table (Item, Table, Header.Word_2);
      end if;
      if Retired /= Arena_Provider.Null_Allocation then
         if Retired = Current then
            raise Layout_Error with
              "dynamic-map current and retired allocations alias";
         end if;
         Attach_Table (Item, Arena, Retired, 2, Retired_Table);
      end if;
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Attach;

   function Is_Attached (Item : View) return Boolean is (Item.Core.Attached);

   function Is_Poisoned (Item : View) return Boolean is
     (Layouts.Is_Poisoned (Item.Core));

   procedure Poison (Region : Region_View; Location : Region_Offset) is
   begin
      Layouts.Poison_At (Region, Location, Identity, 8);
   end Poison;

   procedure Acquire (Item : View) is
      Expected : Interfaces.Unsigned_32 := Unlocked;
   begin
      if not Item.Core.Attached
        or else Item.Guard_Address = System.Null_Address
      then
         raise Region_Error with "detached dynamic-map view";
      elsif not Atomic.Compare_Exchange_U32
        (Item.Guard_Address, Expected, Locked)
      then
         Layouts.Require_Ready (Item.Core);
         if Expected = Locked then
            raise Busy_Error with "dynamic map is busy";
         else
            raise Layout_Error with "dynamic-map guard is corrupt";
         end if;
      end if;
      begin
         Layouts.Require_Ready (Item.Core);
      exception
         when others =>
            Atomic.Store_Release_U32 (Item.Guard_Address, Unlocked);
            raise;
      end;
   end Acquire;

   procedure Release_Guard (Item : View) is
   begin
      Atomic.Store_Release_U32 (Item.Guard_Address, Unlocked);
   end Release_Guard;

   procedure Finish_Failure (Item : View; Mutated : Boolean) is
   begin
      if Mutated then
         begin
            Layouts.Poison (Item.Core);
         exception
            when others =>
               Release_Guard (Item);
               raise;
         end;
      end if;
      Release_Guard (Item);
   end Finish_Failure;

   function Stored_Capacity (Item : View) return Interfaces.Unsigned_64 is
      Value : constant Interfaces.Unsigned_64 :=
        Bytes.Read_U64 (Item.Capacity_Address);
   begin
      if Bytes.Read_U64 (Item.Capacity_Check_Address) /=
           Capacity_Check (Value)
        or else Value > Interfaces.Unsigned_64 (Natural'Last)
      then
         raise Layout_Error with "dynamic-map capacity is corrupt";
      end if;
      return Value;
   end Stored_Capacity;

   function Stored_Count (Item : View) return Interfaces.Unsigned_64 is
      Count : constant Interfaces.Unsigned_64 :=
        Bytes.Read_U64 (Item.Count_Address);
      Current_Capacity : constant Interfaces.Unsigned_64 :=
        Stored_Capacity (Item);
   begin
      if Count > Current_Capacity then
         raise Layout_Error with "dynamic-map count is corrupt";
      end if;
      return Count;
   end Stored_Count;

   function Capacity (Item : View) return Natural is
      Value : Interfaces.Unsigned_64;
   begin
      Acquire (Item);
      begin
         Value := Stored_Capacity (Item);
      exception
         when others =>
            Release_Guard (Item);
            raise;
      end;
      Release_Guard (Item);
      return Natural (Value);
   end Capacity;

   function Length (Item : View) return Natural is
      Value : Interfaces.Unsigned_64;
   begin
      Acquire (Item);
      begin
         Value := Stored_Count (Item);
      exception
         when others =>
            Release_Guard (Item);
            raise;
      end;
      Release_Guard (Item);
      return Natural (Value);
   end Length;

   function Key_Matches
     (Item : View; Slot : System.Address;
      Hash_Value : Interfaces.Unsigned_64;
      Stored_Key : Key.Value) return Boolean
   is
      Reference : Key.Const_Ref;
   begin
      if Bytes.Read_U64 (Slot_Field (Item, Slot, Hash_Offset, 8)) /=
        Hash_Value
      then
         return False;
      end if;
      Key.Bind (Reference, Key_Binding (Item, Slot, False));
      return Key.Equivalent (Stored_Key, Reference);
   end Key_Matches;

   procedure Find
     (Item : View; Table : Table_View;
      Stored_Key : Key.Value;
      Found : out Boolean; Index : out Interfaces.Unsigned_64;
      Insertion : out Interfaces.Unsigned_64)
   is
      Hash_Value : constant Interfaces.Unsigned_64 := Key.Hash (Stored_Key);
      Candidate : Interfaces.Unsigned_64;
      State : Interfaces.Unsigned_32;
      First_Deleted : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;
      Slot : System.Address;
   begin
      for Probe in Interfaces.Unsigned_64 range
        0 .. Interfaces.Unsigned_64 (Table.Capacity) - 1
      loop
         Candidate := Policy.Masked_Index
           (Hash_Value + Probe, Policy.Positive_U32 (Table.Capacity));
         Slot := Slot_Address (Item, Table, Candidate);
         State := Bytes.Read_U32
           (Slot_Field (Item, Slot, Slot_State_Offset, 4));
         if State = Occupied_State
           and then Key_Matches (Item, Slot, Hash_Value, Stored_Key)
         then
            Found := True;
            Index := Candidate;
            Insertion := Candidate;
            return;
         elsif State = Deleted_State
           and then First_Deleted = Interfaces.Unsigned_64'Last
         then
            First_Deleted := Candidate;
         elsif State = Empty_State then
            Found := False;
            Index := 0;
            Insertion :=
              (if First_Deleted = Interfaces.Unsigned_64'Last
               then Candidate else First_Deleted);
            return;
         elsif State /= Occupied_State and then State /= Deleted_State then
            raise Layout_Error with "dynamic-map entry state is corrupt";
         end if;
      end loop;
      Found := False;
      Index := 0;
      Insertion := First_Deleted;
   end Find;

   procedure Initialize_Table (Item : View; Table : Table_View) is
      Slot : System.Address;
   begin
      for Index in Interfaces.Unsigned_64 range
        0 .. Interfaces.Unsigned_64 (Table.Capacity) - 1
      loop
         Slot := Slot_Address (Item, Table, Index);
         Bytes.Write_U32
           (Slot_Field (Item, Slot, Slot_State_Offset, 4), Empty_State);
         Bytes.Write_U32
           (Slot_Field (Item, Slot, Slot_Reserved_Offset, 4), 0);
      end loop;
   end Initialize_Table;

   procedure Insert_Stored
     (Item : View; Source : System.Address; Target_Table : Table_View)
   is
      Hash_Value : constant Interfaces.Unsigned_64 := Bytes.Read_U64
        (Slot_Field (Item, Source, Hash_Offset, 8));
      Candidate : Interfaces.Unsigned_64;
      Target : System.Address;
   begin
      for Probe in Interfaces.Unsigned_64 range
        0 .. Interfaces.Unsigned_64 (Target_Table.Capacity) - 1
      loop
         Candidate := Policy.Masked_Index
           (Hash_Value + Probe, Policy.Positive_U32 (Target_Table.Capacity));
         Target := Slot_Address (Item, Target_Table, Candidate);
         if Bytes.Read_U32
           (Slot_Field (Item, Target, Slot_State_Offset, 4)) = Empty_State
         then
            Bytes.Write_U64
              (Slot_Field (Item, Target, Hash_Offset, 8), Hash_Value);
            Key.Copy
              (Key_Binding (Item, Source, False),
               Key_Binding (Item, Target, True));
            Element.Copy
              (Value_Binding (Item, Source, False),
               Value_Binding (Item, Target, True));
            Bytes.Write_U32
              (Slot_Field (Item, Target, Slot_State_Offset, 4),
               Occupied_State);
            return;
         end if;
      end loop;
      raise Layout_Error with "dynamic-map rehash target is full";
   end Insert_Stored;

   procedure Cleanup_Retired
     (Item    : View;
      Arena   : in out Arena_Provider.View;
      Mutated : in out Boolean)
   is
      Retired : constant Arena_Provider.Allocation_Handle :=
        Read_Handle (Item.Retired_Address);
   begin
      if Retired = Arena_Provider.Null_Allocation then
         return;
      end if;
      Arena_Provider.Release (Arena, Retired);
      Mutated := True;
      Write_Handle (Item.Retired_Address, Arena_Provider.Null_Allocation);
   exception
      when Handle_Error =>
         raise Layout_Error with "dynamic-map deferred allocation is stale";
   end Cleanup_Retired;

   procedure Grow
     (Item : View; Arena : in out Arena_Provider.View;
      Mutated : in out Boolean; Result : out Put_Result)
   is
      Current_Capacity : constant Interfaces.Unsigned_64 :=
        Stored_Capacity (Item);
      Current : constant Arena_Provider.Allocation_Handle :=
        Read_Handle (Item.Current_Address);
      Target : Byte_Count;
      Requested : Byte_Count;
      New_Handle : Arena_Provider.Allocation_Handle :=
        Arena_Provider.Null_Allocation;
      Allocation : Arena_Provider.Allocation_Result;
      Old_Table, New_Table : Table_View;
      Slot : System.Address;
      Cleanup_Mutated : Boolean := False;
   begin
      begin
         Cleanup_Retired (Item, Arena, Cleanup_Mutated);
         Mutated := Mutated or Cleanup_Mutated;
      exception
         when Busy_Error =>
            Result := Put_Arena_Contended;
            return;
      end;

      Target :=
        (if Current_Capacity = 0
         then Byte_Count (Item.Initial_Value)
         else Byte_Count (Current_Capacity) * 2);
      if Target > Byte_Count (Positive'Last) then
         Result := Put_Arena_Exhausted;
         return;
      end if;
      Requested := Layouts.Checked_Multiply (Target, Item.Stride);
      if Requested > Byte_Count (Positive'Last) then
         Result := Put_Arena_Exhausted;
         return;
      end if;
      Arena_Provider.Try_Allocate
        (Arena, Positive (Requested), New_Handle, Allocation);
      case Allocation is
         when Arena_Provider.Allocation_Contended =>
            Result := Put_Arena_Contended;
            return;
         when Arena_Provider.Exhausted =>
            Result := Put_Arena_Exhausted;
            return;
         when Arena_Provider.Allocated =>
            null;
      end case;

      begin
         Attach_Table
           (Item, Arena, New_Handle, Interfaces.Unsigned_64 (Target),
            New_Table);
         Initialize_Table (Item, New_Table);
         if Current /= Arena_Provider.Null_Allocation then
            Attach_Table
              (Item, Arena, Current, Current_Capacity, Old_Table);
            for Index in Interfaces.Unsigned_64 range
              0 .. Interfaces.Unsigned_64 (Old_Table.Capacity) - 1
            loop
               Slot := Slot_Address (Item, Old_Table, Index);
               if Bytes.Read_U32
                 (Slot_Field (Item, Slot, Slot_State_Offset, 4)) =
                   Occupied_State
               then
                  Insert_Stored (Item, Slot, New_Table);
               end if;
            end loop;
         end if;
      exception
         when others =>
            begin
               Arena_Provider.Release (Arena, New_Handle);
            exception
               when others =>
                  null;
            end;
            raise;
      end;

      Mutated := True;
      if Current /= Arena_Provider.Null_Allocation then
         Write_Handle (Item.Retired_Address, Current);
      end if;
      Write_Handle (Item.Current_Address, New_Handle);
      Bytes.Write_U64
        (Item.Capacity_Address, Interfaces.Unsigned_64 (Target));
      Bytes.Write_U64
        (Item.Capacity_Check_Address,
         Capacity_Check (Interfaces.Unsigned_64 (Target)));
      Result := Put_Inserted;

      if Current /= Arena_Provider.Null_Allocation then
         begin
            Cleanup_Mutated := False;
            Cleanup_Retired (Item, Arena, Cleanup_Mutated);
         exception
            when Busy_Error =>
               null;
         end;
      end if;
   end Grow;

   procedure Put
     (Item   : in out View;
      Arena  : in out Arena_Provider.View;
      Key_Data : Key.Source;
      Value  : Element.Source;
      Result : out Put_Result)
   is
      Stored_Key   : constant Key.Value := Key.Create (Key_Data);
      Stored_Value : constant Element.Value := Element.Create (Value);
      Current_Capacity : Interfaces.Unsigned_64;
      Count : Interfaces.Unsigned_64;
      Current : Arena_Provider.Allocation_Handle;
      Table : Table_View;
      Found : Boolean;
      Index, Insertion : Interfaces.Unsigned_64;
      Slot : System.Address;
      Hash_Value : Interfaces.Unsigned_64;
      Mutated : Boolean := False;
   begin
      Acquire (Item);
      begin
         Require_Arena (Item, Arena);
         Count := Stored_Count (Item);
         Current_Capacity := Stored_Capacity (Item);
         if Current_Capacity = 0 then
            Grow (Item, Arena, Mutated, Result);
            if Result = Put_Arena_Exhausted
              or else Result = Put_Arena_Contended
            then
               Release_Guard (Item);
               return;
            end if;
            Current_Capacity := Stored_Capacity (Item);
         end if;
         Current := Read_Handle (Item.Current_Address);
         Attach_Table (Item, Arena, Current, Current_Capacity, Table);
         Find (Item, Table, Stored_Key, Found, Index, Insertion);
         if Found then
            Slot := Slot_Address (Item, Table, Index);
            Mutated := True;
            Element.Copy_To
              (Stored_Value, Value_Binding (Item, Slot, True));
            Result := Put_Replaced;
         else
            if (Count + 1) * 4 > Current_Capacity * 3
              or else Insertion = Interfaces.Unsigned_64'Last
            then
               Grow (Item, Arena, Mutated, Result);
               if Result = Put_Arena_Exhausted
                 or else Result = Put_Arena_Contended
               then
                  Release_Guard (Item);
                  return;
               end if;
               Current_Capacity := Stored_Capacity (Item);
               Current := Read_Handle (Item.Current_Address);
               Attach_Table
                 (Item, Arena, Current, Current_Capacity, Table);
               Find (Item, Table, Stored_Key, Found, Index, Insertion);
               if Found or else Insertion = Interfaces.Unsigned_64'Last then
                  raise Layout_Error with
                    "dynamic-map rehash did not produce an insertion slot";
               end if;
            end if;
            Slot := Slot_Address (Item, Table, Insertion);
            Hash_Value := Key.Hash (Stored_Key);
            Mutated := True;
            Bytes.Write_U64
              (Slot_Field (Item, Slot, Hash_Offset, 8), Hash_Value);
            Key.Copy_To (Stored_Key, Key_Binding (Item, Slot, True));
            Element.Copy_To
              (Stored_Value, Value_Binding (Item, Slot, True));
            Bytes.Write_U32
              (Slot_Field (Item, Slot, Slot_State_Offset, 4),
               Occupied_State);
            Bytes.Write_U64 (Item.Count_Address, Count + 1);
            Result := Put_Inserted;
         end if;
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release_Guard (Item);
   end Put;

   procedure Get
     (Item  : View;
      Arena : Arena_Provider.View;
      Key_Data : Key.Source;
      Value : out Element.Observed;
      Found : out Boolean)
   is
      Stored_Key : constant Key.Value := Key.Create (Key_Data);
      Current_Capacity : Interfaces.Unsigned_64;
      Current : Arena_Provider.Allocation_Handle;
      Table : Table_View;
      Index, Insertion : Interfaces.Unsigned_64;
      Slot : System.Address;
   begin
      Found := False;
      Acquire (Item);
      begin
         Require_Arena (Item, Arena);
         Current_Capacity := Stored_Capacity (Item);
         if Current_Capacity /= 0 then
            Current := Read_Handle (Item.Current_Address);
            Attach_Table (Item, Arena, Current, Current_Capacity, Table);
            Find (Item, Table, Stored_Key, Found, Index, Insertion);
            if Found then
               Slot := Slot_Address (Item, Table, Index);
               declare
                  Reference : Element.Const_Ref;
               begin
                  Element.Bind
                    (Reference, Value_Binding (Item, Slot, False));
                  Value := Element.Observe (Reference);
               end;
            end if;
         end if;
      exception
         when others =>
            Release_Guard (Item);
            raise;
      end;
      Release_Guard (Item);
   end Get;

   procedure Remove
     (Item    : in out View;
      Arena   : Arena_Provider.View;
      Key_Data : Key.Source;
      Removed : out Boolean)
   is
      Stored_Key : constant Key.Value := Key.Create (Key_Data);
      Current_Capacity : Interfaces.Unsigned_64;
      Current : Arena_Provider.Allocation_Handle;
      Table : Table_View;
      Found : Boolean;
      Index, Insertion : Interfaces.Unsigned_64;
      Slot : System.Address;
      Count : Interfaces.Unsigned_64;
      Mutated : Boolean := False;
   begin
      Removed := False;
      Acquire (Item);
      begin
         Require_Arena (Item, Arena);
         Count := Stored_Count (Item);
         Current_Capacity := Stored_Capacity (Item);
         if Current_Capacity /= 0 then
            Current := Read_Handle (Item.Current_Address);
            Attach_Table (Item, Arena, Current, Current_Capacity, Table);
            Find (Item, Table, Stored_Key, Found, Index, Insertion);
            if Found then
               if Count = 0 then
                  raise Layout_Error with
                    "dynamic-map occupied entry contradicts zero count";
               end if;
               Slot := Slot_Address (Item, Table, Index);
               Mutated := True;
               Bytes.Write_U32
                 (Slot_Field (Item, Slot, Slot_State_Offset, 4),
                  Deleted_State);
               Bytes.Write_U64 (Item.Count_Address, Count - 1);
               Removed := True;
            end if;
         end if;
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release_Guard (Item);
   end Remove;

   procedure Clear (Item : in out View; Arena : Arena_Provider.View) is
      Current_Capacity : Interfaces.Unsigned_64;
      Current : Arena_Provider.Allocation_Handle;
      Table : Table_View;
      Slot : System.Address;
      Mutated : Boolean := False;
   begin
      Acquire (Item);
      begin
         Require_Arena (Item, Arena);
         Current_Capacity := Stored_Capacity (Item);
         if Current_Capacity /= 0 then
            Current := Read_Handle (Item.Current_Address);
            Attach_Table (Item, Arena, Current, Current_Capacity, Table);
            Mutated := True;
            for Index in Interfaces.Unsigned_64 range
              0 .. Interfaces.Unsigned_64 (Table.Capacity) - 1
            loop
               Slot := Slot_Address (Item, Table, Index);
               Bytes.Write_U32
                 (Slot_Field (Item, Slot, Slot_State_Offset, 4),
                  Empty_State);
            end loop;
            Bytes.Write_U64 (Item.Count_Address, 0);
         end if;
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release_Guard (Item);
   end Clear;

   procedure Destroy
     (Item : in out View; Arena : in out Arena_Provider.View) is
      Current : Arena_Provider.Allocation_Handle;
      Mutated : Boolean := False;
   begin
      Acquire (Item);
      begin
         Require_Arena (Item, Arena);
         Cleanup_Retired (Item, Arena, Mutated);
         Current := Read_Handle (Item.Current_Address);
         if Current /= Arena_Provider.Null_Allocation then
            Arena_Provider.Release (Arena, Current);
            Mutated := True;
            Write_Handle
              (Item.Current_Address, Arena_Provider.Null_Allocation);
            Bytes.Write_U64 (Item.Capacity_Address, 0);
            Bytes.Write_U64
              (Item.Capacity_Check_Address, Capacity_Check (0));
            Bytes.Write_U64 (Item.Count_Address, 0);
         end if;
         Layouts.Mark_Destroyed (Item.Core);
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release_Guard (Item);
      Detach (Item);
   end Destroy;

end Flyology.Data_Structures.Dynamic.Hash_Maps;
