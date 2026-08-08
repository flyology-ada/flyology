with Ada.Command_Line;
with Ada.Streams;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Byte_Strings;
with Flyology.Data_Structures.Regions;
with Flyology.Shared_Memory;
with Flyology.Shared_Memory.Segments;
with Flyology.Shared_Memory.Testing;
with Flyology.Shared_Memory.Unix_Sockets;
with Interfaces;
with Interfaces.C;

procedure Shared_Memory_Child is
   package DS renames Flyology.Data_Structures;
   package Regions renames DS.Regions;
   package Strings renames DS.Byte_Strings;
   package Shared renames Flyology.Shared_Memory;
   package Segments renames Shared.Segments;
   package Testing renames Shared.Testing;
   package Sockets renames Shared.Unix_Sockets;
   package C renames Interfaces.C;

   use type Ada.Streams.Stream_Element_Array;
   use type C.int;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Segments.Lookup_Result;
   use type Segments.Segment_Open_Result;

   Config : constant Segments.Configuration :=
     (Schema               => 16#5348_4152_4544_0001#,
      Registry_Capacity    => 16,
      Maximum_Name_Length  => 64,
      Allocation_Alignment => 64);

   function Reserve
     (Base, Length : C.unsigned_long_long) return C.int;
   pragma Import (C, Reserve, "flyology_test_reserve_mapping_base");
   function Release_Reserve
     (Base, Length : C.unsigned_long_long) return C.int;
   pragma Import
     (C, Release_Reserve, "flyology_test_release_reserved_base");

begin
   if Ada.Command_Line.Argument_Count = 0 then
      return;
   end if;
   declare
      Parent_Base : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64'Value (Ada.Command_Line.Argument (1));
      Length : constant Shared.Byte_Length :=
        Shared.Byte_Length'Value (Ada.Command_Line.Argument (2));
      Backing : Shared.Backing_Object;
      Map : Shared.Mapping;
      Segment : Segments.View;
      Region : Regions.View;
      Object : Strings.View;
      Segment_Result : Segments.Segment_Open_Result;
      Lookup : Segments.Lookup_Result;
      Handle : Segments.Named_Handle;
      Failure : Interfaces.Unsigned_32;
      Location : DS.Region_Offset;
      Extent : Shared.Byte_Length;
      Observed : Ada.Streams.Stream_Element_Array (1 .. 3);
      Replacement : constant Ada.Streams.Stream_Element_Array :=
        (1 => 16#49#, 2 => 16#50#, 3 => 16#43#);
      Ignored : C.int;
      Reservation : C.int;
   begin
      Reservation := Reserve
        (C.unsigned_long_long (Parent_Base), C.unsigned_long_long (Length));
      if Reservation < 0 then
         raise Program_Error with
           "child could not reserve parent mapping base";
      end if;
      Sockets.Receive (3, Length, Backing);
      Shared.Map (Map, Backing);
      Shared.Close (Backing);
      if Testing.Base_Value (Map) = Parent_Base then
         raise Program_Error with
           "child mapping reused parent virtual address";
      end if;
      Segments.Create_Or_Attach (Segment, Map, Config, Segment_Result);
      if Segment_Result /= Segments.Attached_Existing then
         raise Program_Error with
           "received mapping did not attach ready segment";
      end if;
      Segments.Attach_Region (Segment, Region);
      loop
         Segments.Try_Find
           (Segment, "handoff", Handle, Lookup, Failure);
         exit when Lookup /= Segments.Registry_Busy;
         delay 0.0;
      end loop;
      if Lookup /= Segments.Found or else Failure /= 0 then
         raise Program_Error with "child did not find handoff extent";
      end if;
      Segments.Resolve (Segment, Handle, Location, Extent);
      Strings.Attach (Object, Region, Location, 16);
      Strings.Read (Object, Observed);
      if Observed /= Ada.Streams.Stream_Element_Array'(16#46#, 16#6C#, 16#79#)
      then
         raise Program_Error with "child observed wrong relocatable payload";
      end if;
      Strings.Assign (Object, Replacement);
      Strings.Detach (Object);
      Regions.Detach (Region);
      Segments.Detach (Segment);
      Shared.Unmap (Map);
      if Reservation = 0 then
         Ignored := Release_Reserve
           (C.unsigned_long_long (Parent_Base), C.unsigned_long_long (Length));
         if Ignored /= 0 then
            raise Program_Error with "child could not release reserved base";
         end if;
      end if;
   end;
end Shared_Memory_Child;
