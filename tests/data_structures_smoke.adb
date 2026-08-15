with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Text_IO;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Allocation_Algorithms.Buddy;
with Flyology.Data_Structures.Allocation_Algorithms.Best_Fit;
with Flyology.Data_Structures.Allocation_Algorithms.TLSF;
with Flyology.Data_Structures.Arenas;
with Flyology.Data_Structures.Allocation_Pools.Adaptive;
with Flyology.Data_Structures.Byte_Strings;
with Flyology.Data_Structures.Dynamic.Byte_Strings;
with Flyology.Data_Structures.Dynamic.Hash_Maps;
with Flyology.Data_Structures.Dynamic.Vectors;
with Flyology.Data_Structures.Envelopes;
with Flyology.Data_Structures.Handles;
with Flyology.Data_Structures.Hash_Maps;
with Flyology.Data_Structures.Regions;
with Flyology.Data_Structures.Rings.MPMC;
with Flyology.Data_Structures.Rings.SPSC;
with Flyology.Data_Structures.Slab_Pools;
with Flyology.Data_Structures.Storage_Types.Immutable;
with Flyology.Data_Structures.Storage_Types.Elements;
with Flyology.Data_Structures.Storage_Types.Unsigned_64s;
with Flyology.Data_Structures.Vectors;
with Interfaces;
with Interfaces.C;
with System;
with System.Storage_Elements;

procedure Data_Structures_Smoke is
   package DS renames Flyology.Data_Structures;
   package Regions renames DS.Regions;
   package Arenas is new DS.Arenas
     (Algorithm => DS.Allocation_Algorithms.Buddy);
   package Best_Fit_Arenas is new DS.Arenas
     (Algorithm => DS.Allocation_Algorithms.Best_Fit);
   package TLSF_Arenas is new DS.Arenas
     (Algorithm => DS.Allocation_Algorithms.TLSF);
   package Handles renames DS.Handles;
   package Strings renames DS.Byte_Strings;
   package Dynamic_Strings is new DS.Dynamic.Byte_Strings
     (Arena_Provider => Arenas);
   package U64_Elements renames DS.Storage_Types.Unsigned_64s;
   package Dynamic_Vectors is new DS.Dynamic.Vectors
     (Arena_Provider => Arenas,
      Element        => U64_Elements.Element);
   package Dynamic_Maps is new DS.Dynamic.Hash_Maps
     (Arena_Provider => Arenas,
      Key            => U64_Elements.Element,
      Element        => U64_Elements.Element);
   package Best_Fit_Dynamic_Vectors is new DS.Dynamic.Vectors
     (Arena_Provider => Best_Fit_Arenas,
      Element        => U64_Elements.Element);
   package TLSF_Dynamic_Vectors is new DS.Dynamic.Vectors
     (Arena_Provider => TLSF_Arenas,
      Element        => U64_Elements.Element);
   package Adaptive_U64 is new DS.Allocation_Pools.Adaptive
     (Arena_Provider  => TLSF_Arenas,
      Element         => U64_Elements.Element,
      Slots_Per_Chunk => 16,
      Maximum_Chunks  => 8);
   subtype Bytes_16 is Ada.Streams.Stream_Element_Array (1 .. 16);
   package Bytes_16_Representation is new DS.Storage_Types.Immutable
     (Byte_Size          => 16,
      Required_Alignment => 8,
      Type_Signature     => 16#5445_5354_4231_3601#,
      Layout_Version     => 1);

   function Create_Bytes_16
     (Data : Bytes_16) return Bytes_16_Representation.Value
   is
      Item : Bytes_16_Representation.Value_Builder :=
        Bytes_16_Representation.Start;
   begin
      for Index in Data'Range loop
         Bytes_16_Representation.Store_U8
           (Item, Natural (Index) - Natural (Data'First),
            Interfaces.Unsigned_8 (Data (Index)));
      end loop;
      return Bytes_16_Representation.Freeze (Item);
   end Create_Bytes_16;

   procedure Construct_Bytes_16
     (Item : in out Bytes_16_Representation.Builder;
      Data : Bytes_16) is
   begin
      for Index in Data'Range loop
         Bytes_16_Representation.Store_U8
           (Item, Natural (Index) - Natural (Data'First),
            Interfaces.Unsigned_8 (Data (Index)));
      end loop;
   end Construct_Bytes_16;

   function Observe_Bytes_16
     (Item : Bytes_16_Representation.Const_Ref) return Bytes_16
   is
      Result : Bytes_16;
   begin
      for Index in Result'Range loop
         Result (Index) := Ada.Streams.Stream_Element
           (Bytes_16_Representation.Load_U8
              (Item, Natural (Index) - Natural (Result'First)));
      end loop;
      return Result;
   end Observe_Bytes_16;

   package Bytes_16_Element is new DS.Storage_Types.Elements
     (Representation     => Bytes_16_Representation,
      Source_Type        => Bytes_16,
      Observed_Type      => Bytes_16,
      Create_Value       => Create_Bytes_16,
      Observe_Value      => Observe_Bytes_16,
      Direct_Constructor => Construct_Bytes_16'Access);
   package Slabs is new DS.Slab_Pools (Element => Bytes_16_Element);

   procedure Test_U64_Construct
     (Item : in out U64_Elements.Representation.Builder;
      Data : Interfaces.Unsigned_64) is
   begin
      U64_Elements.Set (Item, Data);
      if Interfaces."=" (Data, 16#DEAD_BEEF#) then
         raise Constraint_Error with "deliberate constructor failure";
      end if;
   end Test_U64_Construct;

   package Test_U64_Element is new DS.Storage_Types.Elements
     (Representation     => U64_Elements.Representation,
      Source_Type        => Interfaces.Unsigned_64,
      Observed_Type      => Interfaces.Unsigned_64,
      Create_Value       => U64_Elements.Create,
      Observe_Value      => U64_Elements.Value_Of,
      Direct_Constructor => Test_U64_Construct'Access);
   package Vectors is new DS.Vectors
     (Element => Test_U64_Element);
   package Alternate_U64 is new DS.Storage_Types.Immutable
     (Byte_Size          => 8,
      Required_Alignment => 8,
      Type_Signature     => 16#5445_5354_5536_3402#,
      Layout_Version     => 1);

   function Alternate_Create
     (Item : Interfaces.Unsigned_64) return Alternate_U64.Value
   is
      Builder : Alternate_U64.Value_Builder := Alternate_U64.Start;
   begin
      Alternate_U64.Store_U64 (Builder, 0, Item);
      return Alternate_U64.Freeze (Builder);
   end Alternate_Create;

   function Alternate_Observe
     (Item : Alternate_U64.Const_Ref) return Interfaces.Unsigned_64 is
     (Alternate_U64.Load_U64 (Item, 0));

   package Alternate_Element is new DS.Storage_Types.Elements
     (Representation  => Alternate_U64,
      Source_Type     => Interfaces.Unsigned_64,
      Observed_Type   => Interfaces.Unsigned_64,
      Create_Value    => Alternate_Create,
      Observe_Value   => Alternate_Observe);
   package Wrong_Vectors is new DS.Vectors (Element => Alternate_Element);
   package Alternate_Bytes_16 is new DS.Storage_Types.Immutable
     (Byte_Size          => 16,
      Required_Alignment => 8,
      Type_Signature     => 16#5445_5354_4231_3602#,
      Layout_Version     => 1);

   function Alternate_Bytes_16_Create
     (Data : Bytes_16) return Alternate_Bytes_16.Value
   is
      Item : Alternate_Bytes_16.Value_Builder := Alternate_Bytes_16.Start;
   begin
      for Index in Data'Range loop
         Alternate_Bytes_16.Store_U8
           (Item, Natural (Index) - Natural (Data'First),
            Interfaces.Unsigned_8 (Data (Index)));
      end loop;
      return Alternate_Bytes_16.Freeze (Item);
   end Alternate_Bytes_16_Create;

   function Alternate_Bytes_16_Observe
     (Item : Alternate_Bytes_16.Const_Ref) return Bytes_16
   is
      Result : Bytes_16;
   begin
      for Index in Result'Range loop
         Result (Index) := Ada.Streams.Stream_Element
           (Alternate_Bytes_16.Load_U8
              (Item, Natural (Index) - Natural (Result'First)));
      end loop;
      return Result;
   end Alternate_Bytes_16_Observe;

   package Alternate_Bytes_16_Element is new DS.Storage_Types.Elements
     (Representation  => Alternate_Bytes_16,
      Source_Type     => Bytes_16,
      Observed_Type   => Bytes_16,
      Create_Value    => Alternate_Bytes_16_Create,
      Observe_Value   => Alternate_Bytes_16_Observe);
   package Alternate_U64_Version is new DS.Storage_Types.Immutable
     (Byte_Size          => 8,
      Required_Alignment => 8,
      Type_Signature     => U64_Elements.Representation.Signature,
      Layout_Version     => 2);

   function Alternate_Version_Create
     (Item : Interfaces.Unsigned_64) return Alternate_U64_Version.Value
   is
      Builder : Alternate_U64_Version.Value_Builder :=
        Alternate_U64_Version.Start;
   begin
      Alternate_U64_Version.Store_U64 (Builder, 0, Item);
      return Alternate_U64_Version.Freeze (Builder);
   end Alternate_Version_Create;

   function Alternate_Version_Observe
     (Item : Alternate_U64_Version.Const_Ref)
      return Interfaces.Unsigned_64 is
     (Alternate_U64_Version.Load_U64 (Item, 0));

   package Alternate_Version_Element is new DS.Storage_Types.Elements
     (Representation  => Alternate_U64_Version,
      Source_Type     => Interfaces.Unsigned_64,
      Observed_Type   => Interfaces.Unsigned_64,
      Create_Value    => Alternate_Version_Create,
      Observe_Value   => Alternate_Version_Observe);
   package Wrong_Version_Vectors is new DS.Vectors
     (Element => Alternate_Version_Element);
   package Wrong_Slabs is new DS.Slab_Pools
     (Element => Alternate_Bytes_16_Element);
   package Wrong_SPSC is new DS.Rings.SPSC
     (Element => Alternate_Element);
   package Wrong_MPMC is new DS.Rings.MPMC
     (Element => Alternate_Element);
   package Wrong_Maps is new DS.Hash_Maps
     (Key     => Alternate_Element,
      Element => U64_Elements.Element);
   package Wrong_Dynamic_Vectors is new DS.Dynamic.Vectors
     (Arena_Provider => Arenas,
      Element        => Alternate_Element);
   package Wrong_Dynamic_Maps is new DS.Dynamic.Hash_Maps
     (Arena_Provider => Arenas,
      Key            => U64_Elements.Element,
      Element        => Alternate_Element);
   package SPSC is new DS.Rings.SPSC
     (Element => U64_Elements.Element);
   package MPMC is new DS.Rings.MPMC
     (Element => U64_Elements.Element);
   package Maps is new DS.Hash_Maps
     (Key     => U64_Elements.Element,
      Element => U64_Elements.Element);
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
   use type C.size_t;
   use type DS.Byte_Count;
   use type DS.Open_Result;
   use type DS.Allocation_Algorithms.Search_Bound;
   use type Slabs.Allocation_Result;
   use type Arenas.Allocation_Handle;
   use type Arenas.Allocation_Result;
   use type DS.Dynamic.Growth_Result;
   use type Adaptive_U64.Allocation_Result;
   use type Dynamic_Maps.Put_Result;
   use type Handles.Generation;
   use type Handles.Slot_Index;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Maps.Put_Result;
   use type MPMC.Pop_Result;
   use type MPMC.Push_Result;
   use type System.Address;

   Mapping_Length : constant C.size_t := 524_288;
   Slab_Location  : constant DS.Region_Offset := 64;
   String_Location : constant DS.Region_Offset := 4_096;
   Vector_Location : constant DS.Region_Offset := 8_192;
   SPSC_Location  : constant DS.Region_Offset := 16_384;
   MPMC_Location  : constant DS.Region_Offset := 32_768;
   Map_Location   : constant DS.Region_Offset := 65_536;
   Envelope_Location : constant DS.Region_Offset := 100_000;
   Crash_Envelope_Location : constant DS.Region_Offset := 110_000;
   Poison_String_Location : constant DS.Region_Offset := 120_000;
   Poison_Vector_Location : constant DS.Region_Offset := 121_000;
   Scratch_MPMC_Location : constant DS.Region_Offset := 130_000;
   Scratch_Slab_Location : constant DS.Region_Offset := 132_000;
   Scratch_Map_Location  : constant DS.Region_Offset := 134_000;
   Scratch_Open_Location : constant DS.Region_Offset := 140_000;
   Arena_Location : constant DS.Region_Offset := 180_224;
   Dynamic_Vector_Location : constant DS.Region_Offset := 150_016;
   Dynamic_String_Location : constant DS.Region_Offset := 151_040;
   Dynamic_Map_Location : constant DS.Region_Offset := 152_064;
   Scratch_Arena_Location : constant DS.Region_Offset := 154_112;
   Scratch_Dynamic_Location : constant DS.Region_Offset := 157_184;
   Best_Fit_Dynamic_Location : constant DS.Region_Offset := 245_760;
   Best_Fit_Arena_Location : constant DS.Region_Offset := 262_144;
   Best_Fit_Configuration : constant Best_Fit_Arenas.Configuration :=
     (Usable_Capacity => 65_472, Minimum_Block_Size => 64);
   Best_Fit_Instance : constant Interfaces.Unsigned_64 :=
     16#B35F_17A1_10C8_0001#;
   TLSF_Dynamic_Location : constant DS.Region_Offset := 333_000;
   TLSF_Arena_Location : constant DS.Region_Offset := 344_064;
   TLSF_Configuration : constant TLSF_Arenas.Configuration :=
     (Usable_Capacity => 65_536, Minimum_Block_Size => 64);
   TLSF_Instance : constant Interfaces.Unsigned_64 :=
     16#715F_17A1_10C8_0001#;
   Adaptive_Pool_Location : constant DS.Region_Offset := 420_032;
   Envelope_Content_Extent : constant DS.Byte_Count :=
     Vectors.Required_Storage (4);

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

   generic
      with package Provider is new DS.Arenas (<>);
   procedure Stress_Variable_Arena
     (First, Second : in out Provider.View;
      Region         : Regions.View;
      Location       : DS.Region_Offset;
      Configuration  : Provider.Configuration;
      Instance       : Interfaces.Unsigned_64);

   procedure Stress_Variable_Arena
     (First, Second : in out Provider.View;
      Region         : Regions.View;
      Location       : DS.Region_Offset;
      Configuration  : Provider.Configuration;
      Instance       : Interfaces.Unsigned_64)
   is
      Slot_Count : constant := 64;
      type Handle_Array is
        array (Positive range <>) of Provider.Allocation_Handle;
      Handles : Handle_Array (1 .. Slot_Count) :=
        [others => Provider.Null_Allocation];
      Live : array (Positive range 1 .. Slot_Count) of Boolean :=
        [others => False];
      Values : array (Positive range 1 .. Slot_Count) of
        Interfaces.Unsigned_64 := [others => 0];
      Seed : Interfaces.Unsigned_64 := 16#91E1_0DA5_C79E_7B1D#;
      Result : Provider.Allocation_Result;
      Probe  : Provider.View;
      Data   : Ada.Streams.Stream_Element_Array (1 .. 8);
      Index  : Positive;
      Size   : Positive;
   begin
      for Step in 1 .. 20_000 loop
         Seed := Seed * 6_364_136_223_846_793_005 + 1;
         Index := Positive
           (Natural (Seed mod Slot_Count) + 1);
         if Live (Index) then
            if Step mod 2 = 0 then
               Provider.Read (First, Handles (Index), 0, Data);
               Provider.Release (Second, Handles (Index));
            else
               Provider.Read (Second, Handles (Index), 0, Data);
               Provider.Release (First, Handles (Index));
            end if;
            Assert
              (Decode (Data) = Values (Index),
               "variable-size allocator stress corrupted a payload");
            Live (Index) := False;
         else
            Size := Positive (Natural
              (Interfaces.Shift_Right (Seed, 17) mod 2_048) + 1);
            if Step mod 2 = 0 then
               Provider.Try_Allocate
                 (First, Size, Handles (Index), Result);
            else
               Provider.Try_Allocate
                 (Second, Size, Handles (Index), Result);
            end if;
            if Result = Provider.Allocated then
               Values (Index) :=
                 Interfaces.Unsigned_64 (Index) * 1_000_000
                 + Interfaces.Unsigned_64 (Step);
               if Step mod 2 = 0 then
                  Provider.Write
                    (Second, Handles (Index), 0, Encode (Values (Index)));
               else
                  Provider.Write
                    (First, Handles (Index), 0, Encode (Values (Index)));
               end if;
               Live (Index) := True;
            elsif Result /= Provider.Exhausted then
               raise Program_Error with
                 "single-task allocator stress observed contention";
            end if;
         end if;
         if Step mod 251 = 0 then
            Provider.Attach
              (Probe, Region, Location, Configuration, Instance);
            Provider.Detach (Probe);
         end if;
      end loop;
      for Slot in Live'Range loop
         if Live (Slot) then
            Provider.Release (First, Handles (Slot));
         end if;
      end loop;
      Provider.Attach (Probe, Region, Location, Configuration, Instance);
      Provider.Detach (Probe);
   end Stress_Variable_Arena;

   procedure Stress_Best_Fit is new Stress_Variable_Arena
     (Provider => Best_Fit_Arenas);
   procedure Stress_TLSF is new Stress_Variable_Arena
     (Provider => TLSF_Arenas);

   function Test_Hash
     (Key : Ada.Streams.Stream_Element_Array)
      return Interfaces.Unsigned_64
   is
      Result : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   begin
      for Byte of Key loop
         Result := (Result xor Interfaces.Unsigned_64 (Byte)) *
           16#0000_0100_0000_01B3#;
      end loop;
      return Result;
   end Test_Hash;

   function Raw_Offset
     (Location : DS.Region_Offset; Relative : Natural) return C.size_t is
     (C.size_t (DS.Byte_Count (Location) + DS.Byte_Count (Relative)));

   function Map_Entry_Offset
     (Index : Interfaces.Unsigned_64; Relative : Natural) return C.size_t is
     (Raw_Offset
        (Map_Location, 72 + Natural (Index) * 32 + Relative));

   function Map_Entry_Offset_At
     (Location : DS.Region_Offset;
      Index    : Interfaces.Unsigned_64;
      Relative : Natural) return C.size_t is
     (Raw_Offset (Location, 72 + Natural (Index) * 32 + Relative));

   Temp_Root : constant String := Ada.Environment_Variables.Value
     ("FLYOLOGY_TEST_TEMP_ROOT", "/tmp");
   Path : constant C.char_array := C.To_C
     (Temp_Root & "/data-structures-smoke.map");
   Base_A : aliased System.Address := System.Null_Address;
   Base_B : aliased System.Address := System.Null_Address;
   Base_C : aliased System.Address := System.Null_Address;
   FD     : aliased C.int := -1;

   Region_A, Region_B, Region_C, Truncated : Regions.View;
   Arena_A, Arena_B, Arena_C, Arena_Bad : Arenas.View;
   Best_Fit_A, Best_Fit_B, Best_Fit_C, Best_Fit_Bad :
     Best_Fit_Arenas.View;
   TLSF_A, TLSF_B, TLSF_C, TLSF_Bad : TLSF_Arenas.View;
   Scratch_Arena_A, Scratch_Arena_B : Arenas.View;
   Dynamic_Vector_A, Dynamic_Vector_B, Dynamic_Vector_C :
     Dynamic_Vectors.View;
   Dynamic_Vector_Bad : Dynamic_Vectors.View;
   Scratch_Dynamic_A, Scratch_Dynamic_B : Dynamic_Vectors.View;
   Dynamic_String_A, Dynamic_String_B, Dynamic_String_C :
     Dynamic_Strings.View;
   Dynamic_Map_A, Dynamic_Map_B, Dynamic_Map_C : Dynamic_Maps.View;
   Dynamic_Map_Bad : Dynamic_Maps.View;
   Best_Fit_Vector_A, Best_Fit_Vector_B, Best_Fit_Vector_C :
     Best_Fit_Dynamic_Vectors.View;
   TLSF_Vector_A, TLSF_Vector_B, TLSF_Vector_C :
     TLSF_Dynamic_Vectors.View;
   Adaptive_A, Adaptive_B, Adaptive_C, Adaptive_Bad : Adaptive_U64.View;
   Slab_A, Slab_B, Slab_C, Slab_Bad : Slabs.View;
   String_A, String_B, String_C : Strings.View;
   Vector_A, Vector_B, Vector_C : Vectors.View;
   Ring_A, Ring_B, Ring_C, Ring_Bad : SPSC.View;
   Multi_A, Multi_B, Multi_C, Multi_Bad : MPMC.View;
   Map_A, Map_B, Map_C, Map_Bad : Maps.View;
   Envelope_A, Envelope_B, Envelope_C : Contract_V1.View;
   Wrapped_A, Wrapped_B, Wrapped_C : Vectors.View;

   Payload_16 : Ada.Streams.Stream_Element_Array (1 .. 16) :=
     (others => 16#2A#);
   Arena_Data : constant Ada.Streams.Stream_Element_Array (1 .. 16) :=
     (others => 16#A7#);
   Read_16 : Ada.Streams.Stream_Element_Array (1 .. 16);
   Eight : Ada.Streams.Stream_Element_Array (1 .. 8);
   U64_Value : Interfaces.Unsigned_64 := 0;
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
   type Handle_Array is array (Positive range <>) of Handles.Handle;
   Handle_1 : Handles.Handle;
   Arena_Handle : Arenas.Allocation_Handle;
   Arena_Released : Arenas.Allocation_Handle;
   Best_Fit_Handle : Best_Fit_Arenas.Allocation_Handle;
   TLSF_Handle : TLSF_Arenas.Allocation_Handle;
   type Adaptive_Handle_Array is
     array (Positive range <>) of Adaptive_U64.Handle;
   Adaptive_Handles : Adaptive_Handle_Array (1 .. 40);
   Poison_Handle : Handles.Handle;
   Recovered_Handles : Handle_Array (1 .. 7);
   Bad_Handles : constant Handle_Array :=
     [Handles.Null_Handle,
      (Slot => 99, Stamp => 1),
      (Slot => 1, Stamp => 0)];
   Flag : Boolean;
   Allocation : Slabs.Allocation_Result;
   Arena_Allocation : Arenas.Allocation_Result;
   Growth : DS.Dynamic.Growth_Result;
   Dynamic_Put : Dynamic_Maps.Put_Result;
   Put_Outcome : Maps.Put_Result;
   Push_Outcome : MPMC.Push_Result;
   Pop_Outcome : MPMC.Pop_Result;
   Open_Outcome : DS.Open_Result;

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

   --  An adapter may omit the optional direct constructor. The container then
   --  creates one independent immutable value and copies it before publishing.
   declare
      Local_Storage : aliased SSE.Storage_Array (1 .. 512) := [others => 0]
        with Alignment => 64;
      Local_Region  : Regions.View;
      Local_Vector  : Wrong_Vectors.View;
      Outcome       : DS.Open_Result;
      Appended      : Boolean;
   begin
      Regions.Attach
        (Local_Region, Local_Storage'Address,
         DS.Byte_Count (Local_Storage'Length));
      Wrong_Vectors.Create_Or_Attach
        (Local_Vector, Local_Region, 64, 4, Outcome);
      Assert
        (Outcome = DS.Initialized_New,
         "fallback-adapter vector was not created");
      Wrong_Vectors.Try_Emplace (Local_Vector, 42, Appended);
      Assert
        (Appended and then Wrong_Vectors.Read (Local_Vector, 1) = 42,
         "fallback adapter did not preserve its value");
      Wrong_Vectors.Detach (Local_Vector);
      Regions.Detach (Local_Region);
   end;

   Arenas.Create_Or_Attach
     (Arena_A, Region_A, Arena_Location,
      (Usable_Capacity => 32_768, Minimum_Block_Size => 64),
      16#A8E4_7B19_2C63_D501#, Open_Outcome);
   Assert (Open_Outcome = DS.Initialized_New, "arena was not created");
   Arenas.Create_Or_Attach
     (Arena_B, Region_B, Arena_Location,
      (Usable_Capacity => 32_768, Minimum_Block_Size => 64),
      16#A8E4_7B19_2C63_D501#, Open_Outcome);
   Assert
     (Open_Outcome = DS.Attached_Existing, "arena was reinitialized");

   declare
      Failed : Boolean := False;
   begin
      begin
         Arenas.Create_Or_Attach
           (Arena_Bad, Region_B, Arena_Location,
            (Usable_Capacity => 16_384, Minimum_Block_Size => 64),
            16#A8E4_7B19_2C63_D501#, Open_Outcome);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed and then not Arenas.Is_Attached (Arena_Bad),
         "arena accepted incompatible managed capacity");

      Failed := False;
      begin
         Arenas.Create_Or_Attach
           (Arena_Bad, Region_B, Arena_Location,
            (Usable_Capacity => 32_768, Minimum_Block_Size => 128),
            16#A8E4_7B19_2C63_D501#, Open_Outcome);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed and then not Arenas.Is_Attached (Arena_Bad),
         "arena accepted incompatible algorithm configuration");

      Failed := False;
      begin
         Arenas.Create_Or_Attach
           (Arena_Bad, Region_B, Arena_Location,
            (Usable_Capacity => 32_768, Minimum_Block_Size => 64),
            16#A8E4_7B19_2C63_D502#, Open_Outcome);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed and then not Arenas.Is_Attached (Arena_Bad),
         "arena accepted an incompatible instance identity");
   end;

   Arenas.Try_Allocate (Arena_A, 33, Arena_Handle, Arena_Allocation);
   Assert
     (Arena_Allocation = Arenas.Allocated
      and then Arenas.Block_Capacity (Arena_B, Arena_Handle) = 64,
      "arena did not allocate the smallest fitting buddy block");
   Arenas.Write (Arena_A, Arena_Handle, 0, Arena_Data);
   Arenas.Read (Arena_B, Arena_Handle, 0, Read_16);
   Assert (Read_16 = Arena_Data, "arena payload was not shared across views");

   Arenas.Try_Allocate (Arena_B, 5_000, Arena_Released, Arena_Allocation);
   Assert
     (Arena_Allocation = Arenas.Allocated
      and then Arenas.Block_Capacity (Arena_A, Arena_Released) = 8_192,
      "arena did not round a large allocation to its buddy capacity");
   Arenas.Release (Arena_A, Arena_Released);
   declare
      Failed : Boolean := False;
   begin
      begin
         Arenas.Release (Arena_B, Arena_Released);
      exception
         when DS.Handle_Error => Failed := True;
      end;
      Assert (Failed, "arena accepted a double release");
   end;

   Dynamic_Vectors.Create_Or_Attach
     (Dynamic_Vector_A, Region_A, Dynamic_Vector_Location, Arena_A, 2,
      Open_Outcome);
   Assert
     (Open_Outcome = DS.Initialized_New,
      "dynamic vector was not created");
   Dynamic_Vectors.Create_Or_Attach
     (Dynamic_Vector_B, Region_B, Dynamic_Vector_Location, Arena_B, 2,
      Open_Outcome);
   Assert
     (Open_Outcome = DS.Attached_Existing,
      "dynamic vector was reinitialized");
   for Index in 1 .. 20 loop
      Dynamic_Vectors.Try_Append
        (Dynamic_Vector_A, Arena_A, Interfaces.Unsigned_64 (Index), Growth);
      Assert
        (Growth = DS.Dynamic.Completed,
         "dynamic vector failed to grow in its arena");
   end loop;
   Assert
     (Dynamic_Vectors.Length (Dynamic_Vector_B) = 20
      and then Dynamic_Vectors.Capacity (Dynamic_Vector_B) >= 20,
      "dynamic-vector growth metadata was not shared");
   U64_Value := Dynamic_Vectors.Read (Dynamic_Vector_B, Arena_B, 20);
   Assert
     (U64_Value = 20,
      "dynamic-vector payload was not shared across mappings");

   Dynamic_Strings.Create_Or_Attach
     (Dynamic_String_A, Region_A, Dynamic_String_Location, Arena_A, 4,
      Open_Outcome);
   Assert
     (Open_Outcome = DS.Initialized_New,
      "dynamic byte string was not created");
   Dynamic_Strings.Create_Or_Attach
     (Dynamic_String_B, Region_B, Dynamic_String_Location, Arena_B, 4,
      Open_Outcome);
   Assert
     (Open_Outcome = DS.Attached_Existing,
      "dynamic byte string was reinitialized");
   Dynamic_Strings.Try_Append
     (Dynamic_String_A, Arena_A, String_Data, Growth);
   Assert (Growth = DS.Dynamic.Completed, "dynamic string append failed");
   Dynamic_Strings.Try_Append
     (Dynamic_String_B, Arena_B, String_More, Growth);
   Assert
     (Growth = DS.Dynamic.Completed
      and then Dynamic_Strings.Length (Dynamic_String_A) = 8,
      "dynamic byte string did not grow across mappings");
   Dynamic_Strings.Read (Dynamic_String_A, Arena_A, String_Read);
   Assert
     (String_Read (1 .. 3) = String_Data
      and then String_Read (4 .. 8) = String_More,
      "dynamic byte-string payload order is wrong");

   Dynamic_Maps.Create_Or_Attach
     (Dynamic_Map_A, Region_A, Dynamic_Map_Location, Arena_A, 2,
      Open_Outcome);
   Assert
     (Open_Outcome = DS.Initialized_New, "dynamic map was not created");
   Dynamic_Maps.Create_Or_Attach
     (Dynamic_Map_B, Region_B, Dynamic_Map_Location, Arena_B, 2,
      Open_Outcome);
   Assert
     (Open_Outcome = DS.Attached_Existing,
      "dynamic map was reinitialized");
   for Index in Interfaces.Unsigned_64 range 1 .. 20 loop
      Dynamic_Maps.Put
        (Dynamic_Map_A, Arena_A, Index, Index * 10,
         Dynamic_Put);
      Assert
        (Dynamic_Put = Dynamic_Maps.Put_Inserted,
         "dynamic map failed to insert while growing");
   end loop;
   Dynamic_Maps.Get
     (Dynamic_Map_B, Arena_B, 20, U64_Value, Flag);
   Assert
     (Flag and then U64_Value = 200
      and then Dynamic_Maps.Length (Dynamic_Map_B) = 20
      and then Dynamic_Maps.Capacity (Dynamic_Map_B) >= 32,
      "dynamic-map growth or lookup was not shared");

   Best_Fit_Arenas.Create_Or_Attach
     (Best_Fit_A, Region_A, Best_Fit_Arena_Location,
      Best_Fit_Configuration, Best_Fit_Instance, Open_Outcome);
   Assert
     (Open_Outcome = DS.Initialized_New,
      "best-fit arena was not created");
   Best_Fit_Arenas.Create_Or_Attach
     (Best_Fit_B, Region_B, Best_Fit_Arena_Location,
      Best_Fit_Configuration, Best_Fit_Instance, Open_Outcome);
   Assert
     (Open_Outcome = DS.Attached_Existing,
      "best-fit arena was reinitialized");
   declare
      Failed : Boolean := False;
   begin
      begin
         Best_Fit_Arenas.Attach
           (Best_Fit_Bad, Region_B, Best_Fit_Arena_Location,
            (Usable_Capacity => 65_408, Minimum_Block_Size => 64),
            Best_Fit_Instance);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed and then not Best_Fit_Arenas.Is_Attached (Best_Fit_Bad),
         "best-fit arena accepted incompatible geometry");

      Failed := False;
      begin
         Arenas.Attach
           (Arena_Bad, Region_B, Best_Fit_Arena_Location,
            (Usable_Capacity => 65_536, Minimum_Block_Size => 64),
            Best_Fit_Instance);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed and then not Arenas.Is_Attached (Arena_Bad),
         "best-fit arena attached through the buddy algorithm");
   end;

   declare
      type Best_Fit_Handle_Array is
        array (Positive range <>) of Best_Fit_Arenas.Allocation_Handle;
      Handles : Best_Fit_Handle_Array (1 .. 5);
      Selected : Best_Fit_Arenas.Allocation_Handle;
      Sizes : constant array (Positive range 1 .. 5) of Positive :=
        [100, 200, 100, 400, 100];
   begin
      for Index in Handles'Range loop
         Best_Fit_Arenas.Try_Allocate
           (Best_Fit_A, Sizes (Index), Handles (Index), Arena_Allocation);
         Assert
           (Arena_Allocation = Best_Fit_Arenas.Allocated,
            "best-fit arena rejected an available allocation");
      end loop;
      Best_Fit_Arenas.Release (Best_Fit_B, Handles (2));
      Best_Fit_Arenas.Release (Best_Fit_A, Handles (4));

      Best_Fit_Arenas.Try_Allocate
        (Best_Fit_B, 180, Selected, Arena_Allocation);
      Assert
        (Arena_Allocation = Best_Fit_Arenas.Allocated
         and then Best_Fit_Arenas.Block_Capacity
           (Best_Fit_A, Selected) = 256,
         "best-fit arena did not choose the smallest fitting block");
      Best_Fit_Arenas.Release (Best_Fit_A, Selected);

      Best_Fit_Arenas.Try_Allocate
        (Best_Fit_A, 300, Selected, Arena_Allocation);
      Assert
        (Arena_Allocation = Best_Fit_Arenas.Allocated
         and then Best_Fit_Arenas.Block_Capacity
           (Best_Fit_B, Selected) = 320,
         "best-fit arena did not split the selected block");
      Best_Fit_Arenas.Release (Best_Fit_B, Selected);

      Best_Fit_Arenas.Release (Best_Fit_A, Handles (1));
      Best_Fit_Arenas.Release (Best_Fit_B, Handles (3));
      Best_Fit_Arenas.Release (Best_Fit_A, Handles (5));
      Best_Fit_Arenas.Try_Allocate
        (Best_Fit_B, 65_000, Selected, Arena_Allocation);
      Assert
        (Arena_Allocation = Best_Fit_Arenas.Allocated
         and then Best_Fit_Arenas.Block_Capacity
           (Best_Fit_A, Selected) = 65_024,
         "best-fit arena did not coalesce adjacent free blocks");
      Best_Fit_Arenas.Release (Best_Fit_A, Selected);
   end;

   Stress_Best_Fit
     (Best_Fit_A, Best_Fit_B, Region_B, Best_Fit_Arena_Location,
      Best_Fit_Configuration, Best_Fit_Instance);

   Best_Fit_Arenas.Try_Allocate
     (Best_Fit_A, 33, Best_Fit_Handle, Arena_Allocation);
   Assert
     (Arena_Allocation = Best_Fit_Arenas.Allocated
      and then Best_Fit_Arenas.Block_Capacity
        (Best_Fit_B, Best_Fit_Handle) = 64,
      "best-fit arena did not expose its rounded payload capacity");
   Best_Fit_Arenas.Write
     (Best_Fit_A, Best_Fit_Handle, 0, Arena_Data);
   Best_Fit_Arenas.Read
     (Best_Fit_B, Best_Fit_Handle, 0, Read_16);
   Assert
     (Read_16 = Arena_Data,
      "best-fit payload was not shared across mappings");

   Best_Fit_Dynamic_Vectors.Create_Or_Attach
     (Best_Fit_Vector_A, Region_A, Best_Fit_Dynamic_Location,
      Best_Fit_A, 2, Open_Outcome);
   Assert
     (Open_Outcome = DS.Initialized_New,
      "best-fit dynamic vector was not created");
   Best_Fit_Dynamic_Vectors.Create_Or_Attach
     (Best_Fit_Vector_B, Region_B, Best_Fit_Dynamic_Location,
      Best_Fit_B, 2, Open_Outcome);
   Assert
     (Open_Outcome = DS.Attached_Existing,
      "best-fit dynamic vector was reinitialized");
   for Index in 1 .. 40 loop
      Best_Fit_Dynamic_Vectors.Try_Append
        (Best_Fit_Vector_A, Best_Fit_A,
         Interfaces.Unsigned_64 (Index), Growth);
      Assert
        (Growth = DS.Dynamic.Completed,
         "best-fit dynamic vector failed to grow");
   end loop;
   Assert
     (Best_Fit_Dynamic_Vectors.Read
        (Best_Fit_Vector_B, Best_Fit_B, 40) = 40,
      "best-fit dynamic vector was not shared across mappings");

   declare
      Saved : constant Interfaces.Unsigned_32 := Read_U32
        (Base_B, Raw_Offset (Best_Fit_Arena_Location, 228));
      Failed : Boolean := False;
   begin
      Write_U32
        (Base_B, Raw_Offset (Best_Fit_Arena_Location, 228), 1);
      begin
         Best_Fit_Arenas.Attach
           (Best_Fit_Bad, Region_B, Best_Fit_Arena_Location,
            Best_Fit_Configuration, Best_Fit_Instance);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U32
        (Base_B, Raw_Offset (Best_Fit_Arena_Location, 228), Saved);
      Assert
        (Failed and then not Best_Fit_Arenas.Is_Attached (Best_Fit_Bad),
         "best-fit arena accepted corrupt block metadata");
   end;

   Assert
     (Best_Fit_Arenas.Capabilities.Search =
        DS.Allocation_Algorithms.Logarithmic
      and then TLSF_Arenas.Capabilities.Search =
        DS.Allocation_Algorithms.Linear
      and then not TLSF_Arenas.Capabilities.Coalesces_On_Release,
      "allocator search capabilities are not exposed accurately");
   TLSF_Arenas.Create_Or_Attach
     (TLSF_A, Region_A, TLSF_Arena_Location,
      TLSF_Configuration, TLSF_Instance, Open_Outcome);
   Assert
     (Open_Outcome = DS.Initialized_New,
      "TLSF arena was not created");
   TLSF_Arenas.Create_Or_Attach
     (TLSF_B, Region_B, TLSF_Arena_Location,
      TLSF_Configuration, TLSF_Instance, Open_Outcome);
   Assert
     (Open_Outcome = DS.Attached_Existing,
      "TLSF arena was reinitialized");
   declare
      Saved_Version : constant Interfaces.Unsigned_32 := Read_U32
        (Base_B, Raw_Offset (TLSF_Arena_Location, 4));
      Saved_Schema : constant Interfaces.Unsigned_64 := Read_U64
        (Base_B, Raw_Offset (TLSF_Arena_Location, 16));
      Failed : Boolean := False;
   begin
      Write_U32
        (Base_B, Raw_Offset (TLSF_Arena_Location, 4), 2);
      Write_U64
        (Base_B, Raw_Offset (TLSF_Arena_Location, 16),
         16#0001_544C_5346_0002#);
      begin
         TLSF_Arenas.Attach
           (TLSF_Bad, Region_B, TLSF_Arena_Location,
            TLSF_Configuration, TLSF_Instance);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U32
        (Base_B, Raw_Offset (TLSF_Arena_Location, 4), Saved_Version);
      Write_U64
        (Base_B, Raw_Offset (TLSF_Arena_Location, 16), Saved_Schema);
      Assert
        (Failed and then not TLSF_Arenas.Is_Attached (TLSF_Bad),
         "TLSF arena accepted the eager-coalescing identity");
   end;
   declare
      Failed : Boolean := False;
   begin
      begin
         TLSF_Arenas.Attach
           (TLSF_Bad, Region_B, TLSF_Arena_Location,
            (Usable_Capacity => 65_472, Minimum_Block_Size => 64),
            TLSF_Instance);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed and then not TLSF_Arenas.Is_Attached (TLSF_Bad),
         "TLSF arena accepted incompatible geometry");
   end;

   declare
      type TLSF_Handle_Array is
        array (Positive range <>) of TLSF_Arenas.Allocation_Handle;
      Handles : TLSF_Handle_Array (1 .. 5);
      Selected : TLSF_Arenas.Allocation_Handle;
      Sizes : constant array (Positive range 1 .. 5) of Positive :=
        [100, 200, 100, 400, 100];
   begin
      for Index in Handles'Range loop
         TLSF_Arenas.Try_Allocate
           (TLSF_A, Sizes (Index), Handles (Index), Arena_Allocation);
         Assert
           (Arena_Allocation = TLSF_Arenas.Allocated,
            "TLSF arena rejected an available allocation");
      end loop;
      TLSF_Arenas.Release (TLSF_B, Handles (2));
      TLSF_Arenas.Release (TLSF_A, Handles (4));
      TLSF_Arenas.Try_Allocate
        (TLSF_B, 180, Selected, Arena_Allocation);
      Assert
        (Arena_Allocation = TLSF_Arenas.Allocated
         and then TLSF_Arenas.Block_Capacity (TLSF_A, Selected) = 256,
         "TLSF did not select the lowest fitting size class");
      TLSF_Arenas.Release (TLSF_A, Selected);
      TLSF_Arenas.Try_Allocate
        (TLSF_A, 300, Selected, Arena_Allocation);
      Assert
        (Arena_Allocation = TLSF_Arenas.Allocated
         and then TLSF_Arenas.Block_Capacity (TLSF_B, Selected) = 320,
         "TLSF did not split its selected free block");
      TLSF_Arenas.Release (TLSF_B, Selected);
      TLSF_Arenas.Release (TLSF_A, Handles (1));
      TLSF_Arenas.Release (TLSF_B, Handles (3));
      TLSF_Arenas.Release (TLSF_A, Handles (5));
      TLSF_Arenas.Try_Allocate
        (TLSF_B, 65_400, Selected, Arena_Allocation);
      Assert
        (Arena_Allocation = TLSF_Arenas.Allocated
         and then TLSF_Arenas.Block_Capacity
           (TLSF_A, Selected) = 65_472,
         "TLSF did not coalesce its complete managed extent");
      TLSF_Arenas.Release (TLSF_A, Selected);
   end;

   Stress_TLSF
     (TLSF_A, TLSF_B, Region_B, TLSF_Arena_Location,
      TLSF_Configuration, TLSF_Instance);

   TLSF_Arenas.Try_Allocate
     (TLSF_A, 33, TLSF_Handle, Arena_Allocation);
   Assert
     (Arena_Allocation = TLSF_Arenas.Allocated
      and then TLSF_Arenas.Block_Capacity (TLSF_B, TLSF_Handle) = 64,
      "TLSF did not expose its rounded payload capacity");
   TLSF_Arenas.Write (TLSF_A, TLSF_Handle, 0, Arena_Data);
   TLSF_Arenas.Read (TLSF_B, TLSF_Handle, 0, Read_16);
   Assert
     (Read_16 = Arena_Data,
      "TLSF payload was not shared across mappings");

   TLSF_Dynamic_Vectors.Create_Or_Attach
     (TLSF_Vector_A, Region_A, TLSF_Dynamic_Location,
      TLSF_A, 2, Open_Outcome);
   TLSF_Dynamic_Vectors.Create_Or_Attach
     (TLSF_Vector_B, Region_B, TLSF_Dynamic_Location,
      TLSF_B, 2, Open_Outcome);
   Assert
     (Open_Outcome = DS.Attached_Existing,
      "TLSF dynamic vector was not attached");
   for Index in 1 .. 40 loop
      TLSF_Dynamic_Vectors.Try_Append
        (TLSF_Vector_A, TLSF_A, Interfaces.Unsigned_64 (Index), Growth);
      Assert
        (Growth = DS.Dynamic.Completed,
         "TLSF dynamic vector failed to grow");
   end loop;
   Assert
     (TLSF_Dynamic_Vectors.Read (TLSF_Vector_B, TLSF_B, 40) = 40,
      "TLSF dynamic vector was not shared across mappings");

   declare
      Saved : constant Interfaces.Unsigned_32 := Read_U32
        (Base_B, Raw_Offset (TLSF_Arena_Location, 128));
      Failed : Boolean := False;
   begin
      Write_U32
        (Base_B, Raw_Offset (TLSF_Arena_Location, 128), Saved xor 1);
      begin
         TLSF_Arenas.Attach
           (TLSF_Bad, Region_B, TLSF_Arena_Location,
            TLSF_Configuration, TLSF_Instance);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U32
        (Base_B, Raw_Offset (TLSF_Arena_Location, 128), Saved);
      Assert
        (Failed and then not TLSF_Arenas.Is_Attached (TLSF_Bad),
         "TLSF accepted a corrupt first-level bitmap");
   end;

   Adaptive_U64.Create_Or_Attach
     (Adaptive_A, Region_A, Adaptive_Pool_Location,
      TLSF_A, Open_Outcome);
   Assert
     (Open_Outcome = DS.Initialized_New,
      "adaptive pool was not created");
   Adaptive_U64.Create_Or_Attach
     (Adaptive_B, Region_B, Adaptive_Pool_Location,
      TLSF_B, Open_Outcome);
   Assert
     (Open_Outcome = DS.Attached_Existing,
      "adaptive pool was reinitialized");
   for Index in Adaptive_Handles'Range loop
      declare
         Result : Adaptive_U64.Allocation_Result;
      begin
         Adaptive_U64.Try_Allocate
           (Adaptive_A, TLSF_A, Interfaces.Unsigned_64 (Index),
            Adaptive_Handles (Index), Result);
         Assert
           (Result = Adaptive_U64.Allocated,
            "adaptive pool failed to add or allocate a chunk");
      end;
   end loop;
   Adaptive_U64.Read
     (Adaptive_B, TLSF_B, Adaptive_Handles (40), U64_Value);
   Assert
     (U64_Value = 40
      and then Adaptive_Handles (17).Chunk = 2
      and then Adaptive_Handles (33).Chunk = 3,
      "adaptive pool chunk growth or cross-view read is wrong");
   Adaptive_U64.Release
     (Adaptive_B, TLSF_B, Adaptive_Handles (1));
   declare
      Failed : Boolean := False;
   begin
      begin
         Adaptive_U64.Release
           (Adaptive_A, TLSF_A, Adaptive_Handles (1));
      exception
         when DS.Handle_Error => Failed := True;
      end;
      Assert (Failed, "adaptive pool accepted a stale slot handle");
   end;

   declare
      Saved : constant Interfaces.Unsigned_32 := Read_U32
        (Base_B, Raw_Offset (Adaptive_Pool_Location, 80));
      Failed : Boolean := False;
   begin
      Write_U32
        (Base_B, Raw_Offset (Adaptive_Pool_Location, 80), 99);
      begin
         Adaptive_U64.Attach
           (Adaptive_Bad, Region_B, Adaptive_Pool_Location, TLSF_B);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U32
        (Base_B, Raw_Offset (Adaptive_Pool_Location, 80), Saved);
      Assert
        (Failed and then not Adaptive_U64.Is_Attached (Adaptive_Bad),
         "adaptive pool accepted corrupt chunk state");

      --  Arena validation can fail before the outer header is inspected. A
      --  reused output view must still be detached before that failure so the
      --  caller cannot accidentally continue through its earlier attachment.
      Adaptive_U64.Attach
        (Adaptive_Bad, Region_B, Adaptive_Pool_Location, TLSF_B);
      Failed := False;
      begin
         Adaptive_U64.Attach
           (Adaptive_Bad, Region_B, Adaptive_Pool_Location, TLSF_Bad);
      exception
         when DS.Region_Error => Failed := True;
      end;
      Assert
        (Failed and then not Adaptive_U64.Is_Attached (Adaptive_Bad),
         "adaptive pool retained a view after arena validation failed");
   end;

   --  A pool view resolves chunks through arena allocation handles and caches
   --  their attachments locally, so it must reject an arena that is not the
   --  instance and incarnation it attached to. Otherwise a caller could read a
   --  warm cache belonging to another arena, or resolve a chunk token against
   --  storage that arena has since handed to something else.
   declare
      Foreign_Arena_Location : constant DS.Region_Offset := 430_080;
      Foreign_Pool_Location  : constant DS.Region_Offset := 458_752;
      Foreign_Configuration  : constant TLSF_Arenas.Configuration :=
        (Usable_Capacity => 16_384, Minimum_Block_Size => 64);
      Foreign_Instance : constant Interfaces.Unsigned_64 :=
        16#715F_17A1_10C8_0002#;
      Foreign_Arena  : TLSF_Arenas.View;
      Foreign_Pool   : Adaptive_U64.View;
      Foreign_Handle : Adaptive_U64.Handle;
      Foreign_Result : Adaptive_U64.Allocation_Result;
      Failed : Boolean := False;
   begin
      TLSF_Arenas.Initialize
        (Foreign_Arena, Region_A, Foreign_Arena_Location,
         Foreign_Configuration, Foreign_Instance);
      begin
         Adaptive_U64.Read
           (Adaptive_A, Foreign_Arena, Adaptive_Handles (40), U64_Value);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "adaptive pool read through a foreign arena instance");
      Failed := False;
      begin
         Adaptive_U64.Try_Allocate
           (Adaptive_A, Foreign_Arena, 7, Foreign_Handle, Foreign_Result);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "adaptive pool allocated through a foreign arena");

      --  Reinitializing the backing arena keeps its caller-selected instance
      --  identity but starts a new incarnation, so an older pool view must
      --  fail closed rather than resolve its recorded chunk allocations.
      Adaptive_U64.Initialize
        (Foreign_Pool, Region_A, Foreign_Pool_Location, Foreign_Arena);
      Adaptive_U64.Try_Allocate
        (Foreign_Pool, Foreign_Arena, 5, Foreign_Handle, Foreign_Result);
      Assert
        (Foreign_Result = Adaptive_U64.Allocated,
         "scratch adaptive pool did not allocate its first chunk");
      TLSF_Arenas.Initialize
        (Foreign_Arena, Region_A, Foreign_Arena_Location,
         Foreign_Configuration, Foreign_Instance);
      Failed := False;
      begin
         Adaptive_U64.Read
           (Foreign_Pool, Foreign_Arena, Foreign_Handle, U64_Value);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "adaptive pool accepted a stale arena incarnation");
      Adaptive_U64.Detach (Foreign_Pool);
      TLSF_Arenas.Destroy (Foreign_Arena);

      --  The nested slab begins 64 bytes into each arena allocation. Reject a
      --  smaller arena quantum before initialization can overwrite even an
      --  unrelated pre-existing outer header.
      declare
         Low_Alignment_Configuration : constant TLSF_Arenas.Configuration :=
           (Usable_Capacity => 16_384, Minimum_Block_Size => 32);
         Saved_State : constant Interfaces.Unsigned_32 := Read_U32
           (Base_A, Raw_Offset (Foreign_Pool_Location, 0));
      begin
         TLSF_Arenas.Initialize
           (Foreign_Arena, Region_A, Foreign_Arena_Location,
            Low_Alignment_Configuration, Foreign_Instance);
         Failed := False;
         begin
            Adaptive_U64.Initialize
              (Foreign_Pool, Region_A, Foreign_Pool_Location, Foreign_Arena);
         exception
            when Constraint_Error => Failed := True;
         end;
         Assert
           (Failed
            and then not Adaptive_U64.Is_Attached (Foreign_Pool)
            and then Read_U32
              (Base_A, Raw_Offset (Foreign_Pool_Location, 0)) = Saved_State,
            "adaptive pool modified storage for insufficient alignment");
         TLSF_Arenas.Destroy (Foreign_Arena);
      end;
   end;

   --  A dependent dynamic header records the arena incarnation, not only its
   --  caller-selected instance id. Reinitializing the arena under exclusive
   --  authority must therefore make that older header fail closed.
   Arenas.Initialize
     (Scratch_Arena_A, Region_A, Scratch_Arena_Location,
      (Usable_Capacity => 1_024, Minimum_Block_Size => 64),
      16#C0DE_0110_CAFE_0001#);
   Arenas.Attach
     (Scratch_Arena_B, Region_B, Scratch_Arena_Location,
      (Usable_Capacity => 1_024, Minimum_Block_Size => 64),
      16#C0DE_0110_CAFE_0001#);
   declare
      type Arena_Handle_Array is
        array (Positive range <>) of Arenas.Allocation_Handle;
      Values : Arena_Handle_Array (1 .. 16);
      Extra  : Arenas.Allocation_Handle;
   begin
      for Index in Values'Range loop
         Arenas.Try_Allocate
           (Scratch_Arena_A, 1, Values (Index), Arena_Allocation);
         Assert
           (Arena_Allocation = Arenas.Allocated,
            "arena rejected an available minimum block");
         Arenas.Write
           (Scratch_Arena_A, Values (Index), 0,
            Encode (Interfaces.Unsigned_64 (Index)));
      end loop;
      Arenas.Try_Allocate
        (Scratch_Arena_A, 1, Extra, Arena_Allocation);
      Assert
        (Arena_Allocation = Arenas.Exhausted
         and then Extra = Arenas.Null_Allocation,
         "full arena did not report exhaustion");
      for Index in Values'Range loop
         Arenas.Read (Scratch_Arena_B, Values (Index), 0, Eight);
         Assert
           (Decode (Eight) = Interfaces.Unsigned_64 (Index),
            "buddy-node payload ranges overlap or are misplaced");
         Arenas.Release (Scratch_Arena_B, Values (Index));
      end loop;
   end;
   Dynamic_Vectors.Initialize
     (Scratch_Dynamic_A, Region_A, Scratch_Dynamic_Location,
      Scratch_Arena_A, 2);
   Dynamic_Vectors.Try_Append
     (Scratch_Dynamic_A, Scratch_Arena_A, 77, Growth);
   Assert
     (Growth = DS.Dynamic.Completed,
      "scratch dynamic vector did not allocate from its arena");
   Dynamic_Vectors.Detach (Scratch_Dynamic_A);
   Arenas.Detach (Scratch_Arena_B);
   Arenas.Initialize
     (Scratch_Arena_A, Region_A, Scratch_Arena_Location,
      (Usable_Capacity => 1_024, Minimum_Block_Size => 64),
      16#C0DE_0110_CAFE_0001#);
   Arenas.Attach
     (Scratch_Arena_B, Region_B, Scratch_Arena_Location,
      (Usable_Capacity => 1_024, Minimum_Block_Size => 64),
      16#C0DE_0110_CAFE_0001#);
   declare
      Failed : Boolean := False;
   begin
      begin
         Dynamic_Vectors.Attach
           (Scratch_Dynamic_B, Region_B, Scratch_Dynamic_Location,
            Scratch_Arena_B, 2);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed and then not Dynamic_Vectors.Is_Attached (Scratch_Dynamic_B),
         "dynamic vector accepted a stale arena incarnation");
   end;
   Dynamic_Vectors.Initialize
     (Scratch_Dynamic_A, Region_A, Scratch_Dynamic_Location,
      Scratch_Arena_A, 2);
   Dynamic_Vectors.Destroy (Scratch_Dynamic_A, Scratch_Arena_A);
   Arenas.Destroy (Scratch_Arena_A);
   Arenas.Detach (Scratch_Arena_B);

   declare
      Failed : Boolean := False;
      Saved_Node : constant Interfaces.Unsigned_32 := Read_U32
        (Base_B, Raw_Offset (Dynamic_Vector_Location, 72));
      Saved_Vector_Capacity : constant Interfaces.Unsigned_64 := Read_U64
        (Base_B, Raw_Offset (Dynamic_Vector_Location, 64));
      Saved_String_Capacity : constant Interfaces.Unsigned_64 := Read_U64
        (Base_B, Raw_Offset (Dynamic_String_Location, 64));
      Saved_Map_Capacity : constant Interfaces.Unsigned_64 := Read_U64
        (Base_B, Raw_Offset (Dynamic_Map_Location, 64));
      Saved_Map_Node : constant Interfaces.Unsigned_32 := Read_U32
        (Base_B, Raw_Offset (Dynamic_Map_Location, 72));
      Saved_Reserved : constant Interfaces.Unsigned_32 := Read_U32
        (Base_B, Raw_Offset (Arena_Location, 132));
   begin
      begin
         Dynamic_Vectors.Create_Or_Attach
           (Dynamic_Vector_Bad, Region_B, Dynamic_Vector_Location,
            Arena_B, 4, Open_Outcome);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed and then not Dynamic_Vectors.Is_Attached (Dynamic_Vector_Bad),
         "dynamic vector accepted mismatched creation parameters");

      Write_U64
        (Base_B, Raw_Offset (Dynamic_Vector_Location, 64),
         Saved_Vector_Capacity xor 1);
      Failed := False;
      begin
         if Dynamic_Vectors.Length (Dynamic_Vector_B) = Natural'Last then
            raise Program_Error with "unreachable dynamic-vector length";
         end if;
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U64
        (Base_B, Raw_Offset (Dynamic_Vector_Location, 64),
         Saved_Vector_Capacity);
      Assert (Failed, "dynamic vector ignored a corrupt capacity field");

      Write_U64
        (Base_B, Raw_Offset (Dynamic_String_Location, 64),
         Saved_String_Capacity xor 1);
      Failed := False;
      begin
         if Dynamic_Strings.Length (Dynamic_String_B) = Natural'Last then
            raise Program_Error with "unreachable dynamic-string length";
         end if;
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U64
        (Base_B, Raw_Offset (Dynamic_String_Location, 64),
         Saved_String_Capacity);
      Assert (Failed, "dynamic byte string ignored corrupt capacity");

      Write_U64
        (Base_B, Raw_Offset (Dynamic_Map_Location, 64),
         Saved_Map_Capacity xor 1);
      Failed := False;
      begin
         if Dynamic_Maps.Length (Dynamic_Map_B) = Natural'Last then
            raise Program_Error with "unreachable dynamic-map length";
         end if;
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U64
        (Base_B, Raw_Offset (Dynamic_Map_Location, 64),
         Saved_Map_Capacity);
      Assert (Failed, "dynamic map ignored a corrupt capacity field");

      Write_U32
        (Base_B, Raw_Offset (Dynamic_Vector_Location, 72),
         Interfaces.Unsigned_32'Last);
      Failed := False;
      begin
         Dynamic_Vectors.Attach
           (Dynamic_Vector_Bad, Region_B, Dynamic_Vector_Location,
            Arena_B, 2);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U32
        (Base_B, Raw_Offset (Dynamic_Vector_Location, 72), Saved_Node);
      Assert
        (Failed and then not Dynamic_Vectors.Is_Attached (Dynamic_Vector_Bad),
         "dynamic vector accepted a corrupt arena handle");

      Write_U32 (Base_B, Raw_Offset (Arena_Location, 132), 1);
      Failed := False;
      begin
         Arenas.Attach
           (Arena_Bad, Region_B, Arena_Location,
            (Usable_Capacity => 32_768, Minimum_Block_Size => 64),
            16#A8E4_7B19_2C63_D501#);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U32
        (Base_B, Raw_Offset (Arena_Location, 132), Saved_Reserved);
      Assert
        (Failed and then not Arenas.Is_Attached (Arena_Bad),
         "arena accepted corrupt buddy-node metadata");

      Write_U32 (Base_B, Raw_Offset (Arena_Location, 108), 1);
      Failed := False;
      begin
         Arenas.Attach
           (Arena_Bad, Region_B, Arena_Location,
            (Usable_Capacity => 32_768, Minimum_Block_Size => 64),
            16#A8E4_7B19_2C63_D501#);
      exception
         when DS.Busy_Error => Failed := True;
      end;
      Write_U32 (Base_B, Raw_Offset (Arena_Location, 108), 0);
      Assert
        (Failed and then not Arenas.Is_Attached (Arena_Bad),
         "arena attached through an owned metadata guard");

      Write_U32
        (Base_B, Raw_Offset (Dynamic_Map_Location, 72),
         Interfaces.Unsigned_32'Last);
      Failed := False;
      begin
         Dynamic_Maps.Attach
           (Dynamic_Map_Bad, Region_B, Dynamic_Map_Location,
            Arena_B, 2);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U32
        (Base_B, Raw_Offset (Dynamic_Map_Location, 72),
         Saved_Map_Node);
      Assert
        (Failed and then not Dynamic_Maps.Is_Attached (Dynamic_Map_Bad),
         "dynamic map accepted a corrupt arena handle");
   end;

   declare
      Failed : Boolean := False;
   begin
      begin
         if Contract_V1.Required_Storage (DS.Byte_Count (63), 8) = 0 then
            raise Program_Error with "unreachable envelope extent";
         end if;
      exception
         when Constraint_Error => Failed := True;
      end;
      Assert (Failed, "envelope accepted less than a complete leaf header");

      Failed := False;
      begin
         if MPMC.Required_Storage (1) = 0 then
            raise Program_Error with "unreachable MPMC extent";
         end if;
      exception
         when Constraint_Error => Failed := True;
      end;
      Assert (Failed, "MPMC accepted capacity one");
   end;

   Slabs.Create_Or_Attach
     (Slab_A, Region_A, Slab_Location, 8, Open_Outcome);
   Assert (Open_Outcome = DS.Initialized_New, "slab was not created");
   Slabs.Create_Or_Attach
     (Slab_B, Region_B, Slab_Location, 8, Open_Outcome);
   Assert (Open_Outcome = DS.Attached_Existing, "slab was reinitialized");
   Strings.Create_Or_Attach
     (String_A, Region_A, String_Location, 128, Open_Outcome);
   Assert (Open_Outcome = DS.Initialized_New, "string was not created");
   Strings.Create_Or_Attach
     (String_B, Region_B, String_Location, 128, Open_Outcome);
   Assert (Open_Outcome = DS.Attached_Existing, "string was reinitialized");
   Vectors.Create_Or_Attach
     (Vector_A, Region_A, Vector_Location, 16, Open_Outcome);
   Assert (Open_Outcome = DS.Initialized_New, "vector was not created");
   Vectors.Create_Or_Attach
     (Vector_B, Region_B, Vector_Location, 16, Open_Outcome);
   Assert (Open_Outcome = DS.Attached_Existing, "vector was reinitialized");
   SPSC.Create_Or_Attach
     (Ring_A, Region_A, SPSC_Location, 16, Open_Outcome);
   Assert (Open_Outcome = DS.Initialized_New, "SPSC ring was not created");
   SPSC.Create_Or_Attach
     (Ring_B, Region_B, SPSC_Location, 16, Open_Outcome);
   Assert
     (Open_Outcome = DS.Attached_Existing, "SPSC ring was reinitialized");
   MPMC.Create_Or_Attach
     (Multi_A, Region_A, MPMC_Location, 16, Open_Outcome);
   Assert (Open_Outcome = DS.Initialized_New, "MPMC ring was not created");
   MPMC.Create_Or_Attach
     (Multi_B, Region_B, MPMC_Location, 16, Open_Outcome);
   Assert
     (Open_Outcome = DS.Attached_Existing, "MPMC ring was reinitialized");
   Maps.Create_Or_Attach
     (Map_A, Region_A, Map_Location, 16, Open_Outcome);
   Assert (Open_Outcome = DS.Initialized_New, "map was not created");
   Maps.Create_Or_Attach
     (Map_B, Region_B, Map_Location, 16, Open_Outcome);
   Assert (Open_Outcome = DS.Attached_Existing, "map was reinitialized");

   --  Every generic leaf incorporates its immutable adapter identities into
   --  the persisted schema. Equal byte sizes are deliberately used here so
   --  attachment cannot succeed merely because physical geometry matches.
   declare
      Bad_Slab    : Wrong_Slabs.View;
      Bad_SPSC    : Wrong_SPSC.View;
      Bad_MPMC    : Wrong_MPMC.View;
      Bad_Map     : Wrong_Maps.View;
      Bad_Vector  : Wrong_Dynamic_Vectors.View;
      Bad_Dynamic_Map : Wrong_Dynamic_Maps.View;
      Failed : Boolean;
   begin
      Failed := False;
      begin
         Wrong_Slabs.Attach (Bad_Slab, Region_B, Slab_Location, 8);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "slab accepted another element signature");

      Failed := False;
      begin
         Wrong_SPSC.Attach (Bad_SPSC, Region_B, SPSC_Location, 16);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "SPSC ring accepted another element signature");

      Failed := False;
      begin
         Wrong_MPMC.Attach (Bad_MPMC, Region_B, MPMC_Location, 16);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "MPMC ring accepted another element signature");

      Failed := False;
      begin
         Wrong_Maps.Attach (Bad_Map, Region_B, Map_Location, 16);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "hash map accepted another key signature");

      Failed := False;
      begin
         Wrong_Dynamic_Vectors.Attach
           (Bad_Vector, Region_B, Dynamic_Vector_Location, Arena_B, 2);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed, "dynamic vector accepted another element signature");

      Failed := False;
      begin
         Wrong_Dynamic_Maps.Attach
           (Bad_Dynamic_Map, Region_B, Dynamic_Map_Location, Arena_B, 2);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed, "dynamic map accepted another value signature");
   end;
   Contract_V1.Create_Or_Attach
     (Envelope_A, Region_A, Envelope_Location, Envelope_Content_Extent, 8,
      Open_Outcome);
   Assert (Open_Outcome = DS.Initialized_New, "envelope was not created");
   Vectors.Create_Or_Attach
     (Wrapped_B, Region_B, Contract_V1.Content_Location (Envelope_A), 4,
      Open_Outcome);
   Assert
     (Open_Outcome = DS.Initialization_In_Progress
      and then not Vectors.Is_Attached (Wrapped_B),
      "nested initializer claim was not observable");
   Vectors.Initialize
     (Wrapped_A, Region_A, Contract_V1.Content_Location (Envelope_A), 4);
   Contract_V1.Create_Or_Attach
     (Envelope_B, Region_B, Envelope_Location, Envelope_Content_Extent, 8,
      Open_Outcome);
   Assert
     (Open_Outcome = DS.Attached_Existing, "envelope was reinitialized");
   Vectors.Create_Or_Attach
     (Wrapped_B, Region_B, Contract_V1.Content_Location (Envelope_B), 4,
      Open_Outcome);
   Assert
     (Open_Outcome = DS.Attached_Existing,
      "nested vector was reinitialized");

   declare
      Wrong  : Vectors.View;
      Failed : Boolean := False;
      Saved_State : constant Interfaces.Unsigned_32 :=
        Read_U32 (Base_B, Raw_Offset (Vector_Location, 0));
   begin
      begin
         Vectors.Create_Or_Attach
           (Wrong, Region_B, Vector_Location, 8, Open_Outcome);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed and then not Vectors.Is_Attached (Wrong)
         and then Read_U32
           (Base_B, Raw_Offset (Vector_Location, 0)) = Saved_State,
         "create-or-attach overwrote an incompatible ready vector");

      declare
         Wrong_Element : Wrong_Vectors.View;
         Wrong_Version : Wrong_Version_Vectors.View;
      begin
         Failed := False;
         begin
            Wrong_Vectors.Attach
              (Wrong_Element, Region_B, Vector_Location, 16);
         exception
            when DS.Layout_Error => Failed := True;
         end;
         Assert
           (Failed and then not Wrong_Vectors.Is_Attached (Wrong_Element),
            "vector accepted a different immutable element identity");

         Failed := False;
         begin
            Wrong_Version_Vectors.Attach
              (Wrong_Version, Region_B, Vector_Location, 16);
         exception
            when DS.Layout_Error => Failed := True;
         end;
         Assert
           (Failed and then
            not Wrong_Version_Vectors.Is_Attached (Wrong_Version),
            "vector accepted a different immutable element version");
      end;

      Write_U32
        (Base_A, Raw_Offset (Scratch_Open_Location, 0), 16#FFFF_FFFA#);
      Failed := False;
      begin
         Vectors.Create_Or_Attach
           (Wrong, Region_A, Scratch_Open_Location, 4, Open_Outcome);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed and then not Vectors.Is_Attached (Wrong)
         and then Read_U32
           (Base_B, Raw_Offset (Scratch_Open_Location, 0)) = 16#FFFF_FFFA#,
         "create-or-attach treated a corrupt nonzero state as virgin");
      Write_U32 (Base_A, Raw_Offset (Scratch_Open_Location, 0), 0);
   end;

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

   declare
      Small_A, Small_B : MPMC.View;
      Failed : Boolean := False;
   begin
      MPMC.Initialize
        (Small_A, Region_A, Scratch_MPMC_Location, 2);
      MPMC.Attach
        (Small_B, Region_B, Scratch_MPMC_Location, 2);
      MPMC.Try_Push (Small_A, 99, Push_Outcome);
      Assert (Push_Outcome = MPMC.Pushed,
              "capacity-two MPMC setup push failed");

      --  Model a consumer that advanced Dequeue and then terminated before
      --  it republished the claimed slot as free. Enqueue now equals
      --  Dequeue, but the slot sequence still proves the ring is not empty.
      Write_U64
        (Base_B, Raw_Offset (Scratch_MPMC_Location, 128), 1);
      begin
         MPMC.Destroy (Small_A);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "MPMC destroy accepted an abandoned consumer claim");

      MPMC.Initialize
        (Small_A, Region_A, Scratch_MPMC_Location, 2);
      MPMC.Detach (Small_B);
      MPMC.Attach
        (Small_B, Region_B, Scratch_MPMC_Location, 2);
      for Round in Interfaces.Unsigned_64 range 1 .. 128 loop
         MPMC.Try_Push (Small_A, Round * 2 - 1, Push_Outcome);
         Assert (Push_Outcome = MPMC.Pushed,
                 "capacity-two MPMC rejected its first slot");
         MPMC.Try_Push (Small_B, Round * 2, Push_Outcome);
         Assert (Push_Outcome = MPMC.Pushed,
                 "capacity-two MPMC rejected its second slot");
         MPMC.Try_Push (Small_A, 0, Push_Outcome);
         Assert (Push_Outcome = MPMC.Full,
                 "capacity-two MPMC did not report full");
         if Round = 1 then
            Failed := False;
            begin
               MPMC.Push (Small_A, 0, 0.0);
            exception
               when DS.Timeout_Error => Failed := True;
            end;
            Assert (Failed, "timed MPMC push ignored a full ring");
         end if;
         MPMC.Try_Pop (Small_B, U64_Value, Pop_Outcome);
         Assert
           (Pop_Outcome = MPMC.Popped
            and then U64_Value = Round * 2 - 1,
            "capacity-two MPMC lost FIFO order at wraparound");
         MPMC.Try_Pop (Small_A, U64_Value, Pop_Outcome);
         Assert
           (Pop_Outcome = MPMC.Popped
            and then U64_Value = Round * 2,
            "capacity-two MPMC duplicated or reordered an element");
         MPMC.Try_Pop (Small_B, U64_Value, Pop_Outcome);
         Assert (Pop_Outcome = MPMC.Empty,
                 "capacity-two MPMC did not return to empty");
         if Round = 1 then
            Failed := False;
            begin
               MPMC.Pop (Small_B, U64_Value, 0.0);
            exception
               when DS.Timeout_Error => Failed := True;
            end;
            Assert (Failed, "timed MPMC pop ignored an empty ring");
         end if;
      end loop;
      declare
         Saved_State : constant Interfaces.Unsigned_32 :=
           Read_U32 (Base_B, Raw_Offset (Scratch_MPMC_Location, 0));
      begin
         Write_U32
           (Base_B, Raw_Offset (Scratch_MPMC_Location, 0),
            (Saved_State and not Interfaces.Unsigned_32'(7)) or 4);
         Failed := False;
         begin
            if MPMC.Is_Poisoned (Small_A) then
               raise Program_Error with "unreachable poisoned MPMC state";
            end if;
         exception
            when DS.Layout_Error => Failed := True;
         end;
         Write_U32
           (Base_B, Raw_Offset (Scratch_MPMC_Location, 0), Saved_State);
         Assert (Failed, "corrupt lifecycle was reported as healthy");
      end;
      MPMC.Destroy (Small_A);
      MPMC.Detach (Small_B);

      Write_U32
        (Base_B, Raw_Offset (Scratch_MPMC_Location, 0), 16#FFFF_FFFA#);
      Failed := False;
      begin
         MPMC.Initialize
           (Small_A, Region_A, Scratch_MPMC_Location, 2);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed and then not MPMC.Is_Attached (Small_A),
         "exhausted initialization epoch wrapped or retained a view");
   end;

   declare
      One : Slabs.View;
      Last_Handle : Handles.Handle;
      Failed : Boolean := False;
   begin
      Slabs.Initialize (One, Region_A, Scratch_Slab_Location, 1);
      Write_U32
        (Base_B, Raw_Offset (Scratch_Slab_Location, 64),
         Interfaces.Unsigned_32'Last);
      Slabs.Try_Allocate (One, Payload_16, Last_Handle, Allocation);
      Assert
        (Allocation = Slabs.Allocated
         and then Last_Handle.Stamp = Handles.Generation'Last,
         "slab did not expose the generation-exhaustion fixture");
      Write_U32
        (Base_B, Raw_Offset (Scratch_Slab_Location, 68), 3);
      begin
         Slabs.Read (One, Last_Handle, Read_16, 0.0);
      exception
         when DS.Timeout_Error => Failed := True;
      end;
      Write_U32
        (Base_B, Raw_Offset (Scratch_Slab_Location, 68), 1);
      Assert (Failed, "timed slab access ignored an owned slot");
      Failed := False;
      begin
         Slabs.Release (One, Last_Handle);
      exception
         when DS.Poison_Error => Failed := True;
      end;
      Assert (Failed, "slab generation wrapped and revived an old handle");

      Failed := False;
      begin
         Slabs.Recover_Poisoned (One, Last_Handle.Slot);
      exception
         when DS.Poison_Error => Failed := True;
      end;
      Assert (Failed, "slab recovered an exhausted generation");
      Slabs.Initialize (One, Region_A, Scratch_Slab_Location, 1);
      Slabs.Destroy (One);
   end;

   declare
      Scratch, Peer : Maps.View;
      Replacement : Vectors.View;
      Home : Interfaces.Unsigned_64;
      Failed : Boolean := False;
   begin
      Maps.Initialize
        (Scratch, Region_A, Scratch_Map_Location, 2);
      Maps.Attach
        (Peer, Region_B, Scratch_Map_Location, 2);
      Home := Test_Hash (Key_1) and 1;
      Write_U32
        (Base_B, Map_Entry_Offset_At (Scratch_Map_Location, Home, 0), 9);
      begin
         Maps.Put (Scratch, Decode (Key_1), Decode (Value_1), Put_Outcome);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed and then Maps.Is_Poisoned (Scratch),
         "hash-map operation did not poison an invalid entry state");

      Maps.Initialize
        (Scratch, Region_A, Scratch_Map_Location, 2);
      Maps.Put (Scratch, Decode (Key_1), Decode (Value_1), Put_Outcome);
      Write_U64
        (Base_B, Raw_Offset (Scratch_Map_Location, 48), 0);
      Failed := False;
      begin
         Maps.Remove (Scratch, Decode (Key_1), Flag);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed and then Maps.Is_Poisoned (Scratch),
         "hash-map removal underflow did not fail closed");

      Maps.Initialize
        (Scratch, Region_A, Scratch_Map_Location, 2);
      Write_U64
        (Base_B, Raw_Offset (Scratch_Map_Location, 48), 2);
      Failed := False;
      begin
         Maps.Put (Scratch, Decode (Key_1), Decode (Value_1), Put_Outcome);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed and then Maps.Is_Poisoned (Scratch),
         "hash-map insertion overflow did not fail closed");

      --  Reusing the same bytes for a different leaf must not revive Peer's
      --  cached map geometry. The new initialization epoch is checked before
      --  any cached count, guard, entry, or payload address is dereferenced.
      Maps.Initialize
        (Scratch, Region_A, Scratch_Map_Location, 2);
      Maps.Detach (Peer);
      Maps.Attach
        (Peer, Region_B, Scratch_Map_Location, 2);
      Vectors.Initialize
        (Replacement, Region_A, Scratch_Map_Location, 2);
      Failed := False;
      begin
         Maps.Get (Peer, Decode (Key_1), U64_Value, Flag);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "stale cross-leaf view used replacement storage");
      Maps.Detach (Peer);
      Vectors.Destroy (Replacement);
   end;

   Slabs.Try_Allocate (Slab_A, Payload_16, Handle_1, Allocation);
   Assert (Allocation = Slabs.Allocated
           and then not Handles.Is_Null (Handle_1),
           "slab allocation failed");
   Slabs.Read (Slab_B, Handle_1, Read_16);
   Assert (Read_16 = Payload_16, "slab A-to-B payload was not visible");
   Payload_16 := (others => 16#55#);
   Slabs.Replace (Slab_B, Handle_1, Payload_16);
   Slabs.Read (Slab_A, Handle_1, Read_16);
   Assert (Read_16 = Payload_16, "slab B-to-A mutation was not visible");

   Slabs.Try_Allocate (Slab_A, Payload_16, Poison_Handle, Allocation);
   Assert (Allocation = Slabs.Allocated, "poison test allocation failed");
   Write_U32
     (Base_A,
      Raw_Offset
        (Slab_Location,
         64 + (Natural (Poison_Handle.Slot) - 1) * 32 + 4),
      3);
   declare
      Failed : Boolean := False;
      State_At : constant C.size_t := Raw_Offset
        (Slab_Location,
         64 + (Natural (Poison_Handle.Slot) - 1) * 32 + 4);
   begin
      begin
         Slabs.Read (Slab_B, Poison_Handle, Read_16);
      exception
         when DS.Busy_Error => Failed := True;
      end;
      Assert (Failed, "slab contender did not report bounded contention");
      Assert
        (Read_U32 (Base_A, State_At) = 3,
         "failed slab contender released another owner's claim");
   end;
   Slabs.Detach (Slab_A);
   Slabs.Detach (Slab_B);
   Slabs.Poison_Abandoned_At
     (Region_B, Slab_Location, 8, Poison_Handle.Slot);
   Slabs.Attach (Slab_A, Region_A, Slab_Location, 8);
   Slabs.Attach (Slab_B, Region_B, Slab_Location, 8);
   declare
      Failed : Boolean := False;
   begin
      begin
         Slabs.Read (Slab_A, Poison_Handle, Read_16);
      exception
         when DS.Poison_Error => Failed := True;
      end;
      Assert (Failed, "poisoned slab slot remained readable");
   end;
   Slabs.Recover_Poisoned (Slab_B, Poison_Handle.Slot);
   declare
      Failed : Boolean := False;
   begin
      begin
         Slabs.Read (Slab_A, Poison_Handle, Read_16);
      exception
         when DS.Handle_Error => Failed := True;
      end;
      Assert (Failed, "recovery did not stale the abandoned handle");
   end;
   Flag := False;
   for Index in Recovered_Handles'Range loop
      Slabs.Try_Allocate
        (Slab_A, Payload_16, Recovered_Handles (Index), Allocation);
      Assert (Allocation = Slabs.Allocated,
              "recovery verification allocation failed");
      if Recovered_Handles (Index).Slot = Poison_Handle.Slot then
         Assert
           (Recovered_Handles (Index).Stamp /= Poison_Handle.Stamp,
            "recovery did not advance the poisoned generation");
         Flag := True;
      end if;
   end loop;
   Assert (Flag, "poisoned slab slot was not explicitly recycled");
   Slabs.Try_Allocate (Slab_A, Payload_16, Poison_Handle, Allocation);
   Assert
     (Allocation = Slabs.Exhausted and then Handles.Is_Null (Poison_Handle),
      "full slab did not report an exhausted allocation outcome");
   for Handle of Recovered_Handles loop
      Slabs.Release (Slab_A, Handle);
   end loop;

   Strings.Assign (String_A, String_Data);
   Strings.Append (String_B, String_More);
   Assert (Strings.Length (String_A) = 8, "byte-string length did not relocate");
   Strings.Read (String_A, String_Read);
   Assert
     (String_Read (1 .. 3) = String_Data
      and then String_Read (4 .. 8) = String_More,
      "byte-string cross-view append failed");

   declare
      Seed : constant Ada.Streams.Stream_Element_Array (1 .. 12) :=
        [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12];
      Source : Ada.Streams.Stream_Element_Array (1 .. 5);
      for Source'Address use SSE."+"
        (Base_A,
         SSE.Storage_Offset
           (DS.Byte_Count (String_Location) + DS.Byte_Count (70)));
      Expected : Ada.Streams.Stream_Element_Array (1 .. 5);
      Result   : Ada.Streams.Stream_Element_Array (1 .. 13);
   begin
      Strings.Assign (String_A, Seed);
      Strings.Assign (String_A, Seed (1 .. 8));
      Expected := Source;
      Strings.Append (String_A, Source);
      Strings.Read (String_B, Result);
      Assert
        (Result (9 .. 13) = Expected,
         "overlapping byte-string append did not preserve its source");
      Strings.Assign (String_A, String_Data);
      Strings.Append (String_A, String_More);
   end;

   Vectors.Try_Emplace (Vector_A, 1, Flag);
   Assert (Flag, "vector append failed");
   Assert
     (Vectors.Read (Vector_B, 1) = 1,
      "zero-copy vector A-to-B read failed");
   Vectors.Replace (Vector_B, 1, 2);
   Assert
     (Vectors.Read (Vector_A, 1) = 2,
      "vector B-to-A replace failed");
   declare
      Failed : Boolean := False;
   begin
      begin
         Vectors.Try_Emplace (Vector_A, 16#DEAD_BEEF#, Flag);
      exception
         when Constraint_Error => Failed := True;
      end;
      Assert
        (Failed and then Vectors.Length (Vector_B) = 1,
         "failed vector construction published a partial element");
   end;

   declare
      Recovery_String : Strings.View;
      Recovery_Peer   : Strings.View;
      Recovery_Vector : Vectors.View;
      Failed          : Boolean;
   begin
      Strings.Initialize
        (Recovery_String, Region_A, Poison_String_Location, 32);
      Write_U32
        (Base_B, Raw_Offset (Poison_String_Location, 44), 2);
      Failed := False;
      begin
         if Strings.Length (Recovery_String) /= 0 then
            raise Program_Error with "unreachable corrupt string length";
         end if;
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "corrupt byte-string guard was accepted as contention");
      Write_U32
        (Base_B, Raw_Offset (Poison_String_Location, 44), 1);
      Failed := False;
      begin
         if Strings.Length (Recovery_String) /= 0 then
            raise Program_Error with "unreachable busy string length";
         end if;
      exception
         when DS.Busy_Error => Failed := True;
      end;
      Assert (Failed, "abandoned byte-string guard did not report busy");
      Failed := False;
      begin
         if Strings.Length (Recovery_String, 0.0) /= 0 then
            raise Program_Error with "unreachable timed string length";
         end if;
      exception
         when DS.Timeout_Error => Failed := True;
      end;
      Assert (Failed, "timed byte-string access ignored an owned guard");

      Strings.Poison (Region_B, Poison_String_Location);
      Assert
        (Strings.Is_Poisoned (Recovery_String),
         "byte-string recovery poison was not visible across mappings");
      Failed := False;
      begin
         Strings.Append (Recovery_String, String_Data);
      exception
         when DS.Poison_Error => Failed := True;
      end;
      Assert (Failed, "poisoned byte string accepted an operation");
      Failed := False;
      begin
         Strings.Attach
           (Recovery_Peer, Region_B, Poison_String_Location, 32);
      exception
         when DS.Poison_Error => Failed := True;
      end;
      Assert (Failed, "poisoned byte string attached as ready");
      Failed := False;
      begin
         Strings.Create_Or_Attach
           (Recovery_Peer, Region_B, Poison_String_Location, 32,
            Open_Outcome);
      exception
         when DS.Poison_Error => Failed := True;
      end;
      Assert
        (Failed and then not Strings.Is_Attached (Recovery_Peer),
         "create-or-attach overwrote a poisoned byte string");

      Strings.Initialize
        (Recovery_String, Region_A, Poison_String_Location, 32);
      Assert
        (not Strings.Is_Poisoned (Recovery_String),
         "byte-string reinitialization did not clear poison");
      Strings.Attach
        (Recovery_Peer, Region_B, Poison_String_Location, 32);
      Strings.Assign (Recovery_String, String_Data);
      Strings.Destroy (Recovery_String);
      Strings.Detach (Recovery_Peer);

      Vectors.Initialize
        (Recovery_Vector, Region_A, Poison_Vector_Location, 4);
      Write_U32
        (Base_B, Raw_Offset (Poison_Vector_Location, 44), 1);
      Failed := False;
      begin
         Vectors.Try_Append
           (Recovery_Vector, 1, 0.0, Flag);
      exception
         when DS.Timeout_Error => Failed := True;
      end;
      Assert (Failed, "timed vector access ignored an owned guard");
      Write_U32
        (Base_B, Raw_Offset (Poison_Vector_Location, 44), 0);
      Vectors.Poison (Region_B, Poison_Vector_Location);
      Assert
        (Vectors.Is_Poisoned (Recovery_Vector),
         "vector poison was not visible across mappings");
      Failed := False;
      begin
         Vectors.Try_Append
           (Recovery_Vector, 1, Flag);
      exception
         when DS.Poison_Error => Failed := True;
      end;
      Assert (Failed, "poisoned vector accepted an operation");
      Failed := False;
      begin
         Strings.Poison (Region_B, Poison_Vector_Location);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "recovery poison accepted the wrong leaf identity");

      Vectors.Initialize
        (Recovery_Vector, Region_A, Poison_Vector_Location, 4);
      Vectors.Try_Append
        (Recovery_Vector, 91, Flag);
      Assert (Flag, "reinitialized vector rejected an append");
      Assert
        (Vectors.Read (Recovery_Vector, 1) = 91,
         "reinitialized vector did not restore normal operation");
      Vectors.Destroy (Recovery_Vector);
   end;

   SPSC.Try_Pop (Ring_B, U64_Value, Flag);
   Assert (not Flag, "empty SPSC ring produced an element");
   declare
      Failed : Boolean := False;
   begin
      begin
         SPSC.Pop (Ring_B, U64_Value, 0.0);
      exception
         when DS.Timeout_Error => Failed := True;
      end;
      Assert (Failed, "timed SPSC pop ignored an empty ring");
   end;
   for Value in Interfaces.Unsigned_64 range 1 .. 16 loop
      SPSC.Try_Push (Ring_A, Value, Flag);
      Assert (Flag, "SPSC ring rejected available capacity");
   end loop;
   SPSC.Try_Push (Ring_A, 17, Flag);
   Assert (not Flag, "full SPSC ring accepted an element");
   declare
      Failed : Boolean := False;
   begin
      begin
         SPSC.Push (Ring_A, 17, 0.0);
      exception
         when DS.Timeout_Error => Failed := True;
      end;
      Assert (Failed, "timed SPSC push ignored a full ring");
   end;
   for Value in Interfaces.Unsigned_64 range 1 .. 16 loop
      SPSC.Try_Pop (Ring_B, U64_Value, Flag);
      Assert (Flag and then U64_Value = Value,
              "SPSC ordering or exactly-once delivery failed");
   end loop;

   MPMC.Try_Push (Multi_A, 41, Push_Outcome);
   Assert (Push_Outcome = MPMC.Pushed, "MPMC push failed");
   MPMC.Try_Pop (Multi_B, U64_Value, Pop_Outcome);
   Assert
     (Pop_Outcome = MPMC.Popped and then U64_Value = 41,
      "MPMC cross-view pop failed");

   Maps.Put (Map_A, Decode (Key_1), Decode (Value_1), Put_Outcome);
   Assert (Put_Outcome = Maps.Inserted, "hash-map insert failed");
   Maps.Get (Map_B, Decode (Key_1), U64_Value, Flag);
   Assert (Flag and then U64_Value = 111,
           "hash-map A-to-B lookup failed");
   Maps.Put (Map_B, Decode (Key_1), Decode (Value_2), Put_Outcome);
   Assert (Put_Outcome = Maps.Replaced, "hash-map replacement failed");
   Maps.Get (Map_A, Decode (Key_1), U64_Value, Flag);
   Assert (Flag and then U64_Value = 222,
      "hash-map B-to-A replacement was not visible");

   declare
      Home : constant Interfaces.Unsigned_64 := Test_Hash (Key_1) and 15;
      Saved_Hash : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Map_Entry_Offset (Home, 8));
      Failed : Boolean := False;
   begin
      Write_U64
        (Base_B, Map_Entry_Offset (Home, 8), Saved_Hash xor 1);
      begin
         Maps.Attach (Map_Bad, Region_B, Map_Location, 16);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U64 (Base_B, Map_Entry_Offset (Home, 8), Saved_Hash);
      Assert (Failed, "hash-map entry with a mismatched hash was accepted");
      Assert
        (not Maps.Is_Attached (Map_Bad),
         "failed hash-map attach retained a usable local view");
      Failed := False;
      begin
         Maps.Get (Map_Bad, Decode (Key_1), U64_Value, Flag);
      exception
         when DS.Region_Error => Failed := True;
      end;
      Assert (Failed, "failed hash-map attach allowed a later operation");
   end;

   declare
      Home : constant Interfaces.Unsigned_64 := Test_Hash (Key_1) and 15;
      Gap : constant Interfaces.Unsigned_64 := (Home + 1) and 15;
      Target : constant Interfaces.Unsigned_64 := (Home + 2) and 15;
      Target_State : constant Interfaces.Unsigned_32 :=
        Read_U32 (Base_B, Map_Entry_Offset (Target, 0));
      Target_Hash : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Map_Entry_Offset (Target, 8));
      Target_Key : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Map_Entry_Offset (Target, 16));
      Target_Value : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Map_Entry_Offset (Target, 24));
      Home_Key : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Map_Entry_Offset (Home, 16));
      Home_Value : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Map_Entry_Offset (Home, 24));
      Failed : Boolean := False;
   begin
      Assert
        (Read_U32 (Base_B, Map_Entry_Offset (Home, 0)) = 1
         and then Read_U32 (Base_B, Map_Entry_Offset (Gap, 0)) = 0
         and then Target_State = 0,
         "hash-map corruption fixture does not have an empty probe gap");
      Write_U32 (Base_B, Map_Entry_Offset (Home, 0), 0);
      Write_U64
        (Base_B, Map_Entry_Offset (Target, 8), Test_Hash (Key_1));
      Write_U64 (Base_B, Map_Entry_Offset (Target, 16), Home_Key);
      Write_U64 (Base_B, Map_Entry_Offset (Target, 24), Home_Value);
      Write_U32 (Base_B, Map_Entry_Offset (Target, 0), 1);
      begin
         Maps.Attach (Map_Bad, Region_B, Map_Location, 16);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U32 (Base_B, Map_Entry_Offset (Target, 0), Target_State);
      Write_U64 (Base_B, Map_Entry_Offset (Target, 8), Target_Hash);
      Write_U64 (Base_B, Map_Entry_Offset (Target, 16), Target_Key);
      Write_U64 (Base_B, Map_Entry_Offset (Target, 24), Target_Value);
      Write_U32 (Base_B, Map_Entry_Offset (Home, 0), 1);
      Assert (Failed, "hash-map entry beyond an empty probe gap was accepted");
   end;

   declare
      Home : constant Interfaces.Unsigned_64 := Test_Hash (Key_1) and 15;
      Target : constant Interfaces.Unsigned_64 := (Home + 1) and 15;
      Target_State : constant Interfaces.Unsigned_32 :=
        Read_U32 (Base_B, Map_Entry_Offset (Target, 0));
      Target_Hash : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Map_Entry_Offset (Target, 8));
      Target_Key : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Map_Entry_Offset (Target, 16));
      Target_Value : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Map_Entry_Offset (Target, 24));
      Home_Key : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Map_Entry_Offset (Home, 16));
      Home_Value : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Map_Entry_Offset (Home, 24));
      Failed : Boolean := False;
   begin
      Assert (Target_State = 0, "hash-map duplicate fixture is not empty");
      Write_U64
        (Base_B, Map_Entry_Offset (Target, 8), Test_Hash (Key_1));
      Write_U64 (Base_B, Map_Entry_Offset (Target, 16), Home_Key);
      Write_U64 (Base_B, Map_Entry_Offset (Target, 24), Home_Value);
      Write_U32 (Base_B, Map_Entry_Offset (Target, 0), 1);
      Write_U64 (Base_B, Raw_Offset (Map_Location, 48), 2);
      begin
         Maps.Attach (Map_Bad, Region_B, Map_Location, 16);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U64 (Base_B, Raw_Offset (Map_Location, 48), 1);
      Write_U32 (Base_B, Map_Entry_Offset (Target, 0), Target_State);
      Write_U64 (Base_B, Map_Entry_Offset (Target, 8), Target_Hash);
      Write_U64 (Base_B, Map_Entry_Offset (Target, 16), Target_Key);
      Write_U64 (Base_B, Map_Entry_Offset (Target, 24), Target_Value);
      Assert (Failed, "duplicate occupied hash-map keys were accepted");
   end;

   Vectors.Try_Append (Wrapped_A, 909, Flag);
   Assert
     (Flag and then
      Vectors.Read (Wrapped_B, 1) = 909,
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
      First_Envelope, Reused_Envelope, Peer_Envelope : Contract_V1.View;
      Stale_Leaf, New_Leaf, Peer_Leaf, Failed_Leaf : Vectors.View;
      Crash_Content : DS.Region_Offset := DS.Null_Offset;
      Failed : Boolean := False;
   begin
      Contract_V1.Initialize
        (First_Envelope, Region_A, Crash_Envelope_Location,
         Envelope_Content_Extent, 8);
      Crash_Content := Contract_V1.Content_Location (First_Envelope);
      Vectors.Initialize (Stale_Leaf, Region_A, Crash_Content, 4);
      Vectors.Try_Append
        (Stale_Leaf, 707, Flag);
      Assert
        (Flag and then
         (Read_U32 (Base_B, Raw_Offset (Crash_Content, 0)) and 7) = 2,
         "stale nested leaf was not ready before envelope reuse");
      Vectors.Detach (Stale_Leaf);
      Contract_V1.Detach (First_Envelope);

      Contract_V1.Initialize
        (Reused_Envelope, Region_A, Crash_Envelope_Location,
         Envelope_Content_Extent, 8);
      Contract_V1.Attach
        (Peer_Envelope, Region_B, Crash_Envelope_Location,
         Envelope_Content_Extent, 8);
      Assert
        ((Read_U32 (Base_B, Raw_Offset (Crash_Content, 0)) and 7) = 1,
         "envelope reuse did not invalidate stale nested state");
      begin
         Vectors.Attach (Failed_Leaf, Region_B, Crash_Content, 4);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert
        (Failed,
         "stale nested leaf survived the envelope initialization window");

      Vectors.Initialize (New_Leaf, Region_A, Crash_Content, 4);
      Vectors.Attach (Peer_Leaf, Region_B, Crash_Content, 4);
      Assert
        (Vectors.Length (Peer_Leaf) = 0,
         "nested leaf did not finish initialization after envelope reuse");
      Vectors.Destroy (New_Leaf);
      Vectors.Detach (Peer_Leaf);
      Contract_V1.Destroy (Reused_Envelope);
      Contract_V1.Detach (Peer_Envelope);
   end;

   declare
      Failed : Boolean := False;
   begin
      begin
         Slabs.Attach (Slab_Bad, Region_B, Slab_Location, 7);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "slab capacity mismatch was accepted");
   end;

   declare
      Saved : constant Interfaces.Unsigned_32 :=
        Read_U32 (Base_B, Raw_Offset (Slab_Location, 72));
      Failed : Boolean := False;
   begin
      Write_U32 (Base_B, Raw_Offset (Slab_Location, 72), 1);
      begin
         Slabs.Attach (Slab_Bad, Region_B, Slab_Location, 8);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U32 (Base_B, Raw_Offset (Slab_Location, 72), Saved);
      Assert (Failed, "corrupt slab slot metadata was accepted");
      Assert
        (not Slabs.Is_Attached (Slab_Bad),
         "failed slab attach retained a usable local view");
   end;

   declare
      Saved : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Raw_Offset (Slab_Location, 8));
      Failed : Boolean := False;
   begin
      Write_U64 (Base_B, Raw_Offset (Slab_Location, 8), Saved xor 1);
      begin
         Slabs.Attach (Slab_Bad, Region_B, Slab_Location, 8);
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
         Slabs.Attach (Slab_Bad, Region_B, Slab_Location, 8);
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
         Slabs.Attach (Slab_Bad, Region_B, Slab_Location, 8);
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
         Slabs.Attach (Slab_Bad, Truncated, Slab_Location, 8);
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
         SPSC.Attach (Ring_Bad, Region_B, SPSC_Location, 16);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U64 (Base_B, Raw_Offset (SPSC_Location, 128), Saved);
      Assert (Failed, "corrupt SPSC indices were accepted");
      Assert
        (not SPSC.Is_Attached (Ring_Bad),
         "failed SPSC attach retained a usable local view");
   end;

   declare
      Saved : constant Interfaces.Unsigned_64 :=
        Read_U64 (Base_B, Raw_Offset (MPMC_Location, 192));
      Failed : Boolean := False;
   begin
      Write_U64 (Base_B, Raw_Offset (MPMC_Location, 192), Saved + 1);
      MPMC.Attach (Multi_Bad, Region_B, MPMC_Location, 16);
      begin
         MPMC.Destroy (Multi_Bad);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Write_U64 (Base_B, Raw_Offset (MPMC_Location, 192), Saved);
      Assert
        (Failed,
         "quiescent MPMC destruction accepted a corrupt slot sequence");
      Assert
        (MPMC.Is_Attached (Multi_Bad),
         "failed MPMC destruction detached its diagnostic view");
      MPMC.Detach (Multi_Bad);
   end;

   Slabs.Detach (Slab_A);
   Strings.Detach (String_A);
   Vectors.Detach (Vector_A);
   SPSC.Detach (Ring_A);
   MPMC.Detach (Multi_A);
   Dynamic_Vectors.Detach (Dynamic_Vector_A);
   Dynamic_Strings.Detach (Dynamic_String_A);
   Dynamic_Maps.Detach (Dynamic_Map_A);
   Arenas.Detach (Arena_A);
   Best_Fit_Dynamic_Vectors.Detach (Best_Fit_Vector_A);
   Best_Fit_Arenas.Detach (Best_Fit_A);
   TLSF_Dynamic_Vectors.Detach (TLSF_Vector_A);
   Adaptive_U64.Detach (Adaptive_A);
   TLSF_Arenas.Detach (TLSF_A);
   Maps.Detach (Map_A);
   Vectors.Detach (Wrapped_A);
   Contract_V1.Detach (Envelope_A);
   Regions.Detach (Region_A);
   declare
      Failed : Boolean := False;
      Dummy : Handles.Handle;
   begin
      begin
         Slabs.Try_Allocate (Slab_A, Payload_16, Dummy, Allocation);
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
   Slabs.Attach (Slab_C, Region_C, Slab_Location, 8);
   Arenas.Attach
     (Arena_C, Region_C, Arena_Location,
      (Usable_Capacity => 32_768, Minimum_Block_Size => 64),
      16#A8E4_7B19_2C63_D501#);
   Best_Fit_Arenas.Attach
     (Best_Fit_C, Region_C, Best_Fit_Arena_Location,
      Best_Fit_Configuration, Best_Fit_Instance);
   Best_Fit_Dynamic_Vectors.Attach
     (Best_Fit_Vector_C, Region_C, Best_Fit_Dynamic_Location,
      Best_Fit_C, 2);
   TLSF_Arenas.Attach
     (TLSF_C, Region_C, TLSF_Arena_Location,
      TLSF_Configuration, TLSF_Instance);
   TLSF_Dynamic_Vectors.Attach
     (TLSF_Vector_C, Region_C, TLSF_Dynamic_Location, TLSF_C, 2);
   Adaptive_U64.Attach
     (Adaptive_C, Region_C, Adaptive_Pool_Location, TLSF_C);
   Dynamic_Vectors.Attach
     (Dynamic_Vector_C, Region_C, Dynamic_Vector_Location, Arena_C, 2);
   Dynamic_Strings.Attach
     (Dynamic_String_C, Region_C, Dynamic_String_Location, Arena_C, 4);
   Dynamic_Maps.Attach
     (Dynamic_Map_C, Region_C, Dynamic_Map_Location, Arena_C, 2);
   Strings.Attach (String_C, Region_C, String_Location, 128);
   Vectors.Attach (Vector_C, Region_C, Vector_Location, 16);
   SPSC.Attach (Ring_C, Region_C, SPSC_Location, 16);
   MPMC.Attach (Multi_C, Region_C, MPMC_Location, 16);
   Maps.Attach (Map_C, Region_C, Map_Location, 16);
   Contract_V1.Attach
     (Envelope_C, Region_C, Envelope_Location, Envelope_Content_Extent, 8);
   Vectors.Attach
     (Wrapped_C, Region_C, Contract_V1.Content_Location (Envelope_C), 4);

   Assert
     (Contains_U64
        (Base_C, Mapping_Length,
         Interfaces.Unsigned_64 (SSE.To_Integer (Base_C))) = 0,
      "third mapping address escaped into stored bytes");
   Slabs.Read (Slab_C, Handle_1, Read_16);
   Assert (Read_16 = Payload_16, "slab did not survive third mapping");
   Arenas.Read (Arena_C, Arena_Handle, 0, Read_16);
   Assert (Read_16 = Arena_Data, "arena did not survive third mapping");
   Arenas.Write (Arena_C, Arena_Handle, 16, Payload_16);
   Arenas.Read (Arena_B, Arena_Handle, 16, Read_16);
   Assert
     (Read_16 = Payload_16,
      "arena mutation was not visible after the third mapping");
   Arenas.Release (Arena_B, Arena_Handle);
   Best_Fit_Arenas.Read
     (Best_Fit_C, Best_Fit_Handle, 0, Read_16);
   Assert
     (Read_16 = Arena_Data,
      "best-fit arena did not survive the third mapping");
   Best_Fit_Arenas.Write
     (Best_Fit_C, Best_Fit_Handle, 16, Payload_16);
   Best_Fit_Arenas.Read
     (Best_Fit_B, Best_Fit_Handle, 16, Read_16);
   Assert
     (Read_16 = Payload_16,
      "best-fit mutation was not visible after the third mapping");
   Best_Fit_Arenas.Release (Best_Fit_B, Best_Fit_Handle);
   Best_Fit_Dynamic_Vectors.Try_Append
     (Best_Fit_Vector_C, Best_Fit_C, 41, Growth);
   Assert
     (Growth = DS.Dynamic.Completed
      and then Best_Fit_Dynamic_Vectors.Read
        (Best_Fit_Vector_B, Best_Fit_B, 41) = 41,
      "best-fit dynamic vector did not continue after remapping");
   TLSF_Arenas.Read (TLSF_C, TLSF_Handle, 0, Read_16);
   Assert
     (Read_16 = Arena_Data, "TLSF arena did not survive the third mapping");
   TLSF_Arenas.Write (TLSF_C, TLSF_Handle, 16, Payload_16);
   TLSF_Arenas.Read (TLSF_B, TLSF_Handle, 16, Read_16);
   Assert
     (Read_16 = Payload_16,
      "TLSF mutation was not visible after the third mapping");
   TLSF_Arenas.Release (TLSF_B, TLSF_Handle);
   TLSF_Dynamic_Vectors.Try_Append
     (TLSF_Vector_C, TLSF_C, 41, Growth);
   Assert
     (Growth = DS.Dynamic.Completed
      and then TLSF_Dynamic_Vectors.Read
        (TLSF_Vector_B, TLSF_B, 41) = 41,
      "TLSF dynamic vector did not continue after remapping");
   declare
      New_Handle : Adaptive_U64.Handle;
      Result : Adaptive_U64.Allocation_Result;
   begin
      Adaptive_U64.Try_Allocate
        (Adaptive_C, TLSF_C, 101, New_Handle, Result);
      Assert
        (Result = Adaptive_U64.Allocated and then New_Handle.Chunk = 1,
         "adaptive pool did not reuse a free slot after remapping");
      Adaptive_U64.Read (Adaptive_B, TLSF_B, New_Handle, U64_Value);
      Assert
        (U64_Value = 101,
         "adaptive-pool allocation was not visible across mappings");
      Adaptive_U64.Release (Adaptive_B, TLSF_B, New_Handle);
   end;
   for Index in 2 .. Adaptive_Handles'Last loop
      Adaptive_U64.Release
        (Adaptive_C, TLSF_C, Adaptive_Handles (Index));
   end loop;
   Dynamic_Vectors.Try_Append
     (Dynamic_Vector_C, Arena_C, 21, Growth);
   U64_Value := Dynamic_Vectors.Read (Dynamic_Vector_B, Arena_B, 21);
   Assert
     (Growth = DS.Dynamic.Completed and then U64_Value = 21,
      "dynamic vector did not continue after the third mapping");
   Dynamic_Strings.Try_Assign
     (Dynamic_String_C, Arena_C, String_More, Growth);
   declare
      Remapped_Dynamic : Ada.Streams.Stream_Element_Array (1 .. 5);
   begin
      Dynamic_Strings.Read (Dynamic_String_B, Arena_B, Remapped_Dynamic);
      Assert
        (Growth = DS.Dynamic.Completed and then Remapped_Dynamic = String_More,
         "dynamic byte string did not continue after the third mapping");
   end;
   Dynamic_Maps.Put
     (Dynamic_Map_C, Arena_C, 21, 210, Dynamic_Put);
   Dynamic_Maps.Get
     (Dynamic_Map_B, Arena_B, 21, U64_Value, Flag);
   Assert
     (Dynamic_Put = Dynamic_Maps.Put_Inserted
      and then Flag and then U64_Value = 210,
      "dynamic map did not continue after the third mapping");
   Dynamic_Maps.Remove
     (Dynamic_Map_B, Arena_B, 1, Flag);
   Assert
     (Flag and then Dynamic_Maps.Length (Dynamic_Map_C) = 20,
      "dynamic-map removal was not shared across mappings");
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

   Vectors.Try_Append (Vector_C, 3, Flag);
   Assert (Flag and then Vectors.Length (Vector_B) = 2,
           "vector did not continue after remap");
   SPSC.Try_Push (Ring_C, 77, Flag);
   SPSC.Try_Pop (Ring_B, U64_Value, Flag);
   Assert (Flag and then U64_Value = 77,
           "SPSC did not continue after remap");
   MPMC.Try_Push (Multi_C, 88, Push_Outcome);
   MPMC.Try_Pop (Multi_B, U64_Value, Pop_Outcome);
   Assert
     (Push_Outcome = MPMC.Pushed
      and then Pop_Outcome = MPMC.Popped
      and then U64_Value = 88,
      "MPMC did not continue after remap");

   SPSC.Poison (Region_B, SPSC_Location);
   Assert (SPSC.Is_Poisoned (Ring_C), "SPSC poison was not shared");
   declare
      Failed : Boolean := False;
   begin
      begin
         SPSC.Try_Push (Ring_C, 89, Flag);
      exception
         when DS.Poison_Error => Failed := True;
      end;
      Assert (Failed, "poisoned SPSC ring accepted an operation");
   end;
   SPSC.Initialize (Ring_C, Region_C, SPSC_Location, 16);
   SPSC.Try_Push (Ring_C, 90, Flag);
   declare
      Failed : Boolean := False;
   begin
      begin
         SPSC.Try_Pop (Ring_B, U64_Value, Flag);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "stale SPSC view revived after reinitialization");
   end;
   SPSC.Attach (Ring_B, Region_B, SPSC_Location, 16);
   SPSC.Try_Pop (Ring_B, U64_Value, Flag);
   Assert
     (Flag and then U64_Value = 90,
      "SPSC did not recover through exclusive reinitialization");

   MPMC.Poison (Region_B, MPMC_Location);
   Assert (MPMC.Is_Poisoned (Multi_C), "MPMC poison was not shared");
   declare
      Failed : Boolean := False;
   begin
      begin
         MPMC.Try_Push (Multi_C, 91, Push_Outcome);
      exception
         when DS.Poison_Error => Failed := True;
      end;
      Assert (Failed, "poisoned MPMC ring accepted an operation");
   end;
   MPMC.Initialize (Multi_C, Region_C, MPMC_Location, 16);
   MPMC.Try_Push (Multi_C, 92, Push_Outcome);
   declare
      Failed : Boolean := False;
   begin
      begin
         MPMC.Try_Pop (Multi_B, U64_Value, Pop_Outcome);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "stale MPMC view revived after reinitialization");
   end;
   MPMC.Attach (Multi_B, Region_B, MPMC_Location, 16);
   MPMC.Try_Pop (Multi_B, U64_Value, Pop_Outcome);
   Assert
     (Push_Outcome = MPMC.Pushed
      and then Pop_Outcome = MPMC.Popped
      and then U64_Value = 92,
      "MPMC did not recover through exclusive reinitialization");

   Maps.Put (Map_C, Decode (Key_2), Decode (Value_1), Put_Outcome);
   Maps.Get (Map_B, Decode (Key_2), U64_Value, Flag);
   Assert (Put_Outcome = Maps.Inserted and then Flag,
           "hash map did not continue after remap");
   Maps.Remove (Map_C, Decode (Key_1), Flag);
   Assert (Flag and then Maps.Length (Map_B) = 1,
      "hash-map removal failed across mappings");

   --  Simulate an owner that died after acquiring the stored mutation guard.
   --  A recovery authority operating through another mapping poisons the
   --  abandoned object without first attaching its mutable contents.
   Write_U32
     (Base_C, C.size_t (Map_Location) + C.size_t'(64),
      Interfaces.Unsigned_32'(1));
   declare
      Failed : Boolean := False;
   begin
      begin
         Maps.Put (Map_C, Decode (Key_1), Decode (Value_1), Put_Outcome);
      exception
         when DS.Busy_Error => Failed := True;
      end;
      Assert (Failed, "busy hash map did not fail without waiting");
      Failed := False;
      begin
         Maps.Put
           (Map_C, Decode (Key_1), Decode (Value_1), 0.0, Put_Outcome);
      exception
         when DS.Timeout_Error => Failed := True;
      end;
      Assert (Failed, "timed hash-map access ignored an owned guard");
   end;
   Maps.Poison (Region_B, Map_Location);
   Assert (Maps.Is_Poisoned (Map_C), "hash-map poison was not shared");
   declare
      Failed : Boolean := False;
   begin
      begin
         Maps.Get (Map_B, Decode (Key_2), U64_Value, Flag);
      exception
         when DS.Poison_Error => Failed := True;
      end;
      Assert (Failed, "poisoned hash map accepted an operation");
      Failed := False;
      begin
         Maps.Attach (Map_Bad, Region_B, Map_Location, 16);
      exception
         when DS.Poison_Error => Failed := True;
      end;
      Assert (Failed, "poisoned hash map attached as healthy");
   end;
   Maps.Initialize (Map_C, Region_C, Map_Location, 16);
   Maps.Put (Map_C, Decode (Key_1), Decode (Value_1), Put_Outcome);
   declare
      Failed : Boolean := False;
   begin
      begin
         Maps.Get (Map_B, Decode (Key_1), U64_Value, Flag);
      exception
         when DS.Layout_Error => Failed := True;
      end;
      Assert (Failed, "stale hash-map view revived after reinitialization");
   end;
   Maps.Attach (Map_B, Region_B, Map_Location, 16);
   Maps.Get (Map_B, Decode (Key_1), U64_Value, Flag);
   Assert
     (Put_Outcome = Maps.Inserted and then Flag and then U64_Value = 111,
      "exclusive hash-map reinitialization did not recover poison");

   Assert
     (Vectors.Read (Wrapped_C, 1) = 909,
           "versioned envelope did not survive third mapping");

   Slabs.Destroy (Slab_C);
   Dynamic_Maps.Destroy (Dynamic_Map_C, Arena_C);
   Dynamic_Strings.Destroy (Dynamic_String_C, Arena_C);
   Dynamic_Vectors.Destroy (Dynamic_Vector_C, Arena_C);
   Arenas.Destroy (Arena_C);
   Best_Fit_Dynamic_Vectors.Destroy (Best_Fit_Vector_C, Best_Fit_C);
   Best_Fit_Arenas.Destroy (Best_Fit_C);
   TLSF_Dynamic_Vectors.Destroy (TLSF_Vector_C, TLSF_C);
   Adaptive_U64.Destroy (Adaptive_C, TLSF_C);
   TLSF_Arenas.Destroy (TLSF_C);
   Strings.Destroy (String_C);
   Vectors.Destroy (Vector_C);
   SPSC.Destroy (Ring_C);
   MPMC.Destroy (Multi_C);
   Maps.Destroy (Map_C);
   Vectors.Destroy (Wrapped_C);
   Contract_V1.Destroy (Envelope_C);

   Slabs.Detach (Slab_B);
   Dynamic_Vectors.Detach (Dynamic_Vector_B);
   Dynamic_Strings.Detach (Dynamic_String_B);
   Dynamic_Maps.Detach (Dynamic_Map_B);
   Arenas.Detach (Arena_B);
   Best_Fit_Dynamic_Vectors.Detach (Best_Fit_Vector_B);
   Best_Fit_Arenas.Detach (Best_Fit_B);
   TLSF_Dynamic_Vectors.Detach (TLSF_Vector_B);
   Adaptive_U64.Detach (Adaptive_B);
   TLSF_Arenas.Detach (TLSF_B);
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
