with Flyology.Atomic_Primitives;
with Flyology.Memory_Operations;
with Interfaces.C;
with System.Storage_Elements;

package body Flyology.Shared_Memory.Segments is
   package C renames Interfaces.C;
   package Atomic renames Flyology.Atomic_Primitives;
   package Memory renames Flyology.Memory_Operations;
   package Storage renames System.Storage_Elements;
   package DS renames Flyology.Data_Structures;

   use type Byte_Length;
   use type DS.Region_Offset;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Storage.Storage_Offset;
   use type System.Address;

   Header_Size : constant Byte_Length := 128;
   Name_Offset : constant Byte_Length := 64;

   Lifecycle_Offset : constant Byte_Length := 0;
   Version_Offset   : constant Byte_Length := 4;
   Magic_Offset     : constant Byte_Length := 8;
   Schema_Offset    : constant Byte_Length := 16;
   Extent_Offset    : constant Byte_Length := 24;
   Capacity_Offset  : constant Byte_Length := 32;
   Name_Limit_Offset : constant Byte_Length := 36;
   Slot_Size_Offset : constant Byte_Length := 40;
   Alignment_Offset : constant Byte_Length := 44;
   Data_Start_Offset : constant Byte_Length := 48;
   Next_Offset      : constant Byte_Length := 56;
   Guard_Offset     : constant Byte_Length := 64;
   Generation_Offset : constant Byte_Length := 72;

   Slot_State_Offset      : constant Byte_Length := 0;
   Slot_Name_Length_Offset : constant Byte_Length := 4;
   Slot_Generation_Offset : constant Byte_Length := 8;
   Slot_Hash_Offset       : constant Byte_Length := 16;
   Slot_Location_Offset   : constant Byte_Length := 24;
   Slot_Length_Offset     : constant Byte_Length := 32;
   Slot_Failure_Offset    : constant Byte_Length := 40;
   Slot_Reserved_Offset   : constant Byte_Length := 48;

   Virgin_State      : constant Interfaces.Unsigned_32 := 0;
   Initializing_State : constant Interfaces.Unsigned_32 := 1;
   Ready_State       : constant Interfaces.Unsigned_32 := 2;
   Poisoned_State    : constant Interfaces.Unsigned_32 := 3;

   Free_Slot         : constant Interfaces.Unsigned_32 := 0;
   Initializing_Slot : constant Interfaces.Unsigned_32 := 1;
   Ready_Slot        : constant Interfaces.Unsigned_32 := 2;
   Failed_Slot       : constant Interfaces.Unsigned_32 := 3;
   Removed_Slot      : constant Interfaces.Unsigned_32 := 4;

   Guard_Free   : constant Interfaces.Unsigned_32 := 0;
   Guard_Locked : constant Interfaces.Unsigned_32 := 1;

   Segment_Magic : constant Interfaces.Unsigned_64 :=
     16#464C_594F_5345_474D#;

   function CAS_U32
     (Address  : System.Address;
      Expected : access Interfaces.Unsigned_32;
      Desired  : Interfaces.Unsigned_32) return C.int
   is
      Local : Interfaces.Unsigned_32 := Expected.all;
      Result : constant Boolean :=
        Atomic.Compare_Exchange_U32 (Address, Local, Desired);
   begin
      Expected.all := Local;
      return Boolean'Pos (Result);
   end CAS_U32;

   type Geometry is record
      Slot_Size  : Byte_Length;
      Data_Start : Byte_Length;
   end record;

   function Add (Left, Right : Byte_Length) return Byte_Length is
   begin
      if Right > Byte_Length'Last - Left then
         raise Constraint_Error with "segment layout addition overflows";
      end if;
      return Left + Right;
   end Add;

   function Multiply (Left, Right : Byte_Length) return Byte_Length is
   begin
      if Left /= 0 and then Right > Byte_Length'Last / Left then
         raise Constraint_Error with "segment layout multiplication overflows";
      end if;
      return Left * Right;
   end Multiply;

   function Power_Of_Two (Value : Byte_Length) return Boolean is
     (Value /= 0 and then (Value and (Value - 1)) = 0);

   function Align_Up
     (Value, Alignment : Byte_Length) return Byte_Length
   is
      Remainder : Byte_Length;
   begin
      if not Power_Of_Two (Alignment) then
         raise Constraint_Error with "segment alignment is not a power of two";
      end if;
      Remainder := Value mod Alignment;
      return
        (if Remainder = 0 then Value
         else Add (Value, Alignment - Remainder));
   end Align_Up;

   function Stored_Geometry (Config : Configuration) return Geometry is
      Capacity : Byte_Length;
      Name_Max : Byte_Length;
      Alignment : Byte_Length;
      Slot_Size : Byte_Length;
      Registry_End : Byte_Length;
   begin
      if Config.Schema = 0 then
         raise Constraint_Error with "segment schema must be nonzero";
      end if;
      Capacity := Byte_Length (Config.Registry_Capacity);
      Name_Max := Byte_Length (Config.Maximum_Name_Length);
      Alignment := Byte_Length (Config.Allocation_Alignment);
      if Alignment < 8 or else not Power_Of_Two (Alignment) then
         raise Constraint_Error with
           "segment allocation alignment must be a power of two " &
           "at least eight";
      end if;
      Slot_Size := Align_Up (Add (Name_Offset, Name_Max), 8);
      Registry_End := Add (Header_Size, Multiply (Capacity, Slot_Size));
      return
        (Slot_Size  => Slot_Size,
         Data_Start => Align_Up (Registry_End, Alignment));
   end Stored_Geometry;

   function Required_Registry_Storage
     (Config : Configuration) return Byte_Length is
     (Stored_Geometry (Config).Data_Start);

   function Address_At
     (Item : View; Offset : Byte_Length; Size : Byte_Length)
      return System.Address
   is
   begin
      if not Item.Attached or else Item.Base = System.Null_Address then
         raise Segment_Error with "detached segment view";
      elsif Size = 0 or else Offset > Item.Extent
        or else Size > Item.Extent - Offset
      then
         raise Segment_Error with "segment-relative field is out of range";
      elsif Offset > Byte_Length (Storage.Storage_Offset'Last) then
         raise Segment_Error with "segment-relative field is not native";
      end if;
      return Item.Base + Storage.Storage_Offset (Offset);
   end Address_At;

   function At_Base
     (Base   : System.Address;
      Extent : Byte_Length;
      Offset : Byte_Length;
      Size   : Byte_Length) return System.Address is
   begin
      if Base = System.Null_Address or else Size = 0
        or else Offset > Extent or else Size > Extent - Offset
        or else Offset > Byte_Length (Storage.Storage_Offset'Last)
      then
         raise Segment_Error with
           "segment initialization field is out of range";
      end if;
      return Base + Storage.Storage_Offset (Offset);
   end At_Base;

   function Read_U32
     (Address : System.Address) return Interfaces.Unsigned_32 is
   begin
      return Atomic.Load_Acquire_U32 (Address);
   end Read_U32;

   function Read_U64
     (Address : System.Address) return Interfaces.Unsigned_64 is
   begin
      return Atomic.Load_Acquire_U64 (Address);
   end Read_U64;

   procedure Write_U32
     (Address : System.Address; Value : Interfaces.Unsigned_32)
   is
   begin
      Atomic.Store_Release_U32 (Address, Value);
   end Write_U32;

   procedure Write_U64
     (Address : System.Address; Value : Interfaces.Unsigned_64)
   is
   begin
      Atomic.Store_Release_U64 (Address, Value);
   end Write_U64;

   function Slot_Base
     (Item : View; Slot : Interfaces.Unsigned_32) return Byte_Length is
   begin
      if Slot = 0 or else Slot > Item.Capacity then
         raise Segment_Error with "segment registry slot is out of range";
      end if;
      return Add
        (Header_Size,
         Multiply
           (Byte_Length (Slot - 1), Byte_Length (Item.Slot_Size)));
   end Slot_Base;

   function Slot_At
     (Item     : View;
      Slot     : Interfaces.Unsigned_32;
      Relative : Byte_Length;
      Size     : Byte_Length) return System.Address is
   begin
      if Relative > Byte_Length (Item.Slot_Size)
        or else Size > Byte_Length (Item.Slot_Size) - Relative
      then
         raise Segment_Error with "segment slot field is out of range";
      end if;
      return Address_At
        (Item, Add (Slot_Base (Item, Slot), Relative), Size);
   end Slot_At;

   procedure Validate_Slot_Metadata
     (Item : View; Slot : Interfaces.Unsigned_32)
   is
      Generation : constant Interfaces.Unsigned_64 := Read_U64
        (Slot_At (Item, Slot, Slot_Generation_Offset, 8));
      Name_Length : constant Interfaces.Unsigned_32 := Read_U32
        (Slot_At (Item, Slot, Slot_Name_Length_Offset, 4));
      Location : constant Byte_Length := Byte_Length
        (Read_U64 (Slot_At (Item, Slot, Slot_Location_Offset, 8)));
      Length : constant Byte_Length := Byte_Length
        (Read_U64 (Slot_At (Item, Slot, Slot_Length_Offset, 8)));
      Reserved : constant Byte_Length := Byte_Length
        (Read_U64 (Slot_At (Item, Slot, Slot_Reserved_Offset, 8)));
      Alignment : constant Byte_Length := Byte_Length (Item.Alignment);
   begin
      if Generation = 0 then
         raise Segment_Error with "active segment slot has zero generation";
      elsif Name_Length = 0 or else Name_Length > Item.Name_Limit then
         raise Segment_Error with "segment slot name length is corrupt";
      elsif Location < Item.Data_Start
        or else Location mod Alignment /= 0
      then
         raise Segment_Error with "segment slot location is corrupt";
      elsif Length = 0 or else Reserved = 0 or else Length > Reserved
        or else Reserved mod Alignment /= 0
      then
         raise Segment_Error with "segment slot reservation is corrupt";
      elsif Location > Item.Extent
        or else Reserved > Item.Extent - Location
      then
         raise Segment_Error with "segment slot extent is out of range";
      end if;
   end Validate_Slot_Metadata;

   function Name_Hash (Name : String) return Interfaces.Unsigned_32 is
      Value : Interfaces.Unsigned_32 := 16#811C_9DC5#;
   begin
      for Ch of Name loop
         Value := Value xor Interfaces.Unsigned_32 (Character'Pos (Ch));
         Value := Value * 16#0100_0193#;
      end loop;
      return Value;
   end Name_Hash;

   procedure Validate_Name (Item : View; Name : String) is
   begin
      if Name'Length = 0 then
         raise Constraint_Error with "segment name must not be empty";
      elsif Interfaces.Unsigned_64 (Name'Length) >
        Interfaces.Unsigned_64 (Item.Name_Limit)
      then
         raise Constraint_Error with "segment name exceeds configured limit";
      end if;
   end Validate_Name;

   function Same_Name
     (Item : View;
      Slot : Interfaces.Unsigned_32;
      Name : String;
      Hash : Interfaces.Unsigned_32) return Boolean is
   begin
      return Read_U32
          (Slot_At (Item, Slot, Slot_Hash_Offset, 4)) = Hash
        and then Read_U32
          (Slot_At (Item, Slot, Slot_Name_Length_Offset, 4)) =
            Interfaces.Unsigned_32 (Name'Length)
        and then Memory.Equal
          (Slot_At (Item, Slot, Name_Offset, Byte_Length (Name'Length)),
           Name'Address, C.size_t (Name'Length));
   end Same_Name;

   procedure Clear_Claim (Claim : out Creation_Claim) is
   begin
      Claim.Slot := 0;
      Claim.Stamp := 0;
      Claim.Location := 0;
      Claim.Length := 0;
   end Clear_Claim;

   function Null_Named_Handle return Named_Handle is ((0, 0));

   procedure Require_Ready (Item : View) is
      State : Interfaces.Unsigned_32;
   begin
      if not Item.Attached then
         raise Segment_Error with "detached segment view";
      end if;
      State := Atomic.Load_Acquire_U32
        (Address_At (Item, Lifecycle_Offset, 4));
      if State = Poisoned_State then
         raise Segment_Error with "segment registry is poisoned";
      elsif State /= Ready_State then
         raise Segment_Error with "segment registry is not ready";
      end if;
   end Require_Ready;

   function Acquire_Guard (Item : View) return Boolean is
      Expected : aliased Interfaces.Unsigned_32 := Guard_Free;
   begin
      Require_Ready (Item);
      if CAS_U32
        (Address_At (Item, Guard_Offset, 4), Expected'Access,
         Guard_Locked) /= 0
      then
         return True;
      elsif Expected = Guard_Locked then
         return False;
      else
         raise Segment_Error with "segment registry guard is corrupt";
      end if;
   end Acquire_Guard;

   procedure Release_Guard (Item : View) is
   begin
      Atomic.Store_Release_U32
        (Address_At (Item, Guard_Offset, 4), Guard_Free);
   end Release_Guard;

   procedure Set_View
     (Item   : in out View;
      Source : Mapping;
      Config : Configuration;
      Shape  : Geometry) is
   begin
      Item.Base := Mapping_Base (Source);
      Item.Extent := Mapping_Length (Source);
      Item.Capacity := Interfaces.Unsigned_32 (Config.Registry_Capacity);
      Item.Name_Limit := Interfaces.Unsigned_32 (Config.Maximum_Name_Length);
      Item.Slot_Size := Interfaces.Unsigned_32 (Shape.Slot_Size);
      Item.Alignment := Interfaces.Unsigned_32 (Config.Allocation_Alignment);
      Item.Data_Start := Shape.Data_Start;
      Item.Schema := Config.Schema;
      Item.Attached := True;
   end Set_View;

   procedure Create_Or_Attach
     (Item   : in out View;
      Source : Mapping;
      Config : Configuration;
      Result : out Segment_Open_Result)
   is
      Shape : constant Geometry := Stored_Geometry (Config);
      Expected : aliased Interfaces.Unsigned_32 := Virgin_State;
      Base : System.Address;
      Extent : Byte_Length;
      State : Interfaces.Unsigned_32;
      Claimed : Boolean := False;
   begin
      Detach (Item);
      if not Is_Mapped (Source) then
         raise Validation_Error with
           "cannot attach segment to an unmapped mapping";
      end if;
      Base := Mapping_Base (Source);
      Extent := Mapping_Length (Source);
      if Extent <= Shape.Data_Start then
         raise Constraint_Error with
           "mapping is too small for registry and one named extent";
      elsif Extent > Byte_Length (Storage.Storage_Offset'Last) then
         raise Constraint_Error with
           "segment mapping is not natively indexable";
      end if;

      State := Atomic.Load_Acquire_U32
        (At_Base (Base, Extent, Lifecycle_Offset, 4));
      if State = Virgin_State and then not Mapping_May_Initialize (Source) then
         Result := Initialization_In_Progress;
         return;
      elsif State = Virgin_State then
         Claimed := CAS_U32
           (At_Base (Base, Extent, Lifecycle_Offset, 4), Expected'Access,
            Initializing_State) /= 0;
         if not Claimed then
            State := Expected;
         end if;
      end if;

      if Claimed then
         begin
            Memory.Zero
              (At_Base (Base, Extent, Version_Offset,
                        Shape.Data_Start - Version_Offset),
               C.size_t (Shape.Data_Start - Version_Offset));
            Write_U32
              (At_Base (Base, Extent, Version_Offset, 4), Layout_Version);
            Write_U64
              (At_Base (Base, Extent, Magic_Offset, 8), Segment_Magic);
            Write_U64
              (At_Base (Base, Extent, Schema_Offset, 8), Config.Schema);
            Write_U64
              (At_Base (Base, Extent, Extent_Offset, 8),
               Interfaces.Unsigned_64 (Extent));
            Write_U32
              (At_Base (Base, Extent, Capacity_Offset, 4),
               Interfaces.Unsigned_32 (Config.Registry_Capacity));
            Write_U32
              (At_Base (Base, Extent, Name_Limit_Offset, 4),
               Interfaces.Unsigned_32 (Config.Maximum_Name_Length));
            Write_U32
              (At_Base (Base, Extent, Slot_Size_Offset, 4),
               Interfaces.Unsigned_32 (Shape.Slot_Size));
            Write_U32
              (At_Base (Base, Extent, Alignment_Offset, 4),
               Interfaces.Unsigned_32 (Config.Allocation_Alignment));
            Write_U64
              (At_Base (Base, Extent, Data_Start_Offset, 8),
               Interfaces.Unsigned_64 (Shape.Data_Start));
            Atomic.Store_Release_U64
              (At_Base (Base, Extent, Next_Offset, 8),
               Interfaces.Unsigned_64 (Shape.Data_Start));
            Atomic.Store_Release_U64
              (At_Base (Base, Extent, Generation_Offset, 8), 0);
            Atomic.Store_Release_U32
              (At_Base (Base, Extent, Guard_Offset, 4), Guard_Free);
            Set_View (Item, Source, Config, Shape);
            Atomic.Store_Release_U32
              (Address_At (Item, Lifecycle_Offset, 4), Ready_State);
            Result := Initialized_New;
            return;
         exception
            when others =>
               Atomic.Store_Release_U32
                 (At_Base (Base, Extent, Lifecycle_Offset, 4), Poisoned_State);
               Detach (Item);
               raise;
         end;
      end if;

      if State = Initializing_State then
         Result := Initialization_In_Progress;
         return;
      elsif State = Poisoned_State then
         raise Segment_Error with "segment initialization is poisoned";
      elsif State /= Ready_State then
         raise Segment_Error with "segment lifecycle state is corrupt";
      end if;

      if Read_U32 (At_Base (Base, Extent, Version_Offset, 4)) /= Layout_Version
        or else Read_U64 (At_Base (Base, Extent, Magic_Offset, 8)) /=
          Segment_Magic
        or else Read_U64 (At_Base (Base, Extent, Schema_Offset, 8)) /=
          Config.Schema
        or else Read_U64 (At_Base (Base, Extent, Extent_Offset, 8)) /=
          Interfaces.Unsigned_64 (Extent)
        or else Read_U32 (At_Base (Base, Extent, Capacity_Offset, 4)) /=
          Interfaces.Unsigned_32 (Config.Registry_Capacity)
        or else Read_U32 (At_Base (Base, Extent, Name_Limit_Offset, 4)) /=
          Interfaces.Unsigned_32 (Config.Maximum_Name_Length)
        or else Read_U32 (At_Base (Base, Extent, Slot_Size_Offset, 4)) /=
          Interfaces.Unsigned_32 (Shape.Slot_Size)
        or else Read_U32 (At_Base (Base, Extent, Alignment_Offset, 4)) /=
          Interfaces.Unsigned_32 (Config.Allocation_Alignment)
        or else Read_U64 (At_Base (Base, Extent, Data_Start_Offset, 8)) /=
          Interfaces.Unsigned_64 (Shape.Data_Start)
      then
         raise Segment_Error with "segment configuration does not match";
      end if;
      Set_View (Item, Source, Config, Shape);
      declare
         Next : constant Interfaces.Unsigned_64 :=
           Atomic.Load_Acquire_U64 (Address_At (Item, Next_Offset, 8));
         Guard : constant Interfaces.Unsigned_32 :=
           Atomic.Load_Acquire_U32 (Address_At (Item, Guard_Offset, 4));
      begin
         if Next < Interfaces.Unsigned_64 (Shape.Data_Start)
           or else Next > Interfaces.Unsigned_64 (Extent)
           or else Next mod
             Interfaces.Unsigned_64 (Config.Allocation_Alignment) /= 0
         then
            raise Segment_Error with "segment allocation frontier is corrupt";
         elsif Guard /= Guard_Free and then Guard /= Guard_Locked then
            raise Segment_Error with "segment registry guard is corrupt";
         end if;
      end;
      Result := Attached_Existing;
   exception
      when others =>
         if Item.Attached then
            Detach (Item);
         end if;
         raise;
   end Create_Or_Attach;

   procedure Detach (Item : in out View) is
   begin
      Item.Base := System.Null_Address;
      Item.Extent := 0;
      Item.Capacity := 0;
      Item.Name_Limit := 0;
      Item.Slot_Size := 0;
      Item.Alignment := 0;
      Item.Data_Start := 0;
      Item.Schema := 0;
      Item.Attached := False;
   end Detach;

   function Is_Attached (Item : View) return Boolean is (Item.Attached);

   procedure Attach_Region
     (Item   : View;
      Region : in out Flyology.Data_Structures.Regions.View) is
   begin
      Require_Ready (Item);
      Flyology.Data_Structures.Regions.Attach
        (Region, Item.Base, Item.Extent);
   end Attach_Region;

   procedure Fill_Handle
     (Item : View; Slot : Interfaces.Unsigned_32; Handle : out Named_Handle) is
   begin
      Handle :=
        (Slot  => Slot,
         Stamp => Read_U64
           (Slot_At (Item, Slot, Slot_Generation_Offset, 8)));
   end Fill_Handle;

   procedure Try_Find_Or_Create
     (Item             : View;
      Name             : String;
      Requested_Length : Byte_Length;
      Handle           : out Named_Handle;
      Claim            : out Creation_Claim;
      Result           : out Find_Or_Create_Result;
      Failure          : out Interfaces.Unsigned_32)
   is
      Hash : Interfaces.Unsigned_32;
      Free_Candidate : Interfaces.Unsigned_32 := 0;
      Reuse_Candidate : Interfaces.Unsigned_32 := 0;
      Reuse_Reserved : Byte_Length := 0;
      Acquired : Boolean := False;
   begin
      Handle := Null_Named_Handle;
      Clear_Claim (Claim);
      Failure := 0;
      Validate_Name (Item, Name);
      if Requested_Length = 0 then
         raise Constraint_Error with "named extent length must be positive";
      end if;
      Hash := Name_Hash (Name);
      if not Acquire_Guard (Item) then
         Result := Registry_Busy;
         return;
      end if;
      Acquired := True;

      for Slot in Interfaces.Unsigned_32 range 1 .. Item.Capacity loop
         declare
            State : constant Interfaces.Unsigned_32 :=
              Atomic.Load_Acquire_U32
                (Slot_At (Item, Slot, Slot_State_Offset, 4));
         begin
            if State = Free_Slot then
               if Free_Candidate = 0 then
                  Free_Candidate := Slot;
               end if;
            elsif State = Removed_Slot then
               Validate_Slot_Metadata (Item, Slot);
               declare
                  Reserved : constant Byte_Length := Byte_Length
                    (Read_U64
                       (Slot_At
                          (Item, Slot, Slot_Reserved_Offset, 8)));
               begin
                  if Reserved >= Requested_Length
                    and then
                      (Reuse_Candidate = 0 or else Reserved < Reuse_Reserved)
                  then
                     Reuse_Candidate := Slot;
                     Reuse_Reserved := Reserved;
                  end if;
               end;
            elsif State = Initializing_Slot
              or else State = Ready_Slot
              or else State = Failed_Slot
            then
               Validate_Slot_Metadata (Item, Slot);
               if Same_Name (Item, Slot, Name, Hash) then
                  Fill_Handle (Item, Slot, Handle);
                  if State = Initializing_Slot then
                     Result := Initialization_In_Progress;
                  elsif State = Failed_Slot then
                     Failure := Read_U32
                       (Slot_At (Item, Slot, Slot_Failure_Offset, 4));
                     if Failure = 0 then
                        raise Segment_Error with
                          "failed segment entry has zero failure code";
                     end if;
                     Result := Previous_Initialization_Failed;
                  elsif Byte_Length
                    (Read_U64
                       (Slot_At (Item, Slot, Slot_Length_Offset, 8))) /=
                      Requested_Length
                  then
                     Result := Configuration_Mismatch;
                  else
                     Result := Attached_Existing;
                  end if;
                  Release_Guard (Item);
                  return;
               end if;
            else
               raise Segment_Error with
                 "segment registry slot state is corrupt";
            end if;
         end;
      end loop;

      declare
         Slot : Interfaces.Unsigned_32;
         Location : Byte_Length;
         Reserved : Byte_Length;
         Generation : Interfaces.Unsigned_64 :=
           Atomic.Load_Acquire_U64 (Address_At (Item, Generation_Offset, 8));
      begin
         if Generation = Interfaces.Unsigned_64'Last then
            Release_Guard (Item);
            Acquired := False;
            Result := Generation_Exhausted;
            return;
         end if;
         if Reuse_Candidate /= 0 then
            Slot := Reuse_Candidate;
            Location := Byte_Length
              (Read_U64
                 (Slot_At (Item, Slot, Slot_Location_Offset, 8)));
            Reserved := Reuse_Reserved;
         elsif Free_Candidate = 0 then
            Release_Guard (Item);
            Acquired := False;
            Result := Registry_Exhausted;
            return;
         else
            Slot := Free_Candidate;
            Location := Byte_Length
              (Atomic.Load_Acquire_U64 (Address_At (Item, Next_Offset, 8)));
            Reserved := Align_Up
              (Requested_Length, Byte_Length (Item.Alignment));
            if Location < Item.Data_Start
              or else Location mod Byte_Length (Item.Alignment) /= 0
            then
               raise Segment_Error with
                 "segment allocation frontier is corrupt";
            elsif Location > Item.Extent
              or else Reserved > Item.Extent - Location
            then
               Release_Guard (Item);
               Acquired := False;
               Result := Segment_Exhausted;
               return;
            end if;
            Atomic.Store_Release_U64
              (Address_At (Item, Next_Offset, 8),
               Interfaces.Unsigned_64 (Location + Reserved));
         end if;

         Generation := Generation + 1;
         Atomic.Store_Release_U64
           (Address_At (Item, Generation_Offset, 8), Generation);
         Memory.Zero
           (Slot_At
              (Item, Slot, Name_Offset,
               Byte_Length (Item.Slot_Size) - Name_Offset),
            C.size_t (Byte_Length (Item.Slot_Size) - Name_Offset));
         Write_U32
           (Slot_At (Item, Slot, Slot_Name_Length_Offset, 4),
            Interfaces.Unsigned_32 (Name'Length));
         Write_U64
           (Slot_At (Item, Slot, Slot_Generation_Offset, 8), Generation);
         Write_U32
           (Slot_At (Item, Slot, Slot_Hash_Offset, 4), Hash);
         Write_U64
           (Slot_At (Item, Slot, Slot_Location_Offset, 8),
            Interfaces.Unsigned_64 (Location));
         Write_U64
           (Slot_At (Item, Slot, Slot_Length_Offset, 8),
            Interfaces.Unsigned_64 (Requested_Length));
         Write_U32
           (Slot_At (Item, Slot, Slot_Failure_Offset, 4), 0);
         Write_U64
           (Slot_At (Item, Slot, Slot_Reserved_Offset, 8),
            Interfaces.Unsigned_64 (Reserved));
         Memory.Copy
           (Slot_At (Item, Slot, Name_Offset, Byte_Length (Name'Length)),
            Name'Address, C.size_t (Name'Length));
         Atomic.Store_Release_U32
           (Slot_At (Item, Slot, Slot_State_Offset, 4), Initializing_Slot);
         Handle := (Slot => Slot, Stamp => Generation);
         Claim.Slot := Slot;
         Claim.Stamp := Generation;
         Claim.Location := DS.Region_Offset (Location);
         Claim.Length := Requested_Length;
         Release_Guard (Item);
         Acquired := False;
         Result := Created;
      end;
   exception
      when others =>
         if Acquired then
            Release_Guard (Item);
         end if;
         raise;
   end Try_Find_Or_Create;

   procedure Try_Find
     (Item    : View;
      Name    : String;
      Handle  : out Named_Handle;
      Result  : out Lookup_Result;
      Failure : out Interfaces.Unsigned_32)
   is
      Hash : Interfaces.Unsigned_32;
      Acquired : Boolean := False;
   begin
      Handle := Null_Named_Handle;
      Failure := 0;
      Validate_Name (Item, Name);
      Hash := Name_Hash (Name);
      if not Acquire_Guard (Item) then
         Result := Registry_Busy;
         return;
      end if;
      Acquired := True;
      for Slot in Interfaces.Unsigned_32 range 1 .. Item.Capacity loop
         declare
            State : constant Interfaces.Unsigned_32 :=
              Atomic.Load_Acquire_U32
                (Slot_At (Item, Slot, Slot_State_Offset, 4));
         begin
            if State = Initializing_Slot
              or else State = Ready_Slot
              or else State = Failed_Slot
            then
               Validate_Slot_Metadata (Item, Slot);
               if Same_Name (Item, Slot, Name, Hash) then
                  Fill_Handle (Item, Slot, Handle);
                  if State = Initializing_Slot then
                     Result := Initialization_In_Progress;
                  elsif State = Ready_Slot then
                     Result := Found;
                  else
                     Failure := Read_U32
                       (Slot_At (Item, Slot, Slot_Failure_Offset, 4));
                     if Failure = 0 then
                        raise Segment_Error with
                          "failed segment entry has zero failure code";
                     end if;
                     Result := Initialization_Failed;
                  end if;
                  Release_Guard (Item);
                  return;
               end if;
            elsif State /= Free_Slot and then State /= Removed_Slot then
               raise Segment_Error with
                 "segment registry slot state is corrupt";
            end if;
         end;
      end loop;
      Release_Guard (Item);
      Acquired := False;
      Result := Not_Found;
   exception
      when others =>
         if Acquired then
            Release_Guard (Item);
         end if;
         raise;
   end Try_Find;

   procedure Validate_Claim (Item : View; Claim : Creation_Claim) is
   begin
      Require_Ready (Item);
      if Claim.Slot = 0 or else Claim.Stamp = 0
        or else Claim.Location = DS.Null_Offset or else Claim.Length = 0
      then
         raise Segment_Error with "null segment creation claim";
      elsif Claim.Slot > Item.Capacity
        or else Read_U64
          (Slot_At (Item, Claim.Slot, Slot_Generation_Offset, 8)) /=
            Claim.Stamp
        or else Atomic.Load_Acquire_U32
          (Slot_At (Item, Claim.Slot, Slot_State_Offset, 4)) /=
            Initializing_Slot
        or else Read_U64
          (Slot_At (Item, Claim.Slot, Slot_Location_Offset, 8)) /=
            Interfaces.Unsigned_64 (Claim.Location)
        or else Read_U64
          (Slot_At (Item, Claim.Slot, Slot_Length_Offset, 8)) /=
            Interfaces.Unsigned_64 (Claim.Length)
      then
         raise Segment_Error with "stale or inactive segment creation claim";
      end if;
      Validate_Slot_Metadata (Item, Claim.Slot);
   end Validate_Claim;

   procedure Claimed_Extent
     (Item     : View;
      Claim    : Creation_Claim;
      Location : out DS.Region_Offset;
      Length   : out Byte_Length) is
   begin
      Validate_Claim (Item, Claim);
      Location := Claim.Location;
      Length := Claim.Length;
   end Claimed_Extent;

   procedure Publish (Item : View; Claim : in out Creation_Claim) is
      Expected : aliased Interfaces.Unsigned_32 := Initializing_Slot;
   begin
      Validate_Claim (Item, Claim);
      if CAS_U32
        (Slot_At (Item, Claim.Slot, Slot_State_Offset, 4), Expected'Access,
         Ready_Slot) = 0
      then
         raise Segment_Error with
           "segment creation claim changed during publish";
      end if;
      Clear_Claim (Claim);
   end Publish;

   procedure Publish_Failure
     (Item : View; Claim : in out Creation_Claim; Failure : Failure_Code)
   is
      Expected : aliased Interfaces.Unsigned_32 := Initializing_Slot;
   begin
      Validate_Claim (Item, Claim);
      Write_U32
        (Slot_At (Item, Claim.Slot, Slot_Failure_Offset, 4), Failure);
      if CAS_U32
        (Slot_At (Item, Claim.Slot, Slot_State_Offset, 4), Expected'Access,
         Failed_Slot) = 0
      then
         raise Segment_Error with
           "segment creation claim changed during failure publication";
      end if;
      Clear_Claim (Claim);
   end Publish_Failure;

   function State_Of
     (Item : View; Handle : Named_Handle) return Handle_State
   is
      State : Interfaces.Unsigned_32;
   begin
      Require_Ready (Item);
      if Handle.Slot = 0 and then Handle.Stamp = 0 then
         return Null_Handle;
      elsif Handle.Slot = 0 or else Handle.Stamp = 0
        or else Handle.Slot > Item.Capacity
      then
         return Stale;
      end if;
      State := Atomic.Load_Acquire_U32
        (Slot_At (Item, Handle.Slot, Slot_State_Offset, 4));
      if State = Free_Slot then
         return Stale;
      elsif Read_U64
        (Slot_At (Item, Handle.Slot, Slot_Generation_Offset, 8)) /=
          Handle.Stamp
      then
         return Stale;
      end if;
      case State is
         when Initializing_Slot => return Initializing;
         when Ready_Slot        => return Ready;
         when Failed_Slot       => return Failed;
         when Removed_Slot      => return Removed;
         when Free_Slot         => return Stale;
         when others =>
            raise Segment_Error with "segment registry slot state is corrupt";
      end case;
   end State_Of;

   procedure Resolve
     (Item     : View;
      Handle   : Named_Handle;
      Location : out DS.Region_Offset;
      Length   : out Byte_Length) is
   begin
      if State_Of (Item, Handle) /= Ready then
         raise Segment_Error with "named segment handle is not ready";
      end if;
      Validate_Slot_Metadata (Item, Handle.Slot);
      Location := DS.Region_Offset
        (Read_U64
           (Slot_At (Item, Handle.Slot, Slot_Location_Offset, 8)));
      Length := Byte_Length
        (Read_U64 (Slot_At (Item, Handle.Slot, Slot_Length_Offset, 8)));
      if State_Of (Item, Handle) /= Ready then
         raise Segment_Error with
           "named segment handle changed during resolution";
      elsif Location = DS.Null_Offset or else Length = 0
        or else Byte_Length (Location) > Item.Extent
        or else Length > Item.Extent - Byte_Length (Location)
      then
         raise Segment_Error with "named segment extent is corrupt";
      end if;
   end Resolve;

   function Failure_Of
     (Item : View; Handle : Named_Handle) return Failure_Code
   is
      Value : Interfaces.Unsigned_32;
   begin
      if State_Of (Item, Handle) /= Failed then
         raise Segment_Error with "named segment handle is not failed";
      end if;
      Value := Read_U32
        (Slot_At (Item, Handle.Slot, Slot_Failure_Offset, 4));
      if State_Of (Item, Handle) /= Failed then
         raise Segment_Error with
           "named segment handle changed during failure inspection";
      elsif Value = 0 then
         raise Segment_Error with "failed segment entry has zero failure code";
      end if;
      return Failure_Code (Value);
   end Failure_Of;

   procedure Try_Remove
     (Item : View; Name : String; Result : out Remove_Result)
   is
      Hash : Interfaces.Unsigned_32;
      Acquired : Boolean := False;
   begin
      Validate_Name (Item, Name);
      Hash := Name_Hash (Name);
      if not Acquire_Guard (Item) then
         Result := Registry_Busy;
         return;
      end if;
      Acquired := True;
      for Slot in Interfaces.Unsigned_32 range 1 .. Item.Capacity loop
         declare
            State : constant Interfaces.Unsigned_32 := Atomic.Load_Acquire_U32
              (Slot_At (Item, Slot, Slot_State_Offset, 4));
         begin
            if State = Initializing_Slot
              or else State = Ready_Slot
              or else State = Failed_Slot
            then
               Validate_Slot_Metadata (Item, Slot);
               if Same_Name (Item, Slot, Name, Hash) then
                  if State = Initializing_Slot then
                     Result := Initialization_In_Progress;
                  else
                     Atomic.Store_Release_U32
                       (Slot_At (Item, Slot, Slot_State_Offset, 4),
                        Removed_Slot);
                     Result := Removed;
                  end if;
                  Release_Guard (Item);
                  return;
               end if;
            elsif State /= Free_Slot and then State /= Removed_Slot then
               raise Segment_Error with
                 "segment registry slot state is corrupt";
            end if;
         end;
      end loop;
      Release_Guard (Item);
      Acquired := False;
      Result := Not_Found;
   exception
      when others =>
         if Acquired then
            Release_Guard (Item);
         end if;
         raise;
   end Try_Remove;

end Flyology.Shared_Memory.Segments;
