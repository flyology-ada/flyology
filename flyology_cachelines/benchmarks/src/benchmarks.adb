with Ada.Command_Line;
with Ada.Long_Float_Text_IO;
with Ada.Real_Time;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Flyology_Cachelines;
with Flyology_Cachelines.Fitted_Groups;
with Flyology_Cachelines.Padded;
with Flyology_Cachelines.Padded_Groups;
with System;
with System.Multiprocessors;

procedure Benchmarks is
   use type Ada.Real_Time.Time;

   type Counter is mod 2**64 with Atomic;

   package Padded_Counters is new Flyology_Cachelines.Padded (Counter);
   package Fitted_Counter_Groups is new Flyology_Cachelines.Fitted_Groups (Counter);

   Task_Group_Length : constant Positive := Positive'Max (1, Fitted_Counter_Groups.Elements_Per_Group / 2);
   package Padded_Task_Groups is new
     Flyology_Cachelines.Padded_Groups (Element_Type => Counter, Group_Length => Task_Group_Length);

   type Compact_Array is array (Positive range <>) of aliased Counter;
   type Padded_Array is array (Positive range <>) of aliased Padded_Counters.Padded;
   type Compact_Task_Group_Array is array (Positive range <>) of aliased Padded_Task_Groups.Element_Array;
   type Padded_Task_Group_Array is array (Positive range <>) of aliased Padded_Task_Groups.Group;

   type Fitted_Group_Array is array (Positive range <>) of aliased Fitted_Counter_Groups.Group;

   type Compact_Array_Access is access Compact_Array;
   type Padded_Array_Access is access Padded_Array;
   type Compact_Task_Group_Array_Access is access Compact_Task_Group_Array;
   type Padded_Task_Group_Array_Access is access Padded_Task_Group_Array;
   type Fitted_Group_Array_Access is access Fitted_Group_Array;
   type Fitted_Grouped_Array_Access is access Fitted_Counter_Groups.Grouped_Array;

   type Single_Algorithm is (Sequential, Strided, Hot_Set);
   type Parallel_Algorithm is (Isolated, Grouped, Interleaved, Sharded);

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   function Positive_Argument (Index : Positive; Default : Positive) return Positive is
   begin
      if Ada.Command_Line.Argument_Count < Index then
         return Default;
      end if;
      return Positive'Value (Ada.Command_Line.Argument (Index));
   exception
      when Constraint_Error =>
         raise Constraint_Error with "argument" & Index'Image & " must be a positive integer";
   end Positive_Argument;

   function Default_Worker_Count return Positive is
      Count : constant Positive := Positive (System.Multiprocessors.Number_Of_CPUs);
   begin
      return (if Count > 16 then 16 else Count);
   end Default_Worker_Count;

   function Greatest_Common_Divisor (Left : Positive; Right : Positive) return Positive is
      A : Natural := Left;
      B : Natural := Right;
   begin
      while B /= 0 loop
         declare
            Remainder : constant Natural := A mod B;
         begin
            A := B;
            B := Remainder;
         end;
      end loop;
      return A;
   end Greatest_Common_Divisor;

   function Coprime_Stride (Length : Positive) return Positive is
      Candidate : Positive := (if Length > 4_099 then 4_099 else 1);
   begin
      while Greatest_Common_Divisor (Candidate, Length) /= 1 loop
         Candidate := Candidate + 2;
         if Candidate >= Length then
            Candidate := 1;
         end if;
      end loop;
      return Candidate;
   end Coprime_Stride;

   function Operation_Count
     (Algorithm : Single_Algorithm; Item_Count : Positive; Repetitions : Positive) return Long_Long_Integer
   is (if Algorithm = Hot_Set
       then Long_Long_Integer (Repetitions)
       else Long_Long_Integer (Item_Count) * Long_Long_Integer (Repetitions));

   function Operation_Count
     (Algorithm : Parallel_Algorithm; Item_Count : Positive; Worker_Count : Positive; Repetitions : Positive)
      return Long_Long_Integer
   is (if Algorithm = Isolated or else Algorithm = Grouped
       then Long_Long_Integer (Worker_Count) * Long_Long_Integer (Repetitions)
       else Long_Long_Integer (Item_Count) * Long_Long_Integer (Repetitions));

   generic
      with procedure Increment (Index : Positive);
   procedure Run_Single
     (Algorithm : Single_Algorithm; Item_Count : Positive; Repetitions : Positive; Elapsed : out Duration);

   procedure Run_Single
     (Algorithm : Single_Algorithm; Item_Count : Positive; Repetitions : Positive; Elapsed : out Duration)
   is
      Start     : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Hot_Count : constant Positive := (if Item_Count < 8 then Item_Count else 8);
      Stride    : constant Positive := Coprime_Stride (Item_Count);
      Index     : Positive;
   begin
      case Algorithm is
         when Sequential =>
            for Pass in 1 .. Repetitions loop
               for Item in 1 .. Item_Count loop
                  Increment (Item);
               end loop;
            end loop;

         when Strided    =>
            for Pass in 1 .. Repetitions loop
               Index := 1;
               for Item in 1 .. Item_Count loop
                  Increment (Index);
                  Index := ((Index - 1 + Stride) mod Item_Count) + 1;
               end loop;
            end loop;

         when Hot_Set    =>
            for Operation in 1 .. Repetitions loop
               Increment (((Operation - 1) mod Hot_Count) + 1);
            end loop;
      end case;

      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Start);
   end Run_Single;

   generic
      with procedure Increment (Index : Positive);
   procedure Run_Parallel
     (Algorithm    : Parallel_Algorithm;
      Item_Count   : Positive;
      Worker_Count : Positive;
      Repetitions  : Positive;
      Elapsed      : out Duration;
      Group_Length : Positive := 1);

   procedure Run_Parallel
     (Algorithm    : Parallel_Algorithm;
      Item_Count   : Positive;
      Worker_Count : Positive;
      Repetitions  : Positive;
      Elapsed      : out Duration;
      Group_Length : Positive := 1)
   is
      protected type Start_Gate is
         entry Wait;
         procedure Release;
      private
         Started : Boolean := False;
      end Start_Gate;

      protected body Start_Gate is
         entry Wait when Started is
         begin
            null;
         end Wait;

         procedure Release is
         begin
            Started := True;
         end Release;
      end Start_Gate;

      protected type Completion_Gate (Target : Positive) is
         procedure Mark_Done (Succeeded : Boolean);
         entry Wait (Failed : out Boolean);
      private
         Completed  : Natural := 0;
         Any_Failed : Boolean := False;
      end Completion_Gate;

      protected body Completion_Gate is
         procedure Mark_Done (Succeeded : Boolean) is
         begin
            Completed := Completed + 1;
            Any_Failed := Any_Failed or else not Succeeded;
         end Mark_Done;

         entry Wait (Failed : out Boolean) when Completed = Target is
         begin
            Failed := Any_Failed;
         end Wait;
      end Completion_Gate;

      Gate     : Start_Gate;
      Finished : Completion_Gate (Worker_Count);

      task type Worker is
         entry Configure (Identifier : Positive);
      end Worker;

      task body Worker is
         Worker_Id : Positive := 1;
      begin
         accept Configure (Identifier : Positive) do
            Worker_Id := Identifier;
         end Configure;
         Gate.Wait;

         case Algorithm is
            when Isolated    =>
               for Operation in 1 .. Repetitions loop
                  Increment (Worker_Id);
               end loop;

            when Grouped     =>
               for Operation in 1 .. Repetitions loop
                  Increment ((Worker_Id - 1) * Group_Length + ((Operation - 1) mod Group_Length) + 1);
               end loop;

            when Interleaved =>
               declare
                  Index : Positive := Worker_Id;
               begin
                  while Index <= Item_Count loop
                     for Pass in 1 .. Repetitions loop
                        Increment (Index);
                     end loop;
                     Index := Index + Worker_Count;
                  end loop;
               end;

            when Sharded     =>
               declare
                  First : constant Positive := ((Worker_Id - 1) * Item_Count / Worker_Count) + 1;
                  Last  : constant Natural := Worker_Id * Item_Count / Worker_Count;
               begin
                  for Pass in 1 .. Repetitions loop
                     for Index in First .. Last loop
                        Increment (Index);
                     end loop;
                  end loop;
               end;
         end case;

         Finished.Mark_Done (Succeeded => True);
      exception
         when others =>
            Finished.Mark_Done (Succeeded => False);
      end Worker;

      Workers : array (1 .. Worker_Count) of Worker;
      Start   : Ada.Real_Time.Time;
      Failed  : Boolean;
   begin
      for Index in Workers'Range loop
         Workers (Index).Configure (Index);
      end loop;

      Start := Ada.Real_Time.Clock;
      Gate.Release;
      Finished.Wait (Failed);
      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Start);
      Check (not Failed, "a benchmark worker task failed");
   end Run_Parallel;

   Element_Count         : constant Positive := Positive_Argument (1, 1_000_003);
   Pass_Count            : constant Positive := Positive_Argument (2, 3);
   Iterations_Per_Worker : constant Positive := Positive_Argument (3, 5_000_000);
   Requested_Workers     : constant Positive := Positive_Argument (4, Default_Worker_Count);
   Worker_Count          : constant Positive :=
     (if Requested_Workers > Element_Count then Element_Count else Requested_Workers);
   Sample_Count          : constant Positive := Positive_Argument (5, 3);

   Compact_Data                    : Compact_Array_Access := new Compact_Array (1 .. Element_Count);
   Padded_Data                     : Padded_Array_Access := new Padded_Array (1 .. Element_Count);
   Compact_Task_Group_Data         : Compact_Task_Group_Array_Access :=
     new Compact_Task_Group_Array (1 .. Worker_Count);
   Padded_Task_Group_Data          : Padded_Task_Group_Array_Access :=
     new Padded_Task_Group_Array (1 .. Worker_Count);
   Individually_Aligned_Group_Data : Padded_Array_Access :=
     new Padded_Array (1 .. Worker_Count * Fitted_Counter_Groups.Elements_Per_Group);
   Fitted_Group_Data               : Fitted_Group_Array_Access := new Fitted_Group_Array (1 .. Worker_Count);
   Nested_Iteration_Data           : Fitted_Grouped_Array_Access :=
     new Fitted_Counter_Groups.Grouped_Array'
       (Fitted_Counter_Groups.Create (Element_Count => Element_Count, Initial_Value => 0));
   Flat_Iteration_Data             : Fitted_Grouped_Array_Access :=
     new Fitted_Counter_Groups.Grouped_Array'
       (Fitted_Counter_Groups.Create (Element_Count => Element_Count, Initial_Value => 0));
   Iterable_Iteration_Data         : Fitted_Grouped_Array_Access :=
     new Fitted_Counter_Groups.Grouped_Array'
       (Fitted_Counter_Groups.Create (Element_Count => Element_Count, Initial_Value => 0));

   Compact_Bytes                    : constant Long_Long_Integer :=
     Long_Long_Integer (Element_Count) * Long_Long_Integer (Counter'Object_Size / System.Storage_Unit);
   Padded_Bytes                     : constant Long_Long_Integer :=
     Long_Long_Integer (Element_Count) * Long_Long_Integer (Padded_Counters.Padded_Size_In_Storage_Elements);
   Compact_Task_Group_Bytes         : constant Long_Long_Integer :=
     Long_Long_Integer (Worker_Count * Task_Group_Length)
     * Long_Long_Integer (Counter'Object_Size / System.Storage_Unit);
   Padded_Task_Group_Bytes          : constant Long_Long_Integer :=
     Long_Long_Integer (Worker_Count) * Long_Long_Integer (Padded_Task_Groups.Group_Size_In_Storage_Elements);
   Individually_Aligned_Group_Bytes : constant Long_Long_Integer :=
     Long_Long_Integer (Worker_Count * Fitted_Counter_Groups.Elements_Per_Group)
     * Long_Long_Integer (Padded_Counters.Padded_Size_In_Storage_Elements);
   Fitted_Group_Bytes               : constant Long_Long_Integer :=
     Long_Long_Integer (Worker_Count)
     * Long_Long_Integer (Fitted_Counter_Groups.Group_Size_In_Storage_Elements);
   Fitted_Sequence_Bytes            : constant Long_Long_Integer :=
     Long_Long_Integer (Flat_Iteration_Data.all'Size / System.Storage_Unit);

   procedure Run_Nested_Group_Iteration (Repetitions : Positive; Elapsed : out Duration) is
      Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      for Pass in 1 .. Repetitions loop
         for Group_Number in Nested_Iteration_Data.Groups'Range loop
            declare
               Last : constant Fitted_Counter_Groups.Index :=
                 (if Group_Number = Nested_Iteration_Data.Group_Count
                  then Nested_Iteration_Data.Last_Group_Length
                  else Fitted_Counter_Groups.Index'Last);
            begin
               for Slot in Fitted_Counter_Groups.Index'First .. Last loop
                  Nested_Iteration_Data.Groups (Group_Number) (Slot) :=
                    Nested_Iteration_Data.Groups (Group_Number) (Slot) + 1;
               end loop;
            end;
         end loop;
      end loop;
      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Start);
   end Run_Nested_Group_Iteration;

   procedure Run_Flat_Group_Iteration (Repetitions : Positive; Elapsed : out Duration) is
      Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      for Pass in 1 .. Repetitions loop
         for Item of Flat_Iteration_Data.all loop
            Item := Item + 1;
         end loop;
      end loop;
      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Start);
   end Run_Flat_Group_Iteration;

   procedure Run_Iterable_Group_Iteration (Repetitions : Positive; Elapsed : out Duration) is
      View  : Fitted_Counter_Groups.Fast_View (Iterable_Iteration_Data);
      Start : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      for Pass in 1 .. Repetitions loop
         for Item of View loop
            Item := Item + 1;
         end loop;
      end loop;
      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Start);
   end Run_Iterable_Group_Iteration;

   procedure Increment_Compact (Index : Positive) is
   begin
      Compact_Data (Index) := Compact_Data (Index) + 1;
   end Increment_Compact;

   procedure Increment_Padded (Index : Positive) is
   begin
      Padded_Data (Index).Value := Padded_Data (Index).Value + 1;
   end Increment_Padded;

   procedure Increment_Compact_Task_Group (Index : Positive) is
      Worker : constant Positive := ((Index - 1) / Task_Group_Length) + 1;
      Slot   : constant Positive := ((Index - 1) mod Task_Group_Length) + 1;
   begin
      Compact_Task_Group_Data (Worker) (Slot) := Compact_Task_Group_Data (Worker) (Slot) + 1;
   end Increment_Compact_Task_Group;

   procedure Increment_Padded_Task_Group (Index : Positive) is
      Worker : constant Positive := ((Index - 1) / Task_Group_Length) + 1;
      Slot   : constant Positive := ((Index - 1) mod Task_Group_Length) + 1;
   begin
      Padded_Task_Group_Data (Worker) (Slot) := Padded_Task_Group_Data (Worker) (Slot) + 1;
   end Increment_Padded_Task_Group;

   procedure Increment_Individually_Aligned_Group (Index : Positive) is
   begin
      Individually_Aligned_Group_Data (Index).Value := Individually_Aligned_Group_Data (Index).Value + 1;
   end Increment_Individually_Aligned_Group;

   procedure Increment_Fitted_Group (Index : Positive) is
      Worker : constant Positive := ((Index - 1) / Fitted_Counter_Groups.Elements_Per_Group) + 1;
      Slot   : constant Positive := ((Index - 1) mod Fitted_Counter_Groups.Elements_Per_Group) + 1;
   begin
      Fitted_Group_Data (Worker) (Slot) := Fitted_Group_Data (Worker) (Slot) + 1;
   end Increment_Fitted_Group;

   procedure Run_Single_Compact is new Run_Single (Increment_Compact);
   procedure Run_Single_Padded is new Run_Single (Increment_Padded);
   procedure Run_Parallel_Compact is new Run_Parallel (Increment_Compact);
   procedure Run_Parallel_Padded is new Run_Parallel (Increment_Padded);
   procedure Run_Parallel_Compact_Task_Groups is new Run_Parallel (Increment_Compact_Task_Group);
   procedure Run_Parallel_Padded_Task_Groups is new Run_Parallel (Increment_Padded_Task_Group);
   procedure Run_Parallel_Individually_Aligned_Groups is new
     Run_Parallel (Increment_Individually_Aligned_Group);
   procedure Run_Parallel_Fitted_Groups is new Run_Parallel (Increment_Fitted_Group);

   function Compact_Sum return Counter is
      Result : Counter := 0;
   begin
      for Item of Compact_Data.all loop
         Result := Result + Item;
      end loop;
      return Result;
   end Compact_Sum;

   function Padded_Sum return Counter is
      Result : Counter := 0;
   begin
      for Item of Padded_Data.all loop
         Result := Result + Item.Value;
      end loop;
      return Result;
   end Padded_Sum;

   function Compact_Task_Group_Sum return Counter is
      Result : Counter := 0;
   begin
      for Group of Compact_Task_Group_Data.all loop
         for Item of Group loop
            Result := Result + Item;
         end loop;
      end loop;
      return Result;
   end Compact_Task_Group_Sum;

   function Padded_Task_Group_Sum return Counter is
      Result : Counter := 0;
   begin
      for Group of Padded_Task_Group_Data.all loop
         for Item of Group loop
            Result := Result + Item;
         end loop;
      end loop;
      return Result;
   end Padded_Task_Group_Sum;

   function Individually_Aligned_Group_Sum return Counter is
      Result : Counter := 0;
   begin
      for Item of Individually_Aligned_Group_Data.all loop
         Result := Result + Item.Value;
      end loop;
      return Result;
   end Individually_Aligned_Group_Sum;

   function Fitted_Group_Sum return Counter is
      Result : Counter := 0;
   begin
      for Group of Fitted_Group_Data.all loop
         for Item of Group loop
            Result := Result + Item;
         end loop;
      end loop;
      return Result;
   end Fitted_Group_Sum;

   function Nested_Iteration_Sum return Counter is
      Result : Counter := 0;
   begin
      for Group_Number in Nested_Iteration_Data.Groups'Range loop
         declare
            Last : constant Fitted_Counter_Groups.Index :=
              (if Group_Number = Nested_Iteration_Data.Group_Count
               then Nested_Iteration_Data.Last_Group_Length
               else Fitted_Counter_Groups.Index'Last);
         begin
            for Slot in Fitted_Counter_Groups.Index'First .. Last loop
               Result := Result + Nested_Iteration_Data.Groups (Group_Number) (Slot);
            end loop;
         end;
      end loop;
      return Result;
   end Nested_Iteration_Sum;

   function Flat_Iteration_Sum return Counter is
      Result : Counter := 0;
   begin
      for Item of Flat_Iteration_Data.all loop
         Result := Result + Item;
      end loop;
      return Result;
   end Flat_Iteration_Sum;

   function Iterable_Iteration_Sum return Counter is
      Result : Counter := 0;
   begin
      for Group_Number in Iterable_Iteration_Data.Groups'Range loop
         declare
            Last : constant Fitted_Counter_Groups.Index :=
              (if Group_Number = Iterable_Iteration_Data.Group_Count
               then Iterable_Iteration_Data.Last_Group_Length
               else Fitted_Counter_Groups.Index'Last);
         begin
            for Slot in Fitted_Counter_Groups.Index'First .. Last loop
               Result := Result + Iterable_Iteration_Data.Groups (Group_Number) (Slot);
            end loop;
         end;
      end loop;
      return Result;
   end Iterable_Iteration_Sum;

   procedure Put_Rate (Operations : Long_Long_Integer; Elapsed : Duration) is
      Rate : constant Long_Float := Long_Float (Operations) / Long_Float (Elapsed);
   begin
      Ada.Long_Float_Text_IO.Put (Rate, Fore => 1, Aft => 0, Exp => 0);
   end Put_Rate;

   procedure Report_Pair
     (Name                  : String;
      Operations            : Long_Long_Integer;
      Compact               : Duration;
      Padded                : Duration;
      Compact_Label         : String := "compact";
      Padded_Label          : String := "padded";
      Speedup_Label         : String := "padded speedup";
      Compact_Storage_Bytes : Long_Long_Integer := 0;
      Padded_Storage_Bytes  : Long_Long_Integer := 0)
   is
      Speedup : constant Long_Float := Long_Float (Compact) / Long_Float (Padded);
   begin
      Ada.Text_IO.Put_Line ("");
      Ada.Text_IO.Put_Line (Name);
      Ada.Text_IO.Put ("  " & Compact_Label & ": " & Compact'Image & " s, ");
      Put_Rate (Operations, Compact);
      Ada.Text_IO.Put (" ops/s");
      if Compact_Storage_Bytes > 0 then
         Ada.Text_IO.Put ("," & Compact_Storage_Bytes'Image & " bytes");
      end if;
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put ("  " & Padded_Label & ": " & Padded'Image & " s, ");
      Put_Rate (Operations, Padded);
      Ada.Text_IO.Put (" ops/s");
      if Padded_Storage_Bytes > 0 then
         Ada.Text_IO.Put ("," & Padded_Storage_Bytes'Image & " bytes");
      end if;
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put ("  " & Speedup_Label & ": ");
      Ada.Long_Float_Text_IO.Put (Speedup, Fore => 1, Aft => 2, Exp => 0);
      Ada.Text_IO.Put_Line ("x");
   end Report_Pair;

   procedure Measure_Single_Pair (Algorithm : Single_Algorithm; Name : String; Repetitions : Positive) is
      Operations     : constant Long_Long_Integer := Operation_Count (Algorithm, Element_Count, Repetitions);
      Compact_Before : constant Counter := Compact_Sum;
      Padded_Before  : constant Counter := Padded_Sum;
      Compact_Best   : Duration := Duration'Last;
      Padded_Best    : Duration := Duration'Last;
      Compact_Time   : Duration;
      Padded_Time    : Duration;
   begin
      for Sample in 1 .. Sample_Count loop
         if Sample mod 2 = 1 then
            Run_Single_Compact (Algorithm, Element_Count, Repetitions, Compact_Time);
            Run_Single_Padded (Algorithm, Element_Count, Repetitions, Padded_Time);
         else
            Run_Single_Padded (Algorithm, Element_Count, Repetitions, Padded_Time);
            Run_Single_Compact (Algorithm, Element_Count, Repetitions, Compact_Time);
         end if;
         Compact_Best := Duration'Min (Compact_Best, Compact_Time);
         Padded_Best := Duration'Min (Padded_Best, Padded_Time);
      end loop;

      Check
        (Compact_Sum - Compact_Before = Counter (Operations * Long_Long_Integer (Sample_Count)),
         "compact single-task benchmark produced an incorrect result");
      Check
        (Padded_Sum - Padded_Before = Counter (Operations * Long_Long_Integer (Sample_Count)),
         "padded single-task benchmark produced an incorrect result");
      Report_Pair (Name, Operations, Compact_Best, Padded_Best);
   end Measure_Single_Pair;

   type Group_Run_Access is access procedure (Repetitions : Positive; Elapsed : out Duration);
   type Group_Sum_Access is access function return Counter;

   procedure Measure_Group_Iteration_Pair
     (Name              : String;
      Alternative_Label : String;
      Speedup_Label     : String;
      Run_Alternative   : not null Group_Run_Access;
      Alternative_Sum   : not null Group_Sum_Access)
   is
      Operations         : constant Long_Long_Integer :=
        Long_Long_Integer (Element_Count) * Long_Long_Integer (Pass_Count);
      Nested_Before      : constant Counter := Nested_Iteration_Sum;
      Alternative_Before : constant Counter := Alternative_Sum.all;
      Nested_Best        : Duration := Duration'Last;
      Alternative_Best   : Duration := Duration'Last;
      Nested_Time        : Duration;
      Alternative_Time   : Duration;
   begin
      for Sample in 1 .. Sample_Count loop
         if Sample mod 2 = 1 then
            Run_Nested_Group_Iteration (Pass_Count, Nested_Time);
            Run_Alternative.all (Pass_Count, Alternative_Time);
         else
            Run_Alternative.all (Pass_Count, Alternative_Time);
            Run_Nested_Group_Iteration (Pass_Count, Nested_Time);
         end if;
         Nested_Best := Duration'Min (Nested_Best, Nested_Time);
         Alternative_Best := Duration'Min (Alternative_Best, Alternative_Time);
      end loop;

      Check
        (Nested_Iteration_Sum - Nested_Before = Counter (Operations * Long_Long_Integer (Sample_Count)),
         "nested group iteration produced an incorrect result");
      Check
        (Alternative_Sum.all - Alternative_Before = Counter (Operations * Long_Long_Integer (Sample_Count)),
         Name & " produced an incorrect result");
      Report_Pair
        (Name,
         Operations,
         Nested_Best,
         Alternative_Best,
         Compact_Label         => "nested groups",
         Padded_Label          => Alternative_Label,
         Speedup_Label         => Speedup_Label,
         Compact_Storage_Bytes => Fitted_Sequence_Bytes,
         Padded_Storage_Bytes  => Fitted_Sequence_Bytes);
   end Measure_Group_Iteration_Pair;

   procedure Measure_Group_Iteration is
   begin
      Measure_Group_Iteration_Pair
        (Name              => "fitted grouped-array standard iteration",
         Alternative_Label => "flat for-of",
         Speedup_Label     => "flat iteration speedup",
         Run_Alternative   => Run_Flat_Group_Iteration'Access,
         Alternative_Sum   => Flat_Iteration_Sum'Access);
      Measure_Group_Iteration_Pair
        (Name              => "fitted grouped-array GNAT Iterable traversal",
         Alternative_Label => "Fast_View for-of",
         Speedup_Label     => "Fast_View speedup",
         Run_Alternative   => Run_Iterable_Group_Iteration'Access,
         Alternative_Sum   => Iterable_Iteration_Sum'Access);
   end Measure_Group_Iteration;

   procedure Measure_Parallel_Pair
     (Algorithm : Parallel_Algorithm; Name : String; Item_Count : Positive; Repetitions : Positive)
   is
      Operations     : constant Long_Long_Integer :=
        Operation_Count (Algorithm, Item_Count, Worker_Count, Repetitions);
      Compact_Before : constant Counter := Compact_Sum;
      Padded_Before  : constant Counter := Padded_Sum;
      Compact_Best   : Duration := Duration'Last;
      Padded_Best    : Duration := Duration'Last;
      Compact_Time   : Duration;
      Padded_Time    : Duration;
   begin
      for Sample in 1 .. Sample_Count loop
         if Sample mod 2 = 1 then
            Run_Parallel_Compact (Algorithm, Item_Count, Worker_Count, Repetitions, Compact_Time);
            Run_Parallel_Padded (Algorithm, Item_Count, Worker_Count, Repetitions, Padded_Time);
         else
            Run_Parallel_Padded (Algorithm, Item_Count, Worker_Count, Repetitions, Padded_Time);
            Run_Parallel_Compact (Algorithm, Item_Count, Worker_Count, Repetitions, Compact_Time);
         end if;
         Compact_Best := Duration'Min (Compact_Best, Compact_Time);
         Padded_Best := Duration'Min (Padded_Best, Padded_Time);
      end loop;

      Check
        (Compact_Sum - Compact_Before = Counter (Operations * Long_Long_Integer (Sample_Count)),
         "compact multi-task benchmark produced an incorrect result");
      Check
        (Padded_Sum - Padded_Before = Counter (Operations * Long_Long_Integer (Sample_Count)),
         "padded multi-task benchmark produced an incorrect result");
      Report_Pair (Name, Operations, Compact_Best, Padded_Best);
   end Measure_Parallel_Pair;

   procedure Measure_Task_Group_Pair is
      Operations     : constant Long_Long_Integer :=
        Long_Long_Integer (Worker_Count) * Long_Long_Integer (Iterations_Per_Worker);
      Compact_Before : constant Counter := Compact_Task_Group_Sum;
      Padded_Before  : constant Counter := Padded_Task_Group_Sum;
      Compact_Best   : Duration := Duration'Last;
      Padded_Best    : Duration := Duration'Last;
      Compact_Time   : Duration;
      Padded_Time    : Duration;
   begin
      for Sample in 1 .. Sample_Count loop
         if Sample mod 2 = 1 then
            Run_Parallel_Compact_Task_Groups
              (Grouped,
               Worker_Count * Task_Group_Length,
               Worker_Count,
               Iterations_Per_Worker,
               Compact_Time,
               Group_Length => Task_Group_Length);
            Run_Parallel_Padded_Task_Groups
              (Grouped,
               Worker_Count * Task_Group_Length,
               Worker_Count,
               Iterations_Per_Worker,
               Padded_Time,
               Group_Length => Task_Group_Length);
         else
            Run_Parallel_Padded_Task_Groups
              (Grouped,
               Worker_Count * Task_Group_Length,
               Worker_Count,
               Iterations_Per_Worker,
               Padded_Time,
               Group_Length => Task_Group_Length);
            Run_Parallel_Compact_Task_Groups
              (Grouped,
               Worker_Count * Task_Group_Length,
               Worker_Count,
               Iterations_Per_Worker,
               Compact_Time,
               Group_Length => Task_Group_Length);
         end if;
         Compact_Best := Duration'Min (Compact_Best, Compact_Time);
         Padded_Best := Duration'Min (Padded_Best, Padded_Time);
      end loop;

      Check
        (Compact_Task_Group_Sum - Compact_Before = Counter (Operations * Long_Long_Integer (Sample_Count)),
         "compact task-group benchmark produced an incorrect result");
      Check
        (Padded_Task_Group_Sum - Padded_Before = Counter (Operations * Long_Long_Integer (Sample_Count)),
         "padded task-group benchmark produced an incorrect result");
      Report_Pair
        ("one compact hot group per task (" & Task_Group_Length'Image & " counters/group)",
         Operations,
         Compact_Best,
         Padded_Best,
         Compact_Storage_Bytes => Compact_Task_Group_Bytes,
         Padded_Storage_Bytes  => Padded_Task_Group_Bytes);
   end Measure_Task_Group_Pair;

   procedure Measure_Fitted_Versus_Aligned is
      Group_Length   : constant Positive := Fitted_Counter_Groups.Elements_Per_Group;
      Operations     : constant Long_Long_Integer :=
        Long_Long_Integer (Worker_Count) * Long_Long_Integer (Iterations_Per_Worker);
      Aligned_Before : constant Counter := Individually_Aligned_Group_Sum;
      Fitted_Before  : constant Counter := Fitted_Group_Sum;
      Aligned_Best   : Duration := Duration'Last;
      Fitted_Best    : Duration := Duration'Last;
      Aligned_Time   : Duration;
      Fitted_Time    : Duration;
   begin
      for Sample in 1 .. Sample_Count loop
         if Sample mod 2 = 1 then
            Run_Parallel_Individually_Aligned_Groups
              (Grouped,
               Worker_Count * Group_Length,
               Worker_Count,
               Iterations_Per_Worker,
               Aligned_Time,
               Group_Length => Group_Length);
            Run_Parallel_Fitted_Groups
              (Grouped,
               Worker_Count * Group_Length,
               Worker_Count,
               Iterations_Per_Worker,
               Fitted_Time,
               Group_Length => Group_Length);
         else
            Run_Parallel_Fitted_Groups
              (Grouped,
               Worker_Count * Group_Length,
               Worker_Count,
               Iterations_Per_Worker,
               Fitted_Time,
               Group_Length => Group_Length);
            Run_Parallel_Individually_Aligned_Groups
              (Grouped,
               Worker_Count * Group_Length,
               Worker_Count,
               Iterations_Per_Worker,
               Aligned_Time,
               Group_Length => Group_Length);
         end if;
         Aligned_Best := Duration'Min (Aligned_Best, Aligned_Time);
         Fitted_Best := Duration'Min (Fitted_Best, Fitted_Time);
      end loop;

      Check
        (Individually_Aligned_Group_Sum - Aligned_Before
         = Counter (Operations * Long_Long_Integer (Sample_Count)),
         "individually aligned benchmark produced an incorrect result");
      Check
        (Fitted_Group_Sum - Fitted_Before = Counter (Operations * Long_Long_Integer (Sample_Count)),
         "fitted group benchmark produced an incorrect result");
      Report_Pair
        ("one aligned region per counter versus one fitted group (" & Group_Length'Image & " counters/task)",
         Operations,
         Aligned_Best,
         Fitted_Best,
         Compact_Label         => "one region/counter",
         Padded_Label          => "fitted group",
         Speedup_Label         => "fitted speedup",
         Compact_Storage_Bytes => Individually_Aligned_Group_Bytes,
         Padded_Storage_Bytes  => Fitted_Group_Bytes);
      Ada.Text_IO.Put ("  fitted storage reduction: ");
      Ada.Long_Float_Text_IO.Put
        (Long_Float (Individually_Aligned_Group_Bytes) / Long_Float (Fitted_Group_Bytes),
         Fore => 1,
         Aft  => 2,
         Exp  => 0);
      Ada.Text_IO.Put_Line ("x");
   end Measure_Fitted_Versus_Aligned;

   procedure Free is new Ada.Unchecked_Deallocation (Compact_Array, Compact_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Padded_Array, Padded_Array_Access);
   procedure Free is new
     Ada.Unchecked_Deallocation (Compact_Task_Group_Array, Compact_Task_Group_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Padded_Task_Group_Array, Padded_Task_Group_Array_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Fitted_Group_Array, Fitted_Group_Array_Access);
   procedure Free is new
     Ada.Unchecked_Deallocation (Fitted_Counter_Groups.Grouped_Array, Fitted_Grouped_Array_Access);
begin
   for Index in 1 .. Element_Count loop
      Compact_Data (Index) := 0;
      Padded_Data (Index).Value := 0;
   end loop;
   for Worker in 1 .. Worker_Count loop
      for Slot in 1 .. Task_Group_Length loop
         Compact_Task_Group_Data (Worker) (Slot) := 0;
         Padded_Task_Group_Data (Worker) (Slot) := 0;
      end loop;
      for Slot in 1 .. Fitted_Counter_Groups.Elements_Per_Group loop
         declare
            Index : constant Positive := (Worker - 1) * Fitted_Counter_Groups.Elements_Per_Group + Slot;
         begin
            Individually_Aligned_Group_Data (Index).Value := 0;
         end;
         Fitted_Group_Data (Worker) (Slot) := 0;
      end loop;
   end loop;

   Ada.Text_IO.Put_Line ("flyology_cachelines access benchmarks");
   Ada.Text_IO.Put_Line ("  elements:" & Element_Count'Image);
   Ada.Text_IO.Put_Line ("  passes:" & Pass_Count'Image);
   Ada.Text_IO.Put_Line ("  iterations per worker:" & Iterations_Per_Worker'Image);
   Ada.Text_IO.Put_Line ("  workers:" & Worker_Count'Image);
   Ada.Text_IO.Put_Line ("  samples:" & Sample_Count'Image);
   Ada.Text_IO.Put_Line ("  compact bytes:" & Compact_Bytes'Image);
   Ada.Text_IO.Put_Line ("  padded bytes:" & Padded_Bytes'Image);
   Ada.Text_IO.Put_Line ("  task-group elements:" & Task_Group_Length'Image);
   Ada.Text_IO.Put_Line ("  compact task-group bytes:" & Compact_Task_Group_Bytes'Image);
   Ada.Text_IO.Put_Line ("  padded task-group bytes:" & Padded_Task_Group_Bytes'Image);
   Ada.Text_IO.Put_Line ("  fitted group elements:" & Fitted_Counter_Groups.Elements_Per_Group'Image);
   Ada.Text_IO.Put_Line ("  one-region-per-counter bytes:" & Individually_Aligned_Group_Bytes'Image);
   Ada.Text_IO.Put_Line ("  fitted group bytes:" & Fitted_Group_Bytes'Image);
   Ada.Text_IO.Put_Line ("  fitted grouped-array bytes:" & Fitted_Sequence_Bytes'Image);
   Ada.Text_IO.Put_Line
     ("  destructive interference bytes:" & Flyology_Cachelines.Destructive_Interference_Size'Image);

   Ada.Text_IO.Put_Line ("");
   Ada.Text_IO.Put_Line ("same Ada task");
   Measure_Single_Pair (Sequential, "sequential full-array sweep", Pass_Count);
   Measure_Single_Pair (Strided, "coprime-stride full-array sweep", Pass_Count);
   Measure_Group_Iteration;
   Measure_Single_Pair (Hot_Set, "eight-counter hot set", Iterations_Per_Worker);

   Ada.Text_IO.Put_Line ("");
   Ada.Text_IO.Put_Line ("different Ada tasks");
   Measure_Parallel_Pair
     (Isolated, "one hot counter per task (maximum false sharing)", Worker_Count, Iterations_Per_Worker);
   Measure_Task_Group_Pair;
   Measure_Fitted_Versus_Aligned;
   Measure_Parallel_Pair (Interleaved, "interleaved full-array ownership", Element_Count, Pass_Count);
   Measure_Parallel_Pair (Sharded, "contiguous sharded full-array ownership", Element_Count, Pass_Count);

   Free (Compact_Data);
   Free (Padded_Data);
   Free (Compact_Task_Group_Data);
   Free (Padded_Task_Group_Data);
   Free (Individually_Aligned_Group_Data);
   Free (Fitted_Group_Data);
   Free (Nested_Iteration_Data);
   Free (Flat_Iteration_Data);
   Free (Iterable_Iteration_Data);
end Benchmarks;
