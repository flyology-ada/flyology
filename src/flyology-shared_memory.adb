with Interfaces.C.Strings;

package body Flyology.Shared_Memory is
   package C_Strings renames Interfaces.C.Strings;
   use type Byte_Length;
   use type System.Address;

   Property_CLOEXEC        : constant C.int := 2 ** 0;
   Property_Immutable      : constant C.int := 2 ** 1;
   Property_Noexec         : constant C.int := 2 ** 2;
   Property_Noexec_Support : constant C.int := 2 ** 3;
   Property_Nofollow       : constant C.int := 2 ** 4;
   Property_Owner_Only     : constant C.int := 2 ** 5;

   function C_Create_Anonymous
     (Length          : C.unsigned_long_long;
      Require_Noexec  : C.int;
      Descriptor      : access C.int;
      Properties      : access C.int) return C.int;
   pragma Import
     (C, C_Create_Anonymous, "flyology_shm_create_anonymous");

   function C_Open_Named
     (Name        : C_Strings.chars_ptr;
      Length      : C.unsigned_long_long;
      Permissions : C.unsigned;
      Mode        : C.int;
      Descriptor  : access C.int;
      Properties  : access C.int;
      Outcome     : access C.int) return C.int;
   pragma Import (C, C_Open_Named, "flyology_shm_open_named");

   function C_Open_File
     (Path        : C_Strings.chars_ptr;
      Length      : C.unsigned_long_long;
      Permissions : C.unsigned;
      Create      : C.int;
      Descriptor  : access C.int;
      Properties  : access C.int) return C.int;
   pragma Import (C, C_Open_File, "flyology_shm_open_file");

   function C_Map
     (Descriptor : C.int;
      Length     : C.unsigned_long_long;
      Base       : access System.Address) return C.int;
   pragma Import (C, C_Map, "flyology_shm_map");

   function C_Unmap
     (Base : System.Address; Length : C.unsigned_long_long) return C.int;
   pragma Import (C, C_Unmap, "flyology_shm_unmap");

   function C_Msync
     (Base         : System.Address;
      Length       : C.unsigned_long_long;
      Synchronous  : C.int) return C.int;
   pragma Import (C, C_Msync, "flyology_shm_msync");

   function C_Fsync (Descriptor : C.int) return C.int;
   pragma Import (C, C_Fsync, "flyology_shm_fsync");

   function C_Close (Descriptor : C.int) return C.int;
   pragma Import (C, C_Close, "flyology_shm_close");

   function C_Unlink
     (Descriptor : C.int;
      Name       : C_Strings.chars_ptr;
      POSIX_Name : C.int) return C.int;
   pragma Import (C, C_Unlink, "flyology_shm_unlink_name");

   function Native_Length (Value : Byte_Length) return C.unsigned_long_long is
   begin
      if Value = 0 then
         raise Constraint_Error with "shared-memory length must be positive";
      elsif Value > Byte_Length (C.long_long'Last) then
         raise Constraint_Error with
           "shared-memory length is not natively representable";
      end if;
      return C.unsigned_long_long (Value);
   end Native_Length;

   procedure Raise_Failure (Operation : String; Code : C.int) is
   begin
      if Code = -1 then
         raise Validation_Error with Operation & ": exact size does not match";
      elsif Code = -2 then
         raise Validation_Error with
           Operation & ": object type does not match";
      elsif Code = -3 then
         raise Security_Error with
           Operation & ": required security property is unavailable";
      elsif Code = -4 then
         raise Validation_Error with
           Operation & ": namespace no longer names this backing object";
      else
         raise Operating_System_Error with
           Operation & " failed (errno" & C.int'Image (Code) & ")";
      end if;
   end Raise_Failure;

   function Decode_Properties (Value : C.int) return Security_Properties is
      function Has (Flag : C.int) return Boolean is
        ((Value / Flag) mod 2 = 1);
   begin
      return
        (Close_On_Exec             => Has (Property_CLOEXEC),
         Size_Immutable            => Has (Property_Immutable),
         No_Execute_Seal           => Has (Property_Noexec),
         No_Execute_Seal_Supported => Has (Property_Noexec_Support),
         No_Symlink_Follow         => Has (Property_Nofollow),
         Owner_Only_Permissions    => Has (Property_Owner_Only));
   end Decode_Properties;

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
         raise Constraint_Error with
           "POSIX shared-memory name must begin with slash";
      end if;
      for Index in Name'First + 1 .. Name'Last loop
         if Name (Index) = '/' then
            raise Constraint_Error with
              "POSIX shared-memory name contains an interior slash";
         end if;
      end loop;
   end Validate_POSIX_Name;

   procedure Install
     (Item          : in out Backing_Object;
      Descriptor    : C.int;
      Length        : Byte_Length;
      Kind          : Backing_Kind;
      Properties    : C.int;
      Namespace     : String := "";
      POSIX_Name    : Boolean := False;
      May_Initialize : Boolean := True) is
   begin
      Item.Descriptor := Descriptor;
      Item.Length_Value := Length;
      Item.Kind_Value := Kind;
      Item.Property_Value := Decode_Properties (Properties);
      Item.Namespace_Value := Unbounded.To_Unbounded_String (Namespace);
      Item.Namespace_Is_POSIX := POSIX_Name;
      Item.May_Initialize := May_Initialize;
   end Install;

   procedure Create_Anonymous
     (Item                    : in out Backing_Object;
      Length                  : Byte_Length;
      Require_No_Execute_Seal : Boolean := False)
   is
      Native     : constant C.unsigned_long_long := Native_Length (Length);
      Descriptor : aliased C.int := -1;
      Props      : aliased C.int := 0;
      Result     : C.int;
   begin
      Require_Closed (Item);
      Result := C_Create_Anonymous
        (Native, Boolean'Pos (Require_No_Execute_Seal),
         Descriptor'Access, Props'Access);
      if Result /= 0 then
         Raise_Failure ("anonymous shared-memory creation", Result);
      end if;
      Install
        (Item, Descriptor, Length, Anonymous_Capability, Props);
   end Create_Anonymous;

   procedure Named_Operation
     (Item        : in out Backing_Object;
      Name        : String;
      Length      : Byte_Length;
      Mode        : C.int;
      Result      : out Namespace_Open_Result;
      Permissions : Permission_Bits)
   is
      Native     : constant C.unsigned_long_long := Native_Length (Length);
      C_Name     : C_Strings.chars_ptr := C_Strings.New_String (Name);
      Descriptor : aliased C.int := -1;
      Props      : aliased C.int := 0;
      Outcome    : aliased C.int := 0;
      Status     : C.int;
   begin
      Require_Closed (Item);
      Validate_POSIX_Name (Name);
      Status := C_Open_Named
        (C_Name, Native, C.unsigned (Permissions), Mode,
         Descriptor'Access, Props'Access, Outcome'Access);
      C_Strings.Free (C_Name);
      if Status /= 0 then
         Raise_Failure ("named shared-memory open", Status);
      elsif Outcome = 2 then
         Result := Initialization_In_Progress;
      else
         Result := (if Outcome = 0 then Created_New else Opened_Existing);
         Install
           (Item, Descriptor, Length, Named_POSIX, Props, Name,
            POSIX_Name => True,
            May_Initialize => Outcome = 0);
      end if;
   exception
      when others =>
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
      Named_Operation (Item, Name, Length, 0, Result, Permissions);
      pragma Assert (Result = Created_New);
   end Create_Named;

   procedure Open_Named
     (Item            : in out Backing_Object;
      Name            : String;
      Expected_Length : Byte_Length;
      Result          : out Namespace_Open_Result) is
   begin
      Named_Operation
        (Item, Name, Expected_Length, 1, Result, Permission_Bits'First);
   end Open_Named;

   procedure Create_Or_Open_Named
     (Item        : in out Backing_Object;
      Name        : String;
      Length      : Byte_Length;
      Result      : out Namespace_Open_Result;
      Permissions : Permission_Bits := 8#600#) is
   begin
      Named_Operation (Item, Name, Length, 2, Result, Permissions);
   end Create_Or_Open_Named;

   procedure File_Operation
     (Item        : in out Backing_Object;
      Path        : String;
      Length      : Byte_Length;
      Create      : Boolean;
      Permissions : Permission_Bits)
   is
      Native     : constant C.unsigned_long_long := Native_Length (Length);
      C_Path     : C_Strings.chars_ptr := C_Strings.New_String (Path);
      Descriptor : aliased C.int := -1;
      Props      : aliased C.int := 0;
      Status     : C.int;
   begin
      Require_Closed (Item);
      Validate_Text (Path, "shared-memory file path");
      Status := C_Open_File
        (C_Path, Native, C.unsigned (Permissions), Boolean'Pos (Create),
         Descriptor'Access, Props'Access);
      C_Strings.Free (C_Path);
      if Status /= 0 then
         Raise_Failure ("file-backed shared-memory open", Status);
      end if;
      Install
        (Item, Descriptor, Length, File_Backed, Props, Path,
         May_Initialize => Create);
   exception
      when others =>
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

   procedure Open_File
     (Item            : in out Backing_Object;
      Path            : String;
      Expected_Length : Byte_Length) is
   begin
      File_Operation
        (Item, Path, Expected_Length, False, Permission_Bits'First);
   end Open_File;

   procedure Unlink (Item : in out Backing_Object) is
      Name   : constant String := Unbounded.To_String (Item.Namespace_Value);
      C_Name : C_Strings.chars_ptr := C_Strings.Null_Ptr;
      Status : C.int;
   begin
      if Name'Length = 0 then
         return;
      elsif not Is_Open (Item) then
         raise Validation_Error with
           "cannot unlink without an open identity descriptor";
      end if;
      C_Name := C_Strings.New_String (Name);
      Status := C_Unlink
        (Item.Descriptor, C_Name, Boolean'Pos (Item.Namespace_Is_POSIX));
      C_Strings.Free (C_Name);
      if Status /= 0 then
         Raise_Failure ("shared-memory unlink", Status);
      end if;
      Item.Namespace_Value := Unbounded.Null_Unbounded_String;
      Item.Namespace_Is_POSIX := False;
   exception
      when others =>
         C_Strings.Free (C_Name);
         raise;
   end Unlink;

   procedure Close (Item : in out Backing_Object) is
      Descriptor : constant C.int := Item.Descriptor;
      Status     : C.int;
   begin
      if Descriptor < 0 then
         return;
      end if;
      Item.Descriptor := -1;
      Item.Length_Value := 0;
      Item.Property_Value := (others => False);
      Item.May_Initialize := False;
      Status := C_Close (Descriptor);
      if Status /= 0 then
         Raise_Failure ("shared-memory descriptor close", Status);
      end if;
   end Close;

   function Is_Open (Item : Backing_Object) return Boolean is
     (Item.Descriptor >= 0);

   function Length (Item : Backing_Object) return Byte_Length is
     (if Is_Open (Item) then Item.Length_Value else 0);

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
      Base   : aliased System.Address := System.Null_Address;
      Status : C.int;
   begin
      Require_Unmapped (Item);
      if not Is_Open (Source) then
         raise Validation_Error with "cannot map a closed backing object";
      end if;
      Status := C_Map
        (Source.Descriptor, C.unsigned_long_long (Source.Length_Value),
         Base'Access);
      if Status /= 0 then
         Raise_Failure ("shared-memory map", Status);
      end if;
      Item.State.Base := Base;
      Item.State.Length_Value := Source.Length_Value;
      Item.State.May_Initialize := Source.May_Initialize;
   end Map;

   procedure Flush (Item : Mapping; Synchronous : Boolean := True) is
      Status : C.int;
   begin
      if not Is_Mapped (Item) then
         raise Validation_Error with "cannot flush an unmapped mapping";
      end if;
      Status := C_Msync
        (Item.State.Base,
         C.unsigned_long_long (Item.State.Length_Value),
         Boolean'Pos (Synchronous));
      if Status /= 0 then
         Raise_Failure ("shared mapping flush", Status);
      end if;
   end Flush;

   procedure Flush (Item : Backing_Object) is
      Status : C.int;
   begin
      if not Is_Open (Item) then
         raise Validation_Error with "cannot flush a closed backing object";
      end if;
      Status := C_Fsync (Item.Descriptor);
      if Status /= 0 then
         Raise_Failure ("backing object flush", Status);
      end if;
   end Flush;

   procedure Attach_Region
     (Item   : Mapping;
      Region : in out Flyology.Data_Structures.Regions.View) is
   begin
      if not Is_Mapped (Item) then
         raise Validation_Error with
           "cannot attach a region to an unmapped mapping";
      end if;
      Flyology.Data_Structures.Regions.Attach
        (Region, Item.State.Base, Item.State.Length_Value);
   end Attach_Region;

   procedure Unmap (Item : in out Mapping) is
      Base   : constant System.Address := Item.State.Base;
      Length : constant Byte_Length := Item.State.Length_Value;
      Status : C.int;
   begin
      if Base = System.Null_Address then
         return;
      end if;
      Status := C_Unmap (Base, C.unsigned_long_long (Length));
      if Status /= 0 then
         Raise_Failure ("shared-memory unmap", Status);
      end if;
      Item.State.Base := System.Null_Address;
      Item.State.Length_Value := 0;
      Item.State.May_Initialize := False;
   end Unmap;

   function Is_Mapped (Item : Mapping) return Boolean is
     (Item.State.Base /= System.Null_Address);

   function Length (Item : Mapping) return Byte_Length is
     (if Is_Mapped (Item) then Item.State.Length_Value else 0);

   overriding procedure Finalize (Item : in out Backing_Object) is
      Ignored : C.int;
   begin
      if Item.Descriptor >= 0 then
         declare
            Descriptor : constant C.int := Item.Descriptor;
         begin
            Item.Descriptor := -1;
            Item.Length_Value := 0;
            Item.May_Initialize := False;
            Ignored := C_Close (Descriptor);
         end;
      end if;
   exception
      when others =>
         null;
   end Finalize;

   overriding procedure Finalize (Item : in out Mapping_State) is
      Ignored : C.int;
   begin
      if Item.Base /= System.Null_Address then
         declare
            Base   : constant System.Address := Item.Base;
            Length : constant Byte_Length := Item.Length_Value;
         begin
            Item.Base := System.Null_Address;
            Item.Length_Value := 0;
            Item.May_Initialize := False;
            Ignored := C_Unmap (Base, C.unsigned_long_long (Length));
         end;
      end if;
   exception
      when others =>
         null;
   end Finalize;

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

   function Mapping_Base (Item : Mapping) return System.Address is
     (Item.State.Base);

   function Mapping_Length (Item : Mapping) return Byte_Length is
     (Item.State.Length_Value);

   function Mapping_May_Initialize (Item : Mapping) return Boolean is
     (Item.State.May_Initialize);

end Flyology.Shared_Memory;
