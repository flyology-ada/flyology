with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Byte_Strings;
with Flyology.Data_Structures.Hash_Maps;
with Flyology.Data_Structures.Handles;
with Flyology.Data_Structures.Regions;
with Flyology.Data_Structures.Rings.MPMC;
with Flyology.Data_Structures.Rings.SPSC;
with Flyology.Data_Structures.Slab_Pools;
with Flyology.Data_Structures.Vectors;
with Interfaces;
with Interfaces.C;
with System;

procedure Data_Structures_Concurrency_Smoke is
   package DS renames Flyology.Data_Structures;
   package Byte_Strings renames DS.Byte_Strings;
   package Hash_Maps renames DS.Hash_Maps;
   package Handles renames DS.Handles;
   package Regions renames DS.Regions;
   package SPSC renames DS.Rings.SPSC;
   package MPMC renames DS.Rings.MPMC;
   package Slabs renames DS.Slab_Pools;
   package Vectors renames DS.Vectors;
   package C renames Interfaces.C;

   use type C.int;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_64;
   use type Hash_Maps.Put_Result;
   use type MPMC.Pop_Result;
   use type MPMC.Push_Result;
   use type Slabs.Allocation_Result;
   use type System.Address;

   function Argument
     (Position : Positive; Default : Positive) return Positive is
     (if Ada.Command_Line.Argument_Count >= Position
      then Positive'Value (Ada.Command_Line.Argument (Position))
      else Default);

   SPSC_Iterations : constant Positive := Argument (1, 250_000);
   MPMC_Per_Producer : constant Positive := Argument (2, 25_000);
   Mapping_Length : constant C.size_t := 1_048_576;
   SPSC_Location : constant DS.Region_Offset := 64;
   MPMC_Location : constant DS.Region_Offset := 131_072;
   Slab_Location : constant DS.Region_Offset := 400_000;
   Vector_Location : constant DS.Region_Offset := 524_288;
   String_Location : constant DS.Region_Offset := 700_000;
   Map_Location : constant DS.Region_Offset := 786_432;

   function Mapping_Create
     (Path   : C.char_array;
      Length : C.size_t;
      First  : access System.Address;
      Second : access System.Address;
      FD     : access C.int) return C.int;
   pragma Import
     (C, Mapping_Create, "flyology_test_mapping_create");

   function Unmap
     (Address : System.Address; Length : C.size_t) return C.int;
   pragma Import (C, Unmap, "flyology_test_mapping_unmap");

   function Close_Mapping
     (Path : C.char_array; FD : C.int) return C.int;
   pragma Import (C, Close_Mapping, "flyology_test_mapping_close");

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
      Work : Interfaces.Unsigned_64 := Value;
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

   protected type Completion (Expected : Positive) is
      procedure Done (Success : Boolean);
      entry Await_All;
      function Passed return Boolean;
      function Completed return Natural;
   private
      Count : Natural := 0;
      All_OK : Boolean := True;
   end Completion;

   protected body Completion is
      procedure Done (Success : Boolean) is
      begin
         Count := Count + 1;
         All_OK := All_OK and Success;
      end Done;

      entry Await_All when Count = Expected is
      begin
         null;
      end Await_All;

      function Passed return Boolean is (All_OK);

      function Completed return Natural is (Count);
   end Completion;

   Temp_Root : constant String := Ada.Environment_Variables.Value
     ("FLYOLOGY_TEST_TEMP_ROOT", "/tmp");
   Path : constant C.char_array := C.To_C
     (Temp_Root & "/data-structures-concurrency.map");
   Base_A : aliased System.Address := System.Null_Address;
   Base_B : aliased System.Address := System.Null_Address;
   FD     : aliased C.int := -1;
   Region_A, Region_B : Regions.View;

   procedure Cleanup is
      Ignored : C.int;
   begin
      Ignored := Unmap (Base_A, Mapping_Length);
      Ignored := Unmap (Base_B, Mapping_Length);
      if FD >= 0 then
         Ignored := Close_Mapping (Path, FD);
      end if;
   end Cleanup;

   procedure Run_SPSC is
      Producer_View, Consumer_View : aliased SPSC.View;
      Finished : Completion (2);

      task Producer is
         pragma Task_Info (Flyology.Native_Task);
         entry Start;
      end Producer;

      task Consumer is
         pragma Task_Info (Flyology.Native_Task);
         entry Start;
      end Consumer;

      task body Producer is
         Pushed : Boolean;
      begin
         accept Start;
         for Value in Interfaces.Unsigned_64 range
           1 .. Interfaces.Unsigned_64 (SPSC_Iterations)
         loop
            loop
               SPSC.Try_Push (Producer_View, Encode (Value), Pushed);
               exit when Pushed;
               delay 0.0;
            end loop;
         end loop;
         Finished.Done (True);
      exception
         when others => Finished.Done (False);
      end Producer;

      task body Consumer is
         Data : Ada.Streams.Stream_Element_Array (1 .. 8);
         Popped : Boolean;
      begin
         accept Start;
         for Expected in Interfaces.Unsigned_64 range
           1 .. Interfaces.Unsigned_64 (SPSC_Iterations)
         loop
            loop
               SPSC.Try_Pop (Consumer_View, Data, Popped);
               exit when Popped;
               delay 0.0;
            end loop;
            if Decode (Data) /= Expected then
               raise Program_Error with "SPSC sequence mismatch";
            end if;
         end loop;
         Finished.Done (True);
      exception
         when others => Finished.Done (False);
      end Consumer;
   begin
      SPSC.Initialize
        (Producer_View, Region_A, SPSC_Location, 1_024, 8);
      SPSC.Attach
        (Consumer_View, Region_B, SPSC_Location, 1_024, 8);
      Producer.Start;
      Consumer.Start;
      select
         Finished.Await_All;
      or
         delay 15.0;
         abort Producer;
         abort Consumer;
         raise Program_Error with "SPSC native-task test timed out";
      end select;
      Assert (Finished.Passed, "SPSC native-task sequence test failed");
      declare
         Data : Ada.Streams.Stream_Element_Array (1 .. 8);
         Popped : Boolean;
      begin
         SPSC.Try_Pop (Consumer_View, Data, Popped);
         Assert (not Popped, "SPSC retained a duplicate element");
      end;
      SPSC.Destroy (Producer_View);
      SPSC.Detach (Consumer_View);
   end Run_SPSC;

   Producer_Count : constant Positive := 4;
   Consumer_Count : constant Positive := 4;
   Total_MPMC : constant Positive := Producer_Count * MPMC_Per_Producer;
   type Seen_Array is array (Positive range <>) of Boolean;

   protected type Scoreboard
     (Expected, Task_Count : Positive)
   is
      procedure Observe (Value : Interfaces.Unsigned_64);
      procedure Done (Success : Boolean);
      function Complete return Boolean;
      entry Await_Tasks;
      function Passed return Boolean;
   private
      Seen : Seen_Array (1 .. Expected) := (others => False);
      Observed : Natural := 0;
      Finished : Natural := 0;
      All_OK : Boolean := True;
   end Scoreboard;

   protected body Scoreboard is
      procedure Observe (Value : Interfaces.Unsigned_64) is
      begin
         if Value = 0 or else Value > Interfaces.Unsigned_64 (Expected) then
            All_OK := False;
         elsif Seen (Positive (Value)) then
            All_OK := False;
         else
            Seen (Positive (Value)) := True;
            Observed := Observed + 1;
         end if;
      end Observe;

      procedure Done (Success : Boolean) is
      begin
         Finished := Finished + 1;
         All_OK := All_OK and Success;
      end Done;

      function Complete return Boolean is (Observed = Expected);

      entry Await_Tasks when Finished = Task_Count is
      begin
         null;
      end Await_Tasks;

      function Passed return Boolean is
        (All_OK and then Observed = Expected);
   end Scoreboard;

   procedure Run_MPMC is
      type View_Array is array (Positive range <>) of aliased MPMC.View;
      Producer_Views : View_Array (1 .. Producer_Count);
      Consumer_Views : View_Array (1 .. Consumer_Count);
      Results : Scoreboard
        (Expected => Total_MPMC,
         Task_Count => Producer_Count + Consumer_Count);
      type View_Access is access all MPMC.View;

      task type Producer_Task
        (Identifier : Positive; Ring : not null View_Access)
      is
         pragma Task_Info (Flyology.Native_Task);
      end Producer_Task;

      task type Consumer_Task (Ring : not null View_Access) is
         pragma Task_Info (Flyology.Native_Task);
      end Consumer_Task;

      task body Producer_Task is
         Outcome : MPMC.Push_Result;
         Value : Interfaces.Unsigned_64;
      begin
         for Sequence in 1 .. MPMC_Per_Producer loop
            Value := Interfaces.Unsigned_64
              ((Identifier - 1) * MPMC_Per_Producer + Sequence);
            loop
               MPMC.Try_Push (Ring.all, Encode (Value), Outcome);
               exit when Outcome = MPMC.Pushed;
               delay 0.0;
            end loop;
         end loop;
         Results.Done (True);
      exception
         when others => Results.Done (False);
      end Producer_Task;

      task body Consumer_Task is
         Outcome : MPMC.Pop_Result;
         Data : Ada.Streams.Stream_Element_Array (1 .. 8);
      begin
         loop
            MPMC.Try_Pop (Ring.all, Data, Outcome);
            if Outcome = MPMC.Popped then
               Results.Observe (Decode (Data));
            elsif Results.Complete then
               exit;
            else
               delay 0.0;
            end if;
         end loop;
         Results.Done (True);
      exception
         when others => Results.Done (False);
      end Consumer_Task;

      type Producer_Access is access Producer_Task;
      type Consumer_Access is access Consumer_Task;
      type Producer_Array is array (Positive range <>) of Producer_Access;
      type Consumer_Array is array (Positive range <>) of Consumer_Access;
      Producers : Producer_Array (1 .. Producer_Count);
      Consumers : Consumer_Array (1 .. Consumer_Count);
   begin
      MPMC.Initialize
        (Producer_Views (1), Region_A, MPMC_Location, 1_024, 8);
      for Index in 2 .. Producer_Count loop
         MPMC.Attach
           (Producer_Views (Index), Region_A, MPMC_Location, 1_024, 8);
      end loop;
      for Index in Consumer_Views'Range loop
         MPMC.Attach
           (Consumer_Views (Index), Region_B, MPMC_Location, 1_024, 8);
      end loop;
      for Index in Producers'Range loop
         Producers (Index) := new Producer_Task
           (Index, Producer_Views (Index)'Access);
      end loop;
      for Index in Consumers'Range loop
         Consumers (Index) := new Consumer_Task
           (Consumer_Views (Index)'Access);
      end loop;
      select
         Results.Await_Tasks;
      or
         delay 20.0;
         for Worker of Producers loop
            abort Worker.all;
         end loop;
         for Worker of Consumers loop
            abort Worker.all;
         end loop;
         raise Program_Error with "MPMC native-task test timed out";
      end select;
      Assert (Results.Passed, "MPMC duplicate/loss test failed");
      MPMC.Destroy (Producer_Views (1));
      for Index in 2 .. Producer_Count loop
         MPMC.Detach (Producer_Views (Index));
      end loop;
      for Index in Consumer_Views'Range loop
         MPMC.Detach (Consumer_Views (Index));
      end loop;
   end Run_MPMC;

   procedure Run_Slab is
      Worker_Count : constant Positive := 4;
      Per_Worker   : constant Positive := 10_000;
      Capacity     : constant Positive := 128;
      type View_Array is array (Positive range <>) of aliased Slabs.View;
      Views : View_Array (1 .. Worker_Count);
      type View_Access is access all Slabs.View;
      Finished : Completion (Worker_Count);

      task type Worker_Task
        (Identifier : Positive; Item : not null View_Access)
      is
         pragma Task_Info (Flyology.Native_Task);
      end Worker_Task;

      task body Worker_Task is
         Handle : Handles.Handle;
         Outcome : Slabs.Allocation_Result;
         Data : Ada.Streams.Stream_Element_Array (1 .. 8);
         Value : Interfaces.Unsigned_64;
         Released : Boolean;
      begin
         for Sequence in 1 .. Per_Worker loop
            Value := Interfaces.Unsigned_64
              ((Identifier - 1) * Per_Worker + Sequence);
            loop
               Slabs.Try_Allocate (Item.all, Handle, Outcome);
               exit when Outcome = Slabs.Allocated;
               delay 0.0;
            end loop;
            Slabs.Write (Item.all, Handle, Encode (Value));
            Slabs.Read (Item.all, Handle, Data);
            if Decode (Data) /= Value then
               raise Program_Error with "concurrent slab payload mismatch";
            end if;
            Released := False;
            while not Released loop
               begin
                  Slabs.Release (Item.all, Handle);
                  Released := True;
               exception
                  when DS.Busy_Error => delay 0.0;
               end;
            end loop;
         end loop;
         loop
            begin
               Slabs.Read (Item.all, Handle, Data);
               raise Program_Error with
                 "concurrent slab accepted a released handle";
            exception
               when DS.Busy_Error => delay 0.0;
               when DS.Handle_Error => exit;
            end;
         end loop;
         Finished.Done (True);
      exception
         when others => Finished.Done (False);
      end Worker_Task;

      type Worker_Access is access Worker_Task;
      type Worker_Array is array (Positive range <>) of Worker_Access;
      Workers : Worker_Array (1 .. Worker_Count);
   begin
      Slabs.Initialize
        (Views (1), Region_A, Slab_Location, Capacity, 8, 8);
      for Index in 2 .. Worker_Count loop
         if Index mod 2 = 0 then
            Slabs.Attach
              (Views (Index), Region_B, Slab_Location, Capacity, 8, 8);
         else
            Slabs.Attach
              (Views (Index), Region_A, Slab_Location, Capacity, 8, 8);
         end if;
      end loop;
      for Index in Workers'Range loop
         Workers (Index) := new Worker_Task (Index, Views (Index)'Access);
      end loop;
      select
         Finished.Await_All;
      or
         delay 20.0;
         for Worker of Workers loop
            abort Worker.all;
         end loop;
         raise Program_Error with
           "slab native-task test timed out, completed="
           & Finished.Completed'Image;
      end select;
      Assert (Finished.Passed, "slab concurrent allocation/access failed");
      Slabs.Destroy (Views (1));
      for Index in 2 .. Worker_Count loop
         Slabs.Detach (Views (Index));
      end loop;
   end Run_Slab;

   procedure Run_Internally_Synchronized_Vector is
      Worker_Count : constant Positive := 4;
      Per_Worker   : constant Positive := 5_000;
      Total        : constant Positive := Worker_Count * Per_Worker;
      type View_Array is array (Positive range <>) of aliased Vectors.View;
      Views : View_Array (1 .. Worker_Count);
      type View_Access is access all Vectors.View;
      Finished : Completion (Worker_Count);

      task type Worker_Task
        (Identifier : Positive; Vector : not null View_Access)
      is
         pragma Task_Info (Flyology.Native_Task);
      end Worker_Task;

      task body Worker_Task is
         Appended : Boolean;
         Value : Interfaces.Unsigned_64;
      begin
         for Sequence in 1 .. Per_Worker loop
            Value := Interfaces.Unsigned_64
              ((Identifier - 1) * Per_Worker + Sequence);
            loop
               begin
                  Vectors.Try_Append
                    (Vector.all, Encode (Value), Appended);
                  exit;
               exception
                  when DS.Busy_Error =>
                     delay 0.0;
               end;
            end loop;
            if not Appended then
               raise Program_Error with "synchronized vector append failed";
            end if;
         end loop;
         Finished.Done (True);
      exception
         when others => Finished.Done (False);
      end Worker_Task;

      type Worker_Access is access Worker_Task;
      type Worker_Array is array (Positive range <>) of Worker_Access;
      Workers : Worker_Array (1 .. Worker_Count);
      Seen : Seen_Array (1 .. Total) := (others => False);
      Data : Ada.Streams.Stream_Element_Array (1 .. 8);
      Value : Interfaces.Unsigned_64;
   begin
      Vectors.Initialize
        (Views (1), Region_A, Vector_Location, Total, 8);
      for Index in 2 .. Worker_Count loop
         if Index mod 2 = 0 then
            Vectors.Attach
              (Views (Index), Region_B, Vector_Location, Total, 8);
         else
            Vectors.Attach
              (Views (Index), Region_A, Vector_Location, Total, 8);
         end if;
      end loop;
      for Index in Workers'Range loop
         Workers (Index) := new Worker_Task
           (Index, Views (Index)'Access);
      end loop;
      select
         Finished.Await_All;
      or
         delay 15.0;
         for Worker of Workers loop
            abort Worker.all;
         end loop;
         raise Program_Error with
           "internally synchronized vector test timed out";
      end select;
      Assert (Finished.Passed, "internally synchronized vector tasks failed");
      Assert (Vectors.Length (Views (1)) = Total,
              "internally synchronized vector lost elements");
      for Index in 1 .. Total loop
         Vectors.Read (Views (1), Index, Data);
         Value := Decode (Data);
         Assert
           (Value in 1 .. Interfaces.Unsigned_64 (Total)
            and then not Seen (Positive (Value)),
            "internally synchronized vector duplicated/corrupted an element");
         Seen (Positive (Value)) := True;
      end loop;
      Vectors.Destroy (Views (1));
      for Index in 2 .. Worker_Count loop
         Vectors.Detach (Views (Index));
      end loop;
   end Run_Internally_Synchronized_Vector;

   procedure Run_Internally_Synchronized_String is
      Worker_Count : constant Positive := 4;
      Per_Worker   : constant Positive := 1_000;
      Total        : constant Positive := Worker_Count * Per_Worker;
      Capacity     : constant Positive := 8 * Total;
      type View_Array is array (Positive range <>) of aliased Byte_Strings.View;
      Views : View_Array (1 .. Worker_Count);
      type View_Access is access all Byte_Strings.View;
      Finished : Completion (Worker_Count);

      task type Worker_Task
        (Identifier : Positive; Item : not null View_Access)
      is
         pragma Task_Info (Flyology.Native_Task);
      end Worker_Task;

      task body Worker_Task is
         Value : Interfaces.Unsigned_64;
      begin
         for Sequence in 1 .. Per_Worker loop
            Value := Interfaces.Unsigned_64
              ((Identifier - 1) * Per_Worker + Sequence);
            loop
               begin
                  Byte_Strings.Append (Item.all, Encode (Value));
                  exit;
               exception
                  when DS.Busy_Error =>
                     delay 0.0;
               end;
            end loop;
         end loop;
         Finished.Done (True);
      exception
         when others => Finished.Done (False);
      end Worker_Task;

      type Worker_Access is access Worker_Task;
      type Worker_Array is array (Positive range <>) of Worker_Access;
      Workers : Worker_Array (1 .. Worker_Count);
      Seen : Seen_Array (1 .. Total) := (others => False);
      Data : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Capacity));
      Value : Interfaces.Unsigned_64;
   begin
      Byte_Strings.Initialize
        (Views (1), Region_A, String_Location, Capacity);
      for Index in 2 .. Worker_Count loop
         if Index mod 2 = 0 then
            Byte_Strings.Attach
              (Views (Index), Region_B, String_Location, Capacity);
         else
            Byte_Strings.Attach
              (Views (Index), Region_A, String_Location, Capacity);
         end if;
      end loop;
      for Index in Workers'Range loop
         Workers (Index) := new Worker_Task (Index, Views (Index)'Access);
      end loop;
      select
         Finished.Await_All;
      or
         delay 15.0;
         for Worker of Workers loop
            abort Worker.all;
         end loop;
         raise Program_Error with
           "internally synchronized byte-string test timed out";
      end select;
      Assert
        (Finished.Passed, "internally synchronized byte-string tasks failed");
      Assert
        (Byte_Strings.Length (Views (1)) = Capacity,
         "internally synchronized byte string lost bytes");
      Byte_Strings.Read (Views (2), Data);
      for Position in 1 .. Total loop
         declare
            First : constant Ada.Streams.Stream_Element_Offset :=
              Ada.Streams.Stream_Element_Offset ((Position - 1) * 8 + 1);
         begin
            Value := Decode
              (Data
                 (First ..
                    First + Ada.Streams.Stream_Element_Offset (7)));
         end;
         Assert
           (Value in 1 .. Interfaces.Unsigned_64 (Total)
            and then not Seen (Positive (Value)),
            "internally synchronized byte string duplicated/corrupted data");
         Seen (Positive (Value)) := True;
      end loop;
      Byte_Strings.Destroy (Views (1));
      for Index in 2 .. Worker_Count loop
         Byte_Strings.Detach (Views (Index));
      end loop;
   end Run_Internally_Synchronized_String;

   procedure Run_Internally_Synchronized_Map is
      Worker_Count : constant Positive := 4;
      Per_Worker   : constant Positive := 1_000;
      Total        : constant Positive := Worker_Count * Per_Worker;
      Capacity     : constant Positive := 4_096;
      type View_Array is array (Positive range <>) of aliased Hash_Maps.View;
      Views : View_Array (1 .. Worker_Count);
      type View_Access is access all Hash_Maps.View;
      Finished : Completion (Worker_Count);

      task type Worker_Task
        (Identifier : Positive; Item : not null View_Access)
      is
         pragma Task_Info (Flyology.Native_Task);
      end Worker_Task;

      task body Worker_Task is
         Outcome : Hash_Maps.Put_Result;
         Value : Interfaces.Unsigned_64;
      begin
         for Sequence in 1 .. Per_Worker loop
            Value := Interfaces.Unsigned_64
              ((Identifier - 1) * Per_Worker + Sequence);
            loop
               begin
                  Hash_Maps.Put
                    (Item.all, Encode (Value), Encode (Value xor 16#A5A5#),
                     Outcome);
                  exit;
               exception
                  when DS.Busy_Error =>
                     delay 0.0;
               end;
            end loop;
            if Outcome /= Hash_Maps.Inserted then
               raise Program_Error with "internally guarded map insert failed";
            end if;
         end loop;
         Finished.Done (True);
      exception
         when others => Finished.Done (False);
      end Worker_Task;

      type Worker_Access is access Worker_Task;
      type Worker_Array is array (Positive range <>) of Worker_Access;
      Workers : Worker_Array (1 .. Worker_Count);
      Data : Ada.Streams.Stream_Element_Array (1 .. 8);
      Found : Boolean;
   begin
      Hash_Maps.Initialize
        (Views (1), Region_A, Map_Location, Capacity, 8, 8);
      for Index in 2 .. Worker_Count loop
         if Index mod 2 = 0 then
            Hash_Maps.Attach
              (Views (Index), Region_B, Map_Location, Capacity, 8, 8);
         else
            Hash_Maps.Attach
              (Views (Index), Region_A, Map_Location, Capacity, 8, 8);
         end if;
      end loop;
      for Index in Workers'Range loop
         Workers (Index) := new Worker_Task (Index, Views (Index)'Access);
      end loop;
      select
         Finished.Await_All;
      or
         delay 15.0;
         for Worker of Workers loop
            abort Worker.all;
         end loop;
         raise Program_Error with
           "internally synchronized hash-map test timed out";
      end select;
      Assert (Finished.Passed, "internally synchronized hash-map tasks failed");
      Assert
        (Hash_Maps.Length (Views (1)) = Total,
         "internally synchronized hash map lost entries");
      for Value in Interfaces.Unsigned_64 range
        1 .. Interfaces.Unsigned_64 (Total)
      loop
         Hash_Maps.Get
           (Views (2), Encode (Value), Data, Found);
         Assert
           (Found and then Decode (Data) = (Value xor 16#A5A5#),
            "internally synchronized hash map returned a wrong value");
      end loop;
      Hash_Maps.Destroy (Views (1));
      for Index in 2 .. Worker_Count loop
         Hash_Maps.Detach (Views (Index));
      end loop;
   end Run_Internally_Synchronized_Map;

begin
   Assert
     (Mapping_Create
        (Path, Mapping_Length, Base_A'Access, Base_B'Access, FD'Access) = 0,
      "failed to map concurrency backing file twice");
   Assert (Base_A /= Base_B, "concurrency mappings share one virtual base");
   Regions.Attach (Region_A, Base_A, DS.Byte_Count (Mapping_Length));
   Regions.Attach (Region_B, Base_B, DS.Byte_Count (Mapping_Length));
   Run_SPSC;
   Run_MPMC;
   Run_Slab;
   Run_Internally_Synchronized_Vector;
   Run_Internally_Synchronized_String;
   Run_Internally_Synchronized_Map;
   Regions.Detach (Region_A);
   Regions.Detach (Region_B);
   Assert (Unmap (Base_A, Mapping_Length) = 0, "failed to unmap view A");
   Base_A := System.Null_Address;
   Assert (Unmap (Base_B, Mapping_Length) = 0, "failed to unmap view B");
   Base_B := System.Null_Address;
   Assert (Close_Mapping (Path, FD) = 0, "failed to close concurrency map");
   FD := -1;
   Ada.Text_IO.Put_Line
     ("data structures concurrency passed: SPSC="
      & SPSC_Iterations'Image & " MPMC=" & Total_MPMC'Image);
exception
   when others =>
      Cleanup;
      raise;
end Data_Structures_Concurrency_Smoke;
