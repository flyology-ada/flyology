with Ada.Streams;
with Ada.Text_IO;
with Flyology.Adaptive_Pool_Testing;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Allocation_Algorithms.Buddy;
with Flyology.Data_Structures.Allocation_Pools.Adaptive;
with Flyology.Data_Structures.Arenas;
with Flyology.Data_Structures.Dynamic.Byte_Strings;
with Flyology.Data_Structures.Dynamic.Hash_Maps;
with Flyology.Data_Structures.Dynamic.Vectors;
with Flyology.Data_Structures.Regions;
with Flyology.Data_Structures.Storage_Types.Unsigned_64s;
with Flyology.Dynamic_Destroy_Testing;
with Interfaces;
with Interfaces.C;
with System;
with System.Storage_Elements;

procedure Data_Structures_Destroy_Contention_Smoke is
   package DS renames Flyology.Data_Structures;
   package Regions renames DS.Regions;
   package Arenas is new
     DS.Arenas (Algorithm => DS.Allocation_Algorithms.Buddy);
   package U64_Elements renames DS.Storage_Types.Unsigned_64s;
   package Adaptive is new
     DS.Allocation_Pools.Adaptive
       (Arena_Provider  => Arenas,
        Element         => U64_Elements.Element,
        Slots_Per_Chunk => 2,
        Maximum_Chunks  => 2);
   package Dynamic_Vectors is new
     DS.Dynamic.Vectors
       (Arena_Provider => Arenas,
        Element        => U64_Elements.Element);
   package Dynamic_Strings is new
     DS.Dynamic.Byte_Strings (Arena_Provider => Arenas);
   package Dynamic_Maps is new
     DS.Dynamic.Hash_Maps
       (Arena_Provider => Arenas,
        Key            => U64_Elements.Element,
        Element        => U64_Elements.Element);
   package C renames Interfaces.C;
   package SSE renames System.Storage_Elements;

   use type Arenas.Allocation_Result;
   use type Adaptive.Allocation_Result;
   use type C.size_t;
   use type DS.Byte_Count;
   use type DS.Dynamic.Growth_Result;
   use type Dynamic_Maps.Put_Result;
   use type Interfaces.Unsigned_64;

   Configuration : constant Arenas.Configuration :=
     (Usable_Capacity => 65_536, Minimum_Block_Size => 64);

   --  Dynamic Byte_Strings layout v2 and Dynamic Vectors/Hash_Maps layout v3
   --  all place the deferred arena handle at byte 88. This test writes that
   --  otherwise unobservable, valid intermediate state to exercise the exact
   --  second-release boundary; a layout-version change must update the fixture.
   Dynamic_Retired_Token_Offset      : constant C.size_t :=
     C.size_t (196_608 + 88);
   Dynamic_Retired_Generation_Offset : constant C.size_t :=
     Dynamic_Retired_Token_Offset + 8;

   function Read_U64
     (Base : System.Address; Offset : C.size_t) return Interfaces.Unsigned_64;
   pragma Import (C, Read_U64, "flyology_test_mapping_read_u64");

   procedure Write_U64
     (Base   : System.Address;
      Offset : C.size_t;
      Value  : Interfaces.Unsigned_64);
   pragma Import (C, Write_U64, "flyology_test_mapping_write_u64");

   procedure Assert (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Assert;

   procedure Assert_Reclaimed
     (Arena : Arenas.View; Handle : Arenas.Allocation_Handle; Message : String)
   is
   begin
      declare
         Capacity : constant DS.Byte_Count := Arenas.Block_Capacity (Arena, Handle);
         pragma Unreferenced (Capacity);
      begin
         raise Program_Error with Message;
      end;
   exception
      when DS.Handle_Error =>
         null;
   end Assert_Reclaimed;

   procedure Reproduce_Adaptive_Contention is
      Storage     : aliased SSE.Storage_Array (1 .. 262_144) := [others => 0]
      with Alignment => 64;
      Region      : Regions.View;
      Arena       : aliased Arenas.View;
      Other_Arena : aliased Arenas.View;
      Pool        : Adaptive.View;
      Other_Pool  : Adaptive.View;
      Handles     : array (1 .. 3) of Adaptive.Handle;
      Result      : Adaptive.Allocation_Result;
      Contended   : Boolean := False;
   begin
      Regions.Attach (Region, Storage'Address, DS.Byte_Count (Storage'Length));
      Arenas.Initialize
        (Arena, Region, 64, Configuration, 16#A162_A162_A162_A162#);
      Arenas.Attach
        (Other_Arena, Region, 64, Configuration, 16#A162_A162_A162_A162#);
      Adaptive.Initialize (Pool, Region, 196_608, Arena);
      for Index in Handles'Range loop
         Adaptive.Try_Allocate
           (Pool,
            Arena,
            Interfaces.Unsigned_64 (Index),
            Handles (Index),
            Result);
         Assert
           (Result = Adaptive.Allocated,
            "adaptive contention fixture allocation failed");
      end loop;
      for Handle of Handles loop
         Adaptive.Release (Pool, Arena, Handle);
      end loop;
      Flyology.Adaptive_Pool_Testing.Reset;
      Flyology.Adaptive_Pool_Testing.Arm_Release_Contention
        (After_Releases => 1);
      begin
         Adaptive.Destroy (Pool, Arena);
      exception
         when DS.Busy_Error =>
            Contended := True;
      end;
      Assert
        (Contended,
         "adaptive destroy did not report injected arena contention");
      Adaptive.Attach (Other_Pool, Region, 196_608, Other_Arena);
      Adaptive.Detach (Other_Pool);
      Adaptive.Destroy (Pool, Arena);
      Arenas.Detach (Other_Arena);
      Arenas.Destroy (Arena);
      Regions.Detach (Region);
   end Reproduce_Adaptive_Contention;

   procedure Reproduce_Dynamic_Contention is
      Storage      : aliased SSE.Storage_Array (1 .. 262_144) := [others => 0]
      with Alignment => 64;
      Region       : Regions.View;
      Arena        : aliased Arenas.View;
      Other_Arena  : aliased Arenas.View;
      Item         : Dynamic_Vectors.View;
      Other_Item   : Dynamic_Vectors.View;
      Result       : DS.Dynamic.Growth_Result;
      Retired      : Arenas.Allocation_Handle;
      Arena_Result : Arenas.Allocation_Result;
      Contended    : Boolean := False;
   begin
      Regions.Attach (Region, Storage'Address, DS.Byte_Count (Storage'Length));
      Arenas.Initialize
        (Arena, Region, 64, Configuration, 16#A163_A163_A163_A163#);
      Arenas.Attach
        (Other_Arena, Region, 64, Configuration, 16#A163_A163_A163_A163#);
      Dynamic_Vectors.Initialize (Item, Region, 196_608, Arena, 1);
      for Value in Interfaces.Unsigned_64 range 1 .. 4 loop
         Dynamic_Vectors.Try_Append (Item, Arena, Value, Result);
         Assert
           (Result = DS.Dynamic.Completed,
            "dynamic contention fixture growth failed");
      end loop;
      Arenas.Try_Allocate (Arena, 64, Retired, Arena_Result);
      Assert
        (Arena_Result = Arenas.Allocated,
         "dynamic fixture retired allocation failed");
      Write_U64 (Storage'Address, Dynamic_Retired_Token_Offset, Retired.Token);
      Write_U64
        (Storage'Address,
         Dynamic_Retired_Generation_Offset,
         Retired.Generation);
      Assert
        (Read_U64 (Storage'Address, Dynamic_Retired_Generation_Offset)
         = Retired.Generation,
         "dynamic fixture did not install a live retired allocation");
      Flyology.Dynamic_Destroy_Testing.Reset;
      Flyology.Dynamic_Destroy_Testing.Arm_Current_Release_Contention;
      begin
         Dynamic_Vectors.Destroy (Item, Arena);
      exception
         when DS.Busy_Error =>
            Contended := True;
      end;
      Assert
        (Contended,
         "dynamic destroy did not report injected arena contention");
      Assert
        (Read_U64 (Storage'Address, Dynamic_Retired_Generation_Offset) = 0,
         "dynamic destroy did not release its retired allocation before contention");
      Dynamic_Vectors.Attach (Other_Item, Region, 196_608, Other_Arena, 1);
      Assert
        (Dynamic_Vectors.Length (Other_Item) = 4,
         "contended dynamic destroy changed its payload");
      Dynamic_Vectors.Detach (Other_Item);
      Dynamic_Vectors.Destroy (Item, Arena);
      Arenas.Detach (Other_Arena);
      Arenas.Destroy (Arena);
      Regions.Detach (Region);
   end Reproduce_Dynamic_Contention;

   procedure Reproduce_Dynamic_String_Contention is
      Storage      : aliased SSE.Storage_Array (1 .. 262_144) := [others => 0]
      with Alignment => 64;
      Region       : Regions.View;
      Arena        : aliased Arenas.View;
      Other_Arena  : aliased Arenas.View;
      Item         : Dynamic_Strings.View;
      Other_Item   : Dynamic_Strings.View;
      Result       : DS.Dynamic.Growth_Result;
      Retired      : Arenas.Allocation_Handle;
      Arena_Result : Arenas.Allocation_Result;
      Contended    : Boolean := False;
      Data         : constant Ada.Streams.Stream_Element_Array := [1, 2, 3, 4];
   begin
      Regions.Attach (Region, Storage'Address, DS.Byte_Count (Storage'Length));
      Arenas.Initialize
        (Arena, Region, 64, Configuration, 16#A163_A163_A163_B163#);
      Arenas.Attach
        (Other_Arena, Region, 64, Configuration, 16#A163_A163_A163_B163#);
      Dynamic_Strings.Initialize (Item, Region, 196_608, Arena, 1);
      Dynamic_Strings.Try_Append (Item, Arena, Data, Result);
      Assert
        (Result = DS.Dynamic.Completed,
         "dynamic-string contention fixture growth failed");
      Arenas.Try_Allocate (Arena, 64, Retired, Arena_Result);
      Assert
        (Arena_Result = Arenas.Allocated,
         "dynamic-string fixture retired allocation failed");
      Write_U64 (Storage'Address, Dynamic_Retired_Token_Offset, Retired.Token);
      Write_U64
        (Storage'Address,
         Dynamic_Retired_Generation_Offset,
         Retired.Generation);
      Flyology.Dynamic_Destroy_Testing.Reset;
      Flyology.Dynamic_Destroy_Testing.Arm_Current_Release_Contention;
      begin
         Dynamic_Strings.Destroy (Item, Arena);
      exception
         when DS.Busy_Error =>
            Contended := True;
      end;
      Assert
        (Contended,
         "dynamic-string destroy did not report injected arena contention");
      Assert
        (Read_U64 (Storage'Address, Dynamic_Retired_Generation_Offset) = 0,
         "dynamic-string destroy did not clear its released retired allocation");
      Dynamic_Strings.Attach (Other_Item, Region, 196_608, Other_Arena, 1);
      Assert
        (Dynamic_Strings.Length (Other_Item) = 4,
         "contended dynamic-string destroy changed its payload");
      Dynamic_Strings.Detach (Other_Item);
      Dynamic_Strings.Destroy (Item, Arena);
      Arenas.Detach (Other_Arena);
      Arenas.Destroy (Arena);
      Regions.Detach (Region);
   end Reproduce_Dynamic_String_Contention;

   procedure Reproduce_Dynamic_Map_Contention is
      Storage      : aliased SSE.Storage_Array (1 .. 262_144) := [others => 0]
      with Alignment => 64;
      Region       : Regions.View;
      Arena        : aliased Arenas.View;
      Other_Arena  : aliased Arenas.View;
      Item         : Dynamic_Maps.View;
      Other_Item   : Dynamic_Maps.View;
      Result       : Dynamic_Maps.Put_Result;
      Retired      : Arenas.Allocation_Handle;
      Arena_Result : Arenas.Allocation_Result;
      Contended    : Boolean := False;
   begin
      Regions.Attach (Region, Storage'Address, DS.Byte_Count (Storage'Length));
      Arenas.Initialize
        (Arena, Region, 64, Configuration, 16#A163_A163_A163_C163#);
      Arenas.Attach
        (Other_Arena, Region, 64, Configuration, 16#A163_A163_A163_C163#);
      Dynamic_Maps.Initialize (Item, Region, 196_608, Arena, 2);
      for Value in Interfaces.Unsigned_64 range 1 .. 4 loop
         Dynamic_Maps.Put (Item, Arena, Value, Value * 10, Result);
         Assert
           (Result = Dynamic_Maps.Put_Inserted,
            "dynamic-map contention fixture growth failed");
      end loop;
      Arenas.Try_Allocate (Arena, 64, Retired, Arena_Result);
      Assert
        (Arena_Result = Arenas.Allocated,
         "dynamic-map fixture retired allocation failed");
      Write_U64 (Storage'Address, Dynamic_Retired_Token_Offset, Retired.Token);
      Write_U64
        (Storage'Address,
         Dynamic_Retired_Generation_Offset,
         Retired.Generation);
      Flyology.Dynamic_Destroy_Testing.Reset;
      Flyology.Dynamic_Destroy_Testing.Arm_Current_Release_Contention;
      begin
         Dynamic_Maps.Destroy (Item, Arena);
      exception
         when DS.Busy_Error =>
            Contended := True;
      end;
      Assert
        (Contended,
         "dynamic-map destroy did not report injected arena contention");
      Assert
        (Read_U64 (Storage'Address, Dynamic_Retired_Generation_Offset) = 0,
         "dynamic-map destroy did not clear its released retired allocation");
      Dynamic_Maps.Attach (Other_Item, Region, 196_608, Other_Arena, 2);
      Assert
        (Dynamic_Maps.Length (Other_Item) = 4,
         "contended dynamic-map destroy changed its payload");
      Dynamic_Maps.Detach (Other_Item);
      Dynamic_Maps.Destroy (Item, Arena);
      Arenas.Detach (Other_Arena);
      Arenas.Destroy (Arena);
      Regions.Detach (Region);
   end Reproduce_Dynamic_Map_Contention;

   procedure Reclaim_Dynamic_Vector is
      Storage : aliased SSE.Storage_Array (1 .. 262_144) := [others => 0]
      with Alignment => 64;
      Region  : Regions.View;
      Arena   : Arenas.View;
      Item    : Dynamic_Vectors.View;
      Result  : DS.Dynamic.Growth_Result;
      Retired : Arenas.Allocation_Handle;
      Initial_Capacity : Natural;
   begin
      Regions.Attach (Region, Storage'Address, DS.Byte_Count (Storage'Length));
      Arenas.Initialize (Arena, Region, 64, Configuration, 16#A166_A166_A166_A166#);
      Dynamic_Vectors.Initialize (Item, Region, 196_608, Arena, 1);
      Flyology.Dynamic_Destroy_Testing.Reset;
      Flyology.Dynamic_Destroy_Testing.Arm_Retired_Release_Contention;
      Dynamic_Vectors.Try_Append (Item, Arena, 1, Result);
      Assert (Result = DS.Dynamic.Completed, "dynamic-vector initial append failed");
      Initial_Capacity := Dynamic_Vectors.Capacity (Item);
      for Index in 2 .. Initial_Capacity loop
         Dynamic_Vectors.Try_Append (Item, Arena, Interfaces.Unsigned_64 (Index), Result);
         Assert (Result = DS.Dynamic.Completed, "dynamic-vector fill failed");
      end loop;
      Dynamic_Vectors.Try_Append (Item, Arena, 100, Result);
      Assert (Result = DS.Dynamic.Completed, "dynamic-vector growth failed");
      Retired :=
        (Token      => Read_U64 (Storage'Address, Dynamic_Retired_Token_Offset),
         Generation => Read_U64 (Storage'Address, Dynamic_Retired_Generation_Offset));
      Assert (Retired.Generation /= 0, "dynamic-vector failed release lost its handle");
      Assert (Arenas.Block_Capacity (Arena, Retired) /= 0, "dynamic-vector retired block is not live");
      Flyology.Dynamic_Destroy_Testing.Arm_Retired_Release_Contention;
      Dynamic_Vectors.Try_Append (Item, Arena, 101, Result);
      Assert (Result = DS.Dynamic.Completed, "dynamic-vector busy retry changed append result");
      Assert
        (Read_U64 (Storage'Address, Dynamic_Retired_Generation_Offset) = Retired.Generation,
         "dynamic-vector busy retry lost its handle");
      Dynamic_Vectors.Try_Append (Item, Arena, 102, Result);
      Assert (Result = DS.Dynamic.Completed, "dynamic-vector reclaim append failed");
      Assert
        (Read_U64 (Storage'Address, Dynamic_Retired_Generation_Offset) = 0,
         "dynamic-vector append did not reclaim retired block");
      Assert_Reclaimed (Arena, Retired, "dynamic-vector retired allocation remains live");
      Assert
        (Dynamic_Vectors.Length (Item) = Initial_Capacity + 3,
         "dynamic-vector cleanup changed contents");
      Dynamic_Vectors.Destroy (Item, Arena);
      Arenas.Destroy (Arena);
      Regions.Detach (Region);
   end Reclaim_Dynamic_Vector;

   procedure Reclaim_Dynamic_String is
      Storage : aliased SSE.Storage_Array (1 .. 262_144) := [others => 0]
      with Alignment => 64;
      Region  : Regions.View;
      Arena   : Arenas.View;
      Item    : Dynamic_Strings.View;
      Result  : DS.Dynamic.Growth_Result;
      Retired : Arenas.Allocation_Handle;
      One     : constant Ada.Streams.Stream_Element_Array := [1];
   begin
      Regions.Attach (Region, Storage'Address, DS.Byte_Count (Storage'Length));
      Arenas.Initialize (Arena, Region, 64, Configuration, 16#A166_A166_A166_B166#);
      Dynamic_Strings.Initialize (Item, Region, 196_608, Arena, 1);
      Flyology.Dynamic_Destroy_Testing.Reset;
      Flyology.Dynamic_Destroy_Testing.Arm_Retired_Release_Contention;
      Dynamic_Strings.Try_Append (Item, Arena, One, Result);
      Assert (Result = DS.Dynamic.Completed, "dynamic-string initial append failed");
      declare
         Full :
           constant Ada.Streams.Stream_Element_Array
                      (1 .. Ada.Streams.Stream_Element_Offset (Dynamic_Strings.Capacity (Item))) :=
             [others => 7];
      begin
         Dynamic_Strings.Try_Assign (Item, Arena, Full, Result);
      end;
      Assert (Result = DS.Dynamic.Completed, "dynamic-string fill failed");
      Dynamic_Strings.Try_Append (Item, Arena, One, Result);
      Assert (Result = DS.Dynamic.Completed, "dynamic-string growth failed");
      Retired :=
        (Token      => Read_U64 (Storage'Address, Dynamic_Retired_Token_Offset),
         Generation => Read_U64 (Storage'Address, Dynamic_Retired_Generation_Offset));
      Assert (Retired.Generation /= 0, "dynamic-string failed release lost its handle");
      Assert (Arenas.Block_Capacity (Arena, Retired) /= 0, "dynamic-string retired block is not live");
      Flyology.Dynamic_Destroy_Testing.Arm_Retired_Release_Contention;
      Dynamic_Strings.Try_Assign (Item, Arena, One, Result);
      Assert (Result = DS.Dynamic.Completed, "dynamic-string busy retry changed assign result");
      Assert
        (Read_U64 (Storage'Address, Dynamic_Retired_Generation_Offset) = Retired.Generation,
         "dynamic-string busy retry lost its handle");
      Dynamic_Strings.Try_Append (Item, Arena, One, Result);
      Assert (Result = DS.Dynamic.Completed, "dynamic-string reclaim append failed");
      Assert
        (Read_U64 (Storage'Address, Dynamic_Retired_Generation_Offset) = 0,
         "dynamic-string append did not reclaim retired block");
      Assert_Reclaimed (Arena, Retired, "dynamic-string retired allocation remains live");
      Assert (Dynamic_Strings.Length (Item) = 2, "dynamic-string cleanup changed contents");
      Dynamic_Strings.Destroy (Item, Arena);
      Arenas.Destroy (Arena);
      Regions.Detach (Region);
   end Reclaim_Dynamic_String;

   procedure Reclaim_Dynamic_Map is
      Storage          : aliased SSE.Storage_Array (1 .. 262_144) := [others => 0]
      with Alignment => 64;
      Region           : Regions.View;
      Arena            : Arenas.View;
      Item             : Dynamic_Maps.View;
      Result           : Dynamic_Maps.Put_Result;
      Retired          : Arenas.Allocation_Handle;
      Initial_Capacity : Natural;
      Growth_Key       : Interfaces.Unsigned_64;
   begin
      Regions.Attach (Region, Storage'Address, DS.Byte_Count (Storage'Length));
      Arenas.Initialize (Arena, Region, 64, Configuration, 16#A166_A166_A166_C166#);
      Dynamic_Maps.Initialize (Item, Region, 196_608, Arena, 8);
      Flyology.Dynamic_Destroy_Testing.Reset;
      Flyology.Dynamic_Destroy_Testing.Arm_Retired_Release_Contention;
      Dynamic_Maps.Put (Item, Arena, 1, 10, Result);
      Assert (Result = Dynamic_Maps.Put_Inserted, "dynamic-map initial put failed");
      Initial_Capacity := Dynamic_Maps.Capacity (Item);
      Growth_Key := Interfaces.Unsigned_64 (Initial_Capacity * 3 / 4 + 1);
      for Index in Interfaces.Unsigned_64 range 2 .. Growth_Key loop
         Dynamic_Maps.Put (Item, Arena, Index, Index * 10, Result);
         Assert (Result = Dynamic_Maps.Put_Inserted, "dynamic-map fill or growth failed");
      end loop;
      Assert (Dynamic_Maps.Capacity (Item) > Initial_Capacity, "dynamic-map did not grow");
      Retired :=
        (Token      => Read_U64 (Storage'Address, Dynamic_Retired_Token_Offset),
         Generation => Read_U64 (Storage'Address, Dynamic_Retired_Generation_Offset));
      Assert (Retired.Generation /= 0, "dynamic-map failed release lost its handle");
      Assert (Arenas.Block_Capacity (Arena, Retired) /= 0, "dynamic-map retired block is not live");
      Flyology.Dynamic_Destroy_Testing.Arm_Retired_Release_Contention;
      Dynamic_Maps.Put (Item, Arena, Growth_Key + 1, 20, Result);
      Assert (Result = Dynamic_Maps.Put_Inserted, "dynamic-map busy retry changed put result");
      Assert
        (Read_U64 (Storage'Address, Dynamic_Retired_Generation_Offset) = Retired.Generation,
         "dynamic-map busy retry lost its handle");
      Dynamic_Maps.Put (Item, Arena, Growth_Key + 2, 30, Result);
      Assert (Result = Dynamic_Maps.Put_Inserted, "dynamic-map reclaim put failed");
      Assert
        (Read_U64 (Storage'Address, Dynamic_Retired_Generation_Offset) = 0,
         "dynamic-map put did not reclaim retired block");
      Assert_Reclaimed (Arena, Retired, "dynamic-map retired allocation remains live");
      Assert (Dynamic_Maps.Length (Item) = Natural (Growth_Key + 2), "dynamic-map cleanup changed contents");
      Dynamic_Maps.Destroy (Item, Arena);
      Arenas.Destroy (Arena);
      Regions.Detach (Region);
   end Reclaim_Dynamic_Map;

begin
   Reproduce_Adaptive_Contention;
   Ada.Text_IO.Put_Line ("issue 162 regression passed");
   Reproduce_Dynamic_Contention;
   Reproduce_Dynamic_String_Contention;
   Reproduce_Dynamic_Map_Contention;
   Ada.Text_IO.Put_Line ("issue 163 regression passed");
   Reclaim_Dynamic_Vector;
   Reclaim_Dynamic_String;
   Reclaim_Dynamic_Map;
   Ada.Text_IO.Put_Line ("issue 166 regression passed");
end Data_Structures_Destroy_Contention_Smoke;
