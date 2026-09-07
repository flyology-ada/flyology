with Flyology.Data_Structures.Atomics;
with Flyology.Data_Structures.Policy;
with Flyology.Data_Structures.Storage;
with Flyology.Data_Structures.Waits;
with System.Storage_Elements;

package body Flyology.Data_Structures.Hash_Maps is
   package Atomic renames Flyology.Data_Structures.Atomics;
   package Policy renames Flyology.Data_Structures.Policy;
   package Bytes renames Flyology.Data_Structures.Storage;
   package Waiting renames Flyology.Data_Structures.Waits;
   package Addressing renames System.Storage_Elements;

   use type Interfaces.Unsigned_32;
   use type Addressing.Storage_Offset;

   Count_Offset      : constant Byte_Count := 48;
   Guard_Offset      : constant Byte_Count := Layouts.Header_Size;
   Entries_Offset    : constant Byte_Count := Layouts.Header_Size + 8;
   State_Offset      : constant Byte_Count := 0;
   Hash_Offset       : constant Byte_Count := 8;
   Entry_Data_Offset : constant Byte_Count := 16;
   Empty_State       : constant Interfaces.Unsigned_32 := 0;
   Occupied_State    : constant Interfaces.Unsigned_32 := 1;
   Deleted_State     : constant Interfaces.Unsigned_32 := 2;

   function Storage_Alignment return Byte_Count
   is (Byte_Count'Max (8, Byte_Count'Max (Byte_Count (Key.Alignment), Byte_Count (Element.Alignment))));

   procedure Geometry
     (Capacity     : Positive;
      Key_Offset   : out Byte_Count;
      Value_Offset : out Byte_Count;
      Stride       : out Byte_Count;
      Extent       : out Byte_Count) is
   begin
      if Key.Signature = 0
        or else Key.Version = 0
        or else Element.Signature = 0
        or else Element.Version = 0
        or else Key.Alignment not in 1 | 2 | 4 | 8 | 16 | 32 | 64
        or else Element.Alignment not in 1 | 2 | 4 | 8 | 16 | 32 | 64
      then
         raise Constraint_Error with "invalid immutable map element contract";
      elsif not Policy.Is_Power_Of_Two (Byte_Count (Capacity)) then
         raise Constraint_Error with "hash-map capacity must be a power of two";
      end if;
      Key_Offset := Layouts.Align_Up (Entry_Data_Offset, Byte_Count (Key.Alignment));
      Value_Offset :=
        Layouts.Align_Up
          (Layouts.Checked_Add (Key_Offset, Byte_Count (Key.Size)), Byte_Count (Element.Alignment));
      Stride :=
        Layouts.Align_Up (Layouts.Checked_Add (Value_Offset, Byte_Count (Element.Size)), Storage_Alignment);
      Extent :=
        Layouts.Checked_Add (Entries_Offset, Layouts.Checked_Multiply (Byte_Count (Capacity), Stride));
   end Geometry;

   function Required_Storage (Capacity : Positive) return Byte_Count is
      Key_Offset, Value_Offset, Stride, Extent : Byte_Count;
   begin
      Geometry (Capacity, Key_Offset, Value_Offset, Stride, Extent);
      return Extent;
   end Required_Storage;

   procedure Set_View
     (Item                             : out View;
      Core                             : Layouts.Local_View;
      Capacity                         : Interfaces.Unsigned_32;
      Key_Offset, Value_Offset, Stride : Byte_Count) is
   begin
      Item.Core := Core;
      Item.Capacity_Value := Capacity;
      Item.Key_Value := Interfaces.Unsigned_32 (Key.Size);
      Item.Value_Value := Interfaces.Unsigned_32 (Element.Size);
      Item.Mask := Interfaces.Unsigned_64 (Capacity) - 1;
      Item.Key_Offset := Key_Offset;
      Item.Value_Offset := Value_Offset;
      Item.Stride := Stride;

      --  Core already covers the complete validated extent. Keep these native
      --  addresses only in this process-local view so hot probes do not repeat
      --  the region conversion for every field.
      Item.Count_Address := Layouts.Address_At (Core, Count_Offset, 8, 8);
      Item.Guard_Address := Layouts.Address_At (Core, Guard_Offset, 4, 4);
      Item.Entries_Address := Layouts.Address_At (Core, Entries_Offset, Core.Extent - Entries_Offset, 8);
   end Set_View;

   function Entry_Address (Item : View; Index : Interfaces.Unsigned_64) return System.Address is
   begin
      if Index >= Interfaces.Unsigned_64 (Item.Capacity_Value) then
         raise Layout_Error with "hash-map entry index is corrupt";
      end if;
      return
        Item.Entries_Address
        + Addressing.Storage_Offset (Layouts.Checked_Multiply (Byte_Count (Index), Item.Stride));
   end Entry_Address;

   function Field_Address
     (Item : View; Slot_Address : System.Address; Offset, Extent : Byte_Count) return System.Address is
   begin
      if Offset > Item.Stride or else Extent > Item.Stride - Offset then
         raise Layout_Error with "hash-map entry geometry is corrupt";
      end if;
      return Slot_Address + Addressing.Storage_Offset (Offset);
   end Field_Address;

   function Key_Binding
     (Item : View; Slot_Address : System.Address; Writable : Boolean) return Immutable_Storage_View
   is (Base      => Field_Address (Item, Slot_Address, Item.Key_Offset, Byte_Count (Key.Size)),
       Extent    => Byte_Count (Key.Size),
       Signature => Key.Signature,
       Version   => Key.Version,
       Writable  => Writable);

   function Value_Binding
     (Item : View; Slot_Address : System.Address; Writable : Boolean) return Immutable_Storage_View
   is (Base      => Field_Address (Item, Slot_Address, Item.Value_Offset, Byte_Count (Element.Size)),
       Extent    => Byte_Count (Element.Size),
       Signature => Element.Signature,
       Version   => Element.Version,
       Writable  => Writable);

   procedure Finish_Initialize
     (Item         : out View;
      Core         : Layouts.Local_View;
      Capacity     : Interfaces.Unsigned_32;
      Key_Offset   : Byte_Count;
      Value_Offset : Byte_Count;
      Stride       : Byte_Count) is
   begin
      Set_View (Item, Core, Capacity, Key_Offset, Value_Offset, Stride);
      Bytes.Write_U32 (Item.Guard_Address, 0);
      for Index in Interfaces.Unsigned_64 range 0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1 loop
         Bytes.Write_U32 (Field_Address (Item, Entry_Address (Item, Index), State_Offset, 4), Empty_State);
      end loop;
      Layouts.Publish (Item.Core);
   end Finish_Initialize;

   function Entry_Key_Hash (Item : View; Slot_Address : System.Address) return Interfaces.Unsigned_64 is
      Reference : Key.Const_Ref;
   begin
      Key.Bind (Reference, Key_Binding (Item, Slot_Address, False));
      return Key.Hash (Reference);
   end Entry_Key_Hash;

   procedure Acquire (Item : View);
   procedure Release (Item : View);

   procedure Initialize (Item : out View; Region : Region_View; Location : Region_Offset; Capacity : Positive)
   is
      Core                                     : Layouts.Local_View;
      Key_Offset, Value_Offset, Stride, Extent : Byte_Count;
   begin
      Detach (Item);
      Geometry (Capacity, Key_Offset, Value_Offset, Stride, Extent);
      Layouts.Begin_Initialize
        (Core,
         Region,
         Location,
         Identity,
         Extent,
         (Capacity     => Interfaces.Unsigned_32 (Capacity),
          Element_Size => Interfaces.Unsigned_32 (Key.Size),
          Alignment    => Interfaces.Unsigned_32 (Storage_Alignment),
          Auxiliary    => Interfaces.Unsigned_32 (Element.Size),
          Word_1       => 0,
          Word_2       => Interfaces.Unsigned_64 (Stride)),
         Storage_Alignment);
      Finish_Initialize (Item, Core, Interfaces.Unsigned_32 (Capacity), Key_Offset, Value_Offset, Stride);
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Initialize;

   procedure Create_Or_Attach
     (Item     : out View;
      Region   : Region_View;
      Location : Region_Offset;
      Capacity : Positive;
      Result   : out Open_Result)
   is
      Core                                     : Layouts.Local_View;
      Claim                                    : Layouts.Initialization_Claim;
      Key_Offset, Value_Offset, Stride, Extent : Byte_Count;
   begin
      Detach (Item);
      Geometry (Capacity, Key_Offset, Value_Offset, Stride, Extent);
      Layouts.Try_Begin_Initialize
        (Core,
         Claim,
         Region,
         Location,
         Identity,
         Extent,
         (Capacity     => Interfaces.Unsigned_32 (Capacity),
          Element_Size => Interfaces.Unsigned_32 (Key.Size),
          Alignment    => Interfaces.Unsigned_32 (Storage_Alignment),
          Auxiliary    => Interfaces.Unsigned_32 (Element.Size),
          Word_1       => 0,
          Word_2       => Interfaces.Unsigned_64 (Stride)),
         Storage_Alignment);
      case Claim is
         when Layouts.Claimed_Virgin    =>
            Finish_Initialize
              (Item, Core, Interfaces.Unsigned_32 (Capacity), Key_Offset, Value_Offset, Stride);
            Result := Initialized_New;

         when Layouts.Existing_Ready    =>
            Attach (Item, Region, Location, Capacity);
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

   procedure Attach (Item : out View; Region : Region_View; Location : Region_Offset; Capacity : Positive) is
      Core                                     : Layouts.Local_View;
      Header                                   : Layouts.Header_Values;
      Key_Offset, Value_Offset, Stride, Extent : Byte_Count;
      Occupied                                 : Interfaces.Unsigned_64 := 0;
      State, Candidate_State                   : Interfaces.Unsigned_32;
      Stored_Hash, Candidate_Hash              : Interfaces.Unsigned_64;
      Candidate                                : Interfaces.Unsigned_64;
      Reached                                  : Boolean;
      Guard_Acquired                           : Boolean := False;
      Expected_Count                           : Interfaces.Unsigned_64;
      Slot_Address, Candidate_Address          : System.Address;
   begin
      Detach (Item);
      Geometry (Capacity, Key_Offset, Value_Offset, Stride, Extent);
      Layouts.Attach (Core, Header, Region, Location, Identity, Storage_Alignment);
      if Header.Capacity /= Interfaces.Unsigned_32 (Capacity)
        or else Header.Element_Size /= Interfaces.Unsigned_32 (Key.Size)
        or else Header.Alignment /= Interfaces.Unsigned_32 (Storage_Alignment)
        or else Header.Auxiliary /= Interfaces.Unsigned_32 (Element.Size)
        or else Header.Word_2 /= Interfaces.Unsigned_64 (Stride)
        or else Core.Extent /= Extent
      then
         raise Layout_Error with "hash-map layout does not match";
      end if;
      Set_View (Item, Core, Header.Capacity, Key_Offset, Value_Offset, Stride);
      --  The header snapshot precedes this claim and therefore cannot supply
      --  the live count.  Hold the same process-capable guard as mutation,
      --  then reread every mutable field and validate one stable snapshot.
      Acquire (Item);
      Guard_Acquired := True;
      Expected_Count := Bytes.Read_U64 (Item.Count_Address);
      if Expected_Count > Interfaces.Unsigned_64 (Item.Capacity_Value) then
         raise Layout_Error with "hash-map count is corrupt";
      end if;
      for Index in Interfaces.Unsigned_64 range 0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1 loop
         State := Bytes.Read_U32 (Field_Address (Item, Entry_Address (Item, Index), State_Offset, 4));
         if State = Occupied_State then
            Occupied := Occupied + 1;
         elsif State /= Empty_State and then State /= Deleted_State then
            raise Layout_Error with "hash-map entry state is corrupt";
         end if;
      end loop;
      if Occupied /= Expected_Count then
         raise Layout_Error with "hash-map occupied count is corrupt";
      end if;

      for Index in Interfaces.Unsigned_64 range 0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1 loop
         Slot_Address := Entry_Address (Item, Index);
         State := Bytes.Read_U32 (Field_Address (Item, Slot_Address, State_Offset, 4));
         if State = Occupied_State then
            Stored_Hash := Bytes.Read_U64 (Field_Address (Item, Slot_Address, Hash_Offset, 8));
            if Stored_Hash /= Entry_Key_Hash (Item, Slot_Address) then
               raise Layout_Error with "hash-map stored hash is corrupt";
            end if;

            Reached := False;
            for Probe in Interfaces.Unsigned_64 range 0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1
            loop
               Candidate :=
                 Policy.Masked_Index (Stored_Hash + Probe, Policy.Positive_U32 (Item.Capacity_Value));
               Candidate_Address := Entry_Address (Item, Candidate);
               Candidate_State := Bytes.Read_U32 (Field_Address (Item, Candidate_Address, State_Offset, 4));
               if Candidate_State = Empty_State then
                  raise Layout_Error with "hash-map occupied entry is outside its probe chain";
               elsif Candidate = Index then
                  Reached := True;
                  exit;
               elsif Candidate_State = Occupied_State then
                  Candidate_Hash := Bytes.Read_U64 (Field_Address (Item, Candidate_Address, Hash_Offset, 8));
                  if Candidate_Hash = Stored_Hash then
                     declare
                        Candidate_Key : Key.Const_Ref;
                        Stored_Key    : Key.Const_Ref;
                     begin
                        Key.Bind (Candidate_Key, Key_Binding (Item, Candidate_Address, False));
                        Key.Bind (Stored_Key, Key_Binding (Item, Slot_Address, False));
                        if Key.Equivalent (Candidate_Key, Stored_Key) then
                           raise Layout_Error with "hash-map contains duplicate occupied keys";
                        end if;
                     end;
                  end if;
               end if;
            end loop;
            if not Reached then
               raise Layout_Error with "hash-map occupied entry is outside its probe chain";
            end if;
         end if;
      end loop;
      Guard_Acquired := False;
      Release (Item);
   exception
      when others =>
         if Guard_Acquired then
            Guard_Acquired := False;
            Release (Item);
         end if;
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
      Item.Key_Offset := 0;
      Item.Value_Offset := 0;
      Item.Stride := 0;
      Item.Count_Address := System.Null_Address;
      Item.Guard_Address := System.Null_Address;
      Item.Entries_Address := System.Null_Address;
   end Detach;

   procedure Poison (Region : Region_View; Location : Region_Offset) is
   begin
      Layouts.Poison_At (Region, Location, Identity, Storage_Alignment);
   end Poison;

   function Is_Attached (Item : View) return Boolean
   is (Item.Core.Attached);

   function Is_Poisoned (Item : View) return Boolean
   is (Layouts.Is_Poisoned (Item.Core));

   procedure Acquire (Item : View) is
      Expected : Interfaces.Unsigned_32 := 0;
   begin
      Layouts.Require_Ready (Item.Core);
      if not Atomic.Compare_Exchange_U32 (Item.Guard_Address, Expected, 1) then
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
      Outer :
      loop
         Expected := 0;
         exit Outer when Atomic.Compare_Exchange_U32 (Item.Guard_Address, Expected, 1);
         --  Once contention is established, observe with acquire loads between
         --  yields and issue another read-modify-write only after the guard
         --  appears free. This avoids repeated read-modify-write traffic
         --  against the owner's cache line.
         Inner :
         loop
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

   function Key_Matches
     (Item : View; Slot_Address : System.Address; Hash_Value : Interfaces.Unsigned_64; Stored_Key : Key.Value)
      return Boolean
   is
      Reference : Key.Const_Ref;
   begin
      if Bytes.Read_U64 (Field_Address (Item, Slot_Address, Hash_Offset, 8)) /= Hash_Value then
         return False;
      end if;
      Key.Bind (Reference, Key_Binding (Item, Slot_Address, False));
      return Key.Equivalent (Stored_Key, Reference);
   end Key_Matches;

   procedure Put_Unlocked
     (Item : in out View; Stored_Key : Key.Value; Stored_Value : Element.Value; Result : out Put_Result)
   is
      Hash_Value                   : constant Interfaces.Unsigned_64 := Key.Hash (Stored_Key);
      First_Deleted                : Interfaces.Unsigned_64 := Interfaces.Unsigned_64'Last;
      Index, Target                : Interfaces.Unsigned_64;
      State                        : Interfaces.Unsigned_32;
      Count                        : Interfaces.Unsigned_64;
      Slot_Address, Target_Address : System.Address;
   begin
      Count := Stored_Count (Item);
      for Probe in Interfaces.Unsigned_64 range 0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1 loop
         Index := Policy.Masked_Index (Hash_Value + Probe, Policy.Positive_U32 (Item.Capacity_Value));
         Slot_Address := Entry_Address (Item, Index);
         State := Bytes.Read_U32 (Field_Address (Item, Slot_Address, State_Offset, 4));
         if State = Occupied_State and then Count = 0 then
            raise Layout_Error with "hash-map occupied entry contradicts zero count";
         elsif State = Occupied_State and then Key_Matches (Item, Slot_Address, Hash_Value, Stored_Key) then
            Element.Copy_To (Stored_Value, Value_Binding (Item, Slot_Address, True));
            Result := Replaced;
            return;
         elsif State = Deleted_State and then First_Deleted = Interfaces.Unsigned_64'Last then
            First_Deleted := Index;
         elsif State = Empty_State then
            if Count = Interfaces.Unsigned_64 (Item.Capacity_Value) then
               raise Layout_Error with "hash-map free entry contradicts full count";
            end if;
            Target := (if First_Deleted = Interfaces.Unsigned_64'Last then Index else First_Deleted);
            Target_Address := Entry_Address (Item, Target);
            Bytes.Write_U64 (Field_Address (Item, Target_Address, Hash_Offset, 8), Hash_Value);
            Key.Copy_To (Stored_Key, Key_Binding (Item, Target_Address, True));
            Element.Copy_To (Stored_Value, Value_Binding (Item, Target_Address, True));
            Bytes.Write_U32 (Field_Address (Item, Target_Address, State_Offset, 4), Occupied_State);
            Bytes.Write_U64 (Item.Count_Address, Count + 1);
            Result := Inserted;
            return;
         elsif State /= Occupied_State and then State /= Deleted_State then
            raise Layout_Error with "hash-map entry state is corrupt";
         end if;
      end loop;
      if First_Deleted /= Interfaces.Unsigned_64'Last then
         if Count = Interfaces.Unsigned_64 (Item.Capacity_Value) then
            raise Layout_Error with "hash-map tombstone contradicts full count";
         end if;
         Target := First_Deleted;
         Target_Address := Entry_Address (Item, Target);
         Bytes.Write_U64 (Field_Address (Item, Target_Address, Hash_Offset, 8), Hash_Value);
         Key.Copy_To (Stored_Key, Key_Binding (Item, Target_Address, True));
         Element.Copy_To (Stored_Value, Value_Binding (Item, Target_Address, True));
         Bytes.Write_U32 (Field_Address (Item, Target_Address, State_Offset, 4), Occupied_State);
         Bytes.Write_U64 (Item.Count_Address, Count + 1);
         Result := Inserted;
      else
         Result := Table_Full;
      end if;
   end Put_Unlocked;

   procedure Put (Item : in out View; Key_Data : Key.Source; Value : Element.Source; Result : out Put_Result)
   is
      Stored_Key   : constant Key.Value := Key.Create (Key_Data);
      Stored_Value : constant Element.Value := Element.Create (Value);
   begin
      Acquire (Item);
      begin
         Put_Unlocked (Item, Stored_Key, Stored_Value, Result);
         Release (Item);
      exception
         when others =>
            Layouts.Poison (Item.Core);
            raise;
      end;
   end Put;

   procedure Put
     (Item     : in out View;
      Key_Data : Key.Source;
      Value    : Element.Source;
      Timeout  : Wait_Timeout;
      Result   : out Put_Result)
   is
      Stored_Key   : constant Key.Value := Key.Create (Key_Data);
      Stored_Value : constant Element.Value := Element.Create (Value);
   begin
      Acquire (Item, Timeout);
      begin
         Put_Unlocked (Item, Stored_Key, Stored_Value, Result);
         Release (Item);
      exception
         when others =>
            Layouts.Poison (Item.Core);
            raise;
      end;
   end Put;

   procedure Find_Index_Unlocked
     (Item : View; Stored_Key : Key.Value; Found : out Boolean; Index : out Interfaces.Unsigned_64)
   is
      Hash_Value   : constant Interfaces.Unsigned_64 := Key.Hash (Stored_Key);
      Candidate    : Interfaces.Unsigned_64;
      State        : Interfaces.Unsigned_32;
      Slot_Address : System.Address;
   begin
      for Probe in Interfaces.Unsigned_64 range 0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1 loop
         Candidate := Policy.Masked_Index (Hash_Value + Probe, Policy.Positive_U32 (Item.Capacity_Value));
         Slot_Address := Entry_Address (Item, Candidate);
         State := Bytes.Read_U32 (Field_Address (Item, Slot_Address, State_Offset, 4));
         if State = Empty_State then
            Found := False;
            Index := 0;
            return;
         elsif State = Occupied_State and then Key_Matches (Item, Slot_Address, Hash_Value, Stored_Key) then
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

   procedure Get (Item : View; Key_Data : Key.Source; Value : out Element.Observed; Found : out Boolean) is
      Stored_Key : constant Key.Value := Key.Create (Key_Data);
      Index      : Interfaces.Unsigned_64;
   begin
      Acquire (Item);
      begin
         Find_Index_Unlocked (Item, Stored_Key, Found, Index);
         if Found then
            declare
               Reference : Element.Const_Ref;
            begin
               Element.Bind (Reference, Value_Binding (Item, Entry_Address (Item, Index), False));
               Value := Element.Observe (Reference);
            end;
         end if;
         Release (Item);
      exception
         when Layout_Error =>
            Layouts.Poison (Item.Core);
            raise;
         when others =>
            Release (Item);
            raise;
      end;
   end Get;

   procedure Get
     (Item     : View;
      Key_Data : Key.Source;
      Value    : out Element.Observed;
      Timeout  : Wait_Timeout;
      Found    : out Boolean)
   is
      Stored_Key : constant Key.Value := Key.Create (Key_Data);
      Index      : Interfaces.Unsigned_64;
   begin
      Acquire (Item, Timeout);
      begin
         Find_Index_Unlocked (Item, Stored_Key, Found, Index);
         if Found then
            declare
               Reference : Element.Const_Ref;
            begin
               Element.Bind (Reference, Value_Binding (Item, Entry_Address (Item, Index), False));
               Value := Element.Observe (Reference);
            end;
         end if;
         Release (Item);
      exception
         when Layout_Error =>
            Layouts.Poison (Item.Core);
            raise;
         when others =>
            Release (Item);
            raise;
      end;
   end Get;

   procedure Remove (Item : in out View; Key_Data : Key.Source; Removed : out Boolean) is
      Stored_Key : constant Key.Value := Key.Create (Key_Data);
      Index      : Interfaces.Unsigned_64;
      Count      : Interfaces.Unsigned_64;
   begin
      Acquire (Item);
      begin
         Find_Index_Unlocked (Item, Stored_Key, Removed, Index);
         if Removed then
            Count := Stored_Count (Item);
            if Count = 0 then
               raise Layout_Error with "hash-map occupied entry contradicts zero count";
            end if;
            Bytes.Write_U32
              (Field_Address (Item, Entry_Address (Item, Index), State_Offset, 4), Deleted_State);
            Bytes.Write_U64 (Item.Count_Address, Count - 1);
         end if;
         Release (Item);
      exception
         when others =>
            Layouts.Poison (Item.Core);
            raise;
      end;
   end Remove;

   procedure Remove (Item : in out View; Key_Data : Key.Source; Timeout : Wait_Timeout; Removed : out Boolean)
   is
      Stored_Key : constant Key.Value := Key.Create (Key_Data);
      Index      : Interfaces.Unsigned_64;
      Count      : Interfaces.Unsigned_64;
   begin
      Acquire (Item, Timeout);
      begin
         Find_Index_Unlocked (Item, Stored_Key, Removed, Index);
         if Removed then
            Count := Stored_Count (Item);
            if Count = 0 then
               raise Layout_Error with "hash-map occupied entry contradicts zero count";
            end if;
            Bytes.Write_U32
              (Field_Address (Item, Entry_Address (Item, Index), State_Offset, 4), Deleted_State);
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
         for Index in Interfaces.Unsigned_64 range 0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1 loop
            State := Bytes.Read_U32 (Field_Address (Item, Entry_Address (Item, Index), State_Offset, 4));
            if State = Occupied_State then
               Occupied := Occupied + 1;
            elsif State /= Empty_State and then State /= Deleted_State then
               raise Layout_Error with "hash-map entry state is corrupt";
            end if;
            Bytes.Write_U32 (Field_Address (Item, Entry_Address (Item, Index), State_Offset, 4), Empty_State);
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
         for Index in Interfaces.Unsigned_64 range 0 .. Interfaces.Unsigned_64 (Item.Capacity_Value) - 1 loop
            State := Bytes.Read_U32 (Field_Address (Item, Entry_Address (Item, Index), State_Offset, 4));
            if State = Occupied_State then
               Occupied := Occupied + 1;
            elsif State /= Empty_State and then State /= Deleted_State then
               raise Layout_Error with "hash-map entry state is corrupt";
            end if;
            Bytes.Write_U32 (Field_Address (Item, Entry_Address (Item, Index), State_Offset, 4), Empty_State);
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
