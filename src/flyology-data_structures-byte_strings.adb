with Flyology.Data_Structures.Atomics;
with Flyology.Data_Structures.Storage;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology.Data_Structures.Byte_Strings is
   package Bytes renames Flyology.Data_Structures.Storage;
   package Atomic renames Flyology.Data_Structures.Atomics;
   package Addressing renames System.Storage_Elements;

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Addressing.Storage_Offset;
   use type System.Address;

   Length_Offset : constant Byte_Count := 48;
   Guard_Offset  : constant Byte_Count := 44;
   Unlocked      : constant Interfaces.Unsigned_32 := 0;
   Locked        : constant Interfaces.Unsigned_32 := 1;

   function Required_Storage (Maximum_Length : Positive) return Byte_Count is
     (Layouts.Checked_Add
        (Layouts.Header_Size, Byte_Count (Maximum_Length)));

   procedure Set_View
     (Item : out View;
      Core : Layouts.Local_View;
      Maximum_Length : Interfaces.Unsigned_32) is
   begin
      Item.Core := Core;
      Item.Length_Address := Layouts.Address_At
        (Core, Length_Offset, 8, 8);
      Item.Guard_Address := Layouts.Address_At (Core, Guard_Offset, 4, 4);
      Item.Payload_Address := Layouts.Address_At
        (Core, Layouts.Header_Size, Byte_Count (Maximum_Length), 1);
      Item.Capacity_Value := Maximum_Length;
   end Set_View;

   procedure Initialize
     (Item           : out View;
      Region         : Region_View;
      Location       : Region_Offset;
      Maximum_Length : Positive)
   is
      Core : Layouts.Local_View;
      Stored_Capacity : constant Interfaces.Unsigned_32 :=
        Interfaces.Unsigned_32 (Maximum_Length);
   begin
      Layouts.Begin_Initialize
        (Core, Region, Location, Identity,
         Required_Storage (Maximum_Length),
         (Capacity     => Stored_Capacity,
          Element_Size => 1,
          Alignment    => 1,
          Auxiliary    => 0,
          Word_1       => 0,
          Word_2       => 0),
         8);
      Set_View (Item, Core, Stored_Capacity);
      Layouts.Publish (Item.Core);
   end Initialize;

   procedure Attach
     (Item           : out View;
      Region         : Region_View;
      Location       : Region_Offset;
      Maximum_Length : Positive)
   is
      Core   : Layouts.Local_View;
      Header : Layouts.Header_Values;
      Expected : constant Byte_Count := Required_Storage (Maximum_Length);
   begin
      Layouts.Attach (Core, Header, Region, Location, Identity, 8);
      if Header.Capacity /= Interfaces.Unsigned_32 (Maximum_Length)
        or else Header.Element_Size /= 1
        or else Header.Alignment /= 1
        or else Header.Auxiliary /= 0
        or else Header.Word_2 /= 0
        or else Core.Extent /= Expected
        or else Header.Word_1 > Interfaces.Unsigned_64 (Header.Capacity)
      then
         raise Layout_Error with "byte-string layout does not match";
      end if;
      Set_View (Item, Core, Header.Capacity);
   end Attach;

   procedure Detach (Item : in out View) is
   begin
      Layouts.Detach (Item.Core);
      Item.Guard_Address := System.Null_Address;
      Item.Length_Address := System.Null_Address;
      Item.Payload_Address := System.Null_Address;
      Item.Capacity_Value := 0;
   end Detach;

   function Is_Attached (Item : View) return Boolean is (Item.Core.Attached);

   function Capacity (Item : View) return Natural is
   begin
      if not Item.Core.Attached then
         raise Region_Error with "detached byte-string view";
      end if;
      return Natural (Item.Capacity_Value);
   end Capacity;

   procedure Acquire (Item : View) is
      Expected : Interfaces.Unsigned_32 := Unlocked;
   begin
      if not Item.Core.Attached
        or else Item.Guard_Address = System.Null_Address
      then
         raise Region_Error with "detached byte-string view";
      elsif not Atomic.Compare_Exchange_U32
        (Item.Guard_Address, Expected, Locked)
      then
         Layouts.Require_Ready (Item.Core);
         if Expected = Locked then
            raise Busy_Error with "byte string is busy";
         else
            raise Layout_Error with "byte-string guard is corrupt";
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
         raise Layout_Error with "byte-string length is corrupt";
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

   function Is_Poisoned (Item : View) return Boolean is
     (Layouts.Is_Poisoned (Item.Core));

   procedure Poison
     (Region : Region_View; Location : Region_Offset) is
   begin
      Layouts.Poison_At (Region, Location, Identity, 8);
   end Poison;

   function Data_Address
     (Item : View; Offset, Extent : Byte_Count) return System.Address is
   begin
      if Offset > Byte_Count (Item.Capacity_Value)
        or else Extent > Byte_Count (Item.Capacity_Value) - Offset
      then
         raise Layout_Error with "byte-string payload extent is corrupt";
      end if;
      return Item.Payload_Address + Addressing.Storage_Offset (Offset);
   end Data_Address;
   pragma Inline_Always (Data_Address);

   procedure Assign
     (Item : in out View; Data : Ada.Streams.Stream_Element_Array)
   is
      Mutated : Boolean := False;
      Target  : System.Address := System.Null_Address;
   begin
      if Byte_Count (Data'Length) > Byte_Count (Item.Capacity_Value) then
         raise Constraint_Error with "byte string exceeds capacity";
      end if;
      Acquire (Item);
      begin
         if Data'Length > 0 then
            Target := Data_Address (Item, 0, Byte_Count (Data'Length));
            Mutated := True;
            Bytes.Copy
              (Target, Data'Address, Interfaces.C.size_t (Data'Length));
         end if;
         Mutated := True;
         Bytes.Write_U64
           (Item.Length_Address, Interfaces.Unsigned_64 (Data'Length));
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release (Item);
   end Assign;

   procedure Append
     (Item : in out View; Data : Ada.Streams.Stream_Element_Array)
   is
      Old_Length : Interfaces.Unsigned_64;
      Added      : constant Byte_Count := Byte_Count (Data'Length);
      Mutated    : Boolean := False;
      Target     : System.Address := System.Null_Address;
   begin
      Acquire (Item);
      begin
         Old_Length := Stored_Length_Unlocked (Item);
         if Added >
           Byte_Count (Item.Capacity_Value) - Byte_Count (Old_Length)
         then
            raise Constraint_Error with
              "byte-string append exceeds capacity";
         end if;
         if Data'Length > 0 then
            Target := Data_Address
              (Item, Byte_Count (Old_Length), Added);
            Mutated := True;
            Bytes.Copy
              (Target, Data'Address, Interfaces.C.size_t (Data'Length));
         end if;
         Mutated := True;
         Bytes.Write_U64
           (Item.Length_Address,
            Old_Length + Interfaces.Unsigned_64 (Data'Length));
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release (Item);
   end Append;

   procedure Read
     (Item : View; Data : out Ada.Streams.Stream_Element_Array)
   is
      Current : Interfaces.Unsigned_64;
   begin
      Acquire (Item);
      begin
         Current := Stored_Length_Unlocked (Item);
         if Byte_Count (Data'Length) /= Byte_Count (Current) then
            raise Constraint_Error with
              "byte-string destination length differs";
         end if;
         if Data'Length > 0 then
            Bytes.Copy
              (Data'Address, Data_Address (Item, 0, Byte_Count (Current)),
               Interfaces.C.size_t (Data'Length));
         end if;
      exception
         when others =>
            Release (Item);
            raise;
      end;
      Release (Item);
   end Read;

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

end Flyology.Data_Structures.Byte_Strings;
