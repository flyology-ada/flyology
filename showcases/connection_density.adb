with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with GNAT.Sockets;
with Flyology;
with Flyology.IO.Sockets;
with Flyology.Observability;
with Interfaces.C;
with Showcase_Support;

procedure Connection_Density is
   use Ada.Real_Time;
   use Ada.Streams;
   use Ada.Text_IO;

   package C renames Interfaces.C;
   use type C.long_long;
   use type Flyology.Observability.Counter;

   Worker_Stack_Size : constant := 16 * 1_024;
   One_Byte          : constant Stream_Element_Array := [1 => 42];

   function Current_RSS return C.long_long;
   pragma Import (C, Current_RSS, "flyology_current_rss_bytes");

   function Peak_RSS return C.long_long;
   pragma Import (C, Peak_RSS, "flyology_peak_rss_bytes");

   function Virtual_Bytes return C.long_long;
   pragma Import (C, Virtual_Bytes, "flyology_virtual_bytes");

   function Thread_Count return C.int;
   pragma Import (C, Thread_Count, "flyology_thread_count");

   protected type Progress (Target : Positive) is
      procedure At_Receive_Boundary;
      procedure Finished (Succeeded : Boolean);
      entry Wait_Until_Receive_Boundary;
      entry Wait_Until_Finished;
      function Failure_Count return Natural;
   private
      Receive_Count  : Natural := 0;
      Finished_Count : Natural := 0;
      Failures       : Natural := 0;
   end Progress;

   protected body Progress is
      procedure At_Receive_Boundary is
      begin
         Receive_Count := Receive_Count + 1;
      end At_Receive_Boundary;

      procedure Finished (Succeeded : Boolean) is
      begin
         Finished_Count := Finished_Count + 1;
         if not Succeeded then
            Failures := Failures + 1;
         end if;
      end Finished;

      entry Wait_Until_Receive_Boundary when Receive_Count = Target is
      begin
         null;
      end Wait_Until_Receive_Boundary;

      entry Wait_Until_Finished when Finished_Count = Target is
      begin
         null;
      end Wait_Until_Finished;

      function Failure_Count return Natural is (Failures);
   end Progress;

   type Socket_Array is
     array (Positive range <>) of GNAT.Sockets.Socket_Type;
   type Socket_Array_Access is access Socket_Array;

   function MiB (Bytes : C.long_long) return Long_Float is
     (Long_Float (Bytes) / (1_024.0 * 1_024.0));

   function Increase_From
     (After, Before : C.long_long) return C.long_long
   is
     (C.long_long'Max (0, After - Before));

   procedure Report
     (Mode             : String;
      Connections      : Positive;
      Baseline_RSS     : C.long_long;
      Sample_RSS       : C.long_long;
      Baseline_Virtual : C.long_long;
      Sample_Virtual   : C.long_long;
      Sample_Threads   : C.int;
      Pool             : Flyology.Observability.Stack_Pool_Snapshot;
      Setup_Elapsed    : Duration;
      Release_Elapsed  : Duration)
   is
      RSS_Increase : constant C.long_long :=
        Increase_From (Sample_RSS, Baseline_RSS);
      Virtual_Increase : constant C.long_long :=
        Increase_From (Sample_Virtual, Baseline_Virtual);
   begin
      Put_Line
        ("mode=" & Mode
         & " connections=" & Connections'Image
         & " socket_endpoints=" & Natural'Image (Connections * 2)
         & " task_stack=" & Natural'Image (Worker_Stack_Size / 1_024)
         & " KiB");
      Put_Line
        ("  receive_boundary: threads=" & Sample_Threads'Image
         & " rss=" & Showcase_Support.Fixed_Image (MiB (Sample_RSS))
         & " MiB rss_delta="
         & Showcase_Support.Fixed_Image (MiB (RSS_Increase)) & " MiB");
      Put_Line
        ("  address_space: virtual_delta="
         & Showcase_Support.Fixed_Image (MiB (Virtual_Increase)) & " MiB");
      Put_Line
        ("  density: rss_delta_per_connection="
         & C.long_long'Image (RSS_Increase / C.long_long (Connections))
         & " bytes");
      if Pool.Live_Stacks /= 0 then
         Put_Line
           ("  stack_pool: live=" & Pool.Live_Stacks'Image
            & " arenas=" & Pool.Active_Arenas'Image
            & " usable_per_task="
            & Interfaces.Unsigned_64'Image
                (Pool.Live_Usable_Bytes / Pool.Live_Stacks / 1_024)
            & " KiB"
            & " reserved="
            & Showcase_Support.Fixed_Image
                (Long_Float (Pool.Reserved_Bytes)
                 / (1_024.0 * 1_024.0))
            & " MiB shared=" & Pool.Shared_Stacks'Image);
      end if;
      Put_Line
        ("  timing: setup="
         & Showcase_Support.Fixed_Image (Long_Float (Setup_Elapsed), 6)
         & " s release_all="
         & Showcase_Support.Fixed_Image (Long_Float (Release_Elapsed), 6)
         & " s");
      Put_Line
        ("  peak_rss=" & Showcase_Support.Fixed_Image (MiB (Peak_RSS))
         & " MiB");
   end Report;

   procedure Run
     (Mode        : String;
      Connections : Positive;
      Model       : Flyology.Execution_Model)
   is
      Servers : constant Socket_Array_Access :=
        new Socket_Array (1 .. Connections);
      Peers   : constant Socket_Array_Access :=
        new Socket_Array (1 .. Connections);
      State   : Progress (Connections);

      task type Connection
        (Index : Positive;
         Kind  : Flyology.Execution_Model)
      is
         pragma Task_Info (Kind);
         pragma Storage_Size (Worker_Stack_Size);
      end Connection;

      task body Connection is
         Incoming : Stream_Element_Array (One_Byte'Range);
         Success  : Boolean := False;
      begin
         --  This acknowledges the last observable point before the task calls
         --  into the model-specific blocking receive. It does not claim that
         --  every task has completed its poller/poll registration.
         State.At_Receive_Boundary;
         Flyology.IO.Sockets.Receive_Exactly
           (Servers (Index), Incoming, Timeout => 30.0);
         Success := Incoming = One_Byte;
         State.Finished (Success);
      exception
         when others =>
            State.Finished (False);
      end Connection;

      type Connection_Access is access Connection;
      type Connection_Array is
        array (Positive range <>) of Connection_Access;
      Workers : Connection_Array (1 .. Connections);
      pragma Unreferenced (Workers);

      Baseline_RSS     : constant C.long_long := Current_RSS;
      Baseline_Virtual : constant C.long_long := Virtual_Bytes;
      Sample_RSS     : C.long_long;
      Sample_Virtual : C.long_long;
      Sample_Threads : C.int;
      Pool           : Flyology.Observability.Stack_Pool_Snapshot;
      Setup_Started   : constant Time := Clock;
      Release_Started : Time;
      Setup_Elapsed   : Duration;
      Release_Elapsed : Duration;
   begin
      for Index in 1 .. Connections loop
         GNAT.Sockets.Create_Socket_Pair (Servers (Index), Peers (Index));
      end loop;
      for Index in 1 .. Connections loop
         Workers (Index) := new Connection (Index, Model);
      end loop;

      State.Wait_Until_Receive_Boundary;
      Setup_Elapsed := To_Duration (Clock - Setup_Started);
      Sample_RSS := Current_RSS;
      Sample_Virtual := Virtual_Bytes;
      Sample_Threads := Thread_Count;
      Pool := Flyology.Observability.Stack_Pool;

      Release_Started := Clock;
      for Index in 1 .. Connections loop
         Flyology.IO.Sockets.Send_All
           (Peers (Index), One_Byte, Timeout => 30.0);
      end loop;
      State.Wait_Until_Finished;
      Release_Elapsed := To_Duration (Clock - Release_Started);

      if State.Failure_Count /= 0 then
         raise Program_Error with
           Natural'Image (State.Failure_Count)
           & " " & Mode & " connections failed";
      end if;

      Report
        (Mode,
         Connections,
         Baseline_RSS,
         Sample_RSS,
         Baseline_Virtual,
         Sample_Virtual,
         Sample_Threads,
         Pool,
         Setup_Elapsed,
         Release_Elapsed);

      for Index in 1 .. Connections loop
         GNAT.Sockets.Close_Socket (Servers (Index));
         GNAT.Sockets.Close_Socket (Peers (Index));
      end loop;
   end Run;

   procedure Usage is
   begin
      Put_Line ("usage: connection_density lightweight|native CONNECTIONS");
   end Usage;

begin
   if Ada.Command_Line.Argument_Count /= 2 then
      Usage;
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   declare
      Connections : constant Positive :=
        Positive'Value (Ada.Command_Line.Argument (2));
      Mode : constant String := Ada.Command_Line.Argument (1);
   begin
      if Mode = "lightweight" then
         Run (Mode, Connections, Flyology.Lightweight_Task);
      elsif Mode = "native" then
         Run (Mode, Connections, Flyology.Native_Task);
      else
         Usage;
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      end if;
   end;
exception
   when Constraint_Error =>
      Usage;
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Connection_Density;
