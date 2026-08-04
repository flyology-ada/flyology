with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Text_IO;
with Flyology;
with Flyology.Observability;
with Interfaces;
with Showcase_Support;
with System.Multiprocessors;

procedure Synchronization_Benchmark is
   package CLI renames Ada.Command_Line;
   package Observation renames Flyology.Observability;
   package RT renames Ada.Real_Time;
   package TIO renames Ada.Text_IO;

   use type Interfaces.Unsigned_64;
   use type RT.Time;

   Default_Rounds  : constant := 20_000;
   Default_Samples : constant := 5;

   function Positive_Argument
     (Position : Positive;
      Default  : Positive) return Positive
   is
   begin
      if CLI.Argument_Count < Position then
         return Default;
      end if;
      return Positive'Value (CLI.Argument (Position));
   exception
      when Constraint_Error =>
         raise Program_Error with
           "benchmark arguments must be positive integers";
   end Positive_Argument;

   Rounds  : constant Positive :=
     Positive_Argument (1, Default_Rounds);
   Samples : constant Positive :=
     Positive_Argument (2, Default_Samples);

   function Protected_Procedure_Round_Count return Positive is
   begin
      if Rounds > Positive'Last / 200 then
         raise Program_Error with "benchmark rounds are too large";
      end if;
      return 100 * Rounds;
   end Protected_Procedure_Round_Count;

   Protected_Procedure_Rounds : constant Positive :=
     Protected_Procedure_Round_Count;

   type Duration_Array is array (Positive range <>) of Duration;

   procedure Sort (Values : in out Duration_Array) is
   begin
      for Index in Values'First + 1 .. Values'Last loop
         declare
            Value    : constant Duration := Values (Index);
            Position : Positive := Index;
         begin
            while Position > Values'First
              and then Values (Position - 1) > Value
            loop
               Values (Position) := Values (Position - 1);
               Position := Position - 1;
            end loop;
            Values (Position) := Value;
         end;
      end loop;
   end Sort;

   function Median (Values : Duration_Array) return Duration is
      Ordered : Duration_Array := Values;
      Middle  : constant Positive :=
        Ordered'First + (Ordered'Length - 1) / 2;
   begin
      Sort (Ordered);
      if Ordered'Length mod 2 = 0 then
         return (Ordered (Middle) + Ordered (Middle + 1)) / 2;
      end if;
      return Ordered (Middle);
   end Median;

   protected type Run_Control (Participants : Positive := 2) is
      procedure Arrived;
      entry Wait_Until_Ready;
      procedure Open;
      entry Start;
      procedure Finished;
      entry Wait_Until_Finished;
   private
      Arrivals    : Natural := 0;
      Completions : Natural := 0;
      Is_Open     : Boolean := False;
   end Run_Control;

   protected body Run_Control is
      procedure Arrived is
      begin
         Arrivals := Arrivals + 1;
      end Arrived;

      entry Wait_Until_Ready when Arrivals = Participants is
      begin
         null;
      end Wait_Until_Ready;

      procedure Open is
      begin
         Is_Open := True;
      end Open;

      entry Start when Is_Open is
      begin
         null;
      end Start;

      procedure Finished is
      begin
         Completions := Completions + 1;
      end Finished;

      entry Wait_Until_Finished when Completions = Participants is
      begin
         null;
      end Wait_Until_Finished;
   end Run_Control;

   protected type Counter is
      procedure Increment;
      function Value return Natural;
   private
      Count : Natural := 0;
   end Counter;

   protected body Counter is
      procedure Increment is
      begin
         Count := Count + 1;
      end Increment;

      function Value return Natural is (Count);
   end Counter;

   protected type Alternator is
      entry Left;
      entry Right;
      function Count return Natural;
   private
      Left_Open : Boolean := True;
      Calls     : Natural := 0;
   end Alternator;

   protected body Alternator is
      entry Left when Left_Open is
      begin
         Calls := Calls + 1;
         Left_Open := False;
      end Left;

      entry Right when not Left_Open is
      begin
         Calls := Calls + 1;
         Left_Open := True;
      end Right;

      function Count return Natural is (Calls);
   end Alternator;

   procedure Capture
     (Enabled : Boolean;
      Group   : Observation.Group_Id;
      Item    : out Observation.Group_Snapshot)
   is
   begin
      if Enabled and then not Observation.Snapshot (Group, Item) then
         raise Program_Error with "benchmark execution group is unavailable";
      end if;
   end Capture;

   procedure Report
     (Primitive : String;
      Placement : String;
      Operations : Positive;
      Timings    : Duration_Array;
      Wakeups    : Observation.Counter)
   is
      Typical : constant Duration := Median (Timings);
      NS_Per_Operation : constant Long_Float :=
        Long_Float (Typical) * 1_000_000_000.0 / Long_Float (Operations);
      Wakeups_Per_Operation : constant Long_Float :=
        Long_Float (Wakeups) / Long_Float (Operations);
   begin
      TIO.Put_Line
        (Primitive & " " & Placement
         & " operations=" & Operations'Image
         & " median_s="
         & Showcase_Support.Fixed_Image (Long_Float (Typical), 6)
         & " ns_per_operation="
         & Showcase_Support.Fixed_Image (NS_Per_Operation, 1)
         & " lightweight_wakeups_per_operation="
         & Showcase_Support.Fixed_Image (Wakeups_Per_Operation, 3));
   end Report;

   generic
      Placement     : String;
      Worker_Model  : Flyology.Execution_Model;
      Worker_CPU    : System.Multiprocessors.CPU_Range;
      Observe_Group : Boolean;
   procedure Run_Uncontended_Protected_Procedure;

   procedure Run_Uncontended_Protected_Procedure is
      Timings : Duration_Array (1 .. Samples);
      Wakeups : Observation.Counter := 0;
   begin
      for Sample in Timings'Range loop
         declare
            Control : Run_Control (1);
            State   : Counter;

            task Worker with CPU => Worker_CPU is
               pragma Task_Info (Worker_Model);
            end Worker;

            task body Worker is
            begin
               Control.Arrived;
               Control.Start;
               for Iteration in 1 .. Protected_Procedure_Rounds loop
                  State.Increment;
               end loop;
               Control.Finished;
            end Worker;

            Before, After : Observation.Group_Snapshot;
            Started       : RT.Time;
         begin
            Control.Wait_Until_Ready;
            Capture (Observe_Group, 1, Before);
            Started := RT.Clock;
            Control.Open;
            Control.Wait_Until_Finished;
            Timings (Sample) := RT.To_Duration (RT.Clock - Started);
            Capture (Observe_Group, 1, After);

            if State.Value /= Protected_Procedure_Rounds then
               raise Program_Error with
                 "uncontended protected-procedure benchmark lost an operation";
            end if;
            if Sample = Timings'Last and then Observe_Group then
               Wakeups := After.Wakeups - Before.Wakeups;
            end if;
         end;
      end loop;

      Report
        ("protected_procedure",
         Placement,
         Protected_Procedure_Rounds,
         Timings,
         Wakeups);
   end Run_Uncontended_Protected_Procedure;

   generic
      Placement        : String;
      Left_Model       : Flyology.Execution_Model;
      Right_Model      : Flyology.Execution_Model;
      Left_CPU         : System.Multiprocessors.CPU_Range;
      Right_CPU        : System.Multiprocessors.CPU_Range;
      Observe_Group_1  : Boolean;
      Observe_Group_2  : Boolean;
   procedure Run_Shared_Protected_Procedure;

   procedure Run_Shared_Protected_Procedure is
      Timings : Duration_Array (1 .. Samples);
      Wakeups : Observation.Counter := 0;
   begin
      for Sample in Timings'Range loop
         declare
            Control : Run_Control;
            State   : Counter;

            task Left with CPU => Left_CPU is
               pragma Task_Info (Left_Model);
            end Left;

            task Right with CPU => Right_CPU is
               pragma Task_Info (Right_Model);
            end Right;

            task body Left is
            begin
               Control.Arrived;
               Control.Start;
               for Iteration in 1 .. Protected_Procedure_Rounds loop
                  State.Increment;
               end loop;
               Control.Finished;
            end Left;

            task body Right is
            begin
               Control.Arrived;
               Control.Start;
               for Iteration in 1 .. Protected_Procedure_Rounds loop
                  State.Increment;
               end loop;
               Control.Finished;
            end Right;

            Before_1, After_1 : Observation.Group_Snapshot;
            Before_2, After_2 : Observation.Group_Snapshot;
            Started           : RT.Time;
         begin
            Control.Wait_Until_Ready;
            Capture (Observe_Group_1, 1, Before_1);
            Capture (Observe_Group_2, 2, Before_2);
            Started := RT.Clock;
            Control.Open;
            Control.Wait_Until_Finished;
            Timings (Sample) := RT.To_Duration (RT.Clock - Started);
            Capture (Observe_Group_1, 1, After_1);
            Capture (Observe_Group_2, 2, After_2);

            if State.Value /= 2 * Protected_Procedure_Rounds then
               raise Program_Error with
                 "shared protected-procedure benchmark lost an operation";
            end if;
            if Sample = Timings'Last then
               if Observe_Group_1 then
                  Wakeups := Wakeups + After_1.Wakeups - Before_1.Wakeups;
               end if;
               if Observe_Group_2 then
                  Wakeups := Wakeups + After_2.Wakeups - Before_2.Wakeups;
               end if;
            end if;
         end;
      end loop;

      Report
        ("protected_procedure",
         Placement,
         2 * Protected_Procedure_Rounds,
         Timings,
         Wakeups);
   end Run_Shared_Protected_Procedure;

   generic
      Placement        : String;
      Left_Model       : Flyology.Execution_Model;
      Right_Model      : Flyology.Execution_Model;
      Left_CPU         : System.Multiprocessors.CPU_Range;
      Right_CPU        : System.Multiprocessors.CPU_Range;
      Observe_Group_1  : Boolean;
      Observe_Group_2  : Boolean;
   procedure Run_Protected_Entry;

   procedure Run_Protected_Entry is
      Timings : Duration_Array (1 .. Samples);
      Wakeups : Observation.Counter := 0;
   begin
      for Sample in Timings'Range loop
         declare
            Control : Run_Control;
            State   : Alternator;

            task Left with CPU => Left_CPU is
               pragma Task_Info (Left_Model);
            end Left;

            task Right with CPU => Right_CPU is
               pragma Task_Info (Right_Model);
            end Right;

            task body Left is
            begin
               Control.Arrived;
               Control.Start;
               for Iteration in 1 .. Rounds loop
                  State.Left;
               end loop;
               Control.Finished;
            end Left;

            task body Right is
            begin
               Control.Arrived;
               Control.Start;
               for Iteration in 1 .. Rounds loop
                  State.Right;
               end loop;
               Control.Finished;
            end Right;

            Before_1, After_1 : Observation.Group_Snapshot;
            Before_2, After_2 : Observation.Group_Snapshot;
            Started           : RT.Time;
         begin
            Control.Wait_Until_Ready;
            Capture (Observe_Group_1, 1, Before_1);
            Capture (Observe_Group_2, 2, Before_2);
            Started := RT.Clock;
            Control.Open;
            Control.Wait_Until_Finished;
            Timings (Sample) := RT.To_Duration (RT.Clock - Started);
            Capture (Observe_Group_1, 1, After_1);
            Capture (Observe_Group_2, 2, After_2);

            if State.Count /= 2 * Rounds then
               raise Program_Error with
                 "protected-entry benchmark lost an operation";
            end if;
            if Sample = Timings'Last then
               if Observe_Group_1 then
                  Wakeups := Wakeups + After_1.Wakeups - Before_1.Wakeups;
               end if;
               if Observe_Group_2 then
                  Wakeups := Wakeups + After_2.Wakeups - Before_2.Wakeups;
               end if;
            end if;
         end;
      end loop;

      Report
        ("protected_entry", Placement, 2 * Rounds, Timings, Wakeups);
   end Run_Protected_Entry;

   generic
      Placement        : String;
      Server_Model     : Flyology.Execution_Model;
      Caller_Model     : Flyology.Execution_Model;
      Server_CPU       : System.Multiprocessors.CPU_Range;
      Caller_CPU       : System.Multiprocessors.CPU_Range;
      Observe_Group_1  : Boolean;
      Observe_Group_2  : Boolean;
   procedure Run_Rendezvous;

   procedure Run_Rendezvous is
      Timings : Duration_Array (1 .. Samples);
      Wakeups : Observation.Counter := 0;
   begin
      for Sample in Timings'Range loop
         declare
            Control : Run_Control;

            task Server with CPU => Server_CPU is
               pragma Task_Info (Server_Model);
               entry Ping;
            end Server;

            task Caller with CPU => Caller_CPU is
               pragma Task_Info (Caller_Model);
            end Caller;

            task body Server is
            begin
               Control.Arrived;
               Control.Start;
               for Iteration in 1 .. Rounds loop
                  accept Ping;
               end loop;
               Control.Finished;
            end Server;

            task body Caller is
            begin
               Control.Arrived;
               Control.Start;
               for Iteration in 1 .. Rounds loop
                  Server.Ping;
               end loop;
               Control.Finished;
            end Caller;

            Before_1, After_1 : Observation.Group_Snapshot;
            Before_2, After_2 : Observation.Group_Snapshot;
            Started           : RT.Time;
         begin
            Control.Wait_Until_Ready;
            Capture (Observe_Group_1, 1, Before_1);
            Capture (Observe_Group_2, 2, Before_2);
            Started := RT.Clock;
            Control.Open;
            Control.Wait_Until_Finished;
            Timings (Sample) := RT.To_Duration (RT.Clock - Started);
            Capture (Observe_Group_1, 1, After_1);
            Capture (Observe_Group_2, 2, After_2);

            if Sample = Timings'Last then
               if Observe_Group_1 then
                  Wakeups := Wakeups + After_1.Wakeups - Before_1.Wakeups;
               end if;
               if Observe_Group_2 then
                  Wakeups := Wakeups + After_2.Wakeups - Before_2.Wakeups;
               end if;
            end if;
         end;
      end loop;

      Report ("rendezvous", Placement, Rounds, Timings, Wakeups);
   end Run_Rendezvous;

   No_CPU : constant System.Multiprocessors.CPU_Range :=
     System.Multiprocessors.Not_A_Specific_CPU;

   procedure Procedure_Uncontended_Lightweight is new
     Run_Uncontended_Protected_Procedure
       ("uncontended_lightweight",
        Flyology.Lightweight_Task,
        1,
        True);
   procedure Procedure_Uncontended_Native is new
     Run_Uncontended_Protected_Procedure
       ("uncontended_native",
        Flyology.Native_Task,
        No_CPU,
        False);
   procedure Procedure_Same_Group is new Run_Shared_Protected_Procedure
     ("same_group_lightweight",
      Flyology.Lightweight_Task,
      Flyology.Lightweight_Task,
      1,
      1,
      True,
      False);
   procedure Procedure_Cross_Group is new Run_Shared_Protected_Procedure
     ("cross_group_lightweight",
      Flyology.Lightweight_Task,
      Flyology.Lightweight_Task,
      1,
      2,
      True,
      True);
   procedure Procedure_Native is new Run_Shared_Protected_Procedure
     ("native",
      Flyology.Native_Task,
      Flyology.Native_Task,
      No_CPU,
      No_CPU,
      False,
      False);
   procedure Procedure_Mixed is new Run_Shared_Protected_Procedure
     ("mixed_lightweight_native",
      Flyology.Lightweight_Task,
      Flyology.Native_Task,
      1,
      No_CPU,
      True,
      False);

   procedure Protected_Same_Group is new Run_Protected_Entry
     ("same_group_lightweight",
      Flyology.Lightweight_Task,
      Flyology.Lightweight_Task,
      1,
      1,
      True,
      False);
   procedure Protected_Cross_Group is new Run_Protected_Entry
     ("cross_group_lightweight",
      Flyology.Lightweight_Task,
      Flyology.Lightweight_Task,
      1,
      2,
      True,
      True);
   procedure Protected_Native is new Run_Protected_Entry
     ("native",
      Flyology.Native_Task,
      Flyology.Native_Task,
      No_CPU,
      No_CPU,
      False,
      False);
   procedure Protected_Mixed is new Run_Protected_Entry
     ("mixed_lightweight_native",
      Flyology.Lightweight_Task,
      Flyology.Native_Task,
      1,
      No_CPU,
      True,
      False);

   procedure Rendezvous_Same_Group is new Run_Rendezvous
     ("same_group_lightweight",
      Flyology.Lightweight_Task,
      Flyology.Lightweight_Task,
      1,
      1,
      True,
      False);
   procedure Rendezvous_Cross_Group is new Run_Rendezvous
     ("cross_group_lightweight",
      Flyology.Lightweight_Task,
      Flyology.Lightweight_Task,
      1,
      2,
      True,
      True);
   procedure Rendezvous_Native is new Run_Rendezvous
     ("native",
      Flyology.Native_Task,
      Flyology.Native_Task,
      No_CPU,
      No_CPU,
      False,
      False);
   procedure Rendezvous_Mixed is new Run_Rendezvous
     ("mixed_lightweight_native",
      Flyology.Lightweight_Task,
      Flyology.Native_Task,
      1,
      No_CPU,
      True,
      False);
begin
   TIO.Put_Line
     ("synchronization benchmark rounds=" & Rounds'Image
      & " procedure_rounds=" & Protected_Procedure_Rounds'Image
      & " samples=" & Samples'Image);
   Procedure_Uncontended_Lightweight;
   Procedure_Uncontended_Native;
   Procedure_Same_Group;
   Procedure_Cross_Group;
   Procedure_Native;
   Procedure_Mixed;
   Protected_Same_Group;
   Protected_Cross_Group;
   Protected_Native;
   Protected_Mixed;
   Rendezvous_Same_Group;
   Rendezvous_Cross_Group;
   Rendezvous_Native;
   Rendezvous_Mixed;
end Synchronization_Benchmark;
