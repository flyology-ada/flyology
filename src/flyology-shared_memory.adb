with Ada.Strings;
with Ada.Strings.Fixed;
with Flyology.Shared_Memory_Native;
with Flyology.Shared_Memory_Policy;
with GNAT.OS_Lib;
with Interfaces.C.Strings;

package body Flyology.Shared_Memory is
   package Native renames Flyology.Shared_Memory_Native;
   package Policy renames Flyology.Shared_Memory_Policy;
   package C_Strings renames Interfaces.C.Strings;

   use type Byte_Length;
   use type C.long_long;
   use type C.unsigned;
   use type C.unsigned_long_long;
   use type Interfaces.Unsigned_32;
   use type System.Address;

   type Namespace_Mode is (Create_Only, Open_Only, Create_Or_Open);

   function Current_Error return C.int
   is (C.int (GNAT.OS_Lib.Errno));

   procedure Raise_Failure (Operation : String; Code : C.int) is
   begin
      if Code = -1 then
         raise Validation_Error with Operation & ": exact size does not match";
      elsif Code = -2 then
         raise Validation_Error with Operation & ": object type does not match";
      elsif Code = -3 then
         raise Security_Error with Operation & ": required security property is unavailable";
      elsif Code = -4 then
         raise Validation_Error with Operation & ": namespace no longer names this backing object";
      else
         raise Operating_System_Error with Operation & " failed (errno" & C.int'Image (Code) & ")";
      end if;
   end Raise_Failure;

   procedure Raise_Current (Operation : String) is
   begin
      Raise_Failure (Operation, Current_Error);
   end Raise_Current;

   function Native_Length (Value : Byte_Length) return C.long_long is
   begin
      if Value = 0 then
         raise Constraint_Error with "shared-memory length must be positive";
      elsif Value > Byte_Length (C.long_long'Last) then
         raise Constraint_Error with "shared-memory length is not natively representable";
      end if;
      return C.long_long (Value);
   end Native_Length;

   function Has_All (Value, Flags : C.int) return Boolean
   is ((Interfaces.Unsigned_32 (Value) and Interfaces.Unsigned_32 (Flags)) = Interfaces.Unsigned_32 (Flags));

   procedure Ensure_Close_On_Exec (Descriptor : C.int) is
      Flags : C.int := Native.Get_Descriptor_Flags (Descriptor);
   begin
      if Flags < 0 then
         Raise_Current ("descriptor flag inspection");
      elsif not Has_All (Flags, Native.Descriptor_Close_On_Exec) then
         Flags := Flags + Native.Descriptor_Close_On_Exec;
         if Native.Set_Descriptor_Flags (Descriptor, Flags) /= 0 then
            Raise_Current ("descriptor close-on-exec setup");
         end if;
      end if;
   end Ensure_Close_On_Exec;

   procedure Inspect_Descriptor
     (Descriptor   : C.int;
      No_Follow    : Boolean;
      Fields       : out Native.Stat_Fields;
      Status_Flags : out C.int;
      Properties   : out Security_Properties)
   is
      Descriptor_Flags : C.int;
      Seals            : C.int;
      Immutable_Seals  : constant C.int := Native.Seal_Seal + Native.Seal_Shrink + Native.Seal_Grow;
   begin
      if Native.Descriptor_Stat (Descriptor, Fields) /= 0 then
         Raise_Current ("descriptor metadata inspection");
      elsif Fields.Size < 0 then
         raise Validation_Error with "descriptor length is negative";
      end if;
      Descriptor_Flags := Native.Get_Descriptor_Flags (Descriptor);
      if Descriptor_Flags < 0 then
         Raise_Current ("descriptor flag inspection");
      end if;
      Status_Flags := Native.Get_Status_Flags (Descriptor);
      if Status_Flags < 0 then
         Raise_Current ("descriptor status inspection");
      end if;
      Seals := Native.Get_Seals (Descriptor);
      Properties :=
        (Close_On_Exec             => Has_All (Descriptor_Flags, Native.Descriptor_Close_On_Exec),
         Size_Immutable            => Seals >= 0 and then Has_All (Seals, Immutable_Seals),
         No_Execute_Seal           => Seals >= 0 and then Has_All (Seals, Native.Seal_Execute),
         No_Execute_Seal_Supported => Seals >= 0 and then Has_All (Seals, Native.Seal_Execute),
         No_Symlink_Follow         => No_Follow,
         Owner_Only_Permissions    =>
           Policy.Owner_Only (Interfaces.Unsigned_32 (Fields.Mode), Native.Owner_Only_Mask));
   end Inspect_Descriptor;

   procedure Inspect_Descriptor
     (Descriptor : C.int;
      No_Follow  : Boolean;
      Fields     : out Native.Stat_Fields;
      Properties : out Security_Properties)
   is
      Status_Flags : C.int;
   begin
      Inspect_Descriptor (Descriptor, No_Follow, Fields, Status_Flags, Properties);
   end Inspect_Descriptor;

   procedure Require_Closed (Item : Backing_Object) is
   begin
      if Item.Descriptor >= 0 then
         raise Validation_Error with "backing object is already open";
      end if;
   end Require_Closed;

   procedure Require_Unmapped (Item : Mapping) is
   begin
      if Item.State.Base /= System.Null_Address then
         raise Validation_Error with "mapping owner is already mapped";
      end if;
   end Require_Unmapped;

   procedure Validate_Text (Value, Description : String) is
   begin
      if Value'Length = 0 then
         raise Constraint_Error with Description & " must not be empty";
      end if;
      for Character of Value loop
         if Character = ASCII.NUL then
            raise Constraint_Error with Description & " contains a NUL byte";
         end if;
      end loop;
   end Validate_Text;

   procedure Validate_POSIX_Name (Name : String) is
   begin
      Validate_Text (Name, "POSIX shared-memory name");
      if Name (Name'First) /= '/' then
         raise Constraint_Error with "POSIX shared-memory name must begin with slash";
      end if;
      for Index in Name'First + 1 .. Name'Last loop
         if Name (Index) = '/' then
            raise Constraint_Error with "POSIX shared-memory name contains an interior slash";
         end if;
      end loop;
   end Validate_POSIX_Name;

   procedure Install
     (Item           : in out Backing_Object;
      Descriptor     : C.int;
      Length         : Byte_Length;
      Kind           : Backing_Kind;
      Properties     : Security_Properties;
      Namespace      : String := "";
      POSIX_Name     : Boolean := False;
      May_Initialize : Boolean := True) is
   begin
      Item.Descriptor := Descriptor;
      Item.Length_Value := Length;
      Item.Kind_Value := Kind;
      Item.Property_Value := Properties;
      Item.Namespace_Value := Unbounded.To_Unbounded_String (Namespace);
      Item.Namespace_Is_POSIX := POSIX_Name;
      Item.May_Initialize := May_Initialize;
   end Install;

   procedure Close_Ignoring (Descriptor : in out C.int) is
      Ignored : C.int;
   begin
      if Descriptor >= 0 then
         Ignored := Native.Close (Descriptor);
         Descriptor := -1;
      end if;
   end Close_Ignoring;

   function Identity_Matches
     (Descriptor : C.int; Name : C_Strings.chars_ptr; POSIX_Name : Boolean) return Boolean
   is
      Expected           : Native.Stat_Fields;
      Current            : Native.Stat_Fields;
      Current_Descriptor : C.int := -1;
   begin
      if Native.Descriptor_Stat (Descriptor, Expected) /= 0 then
         Raise_Current ("backing identity inspection");
      end if;
      if POSIX_Name then
         if not Native.POSIX_Identity_Supported then
            return True;
         end if;
         Current_Descriptor :=
           Native.Shared_Open (Name, Native.Open_Read_Only + Native.Shared_Open_Close_On_Exec, 0);
         if Current_Descriptor < 0 then
            Raise_Current ("shared-memory namespace identity open");
         end if;
         Ensure_Close_On_Exec (Current_Descriptor);
         if Native.Descriptor_Stat (Current_Descriptor, Current) /= 0 then
            declare
               Error : constant C.int := Current_Error;
            begin
               Close_Ignoring (Current_Descriptor);
               Raise_Failure ("shared-memory namespace identity", Error);
            end;
         end if;
         if Native.Close (Current_Descriptor) /= 0 then
            Current_Descriptor := -1;
            Raise_Current ("shared-memory identity descriptor close");
         end if;
         Current_Descriptor := -1;
      else
         if Native.Path_Stat (Name, Current) /= 0 then
            Raise_Current ("file namespace identity inspection");
         end if;
      end if;
      return
        Expected.Device = Current.Device
        and then Expected.Inode = Current.Inode
        and then (Interfaces.Unsigned_32 (Expected.Mode) and Native.File_Type_Mask)
                 = (Interfaces.Unsigned_32 (Current.Mode) and Native.File_Type_Mask);
   exception
      when others =>
         Close_Ignoring (Current_Descriptor);
         raise;
   end Identity_Matches;

   procedure Unlink_Matching (Descriptor : C.int; Name : C_Strings.chars_ptr; POSIX_Name : Boolean) is
      Result : C.int;
   begin
      if not Identity_Matches (Descriptor, Name, POSIX_Name) then
         Raise_Failure ("shared-memory unlink", -4);
      end if;
      Result := (if POSIX_Name then Native.Shared_Unlink (Name) else Native.File_Unlink (Name));
      if Result /= 0 then
         Raise_Current ("shared-memory unlink");
      end if;
   end Unlink_Matching;

   procedure Cleanup_Failed_Open
     (Descriptor : in out C.int; Created : Boolean; Name : C_Strings.chars_ptr; POSIX_Name : Boolean) is
   begin
      if Created then
         begin
            Unlink_Matching (Descriptor, Name, POSIX_Name);
         exception
            when others =>
               Close_Ignoring (Descriptor);
               raise;
         end;
      end if;
      Close_Ignoring (Descriptor);
   end Cleanup_Failed_Open;

   procedure Create_Anonymous
     (Item : in out Backing_Object; Length : Byte_Length; Require_No_Execute_Seal : Boolean := False)
   is
      Native_Size : constant C.long_long := Native_Length (Length);
      Descriptor  : C.int := -1;
      Fields      : Native.Stat_Fields;
      Props       : Security_Properties;
   begin
      Require_Closed (Item);
      if Native.Is_Linux then
         declare
            Base_Flags       : constant C.unsigned := Native.Memfd_Close_On_Exec + Native.Memfd_Allow_Sealing;
            Noexec_Supported : Boolean := True;
         begin
            Descriptor := Native.Memfd_Create (Base_Flags + Native.Memfd_No_Execute_Seal);
            if Descriptor < 0 and then Current_Error = Native.Error_Invalid then
               Noexec_Supported := False;
               Descriptor := Native.Memfd_Create (Base_Flags);
            end if;
            if Descriptor < 0 then
               Raise_Current ("anonymous shared-memory creation");
            elsif not Noexec_Supported and then Require_No_Execute_Seal then
               Close_Ignoring (Descriptor);
               Raise_Failure ("anonymous shared-memory creation", -3);
            end if;
            if Native.Truncate (Descriptor, Native_Size) /= 0 then
               declare
                  Error : constant C.int := Current_Error;
               begin
                  Close_Ignoring (Descriptor);
                  Raise_Failure ("anonymous shared-memory sizing", Error);
               end;
            end if;
            if Native.Add_Seals (Descriptor, Native.Seal_Seal + Native.Seal_Shrink + Native.Seal_Grow) /= 0
            then
               declare
                  Error : constant C.int := Current_Error;
               begin
                  Close_Ignoring (Descriptor);
                  Raise_Failure ("anonymous shared-memory sealing", Error);
               end;
            end if;
            Ensure_Close_On_Exec (Descriptor);
            Inspect_Descriptor (Descriptor, False, Fields, Props);
            if Fields.Size /= Native_Size then
               Close_Ignoring (Descriptor);
               Raise_Failure ("anonymous shared-memory creation", -1);
            elsif not Props.Close_On_Exec
              or else not Props.Size_Immutable
              or else (Require_No_Execute_Seal and then not Props.No_Execute_Seal)
            then
               Close_Ignoring (Descriptor);
               Raise_Failure ("anonymous shared-memory creation", -3);
            end if;
         end;
      else
         declare
            --  Darwin limits POSIX shared-memory names to 31 characters.
            --  Eight random bytes retain an unpredictable 64-bit capability
            --  name while leaving room for the prefix and retry suffix.
            subtype Random_Index is Natural range 0 .. 7;
            type Random_Array is array (Random_Index) of Interfaces.Unsigned_8 with Convention => C;
            Random : aliased Random_Array := (others => 0);
            Hex    : constant String := "0123456789abcdef";
            function Random_Name (Attempt : Natural) return String is
               Hex_Text : String (1 .. Random'Length * 2);
               Cursor   : Positive := Hex_Text'First;
            begin
               for Value of Random loop
                  Hex_Text (Cursor) := Hex (Natural (Value) / 16 + Hex'First);
                  Hex_Text (Cursor + 1) := Hex (Natural (Value) mod 16 + Hex'First);
                  Cursor := Cursor + 2;
               end loop;
               return
                 "/flyology-"
                 & Hex_Text
                 & "-"
                 & Ada.Strings.Fixed.Trim (Natural'Image (Attempt), Ada.Strings.Both);
            end Random_Name;
         begin
            if Require_No_Execute_Seal then
               Raise_Failure ("anonymous shared-memory creation", -3);
            elsif Native.Fill_Random (Random'Address, C.size_t (Random'Length)) /= 0 then
               Raise_Current ("anonymous shared-memory name generation");
            end if;
            for Attempt in 0 .. 127 loop
               declare
                  Name   : constant String := Random_Name (Attempt);
                  C_Name : C_Strings.chars_ptr := C_Strings.New_String (Name);
               begin
                  Descriptor :=
                    Native.Shared_Open
                      (C_Name,
                       Native.Open_Read_Write
                       + Native.Open_Create
                       + Native.Open_Exclusive
                       + Native.Shared_Open_Close_On_Exec,
                       8#600#);
                  if Descriptor >= 0 then
                     Ensure_Close_On_Exec (Descriptor);
                     if Native.Truncate (Descriptor, Native_Size) /= 0 then
                        declare
                           Error : constant C.int := Current_Error;
                        begin
                           if Native.Shared_Unlink (C_Name) /= 0 then
                              null;
                           end if;
                           Close_Ignoring (Descriptor);
                           C_Strings.Free (C_Name);
                           Raise_Failure ("anonymous shared-memory sizing", Error);
                        end;
                     elsif Native.Shared_Unlink (C_Name) /= 0 then
                        declare
                           Error : constant C.int := Current_Error;
                        begin
                           if Native.Shared_Unlink (C_Name) /= 0 then
                              null;
                           end if;
                           Close_Ignoring (Descriptor);
                           C_Strings.Free (C_Name);
                           Raise_Failure ("anonymous shared-memory unlink", Error);
                        end;
                     end if;
                     C_Strings.Free (C_Name);
                     exit;
                  elsif Current_Error /= Native.Error_Exists then
                     declare
                        Error : constant C.int := Current_Error;
                     begin
                        C_Strings.Free (C_Name);
                        Raise_Failure ("anonymous shared-memory creation", Error);
                     end;
                  end if;
                  C_Strings.Free (C_Name);
               end;
            end loop;
            if Descriptor < 0 then
               Raise_Failure ("anonymous shared-memory creation", Native.Error_Exists);
            end if;
            Inspect_Descriptor (Descriptor, False, Fields, Props);
            if Fields.Size /= Native_Size then
               Close_Ignoring (Descriptor);
               Raise_Failure ("anonymous shared-memory creation", -1);
            elsif not Props.Close_On_Exec then
               Close_Ignoring (Descriptor);
               Raise_Failure ("anonymous shared-memory creation", -3);
            end if;
         end;
      end if;
      Install (Item, Descriptor, Length, Anonymous_Capability, Props);
      Descriptor := -1;
   exception
      when others =>
         Close_Ignoring (Descriptor);
         raise;
   end Create_Anonymous;

   procedure Named_Operation
     (Item        : in out Backing_Object;
      Name        : String;
      Length      : Byte_Length;
      Mode        : Namespace_Mode;
      Result      : out Namespace_Open_Result;
      Permissions : Permission_Bits)
   is
      Native_Size    : constant C.long_long := Native_Length (Length);
      C_Name         : C_Strings.chars_ptr := C_Strings.Null_Ptr;
      Descriptor     : C.int := -1;
      Created        : Boolean := False;
      Fields         : Native.Stat_Fields;
      Props          : Security_Properties;
      Classification : Policy.Namespace_Classification;
   begin
      Require_Closed (Item);
      Validate_POSIX_Name (Name);
      C_Name := C_Strings.New_String (Name);
      if Mode in Create_Only | Create_Or_Open then
         Descriptor :=
           Native.Shared_Open
             (C_Name,
              Native.Open_Read_Write
              + Native.Open_Create
              + Native.Open_Exclusive
              + Native.Shared_Open_Close_On_Exec,
              C.unsigned (Permissions));
         if Descriptor >= 0 then
            Created := True;
         elsif Mode = Create_Only or else Current_Error /= Native.Error_Exists then
            Raise_Current ("named shared-memory create");
         end if;
      end if;
      if Descriptor < 0 then
         Descriptor :=
           Native.Shared_Open (C_Name, Native.Open_Read_Write + Native.Shared_Open_Close_On_Exec, 0);
         if Descriptor < 0 then
            Raise_Current ("named shared-memory open");
         end if;
      end if;
      Ensure_Close_On_Exec (Descriptor);
      if Created and then Native.Truncate (Descriptor, Native_Size) /= 0 then
         Raise_Current ("named shared-memory sizing");
      end if;
      Inspect_Descriptor (Descriptor, False, Fields, Props);
      Classification :=
        Policy.Classify_Namespace
          (Created, Interfaces.Unsigned_64 (Fields.Size), Interfaces.Unsigned_64 (Native_Size));
      case Classification is
         when Policy.Namespace_In_Progress   =>
            Close_Ignoring (Descriptor);
            Result := Initialization_In_Progress;

         when Policy.Namespace_Size_Mismatch =>
            Raise_Failure ("named shared-memory open", -1);

         when Policy.Namespace_Ready         =>
            Result := (if Created then Created_New else Opened_Existing);
            Install
              (Item,
               Descriptor,
               Length,
               Named_POSIX,
               Props,
               Name,
               POSIX_Name     => True,
               May_Initialize => Created);
            Descriptor := -1;
      end case;
      C_Strings.Free (C_Name);
   exception
      when others =>
         if Descriptor >= 0 then
            Cleanup_Failed_Open (Descriptor, Created, C_Name, POSIX_Name => True);
         end if;
         C_Strings.Free (C_Name);
         raise;
   end Named_Operation;

   procedure Create_Named
     (Item        : in out Backing_Object;
      Name        : String;
      Length      : Byte_Length;
      Permissions : Permission_Bits := 8#600#)
   is
      Result : Namespace_Open_Result;
   begin
      Named_Operation (Item, Name, Length, Create_Only, Result, Permissions);
      pragma Assert (Result = Created_New);
   end Create_Named;

   procedure Open_Named
     (Item            : in out Backing_Object;
      Name            : String;
      Expected_Length : Byte_Length;
      Result          : out Namespace_Open_Result) is
   begin
      Named_Operation (Item, Name, Expected_Length, Open_Only, Result, Permission_Bits'First);
   end Open_Named;

   procedure Create_Or_Open_Named
     (Item        : in out Backing_Object;
      Name        : String;
      Length      : Byte_Length;
      Result      : out Namespace_Open_Result;
      Permissions : Permission_Bits := 8#600#) is
   begin
      Named_Operation (Item, Name, Length, Create_Or_Open, Result, Permissions);
   end Create_Or_Open_Named;

   procedure File_Operation
     (Item        : in out Backing_Object;
      Path        : String;
      Length      : Byte_Length;
      Create      : Boolean;
      Permissions : Permission_Bits)
   is
      Native_Size : constant C.long_long := Native_Length (Length);
      C_Path      : C_Strings.chars_ptr := C_Strings.Null_Ptr;
      Descriptor  : C.int := -1;
      Fields      : Native.Stat_Fields;
      Props       : Security_Properties;
      Flags       : C.int := Native.Open_Read_Write + Native.Open_Close_On_Exec + Native.Open_No_Follow;
   begin
      Require_Closed (Item);
      Validate_Text (Path, "shared-memory file path");
      if Create then
         Flags := Flags + Native.Open_Create + Native.Open_Exclusive;
      end if;
      C_Path := C_Strings.New_String (Path);
      Descriptor := Native.File_Open (C_Path, Flags, C.unsigned (Permissions));
      if Descriptor < 0 then
         Raise_Current ("file-backed shared-memory open");
      end if;
      Ensure_Close_On_Exec (Descriptor);
      Inspect_Descriptor (Descriptor, True, Fields, Props);
      if not Policy.Is_Regular
               (Interfaces.Unsigned_32 (Fields.Mode), Native.File_Type_Mask, Native.Regular_File_Type)
      then
         Raise_Failure ("file-backed shared-memory open", -2);
      elsif Create and then Native.Truncate (Descriptor, Native_Size) /= 0 then
         Raise_Current ("file-backed shared-memory sizing");
      end if;
      if Create then
         Inspect_Descriptor (Descriptor, True, Fields, Props);
      end if;
      if Fields.Size /= Native_Size then
         Raise_Failure ("file-backed shared-memory open", -1);
      end if;
      Install (Item, Descriptor, Length, File_Backed, Props, Path, May_Initialize => Create);
      Descriptor := -1;
      C_Strings.Free (C_Path);
   exception
      when others =>
         if Descriptor >= 0 then
            Cleanup_Failed_Open (Descriptor, Create, C_Path, POSIX_Name => False);
         end if;
         C_Strings.Free (C_Path);
         raise;
   end File_Operation;

   procedure Create_File
     (Item        : in out Backing_Object;
      Path        : String;
      Length      : Byte_Length;
      Permissions : Permission_Bits := 8#600#) is
   begin
      File_Operation (Item, Path, Length, True, Permissions);
   end Create_File;

   procedure Open_File (Item : in out Backing_Object; Path : String; Expected_Length : Byte_Length) is
   begin
      File_Operation (Item, Path, Expected_Length, False, Permission_Bits'First);
   end Open_File;

   procedure Unlink (Item : in out Backing_Object) is
      Name   : constant String := Unbounded.To_String (Item.Namespace_Value);
      C_Name : C_Strings.chars_ptr := C_Strings.Null_Ptr;
   begin
      if Name'Length = 0 then
         return;
      elsif not Is_Open (Item) then
         raise Validation_Error with "cannot unlink without an open identity descriptor";
      end if;
      C_Name := C_Strings.New_String (Name);
      Unlink_Matching (Item.Descriptor, C_Name, Item.Namespace_Is_POSIX);
      C_Strings.Free (C_Name);
      Item.Namespace_Value := Unbounded.Null_Unbounded_String;
      Item.Namespace_Is_POSIX := False;
   exception
      when others =>
         C_Strings.Free (C_Name);
         raise;
   end Unlink;

   procedure Close (Item : in out Backing_Object) is
      Descriptor : constant C.int := Item.Descriptor;
   begin
      if Descriptor < 0 then
         return;
      end if;
      Item.Descriptor := -1;
      Item.Length_Value := 0;
      Item.Property_Value := (others => False);
      Item.May_Initialize := False;
      if Native.Close (Descriptor) /= 0 then
         Raise_Current ("shared-memory descriptor close");
      end if;
   end Close;

   function Is_Open (Item : Backing_Object) return Boolean
   is (Item.Descriptor >= 0);

   function Length (Item : Backing_Object) return Byte_Length
   is (if Is_Open (Item) then Item.Length_Value else 0);

   function Kind (Item : Backing_Object) return Backing_Kind is
   begin
      if not Is_Open (Item) then
         raise Validation_Error with "backing object is closed";
      end if;
      return Item.Kind_Value;
   end Kind;

   function Properties (Item : Backing_Object) return Security_Properties is
   begin
      if not Is_Open (Item) then
         raise Validation_Error with "backing object is closed";
      end if;
      return Item.Property_Value;
   end Properties;

   procedure Map (Item : in out Mapping; Source : Backing_Object) is
      Base : System.Address;
   begin
      Require_Unmapped (Item);
      if not Is_Open (Source) then
         raise Validation_Error with "cannot map a closed backing object";
      end if;
      Base := Native.Map_Shared (Source.Descriptor, C.size_t (Source.Length_Value));
      if Base = Native.Failed_Mapping then
         Raise_Current ("shared-memory map");
      end if;
      Item.State.Base := Base;
      Item.State.Length_Value := Source.Length_Value;
      Item.State.May_Initialize := Source.May_Initialize;
   end Map;

   procedure Flush (Item : Mapping; Synchronous : Boolean := True) is
   begin
      if not Is_Mapped (Item) then
         raise Validation_Error with "cannot flush an unmapped mapping";
      elsif Native.Flush_Mapping (Item.State.Base, C.size_t (Item.State.Length_Value), Synchronous) /= 0 then
         Raise_Current ("shared mapping flush");
      end if;
   end Flush;

   procedure Flush (Item : Backing_Object) is
   begin
      if not Is_Open (Item) then
         raise Validation_Error with "cannot flush a closed backing object";
      elsif Native.Flush_File (Item.Descriptor) /= 0 then
         Raise_Current ("backing object flush");
      end if;
   end Flush;

   procedure Attach_Region (Item : Mapping; Region : in out Flyology.Data_Structures.Regions.View) is
   begin
      if not Is_Mapped (Item) then
         raise Validation_Error with "cannot attach a region to an unmapped mapping";
      end if;
      Flyology.Data_Structures.Regions.Attach (Region, Item.State.Base, Item.State.Length_Value);
   end Attach_Region;

   procedure Unmap (Item : in out Mapping) is
      Base   : constant System.Address := Item.State.Base;
      Length : constant Byte_Length := Item.State.Length_Value;
   begin
      if Base = System.Null_Address then
         return;
      elsif Native.Unmap (Base, C.size_t (Length)) /= 0 then
         Raise_Current ("shared-memory unmap");
      end if;
      Item.State.Base := System.Null_Address;
      Item.State.Length_Value := 0;
      Item.State.May_Initialize := False;
   end Unmap;

   function Is_Mapped (Item : Mapping) return Boolean
   is (Item.State.Base /= System.Null_Address);

   function Length (Item : Mapping) return Byte_Length
   is (if Is_Mapped (Item) then Item.State.Length_Value else 0);

   overriding
   procedure Finalize (Item : in out Backing_Object) is
      Descriptor : C.int := Item.Descriptor;
   begin
      Item.Descriptor := -1;
      Item.Length_Value := 0;
      Item.May_Initialize := False;
      Close_Ignoring (Descriptor);
   exception
      when others =>
         null;
   end Finalize;

   overriding
   procedure Finalize (Item : in out Mapping_State) is
      Base    : constant System.Address := Item.Base;
      Length  : constant Byte_Length := Item.Length_Value;
      Ignored : C.int;
   begin
      Item.Base := System.Null_Address;
      Item.Length_Value := 0;
      Item.May_Initialize := False;
      if Base /= System.Null_Address then
         Ignored := Native.Unmap (Base, C.size_t (Length));
      end if;
   exception
      when others =>
         null;
   end Finalize;

   procedure Validate_Received
     (Descriptor             : C.int;
      Expected_Length        : Byte_Length;
      Require_Immutable_Size : Boolean;
      Properties             : out Security_Properties)
   is
      Fields       : Native.Stat_Fields;
      Status_Flags : C.int;
      Result       : Policy.Descriptor_Validation;
   begin
      Ensure_Close_On_Exec (Descriptor);
      Inspect_Descriptor (Descriptor, False, Fields, Status_Flags, Properties);
      Result :=
        Policy.Validate_Descriptor
          (Actual_Length     => Interfaces.Unsigned_64 (Fields.Size),
           Expected_Length   => Interfaces.Unsigned_64 (Expected_Length),
           Mode              => Interfaces.Unsigned_32 (Fields.Mode),
           Type_Mask         => Native.File_Type_Mask,
           Regular_Type      => Native.Regular_File_Type,
           Allow_Untyped     => not Native.Is_Linux,
           Writable          =>
             (Interfaces.Unsigned_32 (Status_Flags) and Interfaces.Unsigned_32 (Native.Access_Mode_Mask))
             = Interfaces.Unsigned_32 (Native.Status_Read_Write),
           Close_On_Exec     => Properties.Close_On_Exec,
           Size_Immutable    => Properties.Size_Immutable,
           Require_Immutable => Require_Immutable_Size);
      case Result is
         when Policy.Descriptor_Valid =>
            null;

         when Policy.Size_Mismatch    =>
            Raise_Failure ("received descriptor validation", -1);

         when Policy.Type_Mismatch    =>
            Raise_Failure ("received descriptor validation", -2);

         when Policy.Security_Missing =>
            Raise_Failure ("received descriptor validation", -3);
      end case;
   end Validate_Received;

   procedure Adopt_Received
     (Item       : in out Backing_Object;
      Descriptor : C.int;
      Length     : Byte_Length;
      Properties : Security_Properties) is
   begin
      Require_Closed (Item);
      Item.Descriptor := Descriptor;
      Item.Length_Value := Length;
      Item.Kind_Value := Received_Capability;
      Item.Property_Value := Properties;
      Item.Namespace_Value := Unbounded.Null_Unbounded_String;
      Item.Namespace_Is_POSIX := False;
      Item.May_Initialize := False;
   end Adopt_Received;

   function Owned_Descriptor (Item : Backing_Object) return C.int is
   begin
      if not Is_Open (Item) then
         raise Validation_Error with "backing object is closed";
      end if;
      return Item.Descriptor;
   end Owned_Descriptor;

   function Mapping_Base (Item : Mapping) return System.Address
   is (Item.State.Base);

   function Mapping_Length (Item : Mapping) return Byte_Length
   is (Item.State.Length_Value);

   function Mapping_May_Initialize (Item : Mapping) return Boolean
   is (Item.State.May_Initialize);
end Flyology.Shared_Memory;
