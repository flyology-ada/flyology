with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.Buffers;
with Flyology.IO.Files;
with Flyology.IO.Files.Transfers;
with Flyology.IO.Sockets;
with Flyology_Config;
with Interfaces.C;
with Showcase_Support;

procedure File_Transfer_Benchmark is
   package Files renames Flyology.IO.Files;
   package Sockets renames Flyology.IO.Sockets;
   package Transfers renames Flyology.IO.Files.Transfers;

   use Ada.Real_Time;
   use Ada.Streams;
   use Ada.Text_IO;
   use type Files.File_Descriptor;
   use type Files.File_Offset;
   use type Flyology.Execution_Model;
   use type Interfaces.C.int;
   use type Transfers.Byte_Count;

   Path       : constant String :=
     Ada.Environment_Variables.Value
       ("FLYOLOGY_FILE_TRANSFER_BENCH_PATH");
   IO_Block_Size : constant Positive := 1_024 * 1_024;
   Scratch_Size  : constant Positive := 16 * 1_024 * 1_024;
   Max_Size      : constant Positive := 64 * 1_024 * 1_024;

   type Transfer_Method is (Read_Then_Send, Reduced_Copy);

   type Measurement is record
      Wall : Duration;
      CPU  : Duration;
   end record;

   Max_Runs : constant Positive := 7;
   type Duration_Samples is array (1 .. Max_Runs) of Duration;
   type Ratio_Samples is array (1 .. Max_Runs) of Long_Float;

   type Paired_Summary is record
      Baseline      : Measurement;
      Optimized     : Measurement;
      Wall_Speedup  : Long_Float;
      CPU_Speedup   : Long_Float;
   end record;

   File : Files.File_Descriptor := Files.Invalid_File;

   type C_Timespec is record
      Seconds     : Interfaces.C.long;
      Nanoseconds : Interfaces.C.long;
   end record
     with Convention => C;

   function C_Clock_Gettime
     (Clock_ID : Interfaces.C.int;
      Value    : access C_Timespec) return Interfaces.C.int;
   pragma Import (C, C_Clock_Gettime, "clock_gettime");

   Thread_Clock_ID : constant Interfaces.C.int :=
     (if Flyology_Config.Alire_Host_OS = "linux" then 3 else 16);

   function Thread_CPU_Time return Duration is
      Value : aliased C_Timespec;
   begin
      if C_Clock_Gettime (Thread_Clock_ID, Value'Access) /= 0 then
         raise Program_Error with "cannot read thread CPU clock";
      end if;
      return Duration (Value.Seconds)
        + Duration (Value.Nanoseconds) / 1_000_000_000;
   end Thread_CPU_Time;

   function Selected_Linux_Backend return Interfaces.C.int;
   pragma Import
     (C, Selected_Linux_Backend, "flyology_linux_file_backend");

   function Observed_Send_ZC return Interfaces.C.int;
   pragma Import
     (C, Observed_Send_ZC, "flyology_transfer_send_zc_observed");

   function Send_ZC_Copy_Fallback return Interfaces.C.int;
   pragma Import
     (C, Send_ZC_Copy_Fallback, "flyology_send_zc_copy_fallback");

   procedure Remove_File is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   end Remove_File;

   procedure Populate is
      Block  : Stream_Element_Array
        (1 .. Stream_Element_Offset (IO_Block_Size));
      Offset : Files.File_Offset := 0;
      Last   : Stream_Element_Offset;
   begin
      for Index in Block'Range loop
         Block (Index) := Stream_Element ((Index * 17 + 11) mod 251);
      end loop;
      while Offset < Files.File_Offset (Max_Size) loop
         Files.Write_At (File, Offset, Block, Last);
         if Last < Block'First then
            raise Program_Error with
              "benchmark fixture write made no progress";
         end if;
         Offset := Offset + Files.File_Offset (Last - Block'First + 1);
      end loop;
   end Populate;

   procedure Read_Into
     (Offset : Files.File_Offset;
      Limit  : Positive;
      Item   : in out Flyology.Buffers.Unique_Buffer;
      Read   : out Natural)
   is
      procedure Borrow
        (Data   : in out Stream_Element_Array;
         Length : in out Natural)
      is
         Last : Stream_Element_Offset;
      begin
         Files.Read_At
           (File,
            Offset,
            Data
              (Data'First
               .. Data'First + Stream_Element_Offset (Limit) - 1),
            Last,
            Timeout => 10.0);
         Length :=
           (if Last < Data'First
            then 0
            else Natural (Last - Data'First + 1));
         Read := Length;
      end Borrow;
   begin
      Read := 0;
      Flyology.Buffers.With_Writable_Data (Item, Borrow'Access);
   end Read_Into;

   function Measure
     (Kind   : Flyology.Execution_Model;
      Method : Transfer_Method;
      Bytes  : Positive;
      Validate : Boolean := False) return Measurement
   is
      Sender_Socket   : Sockets.Socket_Type;
      Receiver_Socket : Sockets.Socket_Type;
      Listener        : Sockets.Socket_Type;
      Server          : Sockets.Endpoint;
      Peer            : Sockets.Endpoint;
      Elapsed         : Duration := 0.0;
      CPU_Elapsed     : Duration := 0.0;
      Sender_OK       : Boolean := False with Atomic;
      Receiver_OK     : Boolean := False with Atomic;

      task type Receiver is
         pragma Task_Info (Flyology.Native_Task);
      end Receiver;

      task body Receiver is
         Buffer    : Stream_Element_Array
           (1 .. Stream_Element_Offset (IO_Block_Size));
         Remaining : Natural := Bytes;
         Last      : Stream_Element_Offset;
         Limit     : Natural;
         Received  : Natural;
         Absolute  : Natural;
      begin
         while Remaining > 0 loop
            Limit := Natural'Min (Remaining, IO_Block_Size);
            Sockets.Receive
              (Receiver_Socket,
               Buffer (1 .. Stream_Element_Offset (Limit)),
               Last,
               Timeout => 10.0);
            if Last < Buffer'First then
               raise Program_Error with "benchmark receiver reached EOF";
            end if;
            Received := Natural (Last - Buffer'First + 1);
            if Validate then
               for Index in Buffer'First .. Last loop
                  Absolute :=
                    Bytes - Remaining + Natural (Index - Buffer'First);
                  if Buffer (Index) /=
                    Stream_Element
                      (((Absolute mod IO_Block_Size + 1) * 17 + 11) mod 251)
                  then
                     raise Program_Error with
                       "benchmark receiver payload mismatch";
                  end if;
               end loop;
            end if;
            Remaining := Remaining - Received;
         end loop;
         Receiver_OK := True;
      exception
         when others => Receiver_OK := False;
      end Receiver;

      task type Sender is
         pragma Task_Info (Kind);
      end Sender;

      task body Sender is
         Storage : aliased Flyology.Buffers.Pool
           (Block_Size => Scratch_Size, Capacity => 1);
         Scratch : Flyology.Buffers.Unique_Buffer (Storage'Access);
         Offset  : Files.File_Offset := 0;
         Read    : Natural;
         Sent    : Transfers.Byte_Count;
         Started : Time;
         CPU_Started : Duration;
      begin
         Flyology.Buffers.Acquire (Scratch);
         Started := Clock;
         CPU_Started := Thread_CPU_Time;
         while Offset < Files.File_Offset (Bytes) loop
            if Method = Read_Then_Send then
               Read_Into
                 (Offset,
                  Positive'Min
                    (Bytes - Natural (Offset), Scratch_Size),
                  Scratch,
                  Read);
               if Read = 0 then
                  raise Program_Error with "benchmark read reached EOF";
               end if;
               Sockets.Send_All (Sender_Socket, Scratch, Timeout => 10.0);
               Offset := Offset + Files.File_Offset (Read);
            else
               Transfers.Send_Chunk
                 (File,
                  Sender_Socket,
                  Offset,
                  Transfers.Byte_Count (Bytes - Natural (Offset)),
                  Scratch,
                  Sent,
                  Timeout => 10.0);
               if Sent = 0 then
                  raise Program_Error with
                    "benchmark transfer made no progress";
               end if;
               Offset := Offset + Files.File_Offset (Sent);
            end if;
         end loop;
         Elapsed := To_Duration (Clock - Started);
         CPU_Elapsed := Thread_CPU_Time - CPU_Started;
         Sender_OK := True;
      exception
         when others => Sender_OK := False;
      end Sender;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Server := Sockets.Get_Socket_Name (Listener);
      Sockets.Create_Socket (Sender_Socket);
      Sockets.Connect_Socket (Sender_Socket, Server);
      Sockets.Accept_Connection
        (Listener, Receiver_Socket, Peer, Timeout => 10.0);
      Sockets.Close_Socket (Listener);
      declare
         Drain : Receiver;
         Push  : Sender;
         pragma Unreferenced (Drain, Push);
      begin
         null;
      end;
      Sockets.Close_Socket (Sender_Socket);
      Sockets.Close_Socket (Receiver_Socket);
      if not Sender_OK or else not Receiver_OK or else Elapsed <= 0.0 then
         raise Program_Error with "file-transfer benchmark worker failed";
      end if;
      return (Wall => Elapsed, CPU => CPU_Elapsed);
   end Measure;

   function Median
     (Values : Duration_Samples;
      Count  : Positive) return Duration
   is
      Sorted : Duration_Samples := Values;
      Item   : Duration;
      Place  : Positive;
   begin
      for Index in 2 .. Count loop
         Item := Sorted (Index);
         Place := Index;
         while Place > 1 and then Sorted (Place - 1) > Item loop
            Sorted (Place) := Sorted (Place - 1);
            Place := Place - 1;
         end loop;
         Sorted (Place) := Item;
      end loop;
      return Sorted ((Count + 1) / 2);
   end Median;

   function Median
     (Values : Ratio_Samples;
      Count  : Positive) return Long_Float
   is
      Sorted : Ratio_Samples := Values;
      Item   : Long_Float;
      Place  : Positive;
   begin
      for Index in 2 .. Count loop
         Item := Sorted (Index);
         Place := Index;
         while Place > 1 and then Sorted (Place - 1) > Item loop
            Sorted (Place) := Sorted (Place - 1);
            Place := Place - 1;
         end loop;
         Sorted (Place) := Item;
      end loop;
      return Sorted ((Count + 1) / 2);
   end Median;

   function Paired_Measurements
     (Kind   : Flyology.Execution_Model;
      Bytes  : Positive;
      Runs   : Positive) return Paired_Summary
   is
      Baseline_Wall : Duration_Samples := (others => 0.0);
      Baseline_CPU  : Duration_Samples := (others => 0.0);
      Optimized_Wall : Duration_Samples := (others => 0.0);
      Optimized_CPU  : Duration_Samples := (others => 0.0);
      Wall_Ratios   : Ratio_Samples := (others => 0.0);
      CPU_Ratios    : Ratio_Samples := (others => 0.0);
      Baseline      : Measurement;
      Optimized     : Measurement;
      Warmup_Baseline  : Measurement;
      Warmup_Optimized : Measurement;
   begin
      if Runs > Max_Runs then
         raise Program_Error with "benchmark run count exceeds sample bound";
      end if;
      Warmup_Baseline :=
        Measure (Kind, Read_Then_Send, Bytes, Validate => True);
      Warmup_Optimized :=
        Measure (Kind, Reduced_Copy, Bytes, Validate => True);
      for Run in 1 .. Runs loop
         if Run mod 2 = 1 then
            Baseline := Measure (Kind, Read_Then_Send, Bytes);
            Optimized := Measure (Kind, Reduced_Copy, Bytes);
         else
            Optimized := Measure (Kind, Reduced_Copy, Bytes);
            Baseline := Measure (Kind, Read_Then_Send, Bytes);
         end if;
         Baseline_Wall (Run) := Baseline.Wall;
         Baseline_CPU (Run) := Baseline.CPU;
         Optimized_Wall (Run) := Optimized.Wall;
         Optimized_CPU (Run) := Optimized.CPU;
         Wall_Ratios (Run) :=
           Long_Float (Baseline.Wall) / Long_Float (Optimized.Wall);
         CPU_Ratios (Run) :=
           Long_Float (Baseline.CPU) / Long_Float (Optimized.CPU);
      end loop;
      if Warmup_Baseline.Wall <= 0.0 or else Warmup_Optimized.Wall <= 0.0
      then
         raise Program_Error with "benchmark warmup did not run";
      end if;
      return
        (Baseline =>
           (Wall => Median (Baseline_Wall, Runs),
            CPU  => Median (Baseline_CPU, Runs)),
         Optimized =>
           (Wall => Median (Optimized_Wall, Runs),
            CPU  => Median (Optimized_CPU, Runs)),
         Wall_Speedup => Median (Wall_Ratios, Runs),
         CPU_Speedup  => Median (CPU_Ratios, Runs));
   end Paired_Measurements;

   function Rate (Bytes : Positive; Elapsed : Duration) return Long_Float is
     (Long_Float (Bytes) / (1_024.0 * 1_024.0) / Long_Float (Elapsed));

   procedure Run_Lane
     (Kind : Flyology.Execution_Model; Name : String)
   is
      type Size_Row is record
         Bytes : Positive;
         Runs  : Positive;
      end record;
      Rows : constant array (Positive range <>) of Size_Row :=
        [(Bytes => 1 * 1_024 * 1_024, Runs => 7),
         (Bytes => 16 * 1_024 * 1_024, Runs => 5),
         (Bytes => 64 * 1_024 * 1_024, Runs => 5)];
      Baseline  : Measurement;
      Optimized : Measurement;
      Summary   : Paired_Summary;
      Speedup   : Long_Float;
      Best      : Long_Float := 0.0;
      CPU_Speedup : Long_Float;
      CPU_Best    : Long_Float := 0.0;
   begin
      Put_Line (Name & " task");
      Put_Line
        ("  size     read+send MiB/s   Send_Chunk MiB/s   wall    CPU");
      for Row of Rows loop
         Summary := Paired_Measurements (Kind, Row.Bytes, Row.Runs);
         Baseline := Summary.Baseline;
         Optimized := Summary.Optimized;
         Speedup := Summary.Wall_Speedup;
         CPU_Speedup := Summary.CPU_Speedup;
         Best := Long_Float'Max (Best, Speedup);
         CPU_Best := Long_Float'Max (CPU_Best, CPU_Speedup);
         Put_Line
           ("  " & Integer'Image (Row.Bytes / (1_024 * 1_024)) & " MiB"
            & "    "
            & Showcase_Support.Fixed_Image
                (Rate (Row.Bytes, Baseline.Wall), 1)
            & "             "
            & Showcase_Support.Fixed_Image
                (Rate (Row.Bytes, Optimized.Wall), 1)
            & "             "
            & Showcase_Support.Fixed_Image (Speedup, 2) & "x  "
            & Showcase_Support.Fixed_Image (CPU_Speedup, 2) & "x");
      end loop;
      if Kind = Flyology.Lightweight_Task then
         case Selected_Linux_Backend is
            when 1 => Put_Line ("  lightweight file backend: io_uring");
            when 2 =>
               Put_Line ("  lightweight file backend: native AIO fallback");
            when others => Put_Line ("  lightweight file backend: Darwin AIO");
         end case;
         if Observed_Send_ZC /= 0 then
            if Send_ZC_Copy_Fallback = 0 then
               Put_Line
                 ("  reduced-copy socket path: SEND_ZC zero-copy observed");
            else
               Put_Line
                 ("  socket path: SEND_ZC kernel copy fallback observed");
            end if;
         else
            Put_Line ("  reduced-copy socket path: fallback active");
         end if;
      end if;
      if Best >= 1.05
        and then
          (Kind = Flyology.Native_Task
           or else
             (Observed_Send_ZC /= 0 and then Send_ZC_Copy_Fallback = 0))
      then
         Put_Line
           ("  measured reduced-copy crossover: Send_Chunk reached "
            & Showcase_Support.Fixed_Image (Best, 2)
            & "x the read-then-send throughput");
      elsif Best >= 1.05 then
         Put_Line
           ("  measured Send_Chunk crossover, but reduced-copy fallback"
            & " was active");
      else
         Put_Line ("  no reduced-copy crossover measured in this run");
      end if;
      if CPU_Best >= 1.05
        and then
          (Kind = Flyology.Native_Task
           or else
             (Observed_Send_ZC /= 0 and then Send_ZC_Copy_Fallback = 0))
      then
         Put_Line
           ("  measured CPU-efficiency crossover: "
            & Showcase_Support.Fixed_Image (CPU_Best, 2) & "x");
      end if;
   end Run_Lane;

begin
   Remove_File;
   File :=
     Files.Open (Path, Files.Read_Write, Create => True, Truncate => True);
   Populate;
   Put_Line ("regular-file to socket throughput (paired median samples)");
   Put_Line
     ("  alternating method order; validated warmups; cached file data");
   Run_Lane (Flyology.Native_Task, "native");
   New_Line;
   Run_Lane (Flyology.Lightweight_Task, "lightweight");
   Files.Close (File);
   Remove_File;
exception
   when others =>
      if File /= Files.Invalid_File then
         Files.Close (File);
      end if;
      Remove_File;
      raise;
end File_Transfer_Benchmark;
