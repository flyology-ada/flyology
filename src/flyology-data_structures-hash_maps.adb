with Flyology.Data_Structures.Atomics;
with Flyology.Data_Structures.Policy;
with Flyology.Data_Structures.Storage;
with Flyology.Data_Structures.Waits;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology.Data_Structures.Hash_Maps is
   package Atomic renames Flyology.Data_Structures.Atomics;
   package Policy renames Flyology.Data_Structures.Policy;
   package Bytes renames Flyology.Data_Structures.Storage;
   package Waiting renames Flyology.Data_Structures.Waits;
   package Addressing renames System.Storage_Elements;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Addressing.Storage_Offset;

   Count_Offset : constant Byte_Count := 48;
   Guard_Offset   : constant Byte_Count := Layouts.Header_Size;
   Entries_Offset : constant Byte_Count :=
     Layouts.Header_Size + 8;
   State_Offset : constant Byte_Count := 0;
   Hash_Offset  : constant Byte_Count := 8;
   Key_Offset   : constant Byte_Count := 16;
   Empty_State    : constant Interfaces.Unsigned_32 := 0;
   Occupied_State : constant Interfaces.Unsigned_32 := 1;
   Deleted_State  : constant Interfaces.Unsigned_32 := 2;

   procedure Geometry
     (Capacity     : Positive;
      Key_Size     : Positive;
      Value_Size   : Positive;
      Value_Offset : out Byte_Count;
      Stride       : out Byte_Count;
      Extent       : out Byte_Count) is
   begin
      if not Policy.Is_Power_Of_Two (Byte_Count (Capacity))
      then
         raise Constraint_Error with
           "hash-map capacity must be a power of two";
      end if;
      Value_Offset := Layouts.Align_Up
        (Layouts.Checked_Add (Key_Offset, Byte_Count (Key_Size)), 8);
      Stride := Layouts.Align_Up
        (Layouts.Checked_Add (Value_Offset, Byte_Count (Value_Size)), 8);
      Extent := Layouts.Checked_Add
        (Entries_Offset,
         Layouts.Checked_Multiply (Byte_Count (Capacity), Stride));
   end Geometry;

   function Required_Storage
     (Capacity   : Positive;
      Key_Size   : Positive;
      Value_Size : Positive) return Byte_Count
   is
      Value_Offset, Stride, Extent : Byte_Count;
   begin
      Geometry
        (Capacity, Key_Size, Value_Size, Value_Offset, Stride, Extent);
      return Extent;
   end Required_Storage;

   procedure Set_View
     (Item : out View; Core : Layouts.Local_View;
      Capacity, Key_Size, Value_Size : Interfaces.Unsigned_32;
      Value_Offset, Stride : Byte_Count) is
   begin
      Item.Core := Core;
      Item.Capacity_Value := Capacity;
      Item.Key_Value := Key_Size;
      Item.Value_Value := Value_Size;
      Item.Mask := Interfaces.Unsigned_64 (Capacity) - 1;
      Item.Value_Offset := Value_Offset;
      Item.Stride := Stride;

      --  Core already covers the complete validated extent. Keep these native
      --  addresses only in this process-local view so hot probes do not repeat
      --  the region conversion for every field.
      Item.Count_Address := Layouts.Address_At (Core, Count_Offset, 8, 8);
      Item.Guard_Address := Layouts.Address_At (Core, Guard_Offset, 4, 4);
      Item.Entries_Address := Layouts.Address_At
        (Core, Entries_Offset, Core.Extent - Entries_Offset, 8);
   end Set_View;

   function Entry_Address
     (Item : View; Index : Interfaces.Unsigned_64) return System.Address is
   begin
      if Index >= Interfaces.Unsigned_64 (Item.Capacity_Value) then
         raise Layout_Error with "hash-map entry index is corrupt";
      end if;
      return Item.Entries_Address + Addressing.Storage_Offset
        (Layouts.Checked_Multiply (Byte_Count (Index), Item.Stride));
   end Entry_Address;

   function Field_Address
     (Item : View; Slot_Address : System.Address;
      Offset, Extent : Byte_Count) return System.Address is
   begin
      if Offset > Item.Stride or else Extent > Item.Stride - Offset then
         raise Layout_Error with "hash-map entry geometry is corrupt";
      end if;
      return Slot_Address + Addressing.Storage_Offset (Offset);
   end Field_Address;

   procedure Finish_Initialize
     (Item         : out View;
      Core         : Layouts.Local_View;
      Capacity     : Interfaces.Unsigned_32;
      Key_Size     : Interfaces.Unsigned_32;
      Value_Size   : Interfaces.Unsigned_32;
      Value_Offset : Byte_Count;
      Stride       : Byte_Count) is
   begin
      Set_View
        (Item, Core, Capacity, Key_Size, Value_Size, Value_Offset, Stride);
      Bytes.Write_U32 (Item.Guard_Address, 0);
      for Index in Interfaces.Unsigned_64 range
        0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1
      loop
         Bytes.Write_U32
           (Field_Address
              (Item, Entry_Address (Item, Index), State_Offset, 4),
            Empty_State);
      end loop;
      Layouts.Publish (Item.Core);
   end Finish_Initialize;

   function Hash
     (Key : Ada.Streams.Stream_Element_Array) return Interfaces.Unsigned_64;

   function Entry_Key_Hash
     (Item : View; Slot_Address : System.Address)
      return Interfaces.Unsigned_64
   is
      Result : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   begin
      for Offset in Interfaces.Unsigned_32 range 0 .. Item.Key_Value - 1 loop
         Result := (Result xor Interfaces.Unsigned_64
           (Bytes.Read_U8
              (Field_Address
                 (Item, Slot_Address,
                  Layouts.Checked_Add
                    (Key_Offset, Byte_Count (Offset)),
                  1)))) * 16#0000_0100_0000_01B3#;
      end loop;
      return Result;
   end Entry_Key_Hash;

   procedure Initialize
     (Item       : out View;
      Region     : Region_View;
      Location   : Region_Offset;
      Capacity   : Positive;
      Key_Size   : Positive;
      Value_Size : Positive)
   is
      Core : Layouts.Local_View;
      Value_Offset, Stride, Extent : Byte_Count;
   begin
      Detach (Item);
      Geometry
        (Capacity, Key_Size, Value_Size, Value_Offset, Stride, Extent);
      Layouts.Begin_Initialize
        (Core, Region, Location, Identity, Extent,
         (Capacity     => Interfaces.Unsigned_32 (Capacity),
          Element_Size => Interfaces.Unsigned_32 (Key_Size),
          Alignment    => 8,
          Auxiliary    => Interfaces.Unsigned_32 (Value_Size),
          Word_1       => 0,
          Word_2       => Interfaces.Unsigned_64 (Stride)),
         8);
      Finish_Initialize
        (Item, Core, Interfaces.Unsigned_32 (Capacity),
         Interfaces.Unsigned_32 (Key_Size),
         Interfaces.Unsigned_32 (Value_Size), Value_Offset, Stride);
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Initialize;

   procedure Create_Or_Attach
     (Item       : out View;
      Region     : Region_View;
      Location   : Region_Offset;
      Capacity   : Positive;
      Key_Size   : Positive;
      Value_Size : Positive;
      Result     : out Open_Result)
   is
      Core : Layouts.Local_View;
      Claim : Layouts.Initialization_Claim;
      Value_Offset, Stride, Extent : Byte_Count;
   begin
      Detach (Item);
      Geometry
        (Capacity, Key_Size, Value_Size, Value_Offset, Stride, Extent);
      Layouts.Try_Begin_Initialize
        (Core, Claim, Region, Location, Identity, Extent,
         (Capacity     => Interfaces.Unsigned_32 (Capacity),
          Element_Size => Interfaces.Unsigned_32 (Key_Size),
          Alignment    => 8,
          Auxiliary    => Interfaces.Unsigned_32 (Value_Size),
          Word_1       => 0,
          Word_2       => Interfaces.Unsigned_64 (Stride)),
         8);
      case Claim is
         when Layouts.Claimed_Virgin =>
            Finish_Initialize
              (Item, Core, Interfaces.Unsigned_32 (Capacity),
               Interfaces.Unsigned_32 (Key_Size),
               Interfaces.Unsigned_32 (Value_Size), Value_Offset, Stride);
            Result := Initialized_New;
         when Layouts.Existing_Ready =>
            Attach
              (Item, Region, Location, Capacity, Key_Size, Value_Size);
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
     (Item       : out View;
      Region     : Region_View;
      Location   : Region_Offset;
      Capacity   : Positive;
      Key_Size   : Positive;
      Value_Size : Positive)
   is
      Core : Layouts.Local_View;
      Header : Layouts.Header_Values;
      Value_Offset, Stride, Extent : Byte_Count;
      Occupied : Interfaces.Unsigned_64 := 0;
      State, Candidate_State : Interfaces.Unsigned_32;
      Stored_Hash, Candidate_Hash : Interfaces.Unsigned_64;
      Candidate : Interfaces.Unsigned_64;
      Reached : Boolean;
      Slot_Address, Candidate_Address : System.Address;
   begin
      Detach (Item);
      Geometry
        (Capacity, Key_Size, Value_Size, Value_Offset, Stride, Extent);
      Layouts.Attach (Core, Header, Region, Location, Identity, 8);
      if Header.Capacity /= Interfaces.Unsigned_32 (Capacity)
        or else Header.Element_Size /= Interfaces.Unsigned_32 (Key_Size)
        or else Header.Alignment /= 8
        or else Header.Auxiliary /= Interfaces.Unsigned_32 (Value_Size)
        or else Header.Word_2 /= Interfaces.Unsigned_64 (Stride)
        or else Header.Word_1 > Interfaces.Unsigned_64 (Header.Capacity)
        or else Core.Extent /= Extent
      then
         raise Layout_Error with "hash-map layout does not match";
      end if;
      Set_View
        (Item, Core, Header.Capacity, Header.Element_Size, Header.Auxiliary,
         Value_Offset, Stride);
      declare
         Guard : constant Interfaces.Unsigned_32 :=
           Atomic.Load_Acquire_U32 (Item.Guard_Address);
      begin
         if Guard = 1 then
            raise Busy_Error with "hash map is being used";
         elsif Guard /= 0 then
            raise Layout_Error with "hash-map guard is corrupt";
         end if;
      end;
      for Index in Interfaces.Unsigned_64 range
        0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1
      loop
         State := Bytes.Read_U32
           (Field_Address
              (Item, Entry_Address (Item, Index), State_Offset, 4));
         if State = Occupied_State then
            Occupied := Occupied + 1;
         elsif State /= Empty_State and then State /= Deleted_State then
            raise Layout_Error with "hash-map entry state is corrupt";
         end if;
      end loop;
      if Occupied /= Header.Word_1 then
         raise Layout_Error with "hash-map occupied count is corrupt";
      end if;

      for Index in Interfaces.Unsigned_64 range
        0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1
      loop
         Slot_Address := Entry_Address (Item, Index);
         State := Bytes.Read_U32
           (Field_Address (Item, Slot_Address, State_Offset, 4));
         if State = Occupied_State then
            Stored_Hash := Bytes.Read_U64
              (Field_Address (Item, Slot_Address, Hash_Offset, 8));
            if Stored_Hash /= Entry_Key_Hash (Item, Slot_Address) then
               raise Layout_Error with "hash-map stored hash is corrupt";
            end if;

            Reached := False;
            for Probe in Interfaces.Unsigned_64 range
              0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1
            loop
               Candidate := Policy.Masked_Index
                 (Stored_Hash + Probe,
                  Policy.Positive_U32 (Item.Capacity_Value));
               Candidate_Address := Entry_Address (Item, Candidate);
               Candidate_State := Bytes.Read_U32
                 (Field_Address
                    (Item, Candidate_Address, State_Offset, 4));
               if Candidate_State = Empty_State then
                  raise Layout_Error with
                    "hash-map occupied entry is outside its probe chain";
               elsif Candidate = Index then
                  Reached := True;
                  exit;
               elsif Candidate_State = Occupied_State then
                  Candidate_Hash := Bytes.Read_U64
                    (Field_Address
                       (Item, Candidate_Address, Hash_Offset, 8));
                  if Candidate_Hash = Stored_Hash
                    and then Bytes.Equal
                      (Field_Address
                         (Item, Candidate_Address, Key_Offset,
                          Byte_Count (Item.Key_Value)),
                       Field_Address
                         (Item, Slot_Address, Key_Offset,
                          Byte_Count (Item.Key_Value)),
                       Interfaces.C.size_t (Item.Key_Value))
                  then
                     raise Layout_Error with
                       "hash-map contains duplicate occupied keys";
                  end if;
               end if;
            end loop;
            if not Reached then
               raise Layout_Error with
                 "hash-map occupied entry is outside its probe chain";
            end if;
         end if;
      end loop;
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
      Item.Key_Value := 0;
      Item.Value_Value := 0;
      Item.Mask := 0;
      Item.Value_Offset := 0;
      Item.Stride := 0;
      Item.Count_Address := System.Null_Address;
      Item.Guard_Address := System.Null_Address;
      Item.Entries_Address := System.Null_Address;
   end Detach;

   procedure Poison (Region : Region_View; Location : Region_Offset) is
   begin
      Layouts.Poison_At (Region, Location, Identity, 8);
   end Poison;

   function Is_Attached (Item : View) return Boolean is (Item.Core.Attached);

   function Is_Poisoned (Item : View) return Boolean is
     (Layouts.Is_Poisoned (Item.Core));

   procedure Acquire (Item : View) is
      Expected : Interfaces.Unsigned_32 := 0;
   begin
      Layouts.Require_Ready (Item.Core);
      if not Atomic.Compare_Exchange_U32
        (Item.Guard_Address, Expected, 1)
      then
         if Expected = 1 then
            raise Busy_Error with "hash map is being used";
         else
            raise Layout_Error with "hash-map guard is corrupt";
         end if;
      end if;
      begin
         Layouts.Require_Ready (Item.Core);
      exception
         when others =>
            Atomic.Store_Release_U32 (Item.Guard_Address, 0);
            raise;
      end;
   end Acquire;

   procedure Acquire (Item : View; Timeout : Wait_Timeout) is
      Wait     : Waiting.Context := Waiting.Start (Timeout);
      Expected : Interfaces.Unsigned_32;
   begin
      Layouts.Require_Ready (Item.Core);
      Outer : loop
         Expected := 0;
         exit Outer when Atomic.Compare_Exchange_U32
           (Item.Guard_Address, Expected, 1);
         --  Once contention is established, observe with acquire loads between
         --  yields and issue another read-modify-write only after the guard
         --  appears free. This avoids repeated read-modify-write traffic
         --  against the owner's cache line.
         Inner : loop
            Layouts.Require_Ready (Item.Core);
            if Expected /= 1 then
               raise Layout_Error with "hash-map guard is corrupt";
            end if;
            Waiting.Retry (Wait);
            Expected := Atomic.Load_Acquire_U32 (Item.Guard_Address);
            exit Inner when Expected = 0;
         end loop Inner;
      end loop Outer;
      begin
         Layouts.Require_Ready (Item.Core);
      exception
         when others =>
            Atomic.Store_Release_U32 (Item.Guard_Address, 0);
            raise;
      end;
   end Acquire;

   procedure Release (Item : View) is
   begin
      Atomic.Store_Release_U32 (Item.Guard_Address, 0);
   end Release;

   function Stored_Count (Item : View) return Interfaces.Unsigned_64 is
      Result : Interfaces.Unsigned_64;
   begin
      Result := Bytes.Read_U64 (Item.Count_Address);
      if Result > Interfaces.Unsigned_64 (Item.Capacity_Value) then
         raise Layout_Error with "hash-map count is corrupt";
      end if;
      return Result;
   end Stored_Count;

   function Length (Item : View) return Natural is
      Result : Natural;
   begin
      Acquire (Item);
      begin
         Result := Natural (Stored_Count (Item));
         Release (Item);
         return Result;
      exception
         when others =>
            Layouts.Poison (Item.Core);
            raise;
      end;
   end Length;

   function Length (Item : View; Timeout : Wait_Timeout) return Natural is
      Result : Natural;
   begin
      Acquire (Item, Timeout);
      begin
         Result := Natural (Stored_Count (Item));
         Release (Item);
         return Result;
      exception
         when others =>
            Layouts.Poison (Item.Core);
            raise;
      end;
   end Length;

   procedure Check_Key
     (Item : View; Key : Ada.Streams.Stream_Element_Array) is
   begin
      if not Item.Core.Attached then
         raise Region_Error with "detached hash-map view";
      elsif Byte_Count (Key'Length) /= Byte_Count (Item.Key_Value) then
         raise Constraint_Error with "hash-map key length does not match";
      end if;
   end Check_Key;

   procedure Check_Value (Item : View; Length : Natural) is
   begin
      if not Item.Core.Attached then
         raise Region_Error with "detached hash-map view";
      elsif Byte_Count (Length) /= Byte_Count (Item.Value_Value) then
         raise Constraint_Error with "hash-map value length does not match";
      end if;
   end Check_Value;

   function Hash
     (Key : Ada.Streams.Stream_Element_Array) return Interfaces.Unsigned_64
   is
      Result : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   begin
      for Byte of Key loop
         Result := (Result xor Interfaces.Unsigned_64 (Byte)) *
           16#0000_0100_0000_01B3#;
      end loop;
      return Result;
   end Hash;

   function Key_Matches
     (Item : View; Slot_Address : System.Address;
      Hash_Value : Interfaces.Unsigned_64;
      Key : Ada.Streams.Stream_Element_Array) return Boolean is
   begin
      return Bytes.Read_U64
        (Field_Address (Item, Slot_Address, Hash_Offset, 8)) = Hash_Value
        and then Bytes.Equal
          (Field_Address
             (Item, Slot_Address, Key_Offset, Byte_Count (Item.Key_Value)),
           Key'Address, Interfaces.C.size_t (Key'Length));
   end Key_Matches;

   procedure Put_Unlocked
     (Item   : in out View;
      Key    : Ada.Streams.Stream_Element_Array;
      Value  : Ada.Streams.Stream_Element_Array;
      Result : out Put_Result)
   is
      Hash_Value : constant Interfaces.Unsigned_64 := Hash (Key);
      First_Deleted : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;
      Index, Target : Interfaces.Unsigned_64;
      State : Interfaces.Unsigned_32;
      Count : Interfaces.Unsigned_64;
      Slot_Address, Target_Address : System.Address;
   begin
      Count := Stored_Count (Item);
      for Probe in Interfaces.Unsigned_64 range
        0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1
      loop
         Index := Policy.Masked_Index
           (Hash_Value + Probe, Policy.Positive_U32 (Item.Capacity_Value));
         Slot_Address := Entry_Address (Item, Index);
         State := Bytes.Read_U32
           (Field_Address (Item, Slot_Address, State_Offset, 4));
         if State = Occupied_State and then Count = 0 then
            raise Layout_Error with
              "hash-map occupied entry contradicts zero count";
         elsif State = Occupied_State
           and then Key_Matches (Item, Slot_Address, Hash_Value, Key)
         then
            Bytes.Copy
              (Field_Address
                 (Item, Slot_Address, Item.Value_Offset,
                  Byte_Count (Item.Value_Value)),
               Value'Address, Interfaces.C.size_t (Value'Length));
            Result := Replaced;
            return;
         elsif State = Deleted_State
           and then First_Deleted = Interfaces.Unsigned_64'Last
         then
            First_Deleted := Index;
         elsif State = Empty_State then
            if Count = Interfaces.Unsigned_64 (Item.Capacity_Value) then
               raise Layout_Error with
                 "hash-map free entry contradicts full count";
            end if;
            Target :=
              (if First_Deleted = Interfaces.Unsigned_64'Last
               then Index else First_Deleted);
            Target_Address := Entry_Address (Item, Target);
            Bytes.Write_U64
              (Field_Address (Item, Target_Address, Hash_Offset, 8),
               Hash_Value);
            Bytes.Copy
              (Field_Address
                 (Item, Target_Address, Key_Offset,
                  Byte_Count (Item.Key_Value)),
               Key'Address, Interfaces.C.size_t (Key'Length));
            Bytes.Copy
              (Field_Address
                 (Item, Target_Address, Item.Value_Offset,
                  Byte_Count (Item.Value_Value)),
               Value'Address, Interfaces.C.size_t (Value'Length));
            Bytes.Write_U32
              (Field_Address (Item, Target_Address, State_Offset, 4),
               Occupied_State);
            Bytes.Write_U64 (Item.Count_Address, Count + 1);
            Result := Inserted;
            return;
         elsif State /= Occupied_State and then State /= Deleted_State then
            raise Layout_Error with "hash-map entry state is corrupt";
         end if;
      end loop;
      if First_Deleted /= Interfaces.Unsigned_64'Last then
         if Count = Interfaces.Unsigned_64 (Item.Capacity_Value) then
            raise Layout_Error with
              "hash-map tombstone contradicts full count";
         end if;
         Target := First_Deleted;
         Target_Address := Entry_Address (Item, Target);
         Bytes.Write_U64
           (Field_Address (Item, Target_Address, Hash_Offset, 8), Hash_Value);
         Bytes.Copy
           (Field_Address
              (Item, Target_Address, Key_Offset, Byte_Count (Item.Key_Value)),
            Key'Address, Interfaces.C.size_t (Key'Length));
         Bytes.Copy
           (Field_Address
              (Item, Target_Address, Item.Value_Offset,
               Byte_Count (Item.Value_Value)),
            Value'Address, Interfaces.C.size_t (Value'Length));
         Bytes.Write_U32
           (Field_Address (Item, Target_Address, State_Offset, 4),
            Occupied_State);
         Bytes.Write_U64 (Item.Count_Address, Count + 1);
         Result := Inserted;
      else
         Result := Table_Full;
      end if;
   end Put_Unlocked;

   procedure Put
     (Item   : in out View;
      Key    : Ada.Streams.Stream_Element_Array;
      Value  : Ada.Streams.Stream_Element_Array;
      Result : out Put_Result) is
   begin
      Check_Key (Item, Key);
      Check_Value (Item, Value'Length);
      Acquire (Item);
      begin
         Put_Unlocked (Item, Key, Value, Result);
         Release (Item);
      exception
         when others =>
            Layouts.Poison (Item.Core);
            raise;
      end;
   end Put;

   procedure Put
     (Item    : in out View;
      Key     : Ada.Streams.Stream_Element_Array;
      Value   : Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout;
      Result  : out Put_Result) is
   begin
      Check_Key (Item, Key);
      Check_Value (Item, Value'Length);
      Acquire (Item, Timeout);
      begin
         Put_Unlocked (Item, Key, Value, Result);
         Release (Item);
      exception
         when others =>
            Layouts.Poison (Item.Core);
            raise;
      end;
   end Put;

   procedure Find_Index_Unlocked
     (Item : View; Key : Ada.Streams.Stream_Element_Array;
      Found : out Boolean; Index : out Interfaces.Unsigned_64)
   is
      Hash_Value : constant Interfaces.Unsigned_64 := Hash (Key);
      Candidate : Interfaces.Unsigned_64;
      State : Interfaces.Unsigned_32;
      Slot_Address : System.Address;
   begin
      for Probe in Interfaces.Unsigned_64 range
        0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1
      loop
         Candidate := Policy.Masked_Index
           (Hash_Value + Probe, Policy.Positive_U32 (Item.Capacity_Value));
         Slot_Address := Entry_Address (Item, Candidate);
         State := Bytes.Read_U32
           (Field_Address (Item, Slot_Address, State_Offset, 4));
         if State = Empty_State then
            Found := False;
            Index := 0;
            return;
         elsif State = Occupied_State
           and then Key_Matches (Item, Slot_Address, Hash_Value, Key)
         then
            Found := True;
            Index := Candidate;
            return;
         elsif State /= Occupied_State and then State /= Deleted_State then
            raise Layout_Error with "hash-map entry state is corrupt";
         end if;
      end loop;
      Found := False;
      Index := 0;
   end Find_Index_Unlocked;

   procedure Get
     (Item  : View;
      Key   : Ada.Streams.Stream_Element_Array;
      Value : out Ada.Streams.Stream_Element_Array;
      Found : out Boolean)
   is
      Index : Interfaces.Unsigned_64;
   begin
      Check_Value (Item, Value'Length);
      Check_Key (Item, Key);
      Acquire (Item);
      begin
         Find_Index_Unlocked (Item, Key, Found, Index);
         if Found then
            Bytes.Copy
              (Value'Address,
               Field_Address
                 (Item, Entry_Address (Item, Index), Item.Value_Offset,
                  Byte_Count (Item.Value_Value)),
               Interfaces.C.size_t (Value'Length));
         end if;
         Release (Item);
      exception
         when others =>
            Layouts.Poison (Item.Core);
            raise;
      end;
   end Get;

   procedure Get
     (Item    : View;
      Key     : Ada.Streams.Stream_Element_Array;
      Value   : out Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout;
      Found   : out Boolean)
   is
      Index : Interfaces.Unsigned_64;
   begin
      Check_Value (Item, Value'Length);
      Check_Key (Item, Key);
      Acquire (Item, Timeout);
      begin
         Find_Index_Unlocked (Item, Key, Found, Index);
         if Found then
            Bytes.Copy
              (Value'Address,
               Field_Address
                 (Item, Entry_Address (Item, Index), Item.Value_Offset,
                  Byte_Count (Item.Value_Value)),
               Interfaces.C.size_t (Value'Length));
         end if;
         Release (Item);
      exception
         when others =>
            Layouts.Poison (Item.Core);
            raise;
      end;
   end Get;

   procedure Remove
     (Item    : in out View;
      Key     : Ada.Streams.Stream_Element_Array;
      Removed : out Boolean)
   is
      Index : Interfaces.Unsigned_64;
      Count : Interfaces.Unsigned_64;
   begin
      Check_Key (Item, Key);
      Acquire (Item);
      begin
         Find_Index_Unlocked (Item, Key, Removed, Index);
         if Removed then
            Count := Stored_Count (Item);
            if Count = 0 then
               raise Layout_Error with
                 "hash-map occupied entry contradicts zero count";
            end if;
            Bytes.Write_U32
              (Field_Address
                 (Item, Entry_Address (Item, Index), State_Offset, 4),
               Deleted_State);
            Bytes.Write_U64 (Item.Count_Address, Count - 1);
         end if;
         Release (Item);
      exception
         when others =>
            Layouts.Poison (Item.Core);
            raise;
      end;
   end Remove;

   procedure Remove
     (Item    : in out View;
      Key     : Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout;
      Removed : out Boolean)
   is
      Index : Interfaces.Unsigned_64;
      Count : Interfaces.Unsigned_64;
   begin
      Check_Key (Item, Key);
      Acquire (Item, Timeout);
      begin
         Find_Index_Unlocked (Item, Key, Removed, Index);
         if Removed then
            Count := Stored_Count (Item);
            if Count = 0 then
               raise Layout_Error with
                 "hash-map occupied entry contradicts zero count";
            end if;
            Bytes.Write_U32
              (Field_Address
                 (Item, Entry_Address (Item, Index), State_Offset, 4),
               Deleted_State);
            Bytes.Write_U64 (Item.Count_Address, Count - 1);
         end if;
         Release (Item);
      exception
         when others =>
            Layouts.Poison (Item.Core);
            raise;
      end;
   end Remove;

   procedure Clear (Item : in out View) is
      Occupied : Interfaces.Unsigned_64 := 0;
      State    : Interfaces.Unsigned_32;
   begin
      Acquire (Item);
      begin
         for Index in Interfaces.Unsigned_64 range
           0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1
         loop
            State := Bytes.Read_U32
              (Field_Address
                 (Item, Entry_Address (Item, Index), State_Offset, 4));
            if State = Occupied_State then
               Occupied := Occupied + 1;
            elsif State /= Empty_State and then State /= Deleted_State then
               raise Layout_Error with "hash-map entry state is corrupt";
            end if;
            Bytes.Write_U32
              (Field_Address
                 (Item, Entry_Address (Item, Index), State_Offset, 4),
               Empty_State);
         end loop;
         if Occupied /= Stored_Count (Item) then
            raise Layout_Error with "hash-map occupied count is corrupt";
         end if;
         Bytes.Write_U64 (Item.Count_Address, 0);
         Release (Item);
      exception
         when others =>
            Layouts.Poison (Item.Core);
            raise;
      end;
   end Clear;

   procedure Clear (Item : in out View; Timeout : Wait_Timeout) is
      Occupied : Interfaces.Unsigned_64 := 0;
      State    : Interfaces.Unsigned_32;
   begin
      Acquire (Item, Timeout);
      begin
         for Index in Interfaces.Unsigned_64 range
           0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1
         loop
            State := Bytes.Read_U32
              (Field_Address
                 (Item, Entry_Address (Item, Index), State_Offset, 4));
            if State = Occupied_State then
               Occupied := Occupied + 1;
            elsif State /= Empty_State and then State /= Deleted_State then
               raise Layout_Error with "hash-map entry state is corrupt";
            end if;
            Bytes.Write_U32
              (Field_Address
                 (Item, Entry_Address (Item, Index), State_Offset, 4),
               Empty_State);
         end loop;
         if Occupied /= Stored_Count (Item) then
            raise Layout_Error with "hash-map occupied count is corrupt";
         end if;
         Bytes.Write_U64 (Item.Count_Address, 0);
         Release (Item);
      exception
         when others =>
            Layouts.Poison (Item.Core);
            raise;
      end;
   end Clear;

   procedure Destroy (Item : in out View) is
   begin
      Layouts.Mark_Destroyed (Item.Core);
      Detach (Item);
   end Destroy;

end Flyology.Data_Structures.Hash_Maps;
