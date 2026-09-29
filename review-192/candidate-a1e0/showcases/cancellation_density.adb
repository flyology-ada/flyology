with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with Flyology.IO.Sockets;
with Flyology;
with Flyology.IO.Connections;
with Interfaces.C;
with Showcase_Support;

procedure Cancellation_Density is
   package Connections renames Flyology.IO.Connections;
   package C renames Interfaces.C;
   use Ada.Text_IO;
   use type Ada.Real_Time.Time;
   use type C.double;

   function Thread_Count return C.int;
   pragma Import (C, Thread_Count, "flyology_thread_count");
   function Process_CPU_Seconds return C.double;
   pragma Import (C, Process_CPU_Seconds, "flyology_process_cpu_seconds");

   type Socket_Array is array (Positive range <>) of Flyology.IO.Sockets.Socket_Type;
   type Socket_Array_Access is access Socket_Array;

   procedure Run (Count : Positive; Model : Flyology.Execution_Model; Mode : String) is
      Manager : aliased Connections.Server (Capacity => Count);
      Token   : aliased Connections.Cancellation_Token;
      Servers : constant Socket_Array_Access := new Socket_Array (1 .. Count);
      Peers   : constant Socket_Array_Access := new Socket_Array (1 .. Count);

      protected Progress is
         procedure Started;
         procedure Finished (Cancelled : Boolean);
         entry All_Started;
         entry All_Finished;
         function Passed return Boolean;
      private
         Started_Count  : Natural := 0;
         Finished_Count : Natural := 0;
         All_OK         : Boolean := True;
      end Progress;

      protected body Progress is
         procedure Started is
         begin
            Started_Count := Started_Count + 1;
         end Started;
         procedure Finished (Cancelled : Boolean) is
         begin
            Finished_Count := Finished_Count + 1;
            All_OK := All_OK and Cancelled;
         end Finished;
         entry All_Started when Started_Count = Count is
         begin
            null;
         end;
         entry All_Finished when Finished_Count = Count is
         begin
            null;
         end;
         function Passed return Boolean
         is (All_OK);
      end Progress;

      task type Worker
        (Index : Positive;
         Kind  : Flyology.Execution_Model)
      is
         pragma Task_Info (Kind);
         pragma Storage_Size (64 * 1_024);
      end Worker;

      task body Worker is
         Owned     : Connections.Connection;
         Data      : Ada.Streams.Stream_Element_Array (1 .. 1);
         Cancelled : Boolean := False;
      begin
         Connections.Take (Manager, Servers (Index), Owned);
         Progress.Started;
         begin
            Owned.Receive_Exactly (Data, Cancellation_Quantum => 10.0, Token => Token'Access);
         exception
            when Connections.Operation_Cancelled =>
               Cancelled := True;
         end;
         Progress.Finished (Cancelled);
      exception
         when others =>
            Progress.Finished (False);
      end Worker;

      type Worker_Access is access Worker;
      Workers               : array (1 .. Count) of Worker_Access;
      pragma Unreferenced (Workers);
      CPU_Before, CPU_After : C.double;
      Threads_Waiting       : C.int;
      Cancel_At             : Ada.Real_Time.Time;
      Cancel_Elapsed        : Duration;
   begin
      for Index in 1 .. Count loop
         Flyology.IO.Sockets.Create_Socket_Pair (Servers (Index), Peers (Index));
      end loop;
      for Index in 1 .. Count loop
         Workers (Index) := new Worker (Index, Model);
      end loop;
      Progress.All_Started;

      Threads_Waiting := Thread_Count;
      CPU_Before := Process_CPU_Seconds;
      delay 1.0;
      CPU_After := Process_CPU_Seconds;
      Cancel_At := Ada.Real_Time.Clock;
      Token.Request;
      Progress.All_Finished;
      Cancel_Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Cancel_At);

      Put_Line
        ("mode="
         & Mode
         & " connections="
         & Count'Image
         & " threads_waiting="
         & C.int'Image (Threads_Waiting));
      Put_Line
        ("  idle_wall=1.000 s idle_process_cpu="
         & Showcase_Support.Fixed_Image (Long_Float (CPU_After - CPU_Before))
         & " s");
      Put_Line
        ("  cancel_all="
         & Showcase_Support.Fixed_Image (Long_Float (Cancel_Elapsed))
         & " s legacy_quantum=10.000 s");
      pragma Assert (Progress.Passed);
      for Peer of Peers.all loop
         Flyology.IO.Sockets.Close_Socket (Peer);
      end loop;
   end Run;

   Count : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 2 then Positive'Value (Ada.Command_Line.Argument (2)) else 1_000);
   Mode  : constant String :=
     (if Ada.Command_Line.Argument_Count >= 1 then Ada.Command_Line.Argument (1) else "lightweight");
begin
   if Mode = "lightweight" then
      Run (Count, Flyology.Lightweight_Task, Mode);
   elsif Mode = "native" then
      Run (Count, Flyology.Native_Task, Mode);
   else
      raise Constraint_Error with "mode must be lightweight or native";
   end if;
end Cancellation_Density;
