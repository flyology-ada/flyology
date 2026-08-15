with Ada.Characters.Handling;
with Ada.Command_Line;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology_Allocators;
with Flyology_Allocators.Allocation_Algorithms;
with Flyology_Allocators.Allocation_Algorithms.Best_Fit;
with Flyology_Allocators.Allocation_Algorithms.Buddy;
with Flyology_Allocators.Allocation_Algorithms.TLSF;
with Flyology_Allocators.Arenas;
with Flyology_Allocators.Regions;
with Flyology_Bench;
with Flyology_Bench.Reporters;
with Interfaces.C;
with System;

procedure Allocator_Benchmark is
   package CLI renames Ada.Command_Line;
   package FA renames Flyology_Allocators;
   package Bench renames Flyology_Bench;
   package Reporters renames Flyology_Bench.Reporters;
   package Regions renames FA.Regions;
   package Text renames Ada.Strings.Unbounded;
   package TIO renames Ada.Text_IO;

   package Buddy_Arenas is new FA.Arenas
     (FA.Allocation_Algorithms.Buddy);
   package Best_Fit_Arenas is new FA.Arenas
     (FA.Allocation_Algorithms.Best_Fit);
   package TLSF_Arenas is new FA.Arenas
     (FA.Allocation_Algorithms.TLSF);

   use type Bench.Iteration_Count;
   use type FA.Allocation_Algorithms.Allocation_Handle;
   use type FA.Allocation_Algorithms.Allocation_Result;
   use type FA.Byte_Count;
   use type System.Address;

   type Allocator_Case is (Native_Malloc, Buddy, Best_Fit, TLSF);
   type Workload_Kind is (Fixed_Cycle, Fragmented_Churn);
   type Run_Mode is (All_Workloads, Fixed_Only, Churn_Only);

   function C_Malloc (Size : Interfaces.C.size_t) return System.Address;
   pragma Import (C, C_Malloc, "malloc");

   procedure C_Free (Item : System.Address);
   pragma Import (C, C_Free, "free");

   function Positive_Argument
     (Position : Positive; Default : Positive) return Positive is
   begin
      if CLI.Argument_Count < Position then
         return Default;
      end if;
      return Positive'Value (CLI.Argument (Position));
   exception
      when Constraint_Error =>
         raise Program_Error with
           "numeric benchmark arguments must be positive integers";
   end Positive_Argument;

   function Requested_Mode return Run_Mode is
      Value : constant String :=
        (if CLI.Argument_Count < 4 then "all"
         else Ada.Characters.Handling.To_Lower (CLI.Argument (4)));
   begin
      if Value = "all" then
         return All_Workloads;
      elsif Value = "fixed" then
         return Fixed_Only;
      elsif Value = "churn" then
         return Churn_Only;
      end if;
      raise Program_Error with "benchmark mode must be all, fixed, or churn";
   end Requested_Mode;

   Maximum_Iterations_Argument : constant Positive :=
     Positive_Argument (1, 250_000);
   Samples_Argument : constant Positive := Positive_Argument (2, 30);
   Measurement_Milliseconds : constant Positive := Positive_Argument (3, 750);
   Mode : constant Run_Mode := Requested_Mode;
   Selected_Size : constant Positive := Positive_Argument (5, 64);

   Maximum_Iterations : constant Bench.Iteration_Count :=
     Bench.Iteration_Count (Maximum_Iterations_Argument);
   Samples : constant Bench.Sample_Count :=
     Bench.Sample_Count (Samples_Argument);
   Measurement_Time : constant Duration :=
     Duration (Long_Float (Measurement_Milliseconds) / 1_000.0);

   Arena_Capacity : constant Positive := 4 * 1_024 * 1_024;
   Arena_Location : constant FA.Region_Offset := 64;
   Churn_Window : constant Positive := 256;

   type Size_Array is array (Positive range <>) of Positive;
   Fixed_Sizes : constant Size_Array := [8, 64, 256, 1_024, 4_096];
   Churn_Sizes : constant Size_Array :=
     [8, 24, 64, 96, 256, 1_024, 4_096];

   Buddy_Extent : constant FA.Byte_Count :=
     Buddy_Arenas.Required_Storage
       ((Usable_Capacity => Arena_Capacity, Minimum_Block_Size => 64));
   Best_Fit_Extent : constant FA.Byte_Count :=
     Best_Fit_Arenas.Required_Storage
       ((Usable_Capacity => Arena_Capacity, Minimum_Block_Size => 64));
   TLSF_Extent : constant FA.Byte_Count :=
     TLSF_Arenas.Required_Storage
       ((Usable_Capacity => Arena_Capacity, Minimum_Block_Size => 64));

   Buddy_Base, Best_Fit_Base, TLSF_Base : System.Address :=
     System.Null_Address;
   Buddy_Region, Best_Fit_Region, TLSF_Region : Regions.View;
   Buddy_View : Buddy_Arenas.View;
   Best_Fit_View : Best_Fit_Arenas.View;
   TLSF_View : TLSF_Arenas.View;
   Buddy_Initialized, Best_Fit_Initialized, TLSF_Initialized : Boolean :=
     False;

   subtype Slot_Index is Positive range 1 .. Churn_Window;
   type Native_Slot_Array is array (Slot_Index) of System.Address;
   type Handle_Array is array (Slot_Index) of
     FA.Allocation_Algorithms.Allocation_Handle;
   type Cursor_Array is array (Allocator_Case) of Natural;

   Native_Slots : Native_Slot_Array := [others => System.Null_Address];
   Buddy_Slots : Handle_Array :=
     [others => FA.Allocation_Algorithms.Null_Allocation];
   Best_Fit_Slots : Handle_Array :=
     [others => FA.Allocation_Algorithms.Null_Allocation];
   TLSF_Slots : Handle_Array :=
     [others => FA.Allocation_Algorithms.Null_Allocation];
   Churn_Cursors : Cursor_Array := [others => 0];

   Active_Workload : Workload_Kind := Fixed_Cycle;
   Active_Size : Positive := 64;
   Completed_Operations : Bench.Iteration_Count := 0 with Volatile;

   function Native_Size (Value : FA.Byte_Count) return Interfaces.C.size_t is
      Result : constant Interfaces.C.size_t := Interfaces.C.size_t (Value);
   begin
      if FA.Byte_Count (Result) /= Value then
         raise Constraint_Error with
           "allocation size is not C-size representable";
      end if;
      return Result;
   end Native_Size;

   function Allocate_Native (Size : Positive) return System.Address is
      Result : constant System.Address :=
        C_Malloc (Native_Size (FA.Byte_Count (Size)));
   begin
      if Result = System.Null_Address then
         raise Storage_Error with "native malloc failed";
      end if;
      return Result;
   end Allocate_Native;

   procedure Prepare_Region
     (Base   : in out System.Address;
      Region : in out Regions.View;
      Extent : FA.Byte_Count)
   is
      Length : constant FA.Byte_Count :=
        Extent + FA.Byte_Count (Arena_Location);
   begin
      Base := C_Malloc (Native_Size (Length));
      if Base = System.Null_Address then
         raise Storage_Error with "arena backing allocation failed";
      end if;
      Regions.Attach (Region, Base, Length);
   end Prepare_Region;

   procedure Initialize_Arenas is
   begin
      Prepare_Region (Buddy_Base, Buddy_Region, Buddy_Extent);
      Buddy_Arenas.Initialize
        (Buddy_View, Buddy_Region, Arena_Location,
         (Usable_Capacity => Arena_Capacity, Minimum_Block_Size => 64),
         16#BADD_0000_0000_0001#);
      Buddy_Initialized := True;

      Prepare_Region (Best_Fit_Base, Best_Fit_Region, Best_Fit_Extent);
      Best_Fit_Arenas.Initialize
        (Best_Fit_View, Best_Fit_Region, Arena_Location,
         (Usable_Capacity => Arena_Capacity, Minimum_Block_Size => 64),
         16#BE57_0000_0000_0001#);
      Best_Fit_Initialized := True;

      Prepare_Region (TLSF_Base, TLSF_Region, TLSF_Extent);
      TLSF_Arenas.Initialize
        (TLSF_View, TLSF_Region, Arena_Location,
         (Usable_Capacity => Arena_Capacity, Minimum_Block_Size => 64),
         16#715F_0000_0000_0001#);
      TLSF_Initialized := True;
   end Initialize_Arenas;

   procedure Fixed_Operation (Which : Allocator_Case; Size : Positive) is
      Handle : FA.Allocation_Algorithms.Allocation_Handle;
      Result : FA.Allocation_Algorithms.Allocation_Result;
      Address : System.Address;
   begin
      case Which is
         when Native_Malloc =>
            Address := Allocate_Native (Size);
            C_Free (Address);
         when Buddy =>
            Buddy_Arenas.Try_Allocate (Buddy_View, Size, Handle, Result);
            if Result /= Buddy_Arenas.Allocated then
               raise Program_Error with "buddy allocation cycle failed";
            end if;
            Buddy_Arenas.Release (Buddy_View, Handle);
         when Best_Fit =>
            Best_Fit_Arenas.Try_Allocate
              (Best_Fit_View, Size, Handle, Result);
            if Result /= Best_Fit_Arenas.Allocated then
               raise Program_Error with "best-fit allocation cycle failed";
            end if;
            Best_Fit_Arenas.Release (Best_Fit_View, Handle);
         when TLSF =>
            TLSF_Arenas.Try_Allocate (TLSF_View, Size, Handle, Result);
            if Result /= TLSF_Arenas.Allocated then
               raise Program_Error with "TLSF allocation cycle failed";
            end if;
            TLSF_Arenas.Release (TLSF_View, Handle);
      end case;
   end Fixed_Operation;

   function Churn_Size (Sequence : Natural) return Positive is
     (Churn_Sizes
        (Churn_Sizes'First + Sequence mod Churn_Sizes'Length));

   procedure Allocate_Slot
     (Which : Allocator_Case; Slot : Slot_Index; Size : Positive)
   is
      Handle : FA.Allocation_Algorithms.Allocation_Handle;
      Result : FA.Allocation_Algorithms.Allocation_Result;
   begin
      case Which is
         when Native_Malloc =>
            Native_Slots (Slot) := Allocate_Native (Size);
         when Buddy =>
            Buddy_Arenas.Try_Allocate (Buddy_View, Size, Handle, Result);
            if Result /= Buddy_Arenas.Allocated then
               raise Program_Error with "buddy churn allocation failed";
            end if;
            Buddy_Slots (Slot) := Handle;
         when Best_Fit =>
            Best_Fit_Arenas.Try_Allocate
              (Best_Fit_View, Size, Handle, Result);
            if Result /= Best_Fit_Arenas.Allocated then
               raise Program_Error with "best-fit churn allocation failed";
            end if;
            Best_Fit_Slots (Slot) := Handle;
         when TLSF =>
            TLSF_Arenas.Try_Allocate (TLSF_View, Size, Handle, Result);
            if Result /= TLSF_Arenas.Allocated then
               raise Program_Error with "TLSF churn allocation failed";
            end if;
            TLSF_Slots (Slot) := Handle;
      end case;
   end Allocate_Slot;

   procedure Release_Slot (Which : Allocator_Case; Slot : Slot_Index) is
   begin
      case Which is
         when Native_Malloc =>
            if Native_Slots (Slot) /= System.Null_Address then
               C_Free (Native_Slots (Slot));
               Native_Slots (Slot) := System.Null_Address;
            end if;
         when Buddy =>
            if Buddy_Slots (Slot) /= Buddy_Arenas.Null_Allocation then
               Buddy_Arenas.Release (Buddy_View, Buddy_Slots (Slot));
               Buddy_Slots (Slot) := Buddy_Arenas.Null_Allocation;
            end if;
         when Best_Fit =>
            if Best_Fit_Slots (Slot) /= Best_Fit_Arenas.Null_Allocation then
               Best_Fit_Arenas.Release
                 (Best_Fit_View, Best_Fit_Slots (Slot));
               Best_Fit_Slots (Slot) := Best_Fit_Arenas.Null_Allocation;
            end if;
         when TLSF =>
            if TLSF_Slots (Slot) /= TLSF_Arenas.Null_Allocation then
               TLSF_Arenas.Release (TLSF_View, TLSF_Slots (Slot));
               TLSF_Slots (Slot) := TLSF_Arenas.Null_Allocation;
            end if;
      end case;
   end Release_Slot;

   procedure Prepare_Churn is
   begin
      for Which in Allocator_Case loop
         Churn_Cursors (Which) := 0;
         for Slot in Slot_Index loop
            Allocate_Slot (Which, Slot, Churn_Size (Slot - 1));
            Churn_Cursors (Which) := Churn_Cursors (Which) + 1;
         end loop;
      end loop;
   end Prepare_Churn;

   procedure Churn_Operation (Which : Allocator_Case) is
      Sequence : constant Natural := Churn_Cursors (Which);
      Slot : constant Slot_Index :=
        Slot_Index (Sequence mod Churn_Window + 1);
   begin
      Release_Slot (Which, Slot);
      Allocate_Slot (Which, Slot, Churn_Size (Sequence));
      Churn_Cursors (Which) := Sequence + 1;
   end Churn_Operation;

   procedure Cleanup_Churn is
   begin
      for Which in Allocator_Case loop
         for Slot in Slot_Index loop
            Release_Slot (Which, Slot);
         end loop;
      end loop;
   end Cleanup_Churn;

   procedure Allocator_Batch
     (Which : Allocator_Case; Iterations : Bench.Iteration_Count)
   is
      Remaining : Bench.Iteration_Count := Iterations;
   begin
      while Remaining > 0 loop
         case Active_Workload is
            when Fixed_Cycle => Fixed_Operation (Which, Active_Size);
            when Fragmented_Churn => Churn_Operation (Which);
         end case;
         Remaining := Remaining - 1;
      end loop;
      Completed_Operations := Completed_Operations + Iterations;
   end Allocator_Batch;

   procedure Compare_Allocators is new Bench.Compare_Many
     (Case_Id => Allocator_Case, Batch => Allocator_Batch);
   procedure Put_Allocators is new Reporters.Put_Multi_Comparison_Console
     (Allocator_Case);

   function Configuration (Name : String) return Bench.Configuration is
      Base : constant Bench.Configuration :=
        (Warmup_Time         => 0.100,
         Measurement_Time    => Measurement_Time,
         Samples             => Samples,
         Minimum_Sample_Time => 0.000_100,
         Maximum_Iterations  => Maximum_Iterations,
         Comparison_Batching => Bench.Shared_Iterations,
         Shootout_Scheduling => Bench.Balanced_Rounds,
         Practical_Threshold_Percent => 1.0,
         Random_Seed         => 16#A110_CA70#,
         Metrics             => Bench.Time_Metrics,
         Progress            => Reporters.Terminal_Progress'Access,
         Progress_Name       => Text.To_Unbounded_String (Name),
         others              => <>);
   begin
      return Base;
   end Configuration;

   procedure Run_Fixed (Size : Positive) is
      Result : Bench.Multi_Comparison;
      Name : constant String := "fixed" & Positive'Image (Size) & " bytes";
   begin
      Active_Workload := Fixed_Cycle;
      Active_Size := Size;
      TIO.New_Line;
      TIO.Put_Line
        ("Fixed-size allocation/release: requested bytes =" & Size'Image);
      Compare_Allocators (Configuration (Name), Result);
      Put_Allocators (Result);
   end Run_Fixed;

   procedure Run_Churn is
      Result : Bench.Multi_Comparison;
   begin
      Active_Workload := Fragmented_Churn;
      Prepare_Churn;
      TIO.New_Line;
      TIO.Put_Line
        ("Fragmented churn: replace one of" & Churn_Window'Image
         & " live allocations per operation");
      Compare_Allocators (Configuration ("fragmented churn"), Result);
      Put_Allocators (Result);
      Cleanup_Churn;
   exception
      when others =>
         Cleanup_Churn;
         raise;
   end Run_Churn;

   procedure Finalize is
   begin
      Cleanup_Churn;
      if Buddy_Initialized then
         Buddy_Arenas.Destroy (Buddy_View);
         Buddy_Initialized := False;
      end if;
      if Best_Fit_Initialized then
         Best_Fit_Arenas.Destroy (Best_Fit_View);
         Best_Fit_Initialized := False;
      end if;
      if TLSF_Initialized then
         TLSF_Arenas.Destroy (TLSF_View);
         TLSF_Initialized := False;
      end if;
      if Regions.Is_Attached (Buddy_Region) then
         Regions.Detach (Buddy_Region);
      end if;
      if Regions.Is_Attached (Best_Fit_Region) then
         Regions.Detach (Best_Fit_Region);
      end if;
      if Regions.Is_Attached (TLSF_Region) then
         Regions.Detach (TLSF_Region);
      end if;
      if Buddy_Base /= System.Null_Address then
         C_Free (Buddy_Base);
         Buddy_Base := System.Null_Address;
      end if;
      if Best_Fit_Base /= System.Null_Address then
         C_Free (Best_Fit_Base);
         Best_Fit_Base := System.Null_Address;
      end if;
      if TLSF_Base /= System.Null_Address then
         C_Free (TLSF_Base);
         TLSF_Base := System.Null_Address;
      end if;
   end Finalize;

begin
   Initialize_Arenas;
   TIO.Put_Line ("Flyology Allocators vs native malloc/free");
   TIO.Put_Line
     ("  shared iterations, balanced rounds, malloc reference; lower ns/op is faster");
   TIO.Put_Line
     ("  arenas use 64-byte minimum blocks; backing and setup are outside timed batches");

   case Mode is
      when All_Workloads =>
         for Size of Fixed_Sizes loop
            Run_Fixed (Size);
         end loop;
         Run_Churn;
      when Fixed_Only =>
         Run_Fixed (Selected_Size);
      when Churn_Only =>
         Run_Churn;
   end case;

   TIO.Put_Line
     ("completed logical operations:" & Completed_Operations'Image);
   Finalize;
exception
   when others =>
      Finalize;
      raise;
end Allocator_Benchmark;
