with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Byte_Strings;
with Flyology.Data_Structures.Allocation_Algorithms.Buddy;
with Flyology.Data_Structures.Allocation_Algorithms.Best_Fit;
with Flyology.Data_Structures.Allocation_Algorithms.TLSF;
with Flyology.Data_Structures.Arenas;
with Flyology.Data_Structures.Allocation_Pools.Adaptive;
with Flyology.Data_Structures.Dynamic.Hash_Maps;
with Flyology.Data_Structures.Dynamic.Vectors;
with Flyology.Data_Structures.Hash_Maps;
with Flyology.Data_Structures.Handles;
with Flyology.Data_Structures.Regions;
with Flyology.Data_Structures.Rings.MPMC;
with Flyology.Data_Structures.Rings.SPSC;
with Flyology.Data_Structures.Slab_Pools;
with Flyology.Data_Structures.Storage_Types.Elements;
with Flyology.Data_Structures.Storage_Types.Unsigned_64s;
with Flyology.Data_Structures.Vectors;
with Interfaces;
with Interfaces.C;
with System;

procedure Data_Structures_Concurrency_Smoke is
   package DS renames Flyology.Data_Structures;
   package Byte_Strings renames DS.Byte_Strings;
   package Arenas is new DS.Arenas (Algorithm => DS.Allocation_Algorithms.Buddy);
   package Best_Fit_Arenas is new DS.Arenas (Algorithm => DS.Allocation_Algorithms.Best_Fit);
   package TLSF_Arenas is new DS.Arenas (Algorithm => DS.Allocation_Algorithms.TLSF);
   package Handles renames DS.Handles;
   package Regions renames DS.Regions;
   package U64_Elements renames DS.Storage_Types.Unsigned_64s;
   package Adaptive_U64 is new
     DS.Allocation_Pools.Adaptive
       (Arena_Provider  => TLSF_Arenas,
        Element         => U64_Elements.Element,
        Slots_Per_Chunk => 64,
        Maximum_Chunks  => 8);
   package SPSC is new DS.Rings.SPSC (Element => U64_Elements.Element);
   package MPMC is new DS.Rings.MPMC (Element => U64_Elements.Element);

   --  Hold an observer after its container claims internal state, making
   --  active-attachment ordering deterministic without scheduler timing.
   protected type Observation_Gate is
      procedure Mark_Entered;
      entry Await_Entered;
      entry Continue;
      procedure Release;
   private
      Entered  : Boolean := False;
      Released : Boolean := False;
   end Observation_Gate;

   protected body Observation_Gate is
      procedure Mark_Entered is
      begin
         Entered := True;
      end Mark_Entered;

      entry Await_Entered when Entered is
      begin
         null;
      end Await_Entered;

      entry Continue when Released is
      begin
         null;
      end Continue;

      procedure Release is
      begin
         Released := True;
      end Release;
   end Observation_Gate;

   Paused_Observation     : Observation_Gate;
   Paused_Map_Observation : Observation_Gate;

   function Observe_After_Claim (Item : U64_Elements.Representation.Const_Ref) return Interfaces.Unsigned_64
   is
   begin
      Paused_Observation.Mark_Entered;
      Paused_Observation.Continue;
      return U64_Elements.Value_Of (Item);
   end Observe_After_Claim;

   package Paused_U64_Element is new
     DS.Storage_Types.Elements
       (Representation => U64_Elements.Representation,
        Source_Type    => Interfaces.Unsigned_64,
        Observed_Type  => Interfaces.Unsigned_64,
        Create_Value   => U64_Elements.Create,
        Observe_Value  => Observe_After_Claim);
   package Paused_MPMC is new DS.Rings.MPMC (Element => Paused_U64_Element);
   function Observe_Map_After_Claim
     (Item : U64_Elements.Representation.Const_Ref) return Interfaces.Unsigned_64 is
   begin
      Paused_Map_Observation.Mark_Entered;
      Paused_Map_Observation.Continue;
      return U64_Elements.Value_Of (Item);
   end Observe_Map_After_Claim;

   package Paused_Map_Element is new
     DS.Storage_Types.Elements
       (Representation => U64_Elements.Representation,
        Source_Type    => Interfaces.Unsigned_64,
        Observed_Type  => Interfaces.Unsigned_64,
        Create_Value   => U64_Elements.Create,
        Observe_Value  => Observe_Map_After_Claim);
   package Paused_Hash_Maps is new DS.Hash_Maps (Key => U64_Elements.Element, Element => Paused_Map_Element);
   package Slabs is new DS.Slab_Pools (Element => U64_Elements.Element);
   package Vectors is new DS.Vectors (Element => U64_Elements.Element);
   package Dynamic_Vectors is new
     DS.Dynamic.Vectors (Arena_Provider => Arenas, Element => U64_Elements.Element);
   package Dynamic_Maps is new
     DS.Dynamic.Hash_Maps
       (Arena_Provider => Arenas,
        Key            => U64_Elements.Element,
        Element        => U64_Elements.Element);
   package Hash_Maps is new DS.Hash_Maps (Key => U64_Elements.Element, Element => U64_Elements.Element);
   package C renames Interfaces.C;

   use type C.int;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_64;
   use type DS.Open_Result;
   use type Hash_Maps.Put_Result;
   use type DS.Dynamic.Growth_Result;
   use type Dynamic_Maps.Put_Result;
   use type Slabs.Allocation_Result;
   use type Best_Fit_Arenas.Allocation_Result;
   use type Adaptive_U64.Allocation_Result;
   use type System.Address;

   function Argument (Position : Positive; Default : Positive) return Positive
   is (if Ada.Command_Line.Argument_Count >= Position
       then Positive'Value (Ada.Command_Line.Argument (Position))
       else Default);

   SPSC_Iterations             : constant Positive := Argument (1, 250_000);
   MPMC_Per_Producer           : constant Positive := Argument (2, 25_000);
   Mapping_Length              : constant C.size_t := 4_194_304;
   SPSC_Location               : constant DS.Region_Offset := 64;
   MPMC_Location               : constant DS.Region_Offset := 131_072;
   Active_Attach_MPMC_Location : constant DS.Region_Offset := 200_000;
   Slab_Location               : constant DS.Region_Offset := 400_000;
   Vector_Location             : constant DS.Region_Offset := 524_288;
   String_Location             : constant DS.Region_Offset := 700_000;
   Map_Location                : constant DS.Region_Offset := 786_432;
   Open_Location               : constant DS.Region_Offset := 950_000;
   Arena_Location              : constant DS.Region_Offset := 1_048_576;
   Dynamic_Vector_Location     : constant DS.Region_Offset := 2_700_000;
   Dynamic_Map_Location        : constant DS.Region_Offset := 2_701_024;
   Best_Fit_Arena_Location     : constant DS.Region_Offset := 3_000_000;
   TLSF_Arena_Location         : constant DS.Region_Offset := 3_400_000;
   Adaptive_Pool_Location      : constant DS.Region_Offset := 3_800_000;

   function Mapping_Create
     (Path   : C.char_array;
      Length : C.size_t;
      First  : access System.Address;
      Second : access System.Address;
      FD     : access C.int) return C.int;
   pragma Import (C, Mapping_Create, "flyology_test_mapping_create");

   function Unmap (Address : System.Address; Length : C.size_t) return C.int;
   pragma Import (C, Unmap, "flyology_test_mapping_unmap");

   function Close_Mapping (Path : C.char_array; FD : C.int) return C.int;
   pragma Import (C, Close_Mapping, "flyology_test_mapping_close");

   procedure Assert (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Assert;

   function Encode (Value : Interfaces.Unsigned_64) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array (1 .. 8);
      Work   : Interfaces.Unsigned_64 := Value;
   begin
      for Byte of Result loop
         Byte := Ada.Streams.Stream_Element (Work and 16#FF#);
         Work := Work / 256;
      end loop;
      return Result;
   end Encode;

   function Decode (Data : Ada.Streams.Stream_Element_Array) return Interfaces.Unsigned_64 is
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
      Count  : Natural := 0;
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

      function Passed return Boolean
      is (All_OK);

      function Completed return Natural
      is (Count);
   end Completion;

   Region_A, Region_B : Regions.View;

   procedure Run_Create_Or_Attach_Race is
      View_A, View_B     : Vectors.View;
      Result_A, Result_B : DS.Open_Result;
      Finished           : Completion (2);

      protected Gate is
         procedure Arrive;
         entry Go;
      private
         Arrivals : Natural := 0;
      end Gate;

      protected body Gate is
         procedure Arrive is
         begin
            Arrivals := Arrivals + 1;
         end Arrive;

         entry Go when Arrivals = 2 is
         begin
            null;
         end Go;
      end Gate;

      task Creator_A is
         pragma Task_Info (Flyology.Native_Task);
      end Creator_A;

      task Creator_B is
         pragma Task_Info (Flyology.Native_Task);
      end Creator_B;

      task body Creator_A is
      begin
         Gate.Arrive;
         Gate.Go;
         Vectors.Create_Or_Attach (View_A, Region_A, Open_Location, 128, Result_A);
         Finished.Done (True);
      exception
         when others =>
            Finished.Done (False);
      end Creator_A;

      task body Creator_B is
      begin
         Gate.Arrive;
         Gate.Go;
         Vectors.Create_Or_Attach (View_B, Region_B, Open_Location, 128, Result_B);
         Finished.Done (True);
      exception
         when others =>
            Finished.Done (False);
      end Creator_B;
   begin
      select
         Finished.Await_All;
      or
         delay 5.0;
         abort Creator_A;
         abort Creator_B;
         raise Program_Error with "create-or-attach race timed out";
      end select;
      Assert (Finished.Passed, "create-or-attach race raised an exception");
      Assert
        ((Result_A = DS.Initialized_New) xor (Result_B = DS.Initialized_New),
         "create-or-attach race did not select exactly one initializer");

      if Result_A = DS.Initialization_In_Progress then
         Vectors.Create_Or_Attach (View_A, Region_A, Open_Location, 128, Result_A);
      elsif Result_B = DS.Initialization_In_Progress then
         Vectors.Create_Or_Attach (View_B, Region_B, Open_Location, 128, Result_B);
      end if;
      Assert
        ((Result_A = DS.Initialized_New and then Result_B = DS.Attached_Existing)
         or else (Result_B = DS.Initialized_New and then Result_A = DS.Attached_Existing),
         "create-or-attach loser did not attach after publication");

      if Result_A = DS.Initialized_New then
         Vectors.Destroy (View_A);
         Vectors.Detach (View_B);
      else
         Vectors.Destroy (View_B);
         Vectors.Detach (View_A);
      end if;
   end Run_Create_Or_Attach_Race;

   Temp_Root : constant String := Ada.Environment_Variables.Value ("FLYOLOGY_TEST_TEMP_ROOT", "/tmp");
   Path      : constant C.char_array := C.To_C (Temp_Root & "/data-structures-concurrency.map");
   Base_A    : aliased System.Address := System.Null_Address;
   Base_B    : aliased System.Address := System.Null_Address;
   FD        : aliased C.int := -1;

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
      Finished                     : Completion (2);

      task Producer is
         pragma Task_Info (Flyology.Native_Task);
         entry Start;
      end Producer;

      task Consumer is
         pragma Task_Info (Flyology.Native_Task);
         entry Start;
      end Consumer;

      task body Producer is
      begin
         accept Start;
         for Value in Interfaces.Unsigned_64 range 1 .. Interfaces.Unsigned_64 (SPSC_Iterations) loop
            SPSC.Push (Producer_View, Value, 5.0);
         end loop;
         Finished.Done (True);
      exception
         when others =>
            Finished.Done (False);
      end Producer;

      task body Consumer is
         Data : Interfaces.Unsigned_64;
      begin
         accept Start;
         for Expected in Interfaces.Unsigned_64 range 1 .. Interfaces.Unsigned_64 (SPSC_Iterations) loop
            SPSC.Pop (Consumer_View, Data, 5.0);
            if Data /= Expected then
               raise Program_Error with "SPSC sequence mismatch";
            end if;
         end loop;
         Finished.Done (True);
      exception
         when others =>
            Finished.Done (False);
      end Consumer;
   begin
      SPSC.Initialize (Producer_View, Region_A, SPSC_Location, 1_024);
      SPSC.Attach (Consumer_View, Region_B, SPSC_Location, 1_024);
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
         Data   : Interfaces.Unsigned_64;
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
   Total_MPMC     : constant Positive := Producer_Count * MPMC_Per_Producer;
   type Seen_Array is array (Positive range <>) of Boolean;

   protected type Scoreboard (Expected, Task_Count : Positive) is
      procedure Observe (Value : Interfaces.Unsigned_64);
      procedure Done (Success : Boolean);
      function Complete return Boolean;
      entry Await_Tasks;
      function Passed return Boolean;
   private
      Seen     : Seen_Array (1 .. Expected) := (others => False);
      Observed : Natural := 0;
      Finished : Natural := 0;
      All_OK   : Boolean := True;
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

      function Complete return Boolean
      is (Observed = Expected);

      entry Await_Tasks when Finished = Task_Count is
      begin
         null;
      end Await_Tasks;

      function Passed return Boolean
      is (All_OK and then Observed = Expected);
   end Scoreboard;

   procedure Run_MPMC is
      type View_Array is array (Positive range <>) of aliased MPMC.View;
      Producer_Views : View_Array (1 .. Producer_Count);
      Consumer_Views : View_Array (1 .. Consumer_Count);
      Results        : Scoreboard (Expected => Total_MPMC, Task_Count => Producer_Count + Consumer_Count);
      type View_Access is access all MPMC.View;

      task type Producer_Task
        (Identifier : Positive;
         Ring       : not null View_Access)
      is
         pragma Task_Info (Flyology.Native_Task);
      end Producer_Task;

      task type Consumer_Task (Ring : not null View_Access) is
         pragma Task_Info (Flyology.Native_Task);
      end Consumer_Task;

      task body Producer_Task is
         Value : Interfaces.Unsigned_64;
      begin
         for Sequence in 1 .. MPMC_Per_Producer loop
            Value := Interfaces.Unsigned_64 ((Identifier - 1) * MPMC_Per_Producer + Sequence);
            MPMC.Push (Ring.all, Value, 5.0);
         end loop;
         Results.Done (True);
      exception
         when others =>
            Results.Done (False);
      end Producer_Task;

      task body Consumer_Task is
         Data : Interfaces.Unsigned_64;
      begin
         loop
            begin
               MPMC.Pop (Ring.all, Data, 0.010);
               Results.Observe (Data);
            exception
               when DS.Timeout_Error =>
                  exit when Results.Complete;
            end;
         end loop;
         Results.Done (True);
      exception
         when others =>
            Results.Done (False);
      end Consumer_Task;

      type Producer_Access is access Producer_Task;
      type Consumer_Access is access Consumer_Task;
      type Producer_Array is array (Positive range <>) of Producer_Access;
      type Consumer_Array is array (Positive range <>) of Consumer_Access;
      Producers : Producer_Array (1 .. Producer_Count);
      Consumers : Consumer_Array (1 .. Consumer_Count);
   begin
      MPMC.Initialize (Producer_Views (1), Region_A, MPMC_Location, 1_024);
      for Index in 2 .. Producer_Count loop
         MPMC.Attach (Producer_Views (Index), Region_A, MPMC_Location, 1_024);
      end loop;
      for Index in Consumer_Views'Range loop
         MPMC.Attach (Consumer_Views (Index), Region_B, MPMC_Location, 1_024);
      end loop;
      for Index in Producers'Range loop
         Producers (Index) := new Producer_Task (Index, Producer_Views (Index)'Access);
      end loop;
      for Index in Consumers'Range loop
         Consumers (Index) := new Consumer_Task (Consumer_Views (Index)'Access);
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

   procedure Run_Active_MPMC_Attach is
      Owner    : aliased Paused_MPMC.View;
      Joiner   : Paused_MPMC.View;
      Finished : Completion (1);
      Observed : Interfaces.Unsigned_64 := 0;
      Attached : Boolean := True;

      task type Consumer_Task (Ring : not null access Paused_MPMC.View) is
         pragma Task_Info (Flyology.Native_Task);
      end Consumer_Task;

      task body Consumer_Task is
      begin
         Paused_MPMC.Pop (Ring.all, Observed, 5.0);
         Finished.Done (True);
      exception
         when others =>
            Finished.Done (False);
      end Consumer_Task;

      type Consumer_Access is access Consumer_Task;
      Consumer : Consumer_Access;
   begin
      Paused_MPMC.Initialize (Owner, Region_A, Active_Attach_MPMC_Location, 2);
      Paused_MPMC.Push (Owner, 42, 5.0);
      Consumer := new Consumer_Task (Owner'Access);
      select
         Paused_Observation.Await_Entered;
      or
         delay 5.0;
         abort Consumer.all;
         raise Program_Error with "MPMC consumer did not pause after claiming its slot";
      end select;

      begin
         Paused_MPMC.Attach (Joiner, Region_B, Active_Attach_MPMC_Location, 2);
      exception
         when DS.Layout_Error =>
            Attached := False;
         when others =>
            Paused_Observation.Release;
            raise;
      end;
      Paused_Observation.Release;

      select
         Finished.Await_All;
      or
         delay 5.0;
         abort Consumer.all;
         raise Program_Error with "paused MPMC consumer did not resume";
      end select;
      Assert (Attached, "MPMC attachment rejected a valid in-flight consumer claim");
      Assert
        (Finished.Passed and then Observed = 42, "paused MPMC consumer did not preserve its claimed element");
      if Paused_MPMC.Is_Attached (Joiner) then
         Paused_MPMC.Detach (Joiner);
      end if;
      Paused_MPMC.Destroy (Owner);
   end Run_Active_MPMC_Attach;

   procedure Run_Slab is
      Worker_Count : constant Positive := 4;
      Per_Worker   : constant Positive := 10_000;
      Capacity     : constant Positive := 128;
      type View_Array is array (Positive range <>) of aliased Slabs.View;
      Views        : View_Array (1 .. Worker_Count);
      type View_Access is access all Slabs.View;
      Finished     : Completion (Worker_Count);

      task type Worker_Task
        (Identifier : Positive;
         Item       : not null View_Access)
      is
         pragma Task_Info (Flyology.Native_Task);
      end Worker_Task;

      task body Worker_Task is
         Handle  : Handles.Handle;
         Outcome : Slabs.Allocation_Result;
         Data    : Interfaces.Unsigned_64;
         Value   : Interfaces.Unsigned_64;
      begin
         for Sequence in 1 .. Per_Worker loop
            Value := Interfaces.Unsigned_64 ((Identifier - 1) * Per_Worker + Sequence);
            Slabs.Try_Allocate (Item.all, Value, 5.0, Handle, Outcome);
            if Outcome /= Slabs.Allocated then
               raise Program_Error with "timed slab allocation exhausted";
            end if;
            Slabs.Read (Item.all, Handle, Data, 5.0);
            if Data /= Value then
               raise Program_Error with "concurrent slab payload mismatch";
            end if;
            Slabs.Release (Item.all, Handle, 5.0);
         end loop;
         begin
            Slabs.Read (Item.all, Handle, Data, 5.0);
            raise Program_Error with "concurrent slab accepted a released handle";
         exception
            when DS.Handle_Error =>
               null;
         end;
         Finished.Done (True);
      exception
         when others =>
            Finished.Done (False);
      end Worker_Task;

      type Worker_Access is access Worker_Task;
      type Worker_Array is array (Positive range <>) of Worker_Access;
      Workers : Worker_Array (1 .. Worker_Count);
   begin
      Slabs.Initialize (Views (1), Region_A, Slab_Location, Capacity);
      for Index in 2 .. Worker_Count loop
         if Index mod 2 = 0 then
            Slabs.Attach (Views (Index), Region_B, Slab_Location, Capacity);
         else
            Slabs.Attach (Views (Index), Region_A, Slab_Location, Capacity);
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
         raise Program_Error with "slab native-task test timed out, completed=" & Finished.Completed'Image;
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
      Views        : View_Array (1 .. Worker_Count);
      type View_Access is access all Vectors.View;
      Finished     : Completion (Worker_Count);

      task type Worker_Task
        (Identifier : Positive;
         Vector     : not null View_Access)
      is
         pragma Task_Info (Flyology.Native_Task);
      end Worker_Task;

      task body Worker_Task is
         Appended : Boolean;
         Value    : Interfaces.Unsigned_64;
      begin
         for Sequence in 1 .. Per_Worker loop
            Value := Interfaces.Unsigned_64 ((Identifier - 1) * Per_Worker + Sequence);
            Vectors.Try_Append (Vector.all, Value, 5.0, Appended);
            if not Appended then
               raise Program_Error with "synchronized vector append failed";
            end if;
         end loop;
         Finished.Done (True);
      exception
         when others =>
            Finished.Done (False);
      end Worker_Task;

      type Worker_Access is access Worker_Task;
      type Worker_Array is array (Positive range <>) of Worker_Access;
      Workers : Worker_Array (1 .. Worker_Count);
      Seen    : Seen_Array (1 .. Total) := (others => False);
      Value   : Interfaces.Unsigned_64;
   begin
      Vectors.Initialize (Views (1), Region_A, Vector_Location, Total);
      for Index in 2 .. Worker_Count loop
         if Index mod 2 = 0 then
            Vectors.Attach (Views (Index), Region_B, Vector_Location, Total);
         else
            Vectors.Attach (Views (Index), Region_A, Vector_Location, Total);
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
         raise Program_Error with "internally synchronized vector test timed out";
      end select;
      Assert (Finished.Passed, "internally synchronized vector tasks failed");
      Assert (Vectors.Length (Views (1)) = Total, "internally synchronized vector lost elements");
      for Index in 1 .. Total loop
         Value := Vectors.Read (Views (1), Index);
         Assert
           (Value in 1 .. Interfaces.Unsigned_64 (Total) and then not Seen (Positive (Value)),
            "internally synchronized vector duplicated/corrupted an element");
         Seen (Positive (Value)) := True;
      end loop;
      Vectors.Destroy (Views (1));
      for Index in 2 .. Worker_Count loop
         Vectors.Detach (Views (Index));
      end loop;
   end Run_Internally_Synchronized_Vector;

   procedure Run_Internally_Synchronized_String is
      Worker_Count    : constant Positive := 4;
      Per_Worker      : constant Positive := 1_000;
      Total           : constant Positive := Worker_Count * Per_Worker;
      Capacity        : constant Positive := 8 * Total;
      type View_Array is array (Positive range <>) of aliased Byte_Strings.View;
      Views           : View_Array (1 .. Worker_Count);
      type View_Access is access all Byte_Strings.View;
      Finished        : Completion (Worker_Count);
      Attach_Finished : Completion (1);

      task type Worker_Task
        (Identifier : Positive;
         Item       : not null View_Access)
      is
         pragma Task_Info (Flyology.Native_Task);
      end Worker_Task;

      task body Worker_Task is
         Value : Interfaces.Unsigned_64;
      begin
         for Sequence in 1 .. Per_Worker loop
            Value := Interfaces.Unsigned_64 ((Identifier - 1) * Per_Worker + Sequence);
            Byte_Strings.Append (Item.all, Encode (Value), 5.0);
         end loop;
         Finished.Done (True);
      exception
         when others =>
            Finished.Done (False);
      end Worker_Task;

      type Worker_Access is access Worker_Task;
      type Worker_Array is array (Positive range <>) of Worker_Access;
      Workers : Worker_Array (1 .. Worker_Count);

      task type Attach_Task is
         pragma Task_Info (Flyology.Native_Task);
      end Attach_Task;

      task body Attach_Task is
         Candidate : Byte_Strings.View;
      begin
         for Attempt in 1 .. 10_000 loop
            pragma Unreferenced (Attempt);
            Byte_Strings.Attach (Candidate, Region_B, String_Location, Capacity);
            if Byte_Strings.Capacity (Candidate) /= Capacity then
               raise Program_Error with "concurrent byte-string attachment lost its capacity";
            end if;
            Byte_Strings.Detach (Candidate);
         end loop;
         Attach_Finished.Done (True);
      exception
         when others =>
            Byte_Strings.Detach (Candidate);
            Attach_Finished.Done (False);
      end Attach_Task;

      type Attach_Access is access Attach_Task;
      Attacher : Attach_Access;
      Seen     : Seen_Array (1 .. Total) := (others => False);
      Data     : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Capacity));
      Value    : Interfaces.Unsigned_64;
   begin
      Byte_Strings.Initialize (Views (1), Region_A, String_Location, Capacity);
      for Index in 2 .. Worker_Count loop
         if Index mod 2 = 0 then
            Byte_Strings.Attach (Views (Index), Region_B, String_Location, Capacity);
         else
            Byte_Strings.Attach (Views (Index), Region_A, String_Location, Capacity);
         end if;
      end loop;
      for Index in Workers'Range loop
         Workers (Index) := new Worker_Task (Index, Views (Index)'Access);
      end loop;
      Attacher := new Attach_Task;
      select
         Finished.Await_All;
      or
         delay 15.0;
         for Worker of Workers loop
            abort Worker.all;
         end loop;
         raise Program_Error with "internally synchronized byte-string test timed out";
      end select;
      Assert (Finished.Passed, "internally synchronized byte-string tasks failed");
      select
         Attach_Finished.Await_All;
      or
         delay 15.0;
         abort Attacher.all;
         raise Program_Error with "concurrent byte-string attachment test timed out";
      end select;
      Assert (Attach_Finished.Passed, "byte-string attachment raced a synchronized operation");
      Assert (Byte_Strings.Length (Views (1)) = Capacity, "internally synchronized byte string lost bytes");
      Byte_Strings.Read (Views (2), Data);
      for Position in 1 .. Total loop
         declare
            First : constant Ada.Streams.Stream_Element_Offset :=
              Ada.Streams.Stream_Element_Offset ((Position - 1) * 8 + 1);
         begin
            Value := Decode (Data (First .. First + Ada.Streams.Stream_Element_Offset (7)));
         end;
         Assert
           (Value in 1 .. Interfaces.Unsigned_64 (Total) and then not Seen (Positive (Value)),
            "internally synchronized byte string duplicated/corrupted data");
         Seen (Positive (Value)) := True;
      end loop;
      Byte_Strings.Destroy (Views (1));
      for Index in 2 .. Worker_Count loop
         Byte_Strings.Detach (Views (Index));
      end loop;
   end Run_Internally_Synchronized_String;

   procedure Run_Internally_Synchronized_Map is
      Worker_Count    : constant Positive := 4;
      Per_Worker      : constant Positive := 1_000;
      Total           : constant Positive := Worker_Count * Per_Worker;
      Capacity        : constant Positive := 4_096;
      type View_Array is array (Positive range <>) of aliased Hash_Maps.View;
      Views           : View_Array (1 .. Worker_Count);
      type View_Access is access all Hash_Maps.View;
      Finished        : Completion (Worker_Count);
      Attach_Finished : Completion (1);

      procedure Run_Deterministic_Attach_Contention is
         Held_View    : aliased Paused_Hash_Maps.View;
         Candidate    : Hash_Maps.View;
         Get_Finished : Completion (1);

         task type Guard_Holder (Item : not null access Paused_Hash_Maps.View) is
            pragma Task_Info (Flyology.Native_Task);
         end Guard_Holder;

         task body Guard_Holder is
            Value : Interfaces.Unsigned_64;
            Found : Boolean;
         begin
            Paused_Hash_Maps.Get (Item.all, 1, Value, Found);
            if not Found or else Value /= (1 xor 16#A5A5#) then
               raise Program_Error with "guard-holder map lookup returned a wrong value";
            end if;
            Get_Finished.Done (True);
         exception
            when Error : others =>
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "guard-holder map lookup failed: " & Ada.Exceptions.Exception_Information (Error));
               Get_Finished.Done (False);
         end Guard_Holder;

         type Guard_Holder_Access is access Guard_Holder;
         Holder : Guard_Holder_Access;
      begin
         Paused_Hash_Maps.Attach (Held_View, Region_B, Map_Location, Capacity);
         Holder := new Guard_Holder (Held_View'Access);
         select
            Paused_Map_Observation.Await_Entered;
         or
            delay 5.0;
            Paused_Map_Observation.Release;
            abort Holder.all;
            Paused_Hash_Maps.Detach (Held_View);
            raise Program_Error with "guard-holder map lookup did not acquire the guard";
         end select;

         begin
            begin
               Hash_Maps.Attach (Candidate, Region_A, Map_Location, Capacity);
               Hash_Maps.Detach (Candidate);
               raise Program_Error with "hash-map attachment ignored a held guard";
            exception
               when DS.Busy_Error =>
                  null;
            end;
         exception
            when others =>
               Paused_Map_Observation.Release;
               Hash_Maps.Detach (Candidate);
               Paused_Hash_Maps.Detach (Held_View);
               raise;
         end;

         Paused_Map_Observation.Release;
         select
            Get_Finished.Await_All;
         or
            delay 5.0;
            abort Holder.all;
            Paused_Hash_Maps.Detach (Held_View);
            raise Program_Error with "guard-holder map lookup did not finish";
         end select;
         Assert (Get_Finished.Passed, "guard-holder map lookup failed after releasing the guard");
         Paused_Hash_Maps.Detach (Held_View);
      end Run_Deterministic_Attach_Contention;

      protected Start_Gate is
         procedure Arrive;
         entry Go;
      private
         Arrivals : Natural := 0;
      end Start_Gate;

      protected body Start_Gate is
         procedure Arrive is
         begin
            Arrivals := Arrivals + 1;
         end Arrive;

         entry Go when Arrivals = Worker_Count + 1 is
         begin
            null;
         end Go;
      end Start_Gate;

      task type Worker_Task
        (Identifier : Positive;
         Item       : not null View_Access)
      is
         pragma Task_Info (Flyology.Native_Task);
      end Worker_Task;

      task body Worker_Task is
         Outcome : Hash_Maps.Put_Result;
         Value   : Interfaces.Unsigned_64;
      begin
         Start_Gate.Arrive;
         Start_Gate.Go;
         for Sequence in 1 .. Per_Worker loop
            Value := Interfaces.Unsigned_64 ((Identifier - 1) * Per_Worker + Sequence);
            Hash_Maps.Put (Item.all, Value, Value xor 16#A5A5#, 5.0, Outcome);
            if Outcome /= Hash_Maps.Inserted then
               raise Program_Error with "internally guarded map insert failed";
            end if;
         end loop;
         Finished.Done (True);
      exception
         when others =>
            Finished.Done (False);
      end Worker_Task;

      type Worker_Access is access Worker_Task;
      type Worker_Array is array (Positive range <>) of Worker_Access;
      Workers : Worker_Array (1 .. Worker_Count);

      task type Attach_Task is
         pragma Task_Info (Flyology.Native_Task);
      end Attach_Task;

      task body Attach_Task is
         Candidate           : Hash_Maps.View;
         Successful_Attaches : Natural := 0;
      begin
         Start_Gate.Arrive;
         Start_Gate.Go;
         while Finished.Completed < Worker_Count or else Successful_Attaches < 64 loop
            begin
               Hash_Maps.Attach (Candidate, Region_B, Map_Location, Capacity);
               Successful_Attaches := Successful_Attaches + 1;
               Hash_Maps.Detach (Candidate);
            exception
               when DS.Busy_Error =>
                  null;
            end;
            delay 0.0;
         end loop;
         Attach_Finished.Done (True);
      exception
         when Error : others =>
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "concurrent hash-map attachment failed: " & Ada.Exceptions.Exception_Information (Error));
            Hash_Maps.Detach (Candidate);
            Attach_Finished.Done (False);
      end Attach_Task;

      type Attach_Access is access Attach_Task;
      Attacher : Attach_Access;
      Data     : Interfaces.Unsigned_64;
      Found    : Boolean;
   begin
      Hash_Maps.Initialize (Views (1), Region_A, Map_Location, Capacity);
      for Index in 2 .. Worker_Count loop
         if Index mod 2 = 0 then
            Hash_Maps.Attach (Views (Index), Region_B, Map_Location, Capacity);
         else
            Hash_Maps.Attach (Views (Index), Region_A, Map_Location, Capacity);
         end if;
      end loop;
      for Index in Workers'Range loop
         Workers (Index) := new Worker_Task (Index, Views (Index)'Access);
      end loop;
      Attacher := new Attach_Task;
      select
         Finished.Await_All;
      or
         delay 15.0;
         for Worker of Workers loop
            abort Worker.all;
         end loop;
         raise Program_Error with "internally synchronized hash-map test timed out";
      end select;
      Assert (Finished.Passed, "internally synchronized hash-map tasks failed");
      select
         Attach_Finished.Await_All;
      or
         delay 15.0;
         abort Attacher.all;
         raise Program_Error with "concurrent hash-map attachment test timed out";
      end select;
      Assert (Attach_Finished.Passed, "hash-map attachment raced a synchronized operation");
      Assert (Hash_Maps.Length (Views (1)) = Total, "internally synchronized hash map lost entries");
      for Value in Interfaces.Unsigned_64 range 1 .. Interfaces.Unsigned_64 (Total) loop
         Hash_Maps.Get (Views (2), Value, Data, Found);
         Assert
           (Found and then Data = (Value xor 16#A5A5#),
            "internally synchronized hash map returned a wrong value");
      end loop;
      Run_Deterministic_Attach_Contention;
      Hash_Maps.Destroy (Views (1));
      for Index in 2 .. Worker_Count loop
         Hash_Maps.Detach (Views (Index));
      end loop;
   end Run_Internally_Synchronized_Map;

   procedure Run_Dynamic_Arena is
      Worker_Count : constant Positive := 4;
      Per_Worker   : constant Positive := 2_000;
      Total        : constant Positive := Worker_Count * Per_Worker;
      type Arena_Array is array (Positive range <>) of aliased Arenas.View;
      Arena_Views  : Arena_Array (1 .. Worker_Count);
      type Arena_Access is access all Arenas.View;

      procedure Run_Vector is
         type View_Array is array (Positive range <>) of aliased Dynamic_Vectors.View;
         Views    : View_Array (1 .. Worker_Count);
         type View_Access is access all Dynamic_Vectors.View;
         Finished : Completion (Worker_Count);

         task type Worker_Task
           (Identifier : Positive;
            Item       : not null View_Access;
            Arena      : not null Arena_Access)
         is
            pragma Task_Info (Flyology.Native_Task);
         end Worker_Task;

         task body Worker_Task is
            Value  : Interfaces.Unsigned_64;
            Result : DS.Dynamic.Growth_Result;
         begin
            for Sequence in 1 .. Per_Worker loop
               Value := Interfaces.Unsigned_64 ((Identifier - 1) * Per_Worker + Sequence);
               loop
                  begin
                     Dynamic_Vectors.Try_Append (Item.all, Arena.all, Value, Result);
                     exit when Result = DS.Dynamic.Completed;
                     if Result = DS.Dynamic.Arena_Exhausted then
                        raise Program_Error with "dynamic vector exhausted its concurrency arena";
                     end if;
                  exception
                     when DS.Busy_Error =>
                        null;
                  end;
                  delay 0.0;
               end loop;
            end loop;
            Finished.Done (True);
         exception
            when others =>
               Finished.Done (False);
         end Worker_Task;

         type Worker_Access is access Worker_Task;
         type Worker_Array is array (Positive range <>) of Worker_Access;
         Workers : Worker_Array (1 .. Worker_Count);
         Seen    : Seen_Array (1 .. Total) := (others => False);
         Value   : Interfaces.Unsigned_64;
      begin
         Dynamic_Vectors.Initialize (Views (1), Region_A, Dynamic_Vector_Location, Arena_Views (1), 2);
         for Index in 2 .. Worker_Count loop
            Dynamic_Vectors.Attach
              (Views (Index),
               (if Index mod 2 = 0 then Region_B else Region_A),
               Dynamic_Vector_Location,
               Arena_Views (Index),
               2);
         end loop;
         for Index in Workers'Range loop
            Workers (Index) := new Worker_Task (Index, Views (Index)'Access, Arena_Views (Index)'Access);
         end loop;
         select
            Finished.Await_All;
         or
            delay 20.0;
            for Worker of Workers loop
               abort Worker.all;
            end loop;
            raise Program_Error with "dynamic-vector native-task test timed out";
         end select;
         Assert
           (Finished.Passed and then Dynamic_Vectors.Length (Views (1)) = Total,
            "dynamic-vector concurrent append lost elements");
         for Index in 1 .. Total loop
            Value := Dynamic_Vectors.Read (Views (1), Arena_Views (1), Index);
            Assert
              (Value in 1 .. Interfaces.Unsigned_64 (Total) and then not Seen (Positive (Value)),
               "dynamic-vector concurrent append duplicated an element");
            Seen (Positive (Value)) := True;
         end loop;
         Dynamic_Vectors.Destroy (Views (1), Arena_Views (1));
         for Index in 2 .. Worker_Count loop
            Dynamic_Vectors.Detach (Views (Index));
         end loop;
      end Run_Vector;

      procedure Run_Map is
         type View_Array is array (Positive range <>) of aliased Dynamic_Maps.View;
         Views           : View_Array (1 .. Worker_Count);
         type View_Access is access all Dynamic_Maps.View;
         Finished        : Completion (Worker_Count);
         Attach_Finished : Completion (1);

         protected Start_Gate is
            procedure Arrive;
            entry Go;
         private
            Arrivals : Natural := 0;
         end Start_Gate;

         protected body Start_Gate is
            procedure Arrive is
            begin
               Arrivals := Arrivals + 1;
            end Arrive;

            entry Go when Arrivals = Worker_Count + 1 is
            begin
               null;
            end Go;
         end Start_Gate;

         task type Worker_Task
           (Identifier : Positive;
            Item       : not null View_Access;
            Arena      : not null Arena_Access)
         is
            pragma Task_Info (Flyology.Native_Task);
         end Worker_Task;

         task body Worker_Task is
            Value  : Interfaces.Unsigned_64;
            Result : Dynamic_Maps.Put_Result;
         begin
            Start_Gate.Arrive;
            Start_Gate.Go;
            for Sequence in 1 .. Per_Worker loop
               Value := Interfaces.Unsigned_64 ((Identifier - 1) * Per_Worker + Sequence);
               loop
                  begin
                     Dynamic_Maps.Put (Item.all, Arena.all, Value, Value * 3, Result);
                     exit when Result = Dynamic_Maps.Put_Inserted;
                     if Result = Dynamic_Maps.Put_Replaced then
                        raise Program_Error with "dynamic map replaced a supposedly unique key";
                     elsif Result = Dynamic_Maps.Put_Arena_Exhausted then
                        raise Program_Error with "dynamic map exhausted its concurrency arena";
                     end if;
                  exception
                     when DS.Busy_Error =>
                        null;
                  end;
                  delay 0.0;
               end loop;
            end loop;
            Finished.Done (True);
         exception
            when others =>
               Finished.Done (False);
         end Worker_Task;

         type Worker_Access is access Worker_Task;
         type Worker_Array is array (Positive range <>) of Worker_Access;
         Workers : Worker_Array (1 .. Worker_Count);

         task type Attach_Task is
            pragma Task_Info (Flyology.Native_Task);
         end Attach_Task;

         task body Attach_Task is
            Candidate           : Dynamic_Maps.View;
            Successful_Attaches : Natural := 0;
         begin
            Start_Gate.Arrive;
            Start_Gate.Go;
            while Finished.Completed < Worker_Count or else Successful_Attaches < 32 loop
               begin
                  Dynamic_Maps.Attach (Candidate, Region_B, Dynamic_Map_Location, Arena_Views (2), 2);
                  Successful_Attaches := Successful_Attaches + 1;
                  Dynamic_Maps.Detach (Candidate);
               exception
                  when DS.Busy_Error =>
                     null;
               end;
               delay 0.0;
            end loop;
            Attach_Finished.Done (True);
         exception
            when others =>
               Dynamic_Maps.Detach (Candidate);
               Attach_Finished.Done (False);
         end Attach_Task;

         type Attach_Access is access Attach_Task;
         Attacher : Attach_Access;
         Data     : Interfaces.Unsigned_64;
         Found    : Boolean;
      begin
         Dynamic_Maps.Initialize (Views (1), Region_A, Dynamic_Map_Location, Arena_Views (1), 2);
         for Index in 2 .. Worker_Count loop
            Dynamic_Maps.Attach
              (Views (Index),
               (if Index mod 2 = 0 then Region_B else Region_A),
               Dynamic_Map_Location,
               Arena_Views (Index),
               2);
         end loop;
         for Index in Workers'Range loop
            Workers (Index) := new Worker_Task (Index, Views (Index)'Access, Arena_Views (Index)'Access);
         end loop;
         Attacher := new Attach_Task;
         select
            Finished.Await_All;
         or
            delay 20.0;
            for Worker of Workers loop
               abort Worker.all;
            end loop;
            raise Program_Error with "dynamic-map native-task test timed out";
         end select;
         Assert (Finished.Passed, "dynamic-map concurrent insert tasks failed");
         select
            Attach_Finished.Await_All;
         or
            delay 20.0;
            abort Attacher.all;
            raise Program_Error with "concurrent dynamic-map attachment test timed out";
         end select;
         Assert (Attach_Finished.Passed, "dynamic-map attachment raced a synchronized operation");
         Assert (Dynamic_Maps.Length (Views (1)) = Total, "dynamic-map concurrent insert lost keys");
         for Value in Interfaces.Unsigned_64 range 1 .. Interfaces.Unsigned_64 (Total) loop
            Dynamic_Maps.Get (Views (1), Arena_Views (1), Value, Data, Found);
            Assert (Found and then Data = Value * 3, "dynamic-map concurrent insert corrupted a value");
         end loop;
         Dynamic_Maps.Destroy (Views (1), Arena_Views (1));
         for Index in 2 .. Worker_Count loop
            Dynamic_Maps.Detach (Views (Index));
         end loop;
      end Run_Map;
   begin
      Arenas.Initialize
        (Arena_Views (1),
         Region_A,
         Arena_Location,
         (Usable_Capacity => 1_048_576, Minimum_Block_Size => 64),
         16#D4A9_7C31_08E2_B65F#);
      for Index in 2 .. Worker_Count loop
         Arenas.Attach
           (Arena_Views (Index),
            (if Index mod 2 = 0 then Region_B else Region_A),
            Arena_Location,
            (Usable_Capacity => 1_048_576, Minimum_Block_Size => 64),
            16#D4A9_7C31_08E2_B65F#);
      end loop;
      Run_Vector;
      Run_Map;
      Arenas.Destroy (Arena_Views (1));
      for Index in 2 .. Worker_Count loop
         Arenas.Detach (Arena_Views (Index));
      end loop;
   end Run_Dynamic_Arena;

   procedure Run_Best_Fit_Arena is
      Worker_Count  : constant Positive := 4;
      Per_Worker    : constant Positive := 10_000;
      Configuration : constant Best_Fit_Arenas.Configuration :=
        (Usable_Capacity => 262_080, Minimum_Block_Size => 64);
      Instance      : constant Interfaces.Unsigned_64 := 16#B35F_C0A7_3E11_0001#;
      Views         : array (Positive range 1 .. Worker_Count) of aliased Best_Fit_Arenas.View;
      Finished      : Completion (Worker_Count);

      task type Worker_Task
        (Identifier : Positive;
         Item       : not null access Best_Fit_Arenas.View);

      task body Worker_Task is
         Handle   : Best_Fit_Arenas.Allocation_Handle;
         Result   : Best_Fit_Arenas.Allocation_Result;
         Data     : Ada.Streams.Stream_Element_Array (1 .. 8);
         Expected : Interfaces.Unsigned_64;
      begin
         for Sequence in 1 .. Per_Worker loop
            Expected := Interfaces.Unsigned_64 ((Identifier - 1) * Per_Worker + Sequence);
            loop
               Best_Fit_Arenas.Try_Allocate (Item.all, 1 + Sequence mod 511, Handle, Result);
               exit when Result = Best_Fit_Arenas.Allocated;
               if Result = Best_Fit_Arenas.Exhausted then
                  raise Program_Error with "best-fit concurrency arena unexpectedly exhausted";
               end if;
               delay 0.0;
            end loop;
            Best_Fit_Arenas.Write (Item.all, Handle, 0, Encode (Expected));
            Best_Fit_Arenas.Read (Item.all, Handle, 0, Data);
            if Decode (Data) /= Expected then
               raise Program_Error with "best-fit concurrent payload was corrupted";
            end if;
            loop
               begin
                  Best_Fit_Arenas.Release (Item.all, Handle);
                  exit;
               exception
                  when DS.Busy_Error =>
                     delay 0.0;
               end;
            end loop;
         end loop;
         Finished.Done (True);
      exception
         when others =>
            Finished.Done (False);
      end Worker_Task;

      type Worker_Access is access Worker_Task;
      type Worker_Array is array (Positive range <>) of Worker_Access;
      Workers : Worker_Array (1 .. Worker_Count);
   begin
      Best_Fit_Arenas.Initialize (Views (1), Region_A, Best_Fit_Arena_Location, Configuration, Instance);
      for Index in 2 .. Worker_Count loop
         Best_Fit_Arenas.Attach
           (Views (Index),
            (if Index mod 2 = 0 then Region_B else Region_A),
            Best_Fit_Arena_Location,
            Configuration,
            Instance);
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
         raise Program_Error with "best-fit native-task test timed out";
      end select;
      Assert (Finished.Passed, "best-fit native-task allocation campaign failed");
      Best_Fit_Arenas.Destroy (Views (1));
      for Index in 2 .. Worker_Count loop
         Best_Fit_Arenas.Detach (Views (Index));
      end loop;
   end Run_Best_Fit_Arena;

   procedure Run_TLSF_Arena is
      Worker_Count  : constant Positive := 4;
      Per_Worker    : constant Positive := 10_000;
      Configuration : constant TLSF_Arenas.Configuration :=
        (Usable_Capacity => 262_144, Minimum_Block_Size => 64);
      Instance      : constant Interfaces.Unsigned_64 := 16#715F_C0A7_3E11_0001#;
      Views         : array (Positive range 1 .. Worker_Count) of aliased TLSF_Arenas.View;
      Finished      : Completion (Worker_Count);

      task type Worker_Task
        (Identifier : Positive;
         Item       : not null access TLSF_Arenas.View);

      task body Worker_Task is
         Handle   : TLSF_Arenas.Allocation_Handle;
         Result   : TLSF_Arenas.Allocation_Result;
         Data     : Ada.Streams.Stream_Element_Array (1 .. 8);
         Expected : Interfaces.Unsigned_64;
      begin
         for Sequence in 1 .. Per_Worker loop
            Expected := Interfaces.Unsigned_64 ((Identifier - 1) * Per_Worker + Sequence);
            loop
               TLSF_Arenas.Try_Allocate (Item.all, 1 + Sequence mod 511, Handle, Result);
               exit when Result = TLSF_Arenas.Allocated;
               if Result = TLSF_Arenas.Exhausted then
                  raise Program_Error with "TLSF concurrency arena unexpectedly exhausted";
               end if;
               delay 0.0;
            end loop;
            TLSF_Arenas.Write (Item.all, Handle, 0, Encode (Expected));
            TLSF_Arenas.Read (Item.all, Handle, 0, Data);
            if Decode (Data) /= Expected then
               raise Program_Error with "TLSF concurrent payload was corrupted";
            end if;
            loop
               begin
                  TLSF_Arenas.Release (Item.all, Handle);
                  exit;
               exception
                  when DS.Busy_Error =>
                     delay 0.0;
               end;
            end loop;
         end loop;
         Finished.Done (True);
      exception
         when others =>
            Finished.Done (False);
      end Worker_Task;

      type Worker_Access is access Worker_Task;
      type Worker_Array is array (Positive range <>) of Worker_Access;
      Workers : Worker_Array (1 .. Worker_Count);
   begin
      TLSF_Arenas.Initialize (Views (1), Region_A, TLSF_Arena_Location, Configuration, Instance);
      for Index in 2 .. Worker_Count loop
         TLSF_Arenas.Attach
           (Views (Index),
            (if Index mod 2 = 0 then Region_B else Region_A),
            TLSF_Arena_Location,
            Configuration,
            Instance);
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
         raise Program_Error with "TLSF native-task test timed out";
      end select;
      Assert (Finished.Passed, "TLSF native-task allocation campaign failed");
      TLSF_Arenas.Destroy (Views (1));
      for Index in 2 .. Worker_Count loop
         TLSF_Arenas.Detach (Views (Index));
      end loop;
   end Run_TLSF_Arena;

   procedure Run_Adaptive_Pool is
      Worker_Count  : constant Positive := 4;
      Per_Worker    : constant Positive := 10_000;
      Configuration : constant TLSF_Arenas.Configuration :=
        (Usable_Capacity => 262_144, Minimum_Block_Size => 64);
      Instance      : constant Interfaces.Unsigned_64 := 16#ADA7_C0A7_3E11_0001#;
      Arenas        : array (Positive range 1 .. Worker_Count) of aliased TLSF_Arenas.View;
      Pools         : array (Positive range 1 .. Worker_Count) of aliased Adaptive_U64.View;
      Finished      : Completion (Worker_Count);

      task type Worker_Task
        (Identifier : Positive;
         Pool       : not null access Adaptive_U64.View;
         Arena      : not null access TLSF_Arenas.View);

      task body Worker_Task is
         Handle   : Adaptive_U64.Handle;
         Result   : Adaptive_U64.Allocation_Result;
         Data     : Interfaces.Unsigned_64;
         Expected : Interfaces.Unsigned_64;
      begin
         for Sequence in 1 .. Per_Worker loop
            Expected := Interfaces.Unsigned_64 ((Identifier - 1) * Per_Worker + Sequence);
            loop
               Adaptive_U64.Try_Allocate (Pool.all, Arena.all, Expected, Handle, Result);
               exit when Result = Adaptive_U64.Allocated;
               if Result = Adaptive_U64.Exhausted or else Result = Adaptive_U64.Arena_Exhausted then
                  raise Program_Error with "adaptive concurrency pool unexpectedly exhausted";
               end if;
               delay 0.0;
            end loop;
            loop
               begin
                  Adaptive_U64.Read (Pool.all, Arena.all, Handle, Data);
                  exit;
               exception
                  when DS.Busy_Error =>
                     delay 0.0;
               end;
            end loop;
            if Data /= Expected then
               raise Program_Error with "adaptive concurrent payload was corrupted";
            end if;
            loop
               begin
                  Adaptive_U64.Release (Pool.all, Arena.all, Handle);
                  exit;
               exception
                  when DS.Busy_Error =>
                     delay 0.0;
               end;
            end loop;
         end loop;
         Finished.Done (True);
      exception
         when others =>
            Finished.Done (False);
      end Worker_Task;

      type Worker_Access is access Worker_Task;
      type Worker_Array is array (Positive range <>) of Worker_Access;
      Workers : Worker_Array (1 .. Worker_Count);
   begin
      TLSF_Arenas.Initialize (Arenas (1), Region_A, TLSF_Arena_Location, Configuration, Instance);
      for Index in 2 .. Worker_Count loop
         TLSF_Arenas.Attach
           (Arenas (Index),
            (if Index mod 2 = 0 then Region_B else Region_A),
            TLSF_Arena_Location,
            Configuration,
            Instance);
      end loop;
      Adaptive_U64.Initialize (Pools (1), Region_A, Adaptive_Pool_Location, Arenas (1));
      for Index in 2 .. Worker_Count loop
         Adaptive_U64.Attach
           (Pools (Index),
            (if Index mod 2 = 0 then Region_B else Region_A),
            Adaptive_Pool_Location,
            Arenas (Index));
      end loop;
      for Index in Workers'Range loop
         Workers (Index) := new Worker_Task (Index, Pools (Index)'Access, Arenas (Index)'Access);
      end loop;
      select
         Finished.Await_All;
      or
         delay 20.0;
         for Worker of Workers loop
            abort Worker.all;
         end loop;
         raise Program_Error with "adaptive-pool native-task test timed out";
      end select;
      Assert (Finished.Passed, "adaptive-pool native-task allocation campaign failed");
      for Index in 2 .. Worker_Count loop
         Adaptive_U64.Detach (Pools (Index));
      end loop;
      Adaptive_U64.Destroy (Pools (1), Arenas (1));
      TLSF_Arenas.Destroy (Arenas (1));
      for Index in 2 .. Worker_Count loop
         TLSF_Arenas.Detach (Arenas (Index));
      end loop;
   end Run_Adaptive_Pool;

begin
   Assert
     (Mapping_Create (Path, Mapping_Length, Base_A'Access, Base_B'Access, FD'Access) = 0,
      "failed to map concurrency backing file twice");
   Assert (Base_A /= Base_B, "concurrency mappings share one virtual base");
   Regions.Attach (Region_A, Base_A, DS.Byte_Count (Mapping_Length));
   Regions.Attach (Region_B, Base_B, DS.Byte_Count (Mapping_Length));
   Run_Create_Or_Attach_Race;
   Run_SPSC;
   Run_MPMC;
   Run_Active_MPMC_Attach;
   Run_Slab;
   Run_Internally_Synchronized_Vector;
   Run_Internally_Synchronized_String;
   Run_Internally_Synchronized_Map;
   Run_Dynamic_Arena;
   Run_Best_Fit_Arena;
   Run_TLSF_Arena;
   Run_Adaptive_Pool;
   Regions.Detach (Region_A);
   Regions.Detach (Region_B);
   Assert (Unmap (Base_A, Mapping_Length) = 0, "failed to unmap view A");
   Base_A := System.Null_Address;
   Assert (Unmap (Base_B, Mapping_Length) = 0, "failed to unmap view B");
   Base_B := System.Null_Address;
   Assert (Close_Mapping (Path, FD) = 0, "failed to close concurrency map");
   FD := -1;
   Ada.Text_IO.Put_Line
     ("data structures concurrency passed: SPSC=" & SPSC_Iterations'Image & " MPMC=" & Total_MPMC'Image);
exception
   when others =>
      Cleanup;
      raise;
end Data_Structures_Concurrency_Smoke;
