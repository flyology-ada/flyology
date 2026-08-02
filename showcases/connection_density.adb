with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with GNAT.Sockets;
with Gnatevl;
with Gnatevl.IO.Sockets;
with Interfaces.C;

procedure Connection_Density is
   use Ada.Real_Time;
   use Ada.Streams;
   use Ada.Text_IO;

   package C renames Interfaces.C;
   use type C.long_long;

   Worker_Stack_Size : constant := 32 * 1_024;
   One_Byte          : constant Stream_Element_Array := [1 => 42];

   function Current_RSS return C.long_long;
   pragma Import (C, Current_RSS, "gnatevl_current_rss_bytes");

   function Peak_RSS return C.long_long;
   pragma Import (C, Peak_RSS, "gnatevl_peak_rss_bytes");

   function Virtual_Bytes return C.long_long;
   pragma Import (C, Virtual_Bytes, "gnatevl_virtual_bytes");

   function Thread_Count return C.int;
   pragma Import (C, Thread_Count, "gnatevl_thread_count");

   protected type Progress (Target : Positive) is
      procedure Ready;
      procedure Finished (Succeeded : Boolean);
      entry Wait_Until_Ready;
      entry Wait_Until_Finished;
      function Failure_Count return Natural;
   private
      Ready_Count    : Natural := 0;
      Finished_Count : Natural := 0;
      Failures       : Natural := 0;
   end Progress;

   protected body Progress is
      procedure Ready is
      begin
         Ready_Count := Ready_Count + 1;
      end Ready;

      procedure Finished (Succeeded : Boolean) is
      begin
         Finished_Count := Finished_Count + 1;
         if not Succeeded then
            Failures := Failures + 1;
         end if;
      end Finished;

      entry Wait_Until_Ready when Ready_Count = Target is
      begin
         null;
      end Wait_Until_Ready;

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
      Waiting_RSS      : C.long_long;
      Baseline_Virtual : C.long_long;
      Waiting_Virtual  : C.long_long;
      Waiting_Threads  : C.int;
      Setup_Elapsed    : Duration;
      Release_Elapsed  : Duration)
   is
      RSS_Increase : constant C.long_long :=
        Increase_From (Waiting_RSS, Baseline_RSS);
      Virtual_Increase : constant C.long_long :=
        Increase_From (Waiting_Virtual, Baseline_Virtual);
   begin
      Put_Line
        ("mode=" & Mode
         & " connections=" & Connections'Image
         & " completed=" & Connections'Image
         & " socket_endpoints=" & Natural'Image (Connections * 2)
         & " task_stack=" & Natural'Image (Worker_Stack_Size / 1_024)
         & " KiB");
      Put_Line
        ("  waiting: threads=" & Waiting_Threads'Image
         & " rss=" & Long_Float'Image (MiB (Waiting_RSS)) & " MiB"
         & " rss_delta=" & Long_Float'Image (MiB (RSS_Increase)) & " MiB");
      Put_Line
        ("  address_space: virtual_delta="
         & Long_Float'Image (MiB (Virtual_Increase)) & " MiB");
      Put_Line
        ("  density: rss_delta_per_connection="
         & C.long_long'Image (RSS_Increase / C.long_long (Connections))
         & " bytes");
      Put_Line
        ("  timing: setup=" & Setup_Elapsed'Image
         & " s release_all=" & Release_Elapsed'Image & " s");
      Put_Line
        ("  peak_rss=" & Long_Float'Image (MiB (Peak_RSS)) & " MiB");
   end Report;

   procedure Run
     (Mode        : String;
      Connections : Positive;
      Model       : Gnatevl.Execution_Model)
   is
      Servers : constant Socket_Array_Access :=
        new Socket_Array (1 .. Connections);
      Peers   : constant Socket_Array_Access :=
        new Socket_Array (1 .. Connections);
      State   : Progress (Connections);

      task type Connection
        (Index : Positive;
         Kind  : Gnatevl.Execution_Model)
      is
         pragma Task_Info (Kind);
         pragma Storage_Size (Worker_Stack_Size);
      end Connection;

      task body Connection is
         Incoming : Stream_Element_Array (One_Byte'Range);
         Success  : Boolean := False;
      begin
         State.Ready;
         Gnatevl.IO.Sockets.Receive_Exactly
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
      Waiting_RSS     : C.long_long;
      Waiting_Virtual : C.long_long;
      Waiting_Threads : C.int;
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

      State.Wait_Until_Ready;
      Setup_Elapsed := To_Duration (Clock - Setup_Started);
      Waiting_RSS := Current_RSS;
      Waiting_Virtual := Virtual_Bytes;
      Waiting_Threads := Thread_Count;

      Release_Started := Clock;
      for Index in 1 .. Connections loop
         Gnatevl.IO.Sockets.Send_All
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
         Waiting_RSS,
         Baseline_Virtual,
         Waiting_Virtual,
         Waiting_Threads,
         Setup_Elapsed,
         Release_Elapsed);

      for Index in 1 .. Connections loop
         GNAT.Sockets.Close_Socket (Servers (Index));
         GNAT.Sockets.Close_Socket (Peers (Index));
      end loop;
   end Run;

   procedure Usage is
   begin
      Put_Line ("usage: connection_density evented|native CONNECTIONS");
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
      if Mode = "evented" then
         Run (Mode, Connections, Gnatevl.Event_Loop_Task);
      elsif Mode = "native" then
         Run (Mode, Connections, Gnatevl.Native_Thread);
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
