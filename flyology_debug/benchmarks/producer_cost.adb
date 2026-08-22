--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Text_IO;
with Flyology_Debug;
with Flyology_Debug.Tracers;
with Interfaces;

procedure Producer_Cost is
   use type Flyology_Debug.Timestamp;

   subtype Message is Interfaces.Unsigned_64;

   Iterations              : constant Positive := 1_000_000;
   Concurrent_Producers    : constant Positive := 4;
   Iterations_Per_Producer : constant Positive := Iterations / Concurrent_Producers;

   function Cheap_Clock return Flyology_Debug.Timestamp
   is (0);

   function Select_First (Producer_Count : Positive) return Positive is
      pragma Unreferenced (Producer_Count);
   begin
      return 1;
   end Select_First;

   package Cheap is new
     Flyology_Debug.Tracers
       (Message_Type => Message,
        Capacity     => 1_024,
        Overflow     => Flyology_Debug.Overwrite_Oldest,
        Now          => Cheap_Clock);

   package Native is new
     Flyology_Debug.Tracers
       (Message_Type => Message,
        Capacity     => 1_024,
        Overflow     => Flyology_Debug.Overwrite_Oldest);

   package Disabled is new
     Flyology_Debug.Tracers
       (Message_Type => Message,
        Capacity     => 1_024,
        Overflow     => Flyology_Debug.Overwrite_Oldest,
        Now          => Cheap_Clock);

   package Sharded is new
     Flyology_Debug.Tracers
       (Message_Type   => Message,
        Capacity       => 1_024,
        Overflow       => Flyology_Debug.Overwrite_Oldest,
        Now            => Cheap_Clock,
        Producer_Count => Concurrent_Producers);

   package Automatic is new
     Flyology_Debug.Tracers
       (Message_Type    => Message,
        Capacity        => 1_024,
        Overflow        => Flyology_Debug.Overwrite_Oldest,
        Now             => Cheap_Clock,
        Producer_Count  => Concurrent_Producers,
        Select_Producer => Select_First);

   procedure Report
     (Label      : String;
      Started_At : Flyology_Debug.Timestamp;
      Stopped_At : Flyology_Debug.Timestamp;
      Operations : Positive)
   is
      Elapsed       : constant Long_Float := Long_Float (Stopped_At - Started_At);
      Per_Operation : constant Long_Float := Elapsed / Long_Float (Operations);
   begin
      Ada.Text_IO.Put_Line (Label & ":" & Long_Float'Image (Per_Operation) & " ns/trace");
   end Report;

   generic
      Label : String;
      with procedure Emit (Value : Message);
   procedure Run_Serial;

   procedure Run_Serial is
      Started_At : Flyology_Debug.Timestamp;
      Stopped_At : Flyology_Debug.Timestamp;
   begin
      Started_At := Flyology_Debug.Clock;
      for Index in 1 .. Iterations loop
         Emit (Message (Index));
      end loop;
      Stopped_At := Flyology_Debug.Clock;
      Report (Label, Started_At, Stopped_At, Iterations);
   end Run_Serial;

   procedure Run_Cheap is new Run_Serial (Label => "injected clock, one producer", Emit => Cheap.Trace);

   procedure Run_Native is new Run_Serial (Label => "native clock, one producer", Emit => Native.Trace);

   procedure Run_Automatic is new
     Run_Serial (Label => "injected clock, constant automatic selector", Emit => Automatic.Trace);

   procedure Run_Disabled is new Run_Serial (Label => "disabled, direct Trace", Emit => Disabled.Trace);

   procedure Emit_Shared (Producer : Positive; Value : Message) is
      pragma Unreferenced (Producer);
   begin
      Cheap.Trace (Value);
   end Emit_Shared;

   procedure Emit_Sharded (Producer : Positive; Value : Message) is
   begin
      Sharded.Trace (Value, Producer);
   end Emit_Sharded;

   generic
      Label : String;
      with procedure Emit (Producer : Positive; Value : Message);
   procedure Run_Concurrent;

   procedure Run_Concurrent is
      protected Gate is
         procedure Claim (Producer : out Positive);
         procedure Start;
         entry Await_Start;
         procedure Finish;
         entry Await_Finish;
      private
         Started       : Boolean := False;
         Finished      : Natural := 0;
         Next_Producer : Natural := 0;
      end Gate;

      protected body Gate is
         procedure Claim (Producer : out Positive) is
         begin
            Next_Producer := Next_Producer + 1;
            Producer := Next_Producer;
         end Claim;

         procedure Start is
         begin
            Started := True;
         end Start;

         entry Await_Start when Started is
         begin
            null;
         end Await_Start;

         procedure Finish is
         begin
            Finished := Finished + 1;
         end Finish;

         entry Await_Finish when Finished = Concurrent_Producers is
         begin
            null;
         end Await_Finish;
      end Gate;

      task type Producer;

      task body Producer is
         Id : Positive;
      begin
         Gate.Claim (Id);
         Gate.Await_Start;
         for Index in 1 .. Iterations_Per_Producer loop
            Emit (Id, Message (Index));
         end loop;
         Gate.Finish;
      end Producer;

      Producers  : array (1 .. Concurrent_Producers) of Producer;
      Started_At : Flyology_Debug.Timestamp;
      Stopped_At : Flyology_Debug.Timestamp;
   begin
      Started_At := Flyology_Debug.Clock;
      Gate.Start;
      Gate.Await_Finish;
      Stopped_At := Flyology_Debug.Clock;
      Report (Label, Started_At, Stopped_At, Iterations_Per_Producer * Concurrent_Producers);
   end Run_Concurrent;

   procedure Run_Shared_Concurrent is new
     Run_Concurrent (Label => "injected clock, four producers, one shard", Emit => Emit_Shared);

   procedure Run_Sharded_Concurrent is new
     Run_Concurrent (Label => "injected clock, four producers, four shards", Emit => Emit_Sharded);
begin
   Disabled.Disable;
   Run_Disabled;
   Run_Cheap;
   Run_Automatic;
   Run_Native;
   Run_Shared_Concurrent;
   Run_Sharded_Concurrent;
end Producer_Cost;
