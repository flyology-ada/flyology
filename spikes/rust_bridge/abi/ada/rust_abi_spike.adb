with Ada.Command_Line;
with Ada.Text_IO;
with Interfaces.C;
with System;

procedure Rust_Abi_Spike is
   use type Interfaces.C.size_t;
   use type Interfaces.C.unsigned;
   use type Interfaces.C.unsigned_char;
   use type Interfaces.C.unsigned_long_long;
   use type System.Address;

   OK               : constant Interfaces.C.unsigned := 0;
   Invalid_Argument : constant Interfaces.C.unsigned := 1;
   Panicked         : constant Interfaces.C.unsigned := 2;

   type ABI_Record is record
      Tag   : Interfaces.C.unsigned;
      Flags : Interfaces.C.unsigned;
      Value : Interfaces.C.unsigned_long_long;
   end record
   with Convention => C;

   type ABI_Layout is record
      Record_Size      : Interfaces.C.size_t;
      Record_Alignment : Interfaces.C.size_t;
      Tag_Offset       : Interfaces.C.size_t;
      Flags_Offset     : Interfaces.C.size_t;
      Value_Offset     : Interfaces.C.size_t;
   end record
   with Convention => C;

   type Byte_Array is
     array (Interfaces.C.size_t range <>) of aliased Interfaces.C.unsigned_char
   with Convention => C;

   function ABI_Version return Interfaces.C.unsigned
   with Import, Convention => C, External_Name => "flyology_rust_abi_version";

   function Layout (Output : access ABI_Layout) return Interfaces.C.unsigned
   with Import, Convention => C, External_Name => "flyology_rust_abi_layout";

   function Round_Trip
     (Input : access constant ABI_Record; Output : access ABI_Record)
      return Interfaces.C.unsigned
   with
     Import,
     Convention    => C,
     External_Name => "flyology_rust_abi_round_trip";

   function Sum_Bytes
     (Bytes  : System.Address;
      Length : Interfaces.C.size_t;
      Output : access Interfaces.C.unsigned_long_long)
      return Interfaces.C.unsigned
   with
     Import,
     Convention    => C,
     External_Name => "flyology_rust_abi_sum_bytes";

   function Blob_New
     (Length : Interfaces.C.size_t; Handle : access System.Address)
      return Interfaces.C.unsigned
   with Import, Convention => C, External_Name => "flyology_rust_abi_blob_new";

   function Blob_Copy
     (Handle   : System.Address;
      Output   : System.Address;
      Capacity : Interfaces.C.size_t;
      Written  : access Interfaces.C.size_t) return Interfaces.C.unsigned
   with
     Import,
     Convention    => C,
     External_Name => "flyology_rust_abi_blob_copy";

   function Blob_Drop (Handle : System.Address) return Interfaces.C.unsigned
   with
     Import,
     Convention    => C,
     External_Name => "flyology_rust_abi_blob_drop";

   function Panic_Probe return Interfaces.C.unsigned
   with
     Import,
     Convention    => C,
     External_Name => "flyology_rust_abi_panic_probe";

   function TLS_Probe
     (Main_First   : access Interfaces.C.unsigned;
      Main_Second  : access Interfaces.C.unsigned;
      Child_First  : access Interfaces.C.unsigned;
      Child_Second : access Interfaces.C.unsigned) return Interfaces.C.unsigned
   with
     Import,
     Convention    => C,
     External_Name => "flyology_rust_abi_tls_probe";

   procedure Require (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Require;

   Layout_Value : aliased ABI_Layout;
   Input        : aliased ABI_Record :=
     (Tag => 41, Flags => 16#1122_3344#, Value => 16#1020_3040_5060_7080#);
   Output       : aliased ABI_Record := (Tag => 0, Flags => 0, Value => 0);
   Bytes        : aliased Byte_Array := [1, 2, 3, 4, 250];
   Sum          : aliased Interfaces.C.unsigned_long_long := 0;
   Handle       : aliased System.Address := System.Null_Address;
   Blob_Bytes   : aliased Byte_Array (0 .. 15) := [others => 0];
   Written      : aliased Interfaces.C.size_t := 0;
   Main_First   : aliased Interfaces.C.unsigned := 0;
   Main_Second  : aliased Interfaces.C.unsigned := 0;
   Child_First  : aliased Interfaces.C.unsigned := 0;
   Child_Second : aliased Interfaces.C.unsigned := 0;
   Skip_Panic   : constant Boolean :=
     Ada.Command_Line.Argument_Count = 1
     and then Ada.Command_Line.Argument (1) = "--skip-panic";

begin
   Require (ABI_Version = 1, "unexpected Rust ABI version");

   Require (Layout (Layout_Value'Access) = OK, "Rust layout query failed");
   Require
     (Layout_Value.Record_Size = ABI_Record'Size / System.Storage_Unit,
      "record size differs across ABI");
   Require
     (Layout_Value.Record_Alignment = ABI_Record'Alignment,
      "record alignment differs across ABI");
   Require
     (Layout_Value.Tag_Offset = Input.Tag'Position,
      "tag offset differs across ABI");
   Require
     (Layout_Value.Flags_Offset = Input.Flags'Position,
      "flags offset differs across ABI");
   Require
     (Layout_Value.Value_Offset = Input.Value'Position,
      "value offset differs across ABI");

   Require
     (Round_Trip (Input'Access, Output'Access) = OK,
      "record round trip failed");
   Require (Output.Tag = 42, "record tag was not transformed");
   Require (Output.Flags = 16#B487_96E1#, "record flags were not transformed");
   Require
     (Output.Value = 16#1122_3344_5566_7788#,
      "record value was not transformed");

   Require
     (Sum_Bytes (Bytes (Bytes'First)'Address, Bytes'Length, Sum'Access) = OK,
      "borrowed byte sum failed");
   Require (Sum = 260, "borrowed byte sum was incorrect");
   Require
     (Sum_Bytes (System.Null_Address, 0, Sum'Access) = OK and then Sum = 0,
      "null zero-length span was rejected");
   Require
     (Sum_Bytes (System.Null_Address, 1, Sum'Access) = Invalid_Argument,
      "null nonempty span was accepted");

   Require
     (Blob_New (Blob_Bytes'Length, Handle'Access) = OK,
      "Rust blob allocation failed");
   Require (Handle /= System.Null_Address, "Rust blob returned a null handle");
   Require
     (Blob_Copy
        (Handle,
         Blob_Bytes (Blob_Bytes'First)'Address,
         Blob_Bytes'Length,
         Written'Access)
      = OK,
      "Rust blob copy failed");
   Require (Written = Blob_Bytes'Length, "Rust blob length changed");
   for Index in Blob_Bytes'Range loop
      Require
        (Blob_Bytes (Index) = Interfaces.C.unsigned_char (Index),
         "Rust blob payload changed");
   end loop;
   Require (Blob_Drop (Handle) = OK, "Rust blob release failed");
   Handle := System.Null_Address;

   if not Skip_Panic then
      Require
        (Panic_Probe = Panicked,
         "Rust panic crossed or escaped the ABI boundary");
   end if;
   Require
     (TLS_Probe
        (Main_First'Access,
         Main_Second'Access,
         Child_First'Access,
         Child_Second'Access)
      = OK,
      "Rust TLS/thread probe failed");
   Require
     (Main_First = 1 and then Main_Second = 2,
      "calling-thread Rust TLS did not persist");
   Require
     (Child_First = 1 and then Child_Second = 2,
      "child Rust TLS did not start independently");
   Ada.Text_IO.Put_Line ("Rust ABI probe passed");
end Rust_Abi_Spike;
