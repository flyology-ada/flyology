with Flyology.Data_Structures.Atomics;
with Flyology.Data_Structures.Storage;
with System.Storage_Elements;

package body Flyology.Data_Structures.Dynamic.Byte_Strings is
   package Atomic renames Flyology.Data_Structures.Atomics;
   package Bytes renames Flyology.Data_Structures.Storage;
   package Native renames System.Storage_Elements;

   use type Arena_Provider.Allocation_Handle;
   use type Interfaces.Unsigned_32;
   use type Native.Storage_Offset;
   use type System.Address;

   Header_Extent : constant Byte_Count := 128;
   Guard_Offset : constant Byte_Count := 44;
   Length_Offset : constant Byte_Count := 56;
   Capacity_Offset : constant Byte_Count := 64;
   Current_Offset : constant Byte_Count := 72;
   Retired_Offset : constant Byte_Count := 88;
   Arena_Epoch_Offset : constant Byte_Count := 104;
   Reserved_32_Offset : constant Byte_Count := 108;
   Capacity_Check_Offset : constant Byte_Count := 112;
   Reserved_2_Offset : constant Byte_Count := 120;

   Capacity_Check_Mask : constant Interfaces.Unsigned_64 :=
     16#D71B_405E_29A6_F38C#;

   function Capacity_Check
     (Capacity : Interfaces.Unsigned_64) return Interfaces.Unsigned_64 is
     (Capacity xor Capacity_Check_Mask);

   Unlocked : constant Interfaces.Unsigned_32 := 0;
   Locked   : constant Interfaces.Unsigned_32 := 1;

   function Required_Storage return Byte_Count is (Header_Extent);

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

   function Arena_Metadata
     (Arena : Arena_Provider.View) return Arena_Provider.Metadata is
     (Arena_Provider.Current_Metadata (Arena));

   procedure Validate_Configuration
     (Arena            : Arena_Provider.View;
      Initial_Capacity : Positive;
      Element_Size     : Positive;
      Metadata         : out Arena_Provider.Metadata)
   is
      Bytes_Required : Byte_Count;
   begin
      Metadata := Arena_Metadata (Arena);
      Bytes_Required := Layouts.Checked_Multiply
        (Byte_Count (Initial_Capacity), Byte_Count (Element_Size));
      if Bytes_Required > Byte_Count (Metadata.Usable_Capacity)
      then
         raise Constraint_Error with
           "dynamic-byte-string initial capacity does not fit the arena";
      end if;
   end Validate_Configuration;

   procedure Set_View
     (Item             : out View;
      Core             : Layouts.Local_View;
      Initial_Capacity : Interfaces.Unsigned_32;
      Element_Size     : Interfaces.Unsigned_32;
      Arena_ID         : Interfaces.Unsigned_64;
      Arena_Epoch      : Interfaces.Unsigned_32) is
   begin
      Item.Core := Core;
      Item.Guard_Address := Layouts.Address_At (Core, Guard_Offset, 4, 4);
      Item.Length_Address := Layouts.Address_At (Core, Length_Offset, 8, 8);
      Item.Capacity_Address := Layouts.Address_At
        (Core, Capacity_Offset, 8, 8);
      Item.Capacity_Check_Address := Layouts.Address_At
        (Core, Capacity_Check_Offset, 8, 8);
      Item.Current_Address := Layouts.Address_At
        (Core, Current_Offset, 16, 8);
      Item.Retired_Address := Layouts.Address_At
        (Core, Retired_Offset, 16, 8);
      Item.Initial_Value := Initial_Capacity;
      Item.Element_Value := Element_Size;
      Item.Arena_ID_Value := Arena_ID;
      Item.Arena_Epoch_Value := Arena_Epoch;
   end Set_View;

   procedure Detach (Item : in out View) is
   begin
      Layouts.Detach (Item.Core);
      Item.Guard_Address := System.Null_Address;
      Item.Length_Address := System.Null_Address;
      Item.Capacity_Address := System.Null_Address;
      Item.Capacity_Check_Address := System.Null_Address;
      Item.Current_Address := System.Null_Address;
      Item.Retired_Address := System.Null_Address;
      Item.Initial_Value := 0;
      Item.Element_Value := 0;
      Item.Arena_ID_Value := 0;
      Item.Arena_Epoch_Value := 0;
   end Detach;

   procedure Finish_Initialize
     (Item             : out View;
      Core             : Layouts.Local_View;
      Initial_Capacity : Interfaces.Unsigned_32;
      Element_Size     : Interfaces.Unsigned_32;
      Arena_ID         : Interfaces.Unsigned_64;
      Arena_Epoch      : Interfaces.Unsigned_32) is
   begin
      Set_View
        (Item, Core, Initial_Capacity, Element_Size, Arena_ID, Arena_Epoch);
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

   procedure Attach_Core
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive;
      Element_Size     : Positive);

   procedure Initialize_Core
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive;
      Element_Size     : Positive)
   is
      Metadata : Arena_Provider.Metadata;
      Core : Layouts.Local_View;
   begin
      Validate_Configuration
        (Arena, Initial_Capacity, Element_Size, Metadata);
      Detach (Item);
      Layouts.Begin_Initialize
        (Core, Region, Location, Identity, Header_Extent,
         (Capacity     => Interfaces.Unsigned_32 (Initial_Capacity),
          Element_Size => Interfaces.Unsigned_32 (Element_Size),
          Alignment    => 1,
          Auxiliary    => Unlocked,
          Word_1       => Metadata.Instance_ID,
          Word_2       => 0),
         8);
      Finish_Initialize
        (Item, Core, Interfaces.Unsigned_32 (Initial_Capacity),
         Interfaces.Unsigned_32 (Element_Size), Metadata.Instance_ID,
         Metadata.Incarnation);
   exception
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Initialize_Core;

   procedure Create_Or_Attach_Core
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive;
      Element_Size     : Positive;
      Result           : out Open_Result)
   is
      Metadata : Arena_Provider.Metadata;
      Core  : Layouts.Local_View;
      Claim : Layouts.Initialization_Claim;
   begin
      Validate_Configuration
        (Arena, Initial_Capacity, Element_Size, Metadata);
      Detach (Item);
      Layouts.Try_Begin_Initialize
        (Core, Claim, Region, Location, Identity, Header_Extent,
         (Capacity     => Interfaces.Unsigned_32 (Initial_Capacity),
          Element_Size => Interfaces.Unsigned_32 (Element_Size),
          Alignment    => 1,
          Auxiliary    => Unlocked,
          Word_1       => Metadata.Instance_ID,
          Word_2       => 0),
         8);
      case Claim is
         when Layouts.Claimed_Virgin =>
            Finish_Initialize
              (Item, Core, Interfaces.Unsigned_32 (Initial_Capacity),
               Interfaces.Unsigned_32 (Element_Size), Metadata.Instance_ID,
               Metadata.Incarnation);
            Result := Initialized_New;
         when Layouts.Existing_Ready =>
            Attach_Core
              (Item, Region, Location, Arena, Initial_Capacity, Element_Size);
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
   end Create_Or_Attach_Core;

   procedure Require_Arena (Item : View; Arena : Arena_Provider.View) is
      Metadata : constant Arena_Provider.Metadata := Arena_Metadata (Arena);
   begin
      if Metadata.Instance_ID /= Item.Arena_ID_Value
        or else Metadata.Incarnation /= Item.Arena_Epoch_Value
      then
         raise Layout_Error with
           "dynamic byte string is attached to another arena incarnation";
      end if;
   end Require_Arena;

   procedure Validate_Allocation
     (Item     : View;
      Arena    : Arena_Provider.View;
      Value    : Arena_Provider.Allocation_Handle;
      Capacity : Interfaces.Unsigned_64)
   is
      Block : Byte_Count;
      Payload : Byte_Count;
   begin
      if Value = Arena_Provider.Null_Allocation then
         if Capacity /= 0 then
            raise Layout_Error with
              "dynamic-byte-string capacity has no allocation";
         end if;
         return;
      elsif Capacity = 0 then
         raise Layout_Error with
           "dynamic-byte-string allocation has zero capacity";
      end if;
      begin
         Block := Arena_Provider.Block_Capacity (Arena, Value);
      exception
         when Handle_Error =>
            raise Layout_Error with
              "dynamic-byte-string allocation handle is stale";
      end;
      Payload := Layouts.Checked_Multiply
        (Byte_Count (Capacity), Byte_Count (Item.Element_Value));
      if Payload > Block
        or else Block - Payload >= Byte_Count (Item.Element_Value)
      then
         raise Layout_Error with
           "dynamic-byte-string allocation capacity is inconsistent";
      end if;
   end Validate_Allocation;

   procedure Attach_Core
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive;
      Element_Size     : Positive)
   is
      Metadata : Arena_Provider.Metadata;
      Core     : Layouts.Local_View;
      Header   : Layouts.Header_Values;
      Stored_Epoch : Interfaces.Unsigned_32;
      Current_Capacity : Interfaces.Unsigned_64;
      Current, Retired : Arena_Provider.Allocation_Handle;
   begin
      Validate_Configuration
        (Arena, Initial_Capacity, Element_Size, Metadata);
      Detach (Item);
      Layouts.Attach (Core, Header, Region, Location, Identity, 8);
      Stored_Epoch := Bytes.Read_U32
        (Layouts.Address_At (Core, Arena_Epoch_Offset, 4, 4));
      if Header.Capacity /= Interfaces.Unsigned_32 (Initial_Capacity)
        or else Header.Element_Size /= Interfaces.Unsigned_32 (Element_Size)
        or else Header.Alignment /= 1
        or else Header.Word_1 /= Metadata.Instance_ID
        or else Stored_Epoch /= Metadata.Incarnation
        or else Core.Extent /= Header_Extent
      then
         raise Layout_Error with
           "dynamic-byte-string creation parameters do not match";
      elsif Header.Auxiliary = Locked then
         raise Busy_Error with "dynamic-byte-string guard is active";
      elsif Header.Auxiliary /= Unlocked
        or else Bytes.Read_U32
          (Layouts.Address_At (Core, Reserved_32_Offset, 4, 4)) /= 0
        or else Bytes.Read_U64
          (Layouts.Address_At (Core, Reserved_2_Offset, 8, 8)) /= 0
      then
         raise Layout_Error with "dynamic-byte-string header is corrupt";
      end if;
      Set_View
        (Item, Core, Header.Capacity, Header.Element_Size, Header.Word_1,
         Stored_Epoch);
      Current_Capacity := Bytes.Read_U64 (Item.Capacity_Address);
      if Bytes.Read_U64 (Item.Capacity_Check_Address) /=
           Capacity_Check (Current_Capacity)
        or else Header.Word_2 > Current_Capacity
        or else Current_Capacity > Interfaces.Unsigned_64 (Natural'Last)
      then
         raise Layout_Error with "dynamic-byte-string length is corrupt";
      end if;
      Current := Read_Handle (Item.Current_Address);
      Retired := Read_Handle (Item.Retired_Address);
      Validate_Allocation (Item, Arena, Current, Current_Capacity);
      if Retired /= Arena_Provider.Null_Allocation then
         if Retired = Current then
            raise Layout_Error with
              "dynamic-byte-string current and retired allocations alias";
         end if;
         declare
            Ignored : constant Byte_Count :=
              Arena_Provider.Block_Capacity (Arena, Retired);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      end if;
   exception
      when Handle_Error =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise Layout_Error with
           "dynamic-byte-string deferred allocation handle is stale";
      when others =>
         if Item.Core.Attached then
            Detach (Item);
         end if;
         raise;
   end Attach_Core;

   procedure Initialize
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive) is
   begin
      Initialize_Core
        (Item, Region, Location, Arena, Initial_Capacity, 1);
   end Initialize;

   procedure Create_Or_Attach
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive;
      Result           : out Open_Result) is
   begin
      Create_Or_Attach_Core
        (Item, Region, Location, Arena, Initial_Capacity, 1, Result);
   end Create_Or_Attach;

   procedure Attach
     (Item             : out View;
      Region           : Region_View;
      Location         : Region_Offset;
      Arena            : Arena_Provider.View;
      Initial_Capacity : Positive) is
   begin
      Attach_Core (Item, Region, Location, Arena, Initial_Capacity, 1);
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
         raise Region_Error with "detached dynamic-byte-string view";
      elsif not Atomic.Compare_Exchange_U32
        (Item.Guard_Address, Expected, Locked)
      then
         Layouts.Require_Ready (Item.Core);
         if Expected = Locked then
            raise Busy_Error with "dynamic byte string is busy";
         else
            raise Layout_Error with "dynamic-byte-string guard is corrupt";
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

   procedure Release_Guard (Item : View) is
   begin
      Atomic.Store_Release_U32 (Item.Guard_Address, Unlocked);
   end Release_Guard;
   pragma Inline_Always (Release_Guard);

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

   function Stored_Length (Item : View) return Interfaces.Unsigned_64 is
      Value : constant Interfaces.Unsigned_64 :=
        Bytes.Read_U64 (Item.Length_Address);
      Capacity : constant Interfaces.Unsigned_64 :=
        Bytes.Read_U64 (Item.Capacity_Address);
   begin
      if Bytes.Read_U64 (Item.Capacity_Check_Address) /=
           Capacity_Check (Capacity)
        or else Value > Capacity
        or else Capacity > Interfaces.Unsigned_64 (Natural'Last)
      then
         raise Layout_Error with "dynamic-byte-string length is corrupt";
      end if;
      return Value;
   end Stored_Length;

   function Capacity (Item : View) return Natural is
      Value : Interfaces.Unsigned_64;
   begin
      Acquire (Item);
      begin
         Value := Bytes.Read_U64 (Item.Capacity_Address);
         if Bytes.Read_U64 (Item.Capacity_Check_Address) /=
              Capacity_Check (Value)
           or else Value > Interfaces.Unsigned_64 (Natural'Last)
         then
            raise Layout_Error with "dynamic-byte-string capacity is corrupt";
         end if;
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
         Value := Stored_Length (Item);
      exception
         when others =>
            Release_Guard (Item);
            raise;
      end;
      Release_Guard (Item);
      return Natural (Value);
   end Length;

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
         raise Layout_Error with
           "dynamic-byte-string deferred allocation is stale";
   end Cleanup_Retired;

   procedure Ensure_Capacity
     (Item     : View;
      Arena    : in out Arena_Provider.View;
      Required : Positive;
      Mutated  : in out Boolean;
      Result   : out Growth_Result)
   is
      Current_Capacity : constant Interfaces.Unsigned_64 :=
        Bytes.Read_U64 (Item.Capacity_Address);
      Current : constant Arena_Provider.Allocation_Handle :=
        Read_Handle (Item.Current_Address);
      Target : Byte_Count;
      Requested_Bytes : Byte_Count;
      New_Handle : Arena_Provider.Allocation_Handle :=
        Arena_Provider.Null_Allocation;
      Allocation : Arena_Provider.Allocation_Result;
      Block : Byte_Count;
      New_Capacity : Byte_Count;
      Copy_Length : Byte_Count;
      Retired_Mutation : Boolean := False;
   begin
      if Current_Capacity >= Interfaces.Unsigned_64 (Required) then
         Result := Completed;
         return;
      end if;

      begin
         Cleanup_Retired (Item, Arena, Retired_Mutation);
         Mutated := Mutated or Retired_Mutation;
      exception
         when Busy_Error =>
            Result := Arena_Contended;
            return;
      end;

      Target :=
        (if Current_Capacity = 0
         then Byte_Count (Item.Initial_Value)
         else Byte_Count (Current_Capacity));
      while Target < Byte_Count (Required) loop
         if Target > Byte_Count'Last / 2 then
            Result := Arena_Exhausted;
            return;
         end if;
         Target := Target * 2;
      end loop;
      if Target > Byte_Count (Positive'Last) then
         Result := Arena_Exhausted;
         return;
      end if;
      Requested_Bytes := Layouts.Checked_Multiply
        (Target, Byte_Count (Item.Element_Value));
      if Requested_Bytes > Byte_Count (Positive'Last) then
         Result := Arena_Exhausted;
         return;
      end if;
      Arena_Provider.Try_Allocate
        (Arena, Positive (Requested_Bytes), New_Handle, Allocation);
      case Allocation is
         when Arena_Provider.Allocation_Contended =>
            Result := Arena_Contended;
            return;
         when Arena_Provider.Exhausted =>
            Result := Arena_Exhausted;
            return;
         when Arena_Provider.Allocated =>
            null;
      end case;

      begin
         Block := Arena_Provider.Block_Capacity (Arena, New_Handle);
         New_Capacity := Block / Byte_Count (Item.Element_Value);
         if New_Capacity < Byte_Count (Required)
           or else New_Capacity > Byte_Count (Natural'Last)
         then
            raise Layout_Error with
              "arena returned an unusable dynamic-byte-string block";
         end if;
         Copy_Length := Layouts.Checked_Multiply
           (Byte_Count (Stored_Length (Item)),
            Byte_Count (Item.Element_Value));
         if Copy_Length /= 0 then
            Arena_Provider.Copy
              (Arena, Current, 0, New_Handle, 0, Copy_Length);
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
        (Item.Capacity_Address, Interfaces.Unsigned_64 (New_Capacity));
      Bytes.Write_U64
        (Item.Capacity_Check_Address,
         Capacity_Check (Interfaces.Unsigned_64 (New_Capacity)));
      Result := Completed;

      if Current /= Arena_Provider.Null_Allocation then
         begin
            declare
               Cleanup_Mutated : Boolean := False;
            begin
               Cleanup_Retired (Item, Arena, Cleanup_Mutated);
            end;
         exception
            when Busy_Error =>
               null;
         end;
      end if;
   end Ensure_Capacity;

   procedure Try_Assign
     (Item   : in out View;
      Arena  : in out Arena_Provider.View;
      Data   : Ada.Streams.Stream_Element_Array;
      Result : out Growth_Result)
   is
      New_Length : constant Byte_Count := Byte_Count (Data'Length);
      Mutated : Boolean := False;
      Current : Arena_Provider.Allocation_Handle;
   begin
      Acquire (Item);
      begin
         Require_Arena (Item, Arena);
         if New_Length = 0 then
            Mutated := Stored_Length (Item) /= 0;
            Bytes.Write_U64 (Item.Length_Address, 0);
            Result := Completed;
         elsif New_Length > Byte_Count (Positive'Last) then
            Result := Arena_Exhausted;
         else
            Ensure_Capacity
              (Item, Arena, Positive (New_Length), Mutated, Result);
            if Result = Completed then
               Current := Read_Handle (Item.Current_Address);
               Mutated := True;
               Arena_Provider.Write (Arena, Current, 0, Data);
               Bytes.Write_U64
                 (Item.Length_Address, Interfaces.Unsigned_64 (New_Length));
            end if;
         end if;
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release_Guard (Item);
   end Try_Assign;

   procedure Try_Append
     (Item   : in out View;
      Arena  : in out Arena_Provider.View;
      Data   : Ada.Streams.Stream_Element_Array;
      Result : out Growth_Result)
   is
      Added : constant Byte_Count := Byte_Count (Data'Length);
      Current_Length : Interfaces.Unsigned_64;
      Required : Byte_Count;
      Mutated : Boolean := False;
      Current : Arena_Provider.Allocation_Handle;
   begin
      Acquire (Item);
      begin
         Require_Arena (Item, Arena);
         Current_Length := Stored_Length (Item);
         if Added = 0 then
            Result := Completed;
         elsif Added > Byte_Count'Last - Byte_Count (Current_Length) then
            Result := Arena_Exhausted;
         else
            Required := Byte_Count (Current_Length) + Added;
            if Required > Byte_Count (Positive'Last) then
               Result := Arena_Exhausted;
            else
               Ensure_Capacity
                 (Item, Arena, Positive (Required), Mutated, Result);
               if Result = Completed then
                  Current := Read_Handle (Item.Current_Address);
                  Mutated := True;
                  Arena_Provider.Write
                    (Arena, Current, Byte_Count (Current_Length), Data);
                  Bytes.Write_U64
                    (Item.Length_Address, Interfaces.Unsigned_64 (Required));
               end if;
            end if;
         end if;
      exception
         when others =>
            Finish_Failure (Item, Mutated);
            raise;
      end;
      Release_Guard (Item);
   end Try_Append;

   procedure Read
     (Item  : View;
      Arena : Arena_Provider.View;
      Data  : out Ada.Streams.Stream_Element_Array)
   is
      Current_Length : Interfaces.Unsigned_64;
      Current : Arena_Provider.Allocation_Handle;
   begin
      Acquire (Item);
      begin
         Require_Arena (Item, Arena);
         Current_Length := Stored_Length (Item);
         if Byte_Count (Data'Length) /= Byte_Count (Current_Length) then
            raise Constraint_Error with
              "dynamic-byte-string destination has the wrong length";
         elsif Current_Length /= 0 then
            Current := Read_Handle (Item.Current_Address);
            Arena_Provider.Read (Arena, Current, 0, Data);
         end if;
      exception
         when others =>
            Release_Guard (Item);
            raise;
      end;
      Release_Guard (Item);
   end Read;

   procedure Clear (Item : in out View) is
      Mutated : Boolean := False;
   begin
      Acquire (Item);
      begin
         if Stored_Length (Item) /= 0 then
            Mutated := True;
            Bytes.Write_U64 (Item.Length_Address, 0);
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
            Bytes.Write_U64 (Item.Length_Address, 0);
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

end Flyology.Data_Structures.Dynamic.Byte_Strings;
