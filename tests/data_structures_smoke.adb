with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Text_IO;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Byte_Strings;
with Flyology.Data_Structures.Envelopes;
with Flyology.Data_Structures.Handles;
with Flyology.Data_Structures.Hash_Maps;
with Flyology.Data_Structures.Regions;
with Flyology.Data_Structures.Rings.MPMC;
with Flyology.Data_Structures.Rings.SPSC;
with Flyology.Data_Structures.Slab_Pools;
with Flyology.Data_Structures.Vectors;
with Interfaces;
with Interfaces.C;
with System;
with System.Storage_Elements;

procedure Data_Structures_Smoke is
   package DS renames Flyology.Data_Structures;
   package Regions renames DS.Regions;
   package Handles renames DS.Handles;
   package Slabs renames DS.Slab_Pools;
   package Strings renames DS.Byte_Strings;
   package Vectors renames DS.Vectors;
   package SPSC renames DS.Rings.SPSC;
   package MPMC renames DS.Rings.MPMC;
   package Maps renames DS.Hash_Maps;
   package Contract_V1 is new DS.Envelopes
     (Nested_Identity    => Vectors.Identity,
      Contract_Signature => 16#A17E_5B31_92C4_770D#,
      Contract_Version   => 1);
   package Contract_V2 is new DS.Envelopes
     (Nested_Identity    => Vectors.Identity,
      Contract_Signature => 16#A17E_5B31_92C4_770D#,
      Contract_Version   => 2);
   package Contract_Other is new DS.Envelopes
     (Nested_Identity    => Vectors.Identity,
      Contract_Signature => 16#D8C2_0A6E_47F1_B935#,
      Contract_Version   => 1);
   package Contract_Wrong_Leaf is new DS.Envelopes
     (Nested_Identity    => SPSC.Identity,
      Contract_Signature => 16#A17E_5B31_92C4_770D#,
      Contract_Version   => 1);
   package C renames Interfaces.C;
   package SSE renames System.Storage_Elements;

   use type Ada.Streams.Stream_Element_Array;
   use type C.int;
   use type DS.Byte_Count;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Maps.Put_Result;
   use type MPMC.Pop_Result;
   use type MPMC.Push_Result;
   use type System.Address;

   Mapping_Length : constant C.size_t := 262_144;
   Slab_Location  : constant DS.Region_Offset := 64;
   String_Location : constant DS.Region_Offset := 4_096;
   Vector_Location : constant DS.Region_Offset := 8_192;
   SPSC_Location  : constant DS.Region_Offset := 16_384;
   MPMC_Location  : constant DS.Region_Offset := 32_768;
   Map_Location   : constant DS.Region_Offset := 65_536;
   Envelope_Location : constant DS.Region_Offset := 100_000;
   Envelope_Content_Extent : constant DS.Byte_Count :=
     Vectors.Required_Storage (4, 8);

   function Mapping_Create
     (Path   : C.char_array;
      Length : C.size_t;
      First  : access System.Address;
      Second : access System.Address;
      FD     : access C.int) return C.int;
   pragma Import
     (C, Mapping_Create, "flyology_test_mapping_create");

   function Unmap_And_Reserve
     (Address : System.Address; Length : C.size_t) return C.int;
   pragma Import
     (C, Unmap_And_Reserve,
      "flyology_test_mapping_unmap_and_reserve");

   function Remap
     (FD      : C.int;
      Length  : C.size_t;
      Address : access System.Address) return C.int;
   pragma Import (C, Remap, "flyology_test_mapping_remap");

   function Unmap
     (Address : System.Address; Length : C.size_t) return C.int;
   pragma Import (C, Unmap, "flyology_test_mapping_unmap");

   function Close_Mapping
     (Path : C.char_array; FD : C.int) return C.int;
   pragma Import (C, Close_Mapping, "flyology_test_mapping_close");

   function Read_U32
     (Base : System.Address; Offset : C.size_t)
      return Interfaces.Unsigned_32;
   pragma Import (C, Read_U32, "flyology_test_mapping_read_u32");

   function Read_U64
     (Base : System.Address; Offset : C.size_t)
      return Interfaces.Unsigned_64;
   pragma Import (C, Read_U64, "flyology_test_mapping_read_u64");

   procedure Write_U32
     (Base   : System.Address;
      Offset : C.size_t;
      Value  : Interfaces.Unsigned_32);
   pragma Import (C, Write_U32, "flyology_test_mapping_write_u32");

   procedure Write_U64
     (Base   : System.Address;
      Offset : C.size_t;
      Value  : Interfaces.Unsigned_64);
   pragma Import (C, Write_U64, "flyology_test_mapping_write_u64");

   function Contains_U64
     (Base   : System.Address;
      Length : C.size_t;
      Value  : Interfaces.Unsigned_64) return C.int;
   pragma Import
     (C, Contains_U64, "flyology_test_mapping_contains_u64");

   procedure Assert (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Assert;

   function Encode
     (Value : Interfaces.Unsigned_64)
      return Ada.Streams.Stream_Element_Array
   is
      Result : Ada.Streams.Stream_Element_Array (1 .. 8);
      Work   : Interfaces.Unsigned_64 := Value;
   begin
      for Byte of Result loop
         Byte := Ada.Streams.Stream_Element (Work and 16#FF#);
         Work := Work / 256;
      end loop;
      return Result;
   end Encode;

   function Decode
     (Data : Ada.Streams.Stream_Element_Array)
      return Interfaces.Unsigned_64
   is
      Result : Interfaces.Unsigned_64 := 0;
   begin
      for Index in reverse Data'Range loop
         Result := Result * 256 + Interfaces.Unsigned_64 (Data (Index));
      end loop;
      return Result;
   end Decode;

   function Raw_Offset
     (Location : DS.Region_Offset; Relative : Natural) return C.size_t is
     (C.size_t (DS.Byte_Count (Location) + DS.Byte_Count (Relative)));

   Temp_Root : constant String := Ada.Environment_Variables.Value
     ("FLYOLOGY_TEST_TEMP_ROOT", "/tmp");
   Path : constant C.char_array := C.To_C
     (Temp_Root & "/data-structures-smoke.map");
   Base_A : aliased System.Address := System.Null_Address;
   Base_B : aliased System.Address := System.Null_Address;
   Base_C : aliased System.Address := System.Null_Address;
   FD     : aliased C.int := -1;

   Region_A, Region_B, Region_C, Truncated : Regions.View;
   Slab_A, Slab_B, Slab_C, Slab_Bad : Slabs.View;
   String_A, String_B, String_C : Strings.View;
   Vector_A, Vector_B, Vector_C : Vectors.View;
   Ring_A, Ring_B, Ring_C, Ring_Bad : SPSC.View;
   Multi_A, Multi_B, Multi_C, Multi_Bad : MPMC.View;
   Map_A, Map_B, Map_C : Maps.View;
   Envelope_A, Envelope_B, Envelope_C : Contract_V1.View;
   Wrapped_A, Wrapped_B, Wrapped_C : Vectors.View;

   Payload_16 : Ada.Streams.Stream_Element_Array (1 .. 16) :=
     (others => 16#2A#);
   Read_16 : Ada.Streams.Stream_Element_Array (1 .. 16);
   Eight : Ada.Streams.Stream_Element_Array (1 .. 8);
   String_Data : constant Ada.Streams.Stream_Element_Array :=
     [1 => Character'Pos ('f'), 2 => Character'Pos ('l'),
      3 => Character'Pos ('y')];
   String_More : constant Ada.Streams.Stream_Element_Array :=
     [1 => Character'Pos ('o'), 2 => Character'Pos ('l'),
      3 => Character'Pos ('o'), 4 => Character'Pos ('g'),
      5 => Character'Pos ('y')];
   String_Read : Ada.Streams.Stream_Element_Array (1 .. 8);
   Key_1 : constant Ada.Streams.Stream_Element_Array := Encode (11);
   Key_2 : constant Ada.Streams.Stream_Element_Array := Encode (22);
   Value_1 : constant Ada.Streams.Stream_Element_Array := Encode (111);
   Value_2 : constant Ada.Streams.Stream_Element_Array := Encode (222);
   Handle_1 : Handles.Handle;
   type Handle_Array is array (Positive range <>) of Handles.Handle;
   Bad_Handles : constant Handle_Array :=
     [Handles.Null_Handle,
      (Slot => 99, Stamp => 1),
      (Slot => 1, Stamp => 0)];
   Allocated, Flag : Boolean;
   Put_Outcome : Maps.Put_Result;
   Push_Outcome : MPMC.Push_Result;
   Pop_Outcome : MPMC.Pop_Result;

   procedure Cleanup is
      Ignored : C.int;
   begin
      Ignored := Unmap (Base_A, Mapping_Length);
      Ignored := Unmap (Base_B, Mapping_Length);
      Ignored := Unmap (Base_C, Mapping_Length);
      if FD >= 0 then
         Ignored := Close_Mapping (Path, FD);
      end if;
   end Cleanup;

begin
   Assert
     (Mapping_Create
        (Path, Mapping_Length, Base_A'Access, Base_B'Access, FD'Access) = 0,
      "failed to map one temporary file twice");
   Assert (Base_A /= Base_B, "two shared mappings used the same address");
   Regions.Attach (Region_A, Base_A, DS.Byte_Count (Mapping_Length));
   Regions.Attach (Region_B, Base_B, DS.Byte_Count (Mapping_Length));

   Slabs.Initialize (Slab_A, Region_A, Slab_Location, 8, 16, 8);
   Slabs.Attach (Slab_B, Region_B, Slab_Location, 8, 16, 8);
   Strings.Initialize (String_A, Region_A, String_Location, 128);
   Strings.Attach (String_B, Region_B, String_Location, 128);
   Vectors.Initialize (Vector_A, Region_A, Vector_Location, 16, 8);
   Vectors.Attach (Vector_B, Region_B, Vector_Location, 16, 8);
   SPSC.Initialize (Ring_A, Region_A, SPSC_Location, 16, 8);
   SPSC.Attach (Ring_B, Region_B, SPSC_Location, 16, 8);
   MPMC.Initialize (Multi_A, Region_A, MPMC_Location, 16, 8);
   MPMC.Attach (Multi_B, Region_B, MPMC_Location, 16, 8);
   Maps.Initialize (Map_A, Region_A, Map_Location, 16, 8, 8);
   Maps.Attach (Map_B, Region_B, Map_Location, 16, 8, 8);
   Contract_V1.Initialize
     (Envelope_A, Region_A, Envelope_Location, Envelope_Content_Extent, 8);
   Vectors.Initialize
     (Wrapped_A, Region_A, Contract_V1.Content_Location (Envelope_A), 4, 8);
   Contract_V1.Attach
     (Envelope_B, Region_B, Envelope_Location, Envelope_Content_Extent, 8);
   Vectors.Attach
     (Wrapped_B, Region_B, Contract_V1.Content_Location (Envelope_B), 4, 8);

   Assert
     (Contains_U64
        (Base_A, Mapping_Length,
         Interfaces.Unsigned_64 (SSE.To_Integer (Base_A))) = 0,
      "mapping A address escaped into stored bytes");
   Assert
     (Contains_U64
        (Base_A, Mapping_Length,
         Interfaces.Unsigned_64 (SSE.To_Integer (Base_B))) = 0,
      "mapping B address escaped into stored bytes");

   Slabs.Try_Allocate (Slab_A, Handle_1, Allocated);
   Assert (Allocated and then not Handles.Is_Null (Handle_1),
           "slab allocation failed");
   Slabs.Write (Slab_A, Handle_1, Payload_16);
   Slabs.Read (Slab_B, Handle_1, Read_16);
   Assert (Read_16 = Payload_16, "slab A-to-B payload was not visible");
   Payload_16 := (others => 16#55#);
   Slabs.Write (Slab_B, Handle_1, Payload_16);
   Slabs.Read (Slab_A, Handle_1, Read_16);
   Assert (Read_16 = Payload_16, "slab B-to-A mutation was not visible");

   Strings.Assign (String_A, String_Data);
   Strings.Append (String_B, String_More);
   Assert (Strings.Length (String_A) = 8, "byte-string length did not relocate");
   Strings.Read (String_A, String_Read);
   Assert
     (String_Read (1 .. 3) = String_Data
      and then String_Read (4 .. 8) = String_More,
      "byte-string cross-view append failed");

   Vectors.Try_Append (Vector_A, Encode (1), Flag);
   Assert (Flag, "vector append failed");
   Vectors.Read (Vector_B, 1, Eight);
   Assert (Decode (Eight) = 1, "vector A-to-B read failed");
   Vectors.Replace (Vector_B, 1, Encode (2));
   Vectors.Read (Vector_A, 1, Eight);
   Assert (Decode (Eight) = 2, "vector B-to-A replace failed");

   SPSC.Try_Pop (Ring_B, Eight, Flag);
   Assert (not Flag, "empty SPSC ring produced an element");
   for Value in Interfaces.Unsigned_64 range 1 .. 16 loop
      SPSC.Try_Push (Ring_A, Encode (Value), Flag);
      Assert (Flag, "SPSC ring rejected available capacity");
   end loop;
   SPSC.Try_Push (Ring_A, Encode (17), Flag);
   Assert (not Flag, "full SPSC ring accepted an element");
   for Value in Interfaces.Unsigned_64 range 1 .. 16 loop
      SPSC.Try_Pop (Ring_B, Eight, Flag);
      Assert (Flag and then Decode (Eight) = Value,
              "SPSC ordering or exactly-once delivery failed");
   end loop;

   MPMC.Try_Push (Multi_A, Encode (41), Push_Outcome);
   Assert (Push_Outcome = MPMC.Pushed, "MPMC push failed");
   MPMC.Try_Pop (Multi_B, Eight, Pop_Outcome);
   Assert
     (Pop_Outcome = MPMC.Popped and then Decode (Eight) = 41,
      "MPMC cross-view pop failed");

   Maps.Put (Map_A, Key_1, Value_1, Put_Outcome);
   Assert (Put_Outcome = Maps.Inserted, "hash-map insert failed");
   Maps.Get (Map_B, Key_1, Eight, Flag);
   Assert (Flag and then Decode (Eight) = 111,
           "hash-map A-to-B lookup failed");
   Maps.Put (Map_B, Key_1, Value_2, Put_Outcome);
   Assert (Put_Outcome = Maps.Replaced, "hash-map replacement failed");
   Maps.Get (Map_A, Key_1, Eight, Flag);
   Assert (Flag and then Decode (Eight) = 222,
      "hash-map B-to-A replacement was not visible");

   Vectors.Try_Append (Wrapped_A, Encode (909), Flag);
   Vectors.Read (Wrapped_B, 1, Eight);
   Assert (Flag and then Decode (Eight) = 909,
           "versioned envelope content did not relocate");
   declare
      Wrong : Contract_V2.View;
      Failed : Boolean := False;
   begin
      begin
         Contract_V2.Attach
           (Wrong, Region_B, Envelope_Location, Envelope_Content_Extent, 8);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "wrong envelope contract version was accepted");
   end;
   declare
      Wrong : Contract_Other.View;
      Failed : Boolean := False;
   begin
      begin
         Contract_Other.Attach
           (Wrong, Region_B, Envelope_Location, Envelope_Content_Extent, 8);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "wrong envelope contract signature was accepted");
   end;
   declare
      Wrong : Contract_Wrong_Leaf.View;
      Failed : Boolean := False;
   begin
      begin
         Contract_Wrong_Leaf.Attach
           (Wrong, Region_B, Envelope_Location, Envelope_Content_Extent, 8);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "wrong envelope nested layout identity was accepted");
   end;

   declare
      Failed : Boolean := False;
   begin
      begin
         Slabs.Attach (Slab_Bad, Region_B, Slab_Location, 7, 16, 8);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "slab capacity mismatch was accepted");
   end;

   declare
      Saved : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Raw_Offset (Slab_Location, 8));
      Failed : Boolean := False;
   begin
      Write_U64 (Base_B, Raw_Offset (Slab_Location, 8), Saved xor 1);
      begin
         Slabs.Attach (Slab_Bad, Region_B, Slab_Location, 8, 16, 8);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U64 (Base_B, Raw_Offset (Slab_Location, 8), Saved);
      Assert (Failed, "bad slab magic was accepted");
   end;

   declare
      Saved : constant Interfaces.Unsigned_32 :=
        Read_U32 (Base_B, Raw_Offset (Slab_Location, 4));
      Failed : Boolean := False;
   begin
      Write_U32 (Base_B, Raw_Offset (Slab_Location, 4), Saved + 1);
      begin
         Slabs.Attach (Slab_Bad, Region_B, Slab_Location, 8, 16, 8);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U32 (Base_B, Raw_Offset (Slab_Location, 4), Saved);
      Assert (Failed, "bad slab version was accepted");
   end;

   declare
      Saved : constant Interfaces.Unsigned_32 :=
        Read_U32 (Base_B, Raw_Offset (Slab_Location, 0));
      Failed : Boolean := False;
   begin
      Write_U32 (Base_B, Raw_Offset (Slab_Location, 0), 1);
      begin
         Slabs.Attach (Slab_Bad, Region_B, Slab_Location, 8, 16, 8);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U32 (Base_B, Raw_Offset (Slab_Location, 0), Saved);
      Assert (Failed, "incomplete slab initialization was accepted");
   end;

   Regions.Attach
     (Truncated, Base_B,
      DS.Byte_Count (Slab_Location) + DS.Byte_Count (64));
   declare
      Failed : Boolean := False;
   begin
      begin
         Slabs.Attach (Slab_Bad, Truncated, Slab_Location, 8, 16, 8);
      exception
         when DS.Region_Error => Failed := True;
      end;
      Assert (Failed, "truncated slab region was accepted");
   end;
   Regions.Detach (Truncated);

   declare
      Failed : Boolean := False;
   begin
      begin
         Regions.Validate (Region_B, DS.Null_Offset, 8, 8);
      exception
         when DS.Region_Error => Failed := True;
      end;
      Assert (Failed, "null persisted offset was accepted");
      Failed := False;
      begin
         Regions.Validate (Region_B, 65, 8, 8);
      exception
         when DS.Region_Error => Failed := True;
      end;
      Assert (Failed, "misaligned persisted offset was accepted");
      Failed := False;
      begin
         Regions.Validate (Region_B, DS.Region_Offset'Last, 8, 8);
      exception
         when DS.Region_Error => Failed := True;
      end;
      Assert (Failed, "overflowing persisted offset was accepted");
   end;

   declare
      Saved : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Raw_Offset (SPSC_Location, 128));
      Failed : Boolean := False;
   begin
      Write_U64 (Base_B, Raw_Offset (SPSC_Location, 128), Saved + 17);
      begin
         SPSC.Attach (Ring_Bad, Region_B, SPSC_Location, 16, 8);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U64 (Base_B, Raw_Offset (SPSC_Location, 128), Saved);
      Assert (Failed, "corrupt SPSC indices were accepted");
   end;

   declare
      Saved : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Raw_Offset (MPMC_Location, 192));
      Failed : Boolean := False;
   begin
      Write_U64 (Base_B, Raw_Offset (MPMC_Location, 192), Saved + 1);
      begin
         MPMC.Attach (Multi_Bad, Region_B, MPMC_Location, 16, 8);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U64 (Base_B, Raw_Offset (MPMC_Location, 192), Saved);
      Assert (Failed, "corrupt MPMC slot sequence was accepted");
   end;

   Slabs.Detach (Slab_A);
   Strings.Detach (String_A);
   Vectors.Detach (Vector_A);
   SPSC.Detach (Ring_A);
   MPMC.Detach (Multi_A);
   Maps.Detach (Map_A);
   Vectors.Detach (Wrapped_A);
   Contract_V1.Detach (Envelope_A);
   Regions.Detach (Region_A);
   declare
      Failed : Boolean := False;
      Dummy : Handles.Handle;
   begin
      begin
         Slabs.Try_Allocate (Slab_A, Dummy, Flag);
      exception
         when DS.Region_Error => Failed := True;
      end;
      Assert (Failed, "operation against detached slab view was accepted");
   end;

   Assert (Unmap_And_Reserve (Base_A, Mapping_Length) = 0,
           "failed to reserve the old mapping range");
   Assert (Remap (FD, Mapping_Length, Base_C'Access) = 0,
           "failed to map the backing file a third time");
   Assert (Base_C /= Base_A and then Base_C /= Base_B,
           "third mapping reused an existing virtual base");
   Regions.Attach (Region_C, Base_C, DS.Byte_Count (Mapping_Length));
   Slabs.Attach (Slab_C, Region_C, Slab_Location, 8, 16, 8);
   Strings.Attach (String_C, Region_C, String_Location, 128);
   Vectors.Attach (Vector_C, Region_C, Vector_Location, 16, 8);
   SPSC.Attach (Ring_C, Region_C, SPSC_Location, 16, 8);
   MPMC.Attach (Multi_C, Region_C, MPMC_Location, 16, 8);
   Maps.Attach (Map_C, Region_C, Map_Location, 16, 8, 8);
   Contract_V1.Attach
     (Envelope_C, Region_C, Envelope_Location, Envelope_Content_Extent, 8);
   Vectors.Attach
     (Wrapped_C, Region_C, Contract_V1.Content_Location (Envelope_C), 4, 8);

   Assert
     (Contains_U64
        (Base_C, Mapping_Length,
         Interfaces.Unsigned_64 (SSE.To_Integer (Base_C))) = 0,
      "third mapping address escaped into stored bytes");
   Slabs.Read (Slab_C, Handle_1, Read_16);
   Assert (Read_16 = Payload_16, "slab did not survive third mapping");
   Slabs.Release (Slab_C, Handle_1);
   declare
      Failed : Boolean := False;
   begin
      begin
         Slabs.Release (Slab_B, Handle_1);
      exception
         when DS.Handle_Error => Failed := True;
      end;
      Assert (Failed, "double-free/stale slab handle was accepted");
   end;
   for Bad of Bad_Handles loop
      declare
         Failed : Boolean := False;
      begin
         begin
            Slabs.Release (Slab_C, Bad);
         exception
            when DS.Handle_Error => Failed := True;
         end;
         Assert (Failed, "malformed slab handle was accepted");
      end;
   end loop;

   Strings.Assign (String_C, String_More);
   declare
      Remapped_Read : Ada.Streams.Stream_Element_Array (1 .. 5);
   begin
      Strings.Read (String_B, Remapped_Read);
      Assert
        (Remapped_Read = String_More,
         "byte string mutation was not visible after third mapping");
   end;
   Strings.Append (String_B, String_Data);
   Strings.Read (String_C, String_Read);
   Assert
     (String_Read (1 .. 5) = String_More
      and then String_Read (6 .. 8) = String_Data,
      "byte string did not continue across the third mapping");

   Vectors.Try_Append (Vector_C, Encode (3), Flag);
   Assert (Flag and then Vectors.Length (Vector_B) = 2,
           "vector did not continue after remap");
   SPSC.Try_Push (Ring_C, Encode (77), Flag);
   SPSC.Try_Pop (Ring_B, Eight, Allocated);
   Assert (Flag and then Allocated and then Decode (Eight) = 77,
           "SPSC did not continue after remap");
   MPMC.Try_Push (Multi_C, Encode (88), Push_Outcome);
   MPMC.Try_Pop (Multi_B, Eight, Pop_Outcome);
   Assert
     (Push_Outcome = MPMC.Pushed
      and then Pop_Outcome = MPMC.Popped
      and then Decode (Eight) = 88,
      "MPMC did not continue after remap");
   Maps.Put (Map_C, Key_2, Value_1, Put_Outcome);
   Maps.Get (Map_B, Key_2, Eight, Flag);
   Assert (Put_Outcome = Maps.Inserted and then Flag,
           "hash map did not continue after remap");
   Maps.Remove (Map_C, Key_1, Flag);
   Assert (Flag and then Maps.Length (Map_B) = 1,
      "hash-map removal failed across mappings");
   Vectors.Read (Wrapped_C, 1, Eight);
   Assert (Decode (Eight) = 909,
           "versioned envelope did not survive third mapping");

   Slabs.Destroy (Slab_C);
   Strings.Destroy (String_C);
   Vectors.Destroy (Vector_C);
   SPSC.Destroy (Ring_C);
   MPMC.Destroy (Multi_C);
   Maps.Destroy (Map_C);
   Vectors.Destroy (Wrapped_C);
   Contract_V1.Destroy (Envelope_C);

   Slabs.Detach (Slab_B);
   Strings.Detach (String_B);
   Vectors.Detach (Vector_B);
   SPSC.Detach (Ring_B);
   MPMC.Detach (Multi_B);
   Maps.Detach (Map_B);
   Vectors.Detach (Wrapped_B);
   Contract_V1.Detach (Envelope_B);

   Regions.Detach (Region_B);
   Regions.Detach (Region_C);
   Assert (Unmap (Base_B, Mapping_Length) = 0, "failed to unmap view B");
   Base_B := System.Null_Address;
   Assert (Unmap (Base_C, Mapping_Length) = 0, "failed to unmap view C");
   Base_C := System.Null_Address;
   Assert (Unmap (Base_A, Mapping_Length) = 0,
           "failed to release reserved old range");
   Base_A := System.Null_Address;
   Assert (Close_Mapping (Path, FD) = 0,
           "failed to close temporary mapping");
   FD := -1;
   Ada.Text_IO.Put_Line ("data structures smoke passed");
exception
   when others =>
      Cleanup;
      raise;
end Data_Structures_Smoke;
