with Flyology.Data_Structures.Atomics;
with Flyology.Data_Structures.Storage;
with Flyology.Data_Structures.Waits;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology.Data_Structures.Vectors is
   package Bytes renames Flyology.Data_Structures.Storage;
   package Atomic renames Flyology.Data_Structures.Atomics;
   package Waiting renames Flyology.Data_Structures.Waits;
   package Addressing renames System.Storage_Elements;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Addressing.Integer_Address;
   use type Addressing.Storage_Offset;
   use type System.Address;

   Length_Offset : constant Byte_Count := 48;
   Guard_Offset  : constant Byte_Count := 44;
   Unlocked      : constant Interfaces.Unsigned_32 := 0;
   Locked        : constant Interfaces.Unsigned_32 := 1;

   procedure Geometry
     (Capacity     : Positive;
      Element_Size : Positive;
      Stride       : out Byte_Count;
      Extent       : out Byte_Count) is
   begin
      Stride := Layouts.Align_Up (Byte_Count (Element_Size), 8);
      Extent := Layouts.Checked_Add
        (Layouts.Header_Size,
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
     (Item : out View; Core : Layouts.Local_View;
      Capacity, Element_Size : Interfaces.Unsigned_32;
      Stride : Byte_Count) is
   begin
      Item.Core := Core;
      Item.Length_Address := Layouts.Address_At
        (Core, Length_Offset, 8, 8);
      Item.Guard_Address := Layouts.Address_At (Core, Guard_Offset, 4, 4);
      Item.Payload_Address := Layouts.Address_At
        (Core, Layouts.Header_Size,
         Core.Extent - Layouts.Header_Size, 1);
      Item.Payload_Extent := Core.Extent - Layouts.Header_Size;
      Item.Capacity_Value := Capacity;
      Item.Element_Value := Element_Size;
      Item.Stride := Stride;
   end Set_View;

   procedure Finish_Initialize
     (Item         : out View;
      Core         : Layouts.Local_View;
      Capacity     : Interfaces.Unsigned_32;
      Element_Size : Interfaces.Unsigned_32;
      Stride       : Byte_Count) is
   begin
      Set_View (Item, Core, Capacity, Element_Size, Stride);
      Layouts.Publish (Item.Core);
   end Finish_Initialize;

   procedure Initialize
     (Item         : out View;
      Region       : Region_View;
      Location     : Region_Offset;
      Capacity     : Positive;
      Element_Size : Positive)
   is
      Core : Layouts.Local_View;
      Stride, Extent : Byte_Count;
   begin
      Detach (Item);
      Geometry (Capacity, Element_Size, Stride, Extent);
      Layouts.Begin_Initialize
        (Core, Region, Location, Identity, Extent,
         (Capacity     => Interfaces.Unsigned_32 (Capacity),
          Element_Size => Interfaces.Unsigned_32 (Element_Size),
          Alignment    => 8,
          Auxiliary    => 0,
          Word_1       => 0,
          Word_2       => Interfaces.Unsigned_64 (Stride)),
         8);
      Finish_Initialize
        (Item, Core, Interfaces.Unsigned_32 (Capacity),
         Interfaces.Unsigned_32 (Element_Size), Stride);
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
      Core   : Layouts.Local_View;
      Claim  : Layouts.Initialization_Claim;
      Stride : Byte_Count;
      Extent : Byte_Count;
   begin
      Detach (Item);
      Geometry (Capacity, Element_Size, Stride, Extent);
      Layouts.Try_Begin_Initialize
        (Core, Claim, Region, Location, Identity, Extent,
         (Capacity     => Interfaces.Unsigned_32 (Capacity),
          Element_Size => Interfaces.Unsigned_32 (Element_Size),
          Alignment    => 8,
          Auxiliary    => 0,
          Word_1       => 0,
          Word_2       => Interfaces.Unsigned_64 (Stride)),
         8);
      case Claim is
         when Layouts.Claimed_Virgin =>
            Finish_Initialize
              (Item, Core, Interfaces.Unsigned_32 (Capacity),
               Interfaces.Unsigned_32 (Element_Size), Stride);
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
      Core : Layouts.Local_View;
      Header : Layouts.Header_Values;
      Stride, Extent : Byte_Count;
   begin
      Detach (Item);
      Geometry (Capacity, Element_Size, Stride, Extent);
      Layouts.Attach (Core, Header, Region, Location, Identity, 8);
      if Header.Capacity /= Interfaces.Unsigned_32 (Capacity)
        or else Header.Element_Size /= Interfaces.Unsigned_32 (Element_Size)
        or else Header.Alignment /= 8
        or else Header.Auxiliary /= 0
        or else Header.Word_2 /= Interfaces.Unsigned_64 (Stride)
        or else Header.Word_1 > Interfaces.Unsigned_64 (Header.Capacity)
        or else Core.Extent /= Extent
      then
         raise Layout_Error with "vector layout does not match";
      end if;
      Set_View
        (Item, Core, Header.Capacity, Header.Element_Size, Stride);
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
      Item.Guard_Address := System.Null_Address;
      Item.Length_Address := System.Null_Address;
      Item.Payload_Address := System.Null_Address;
      Item.Payload_Extent := 0;
      Item.Capacity_Value := 0;
      Item.Element_Value := 0;
      Item.Stride := 0;
   end Detach;

   function Is_Attached (Item : View) return Boolean is (Item.Core.Attached);

   function Capacity (Item : View) return Natural is
   begin
      if not Item.Core.Attached then
         raise Region_Error with "detached vector view";
      end if;
      Layouts.Require_Ready (Item.Core);
      return Natural (Item.Capacity_Value);
   end Capacity;

   procedure Acquire (Item : View) is
      Expected : Interfaces.Unsigned_32 := Unlocked;
   begin
      if not Item.Core.Attached
        or else Item.Guard_Address = System.Null_Address
      then
         raise Region_Error with "detached vector view";
      elsif not Atomic.Compare_Exchange_U32
        (Item.Guard_Address, Expected, Locked)
      then
         Layouts.Require_Ready (Item.Core);
         if Expected = Locked then
            raise Busy_Error with "vector is busy";
         else
            raise Layout_Error with "vector guard is corrupt";
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
   pragma Inline_Always (Acquire);

   procedure Acquire (Item : View; Timeout : Wait_Timeout) is
      Wait     : Waiting.Context := Waiting.Start (Timeout);
      Expected : Interfaces.Unsigned_32;
   begin
      if not Item.Core.Attached
        or else Item.Guard_Address = System.Null_Address
      then
         raise Region_Error with "detached vector view";
      end if;
      loop
         Expected := Unlocked;
         exit when Atomic.Compare_Exchange_U32
           (Item.Guard_Address, Expected, Locked);
         Layouts.Require_Ready (Item.Core);
         if Expected /= Locked then
            raise Layout_Error with "vector guard is corrupt";
         end if;
         Waiting.Retry (Wait);
      end loop;
      begin
         Layouts.Require_Ready (Item.Core);
      exception
         when others =>
            Atomic.Store_Release_U32 (Item.Guard_Address, Unlocked);
            raise;
      end;
   end Acquire;

   procedure Release (Item : View) is
   begin
      Atomic.Store_Release_U32 (Item.Guard_Address, Unlocked);
   end Release;
   pragma Inline_Always (Release);

   procedure Finish_Failure (Item : View; Mutated : Boolean) is
   begin
      if Mutated then
         begin
            Layouts.Poison (Item.Core);
         exception
            when others =>
               Release (Item);
               raise;
         end;
      end if;
      Release (Item);
   end Finish_Failure;
   pragma Inline_Always (Finish_Failure);

   function Stored_Length_Unlocked
     (Item : View) return Interfaces.Unsigned_64 is
      Result : Interfaces.Unsigned_64;
   begin
      Result := Bytes.Read_U64
        (Item.Length_Address);
      if Result > Interfaces.Unsigned_64 (Item.Capacity_Value) then
         raise Layout_Error with "vector length is corrupt";
      end if;
      return Result;
   end Stored_Length_Unlocked;
   pragma Inline_Always (Stored_Length_Unlocked);

   function Length (Item : View) return Natural is
      Result : Natural;
   begin
      Acquire (Item);
      begin
         Result := Natural (Stored_Length_Unlocked (Item));
      exception
         when others =>
            Release (Item);
            raise;
      end;
      Release (Item);
      return Result;
   end Length;

   function Length (Item : View; Timeout : Wait_Timeout) return Natural is
      Result : Natural;
   begin
      Acquire (Item, Timeout);
      begin
         Result := Natural (Stored_Length_Unlocked (Item));
      exception
         when others =>
            Release (Item);
            raise;
      end;
      Release (Item);
      return Result;
   end Length;

   function Is_Poisoned (Item : View) return Boolean is
     (Layouts.Is_Poisoned (Item.Core));

   procedure Poison
     (Region : Region_View; Location : Region_Offset) is
   begin
      Layouts.Poison_At (Region, Location, Identity, 8);
   end Poison;

   procedure Check_Data (Item : View; Length : Natural) is
   begin
      if not Item.Core.Attached then
         raise Region_Error with "detached vector view";
      elsif Byte_Count (Length) /= Byte_Count (Item.Element_Value) then
         raise Constraint_Error with "vector element length does not match";
      end if;
   end Check_Data;
   pragma Inline_Always (Check_Data);

   function Element_Address
     (Item : View; Index : Interfaces.Unsigned_64) return System.Address
   is
      Relative   : Byte_Count;
      Base_Value : Addressing.Integer_Address;
   begin
      if not Item.Core.Attached
        or else Item.Payload_Address = System.Null_Address
      then
         raise Region_Error with "detached vector view";
      elsif Index >= Interfaces.Unsigned_64 (Item.Capacity_Value) then
         raise Layout_Error with "vector element index exceeds payload";
      end if;

      Relative := Layouts.Checked_Multiply
        (Byte_Count (Index), Item.Stride);
      if Relative > Item.Payload_Extent
        or else Byte_Count (Item.Element_Value) >
          Item.Payload_Extent - Relative
      then
         raise Layout_Error with "vector element extent is corrupt";
      elsif Relative > Byte_Count (Addressing.Storage_Offset'Last) then
         raise Region_Error with "vector element offset is not native";
      end if;

      Base_Value := Addressing.To_Integer (Item.Payload_Address);
      if Relative > Byte_Count (Addressing.Integer_Address'Last - Base_Value)
      then
         raise Region_Error with "vector element address overflows";
      end if;
      return Item.Payload_Address + Addressing.Storage_Offset (Relative);
   end Element_Address;
   pragma Inline_Always (Element_Address);

   procedure Try_Append
     (Item     : in out View;
      Data     : Ada.Streams.Stream_Element_Array;
      Appended : out Boolean)
   is
      Current : Interfaces.Unsigned_64;
      Mutated : Boolean := False;
      Target  : System.Address := System.Null_Address;
   begin
      Check_Data (Item, Data'Length);
      Acquire (Item);
      begin
         Current := Stored_Length_Unlocked (Item);
         if Current = Interfaces.Unsigned_64 (Item.Capacity_Value) then
            Appended := False;
         else
            Target := Element_Address (Item, Current);
            Mutated := True;
            Bytes.Copy
              (Target, Data'Address,
               Interfaces.C.size_t (Data'Length));
            Bytes.Write_U64
              (Item.Length_Address, Current + 1);
            Appended := True;
         end if;
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release (Item);
   end Try_Append;

   procedure Try_Append
     (Item     : in out View;
      Data     : Ada.Streams.Stream_Element_Array;
      Timeout  : Wait_Timeout;
      Appended : out Boolean)
   is
      Current : Interfaces.Unsigned_64;
      Mutated : Boolean := False;
      Target  : System.Address := System.Null_Address;
   begin
      Check_Data (Item, Data'Length);
      Acquire (Item, Timeout);
      begin
         Current := Stored_Length_Unlocked (Item);
         if Current = Interfaces.Unsigned_64 (Item.Capacity_Value) then
            Appended := False;
         else
            Target := Element_Address (Item, Current);
            Mutated := True;
            Bytes.Copy
              (Target, Data'Address, Interfaces.C.size_t (Data'Length));
            Bytes.Write_U64 (Item.Length_Address, Current + 1);
            Appended := True;
         end if;
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release (Item);
   end Try_Append;

   procedure Check_Index_Unlocked (Item : View; Index : Positive) is
   begin
      if Interfaces.Unsigned_64 (Index) > Stored_Length_Unlocked (Item) then
         raise Constraint_Error with "vector index is out of range";
      end if;
   end Check_Index_Unlocked;
   pragma Inline_Always (Check_Index_Unlocked);

   procedure Read
     (Item  : View;
      Index : Positive;
      Data  : out Ada.Streams.Stream_Element_Array) is
   begin
      Check_Data (Item, Data'Length);
      Acquire (Item);
      begin
         Check_Index_Unlocked (Item, Index);
         Bytes.Copy
           (Data'Address,
            Element_Address (Item, Interfaces.Unsigned_64 (Index - 1)),
            Interfaces.C.size_t (Data'Length));
      exception
         when others =>
            Release (Item);
            raise;
      end;
      Release (Item);
   end Read;

   procedure Read
     (Item    : View;
      Index   : Positive;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout) is
   begin
      Check_Data (Item, Data'Length);
      Acquire (Item, Timeout);
      begin
         Check_Index_Unlocked (Item, Index);
         Bytes.Copy
           (Data'Address,
            Element_Address (Item, Interfaces.Unsigned_64 (Index - 1)),
            Interfaces.C.size_t (Data'Length));
      exception
         when others =>
            Release (Item);
            raise;
      end;
      Release (Item);
   end Read;

   procedure Replace
     (Item  : in out View;
      Index : Positive;
      Data  : Ada.Streams.Stream_Element_Array) is
      Mutated : Boolean := False;
      Target  : System.Address := System.Null_Address;
   begin
      Check_Data (Item, Data'Length);
      Acquire (Item);
      begin
         Check_Index_Unlocked (Item, Index);
         Target := Element_Address
           (Item, Interfaces.Unsigned_64 (Index - 1));
         Mutated := True;
         Bytes.Copy
           (Target, Data'Address, Interfaces.C.size_t (Data'Length));
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release (Item);
   end Replace;

   procedure Replace
     (Item    : in out View;
      Index   : Positive;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout)
   is
      Mutated : Boolean := False;
      Target  : System.Address := System.Null_Address;
   begin
      Check_Data (Item, Data'Length);
      Acquire (Item, Timeout);
      begin
         Check_Index_Unlocked (Item, Index);
         Target := Element_Address
           (Item, Interfaces.Unsigned_64 (Index - 1));
         Mutated := True;
         Bytes.Copy
           (Target, Data'Address, Interfaces.C.size_t (Data'Length));
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release (Item);
   end Replace;

   procedure Try_Pop
     (Item   : in out View;
      Data   : out Ada.Streams.Stream_Element_Array;
      Popped : out Boolean)
   is
      Current : Interfaces.Unsigned_64;
      Mutated : Boolean := False;
   begin
      Check_Data (Item, Data'Length);
      Acquire (Item);
      begin
         Current := Stored_Length_Unlocked (Item);
         if Current = 0 then
            Popped := False;
         else
            Bytes.Copy
              (Data'Address, Element_Address (Item, Current - 1),
               Interfaces.C.size_t (Data'Length));
            Mutated := True;
            Bytes.Write_U64
              (Item.Length_Address, Current - 1);
            Popped := True;
         end if;
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release (Item);
   end Try_Pop;

   procedure Try_Pop
     (Item    : in out View;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Wait_Timeout;
      Popped  : out Boolean)
   is
      Current : Interfaces.Unsigned_64;
      Mutated : Boolean := False;
   begin
      Check_Data (Item, Data'Length);
      Acquire (Item, Timeout);
      begin
         Current := Stored_Length_Unlocked (Item);
         if Current = 0 then
            Popped := False;
         else
            Bytes.Copy
              (Data'Address, Element_Address (Item, Current - 1),
               Interfaces.C.size_t (Data'Length));
            Mutated := True;
            Bytes.Write_U64 (Item.Length_Address, Current - 1);
            Popped := True;
         end if;
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release (Item);
   end Try_Pop;

   procedure Clear (Item : in out View) is
      Mutated : Boolean := False;
   begin
      Acquire (Item);
      begin
         Mutated := True;
         Bytes.Write_U64 (Item.Length_Address, 0);
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release (Item);
   end Clear;

   procedure Clear (Item : in out View; Timeout : Wait_Timeout) is
      Mutated : Boolean := False;
   begin
      Acquire (Item, Timeout);
      begin
         Mutated := True;
         Bytes.Write_U64 (Item.Length_Address, 0);
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release (Item);
   end Clear;

   procedure Destroy (Item : in out View) is
   begin
      Acquire (Item);
      begin
         Layouts.Mark_Destroyed (Item.Core);
      exception
         when others =>
            Release (Item);
            raise;
      end;
      Release (Item);
      Detach (Item);
   end Destroy;

end Flyology.Data_Structures.Vectors;
