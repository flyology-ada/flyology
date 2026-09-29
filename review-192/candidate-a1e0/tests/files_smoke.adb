with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.Buffers;
with Flyology.IO;
with Flyology.IO.Files;
with Interfaces.C;

procedure Files_Smoke is
   use Ada.Streams;
   use type Flyology.IO.Files.File_Descriptor;
   use type Interfaces.C.int;

   function Selected_Linux_Backend return Interfaces.C.int;
   pragma Import (C, Selected_Linux_Backend, "flyology_linux_file_backend");

   Path : constant String := "/tmp/flyology-files-smoke.data";
   Data : constant Stream_Element_Array (1 .. 4) := [10, 20, 30, 40];

   File     : Flyology.IO.Files.File_Descriptor := Flyology.IO.Files.Invalid_File;
   Incoming : Stream_Element_Array (Data'Range);
   Last     : Stream_Element_Offset;
   Rejected : Boolean := False;

   procedure Remove_Test_File is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   end Remove_Test_File;

   --  Outcome codes shared by the zero-timeout readers. They are reported
   --  through an atomic scalar because the reader may be a lightweight task.
   Read_Succeeded : constant Natural := 1;
   Read_Timed_Out : constant Natural := 2;
   Read_Failed    : constant Natural := 3;

   procedure Report (Outcome : Natural; Description : String) is
   begin
      case Outcome is
         when Read_Succeeded =>
            null;

         when Read_Timed_Out =>
            raise Program_Error with Description & " raised Timeout_Error without attempting the read";

         when others         =>
            raise Program_Error with Description & " did not return the data";
      end case;
   end Report;

   --  A zero Timeout is an immediate attempt everywhere else in the library
   --  (Flyology.IO.Wait, Flyology.Buffers.Acquire_For, the connection layer's
   --  zero-remaining paths). A positional read has no readiness wait, so the
   --  immediate attempt must run and its result must win.
   procedure Check_Immediate_Array_Read (Lane : String; Kind : Flyology.Execution_Model) is
      Outcome : Natural := 0
      with Atomic;

      task type Reader is
         pragma Task_Info (Kind);
      end Reader;

      task body Reader is
         Buffer : Stream_Element_Array (Data'Range);
         Stop   : Stream_Element_Offset;
      begin
         Flyology.IO.Files.Read_At (File, 0, Buffer, Stop, Timeout => 0.0);
         Outcome := (if Stop = Buffer'Last and then Buffer = Data then Read_Succeeded else Read_Failed);
      exception
         when Flyology.IO.Files.Timeout_Error =>
            Outcome := Read_Timed_Out;
         when others =>
            Outcome := Read_Failed;
      end Reader;
   begin
      declare
         Worker : Reader;
      begin
         --  Leaving the block waits for Worker to terminate.
         null;
      end;
      Report (Outcome, "zero-timeout Read_At on " & Lane);
   end Check_Immediate_Array_Read;

   procedure Check_Immediate_Buffer_Read (Lane : String; Kind : Flyology.Execution_Model) is
      Outcome : Natural := 0
      with Atomic;

      task type Reader is
         pragma Task_Info (Kind);
      end Reader;

      task body Reader is
         Storage : aliased Flyology.Buffers.Pool (Block_Size => Data'Length, Capacity => 1);
         Item    : Flyology.Buffers.Unique_Buffer (Storage'Access);
         Count   : Natural;

         procedure Compare (Payload : Stream_Element_Array) is
         begin
            Outcome := (if Payload = Data then Read_Succeeded else Read_Failed);
         end Compare;
      begin
         Flyology.Buffers.Acquire (Item);
         Flyology.IO.Files.Read_At (File, 0, Item, Count, Timeout => 0.0);
         if Count /= Data'Length then
            Outcome := Read_Failed;
         else
            Flyology.Buffers.With_Readable_Data (Item, Compare'Access);
         end if;
         Flyology.Buffers.Release (Item);
      exception
         when Flyology.IO.Files.Timeout_Error =>
            Outcome := Read_Timed_Out;
         when others =>
            Outcome := Read_Failed;
      end Reader;
   begin
      declare
         Worker : Reader;
      begin
         --  Leaving the block waits for Worker to terminate.
         null;
      end;
      Report (Outcome, "zero-timeout unique-buffer Read_At on " & Lane);
   end Check_Immediate_Buffer_Read;

   --  Zero remains a deadline value, so the guards that precede any I/O keep
   --  precedence over the immediate attempt.
   procedure Check_Immediate_Read_Guards is
      Token  : aliased Flyology.IO.Files.Cancellation_Token;
      Buffer : Stream_Element_Array (Data'Range);
      Empty  : Stream_Element_Array (1 .. 0);
      Stop   : Stream_Element_Offset;
      Caught : Boolean := False;
   begin
      Flyology.IO.Files.Read_At (File, 0, Empty, Stop, Timeout => 0.0);
      if Stop /= Empty'First - 1 then
         raise Program_Error with "zero-length zero-timeout Read_At reported a transfer";
      end if;

      Token.Request;
      begin
         Flyology.IO.Files.Read_At (File, 0, Buffer, Stop, Timeout => 0.0, Token => Token'Access);
      exception
         when Flyology.IO.Files.Operation_Cancelled =>
            Caught := True;
      end;
      if not Caught then
         raise Program_Error with "pre-cancelled zero-timeout Read_At was not cancelled";
      end if;
   end Check_Immediate_Read_Guards;

begin
   Remove_Test_File;

   File :=
     Flyology.IO.Files.Open (Path, Mode => Flyology.IO.Files.Read_Write, Create => True, Truncate => True);
   Flyology.IO.Files.Write_At (File, 0, Data, Last);
   if Last /= Data'Last then
      raise Program_Error with "read/write create wrote a partial record";
   end if;
   Flyology.IO.Files.Read_At (File, 0, Incoming, Last);
   if Last /= Incoming'Last or else Incoming /= Data then
      raise Program_Error with "read/write create returned a write-only fd";
   end if;

   Check_Immediate_Array_Read ("a native task", Flyology.Native_Task);
   Check_Immediate_Array_Read ("a lightweight task", Flyology.Lightweight_Task);
   Check_Immediate_Buffer_Read ("a native task", Flyology.Native_Task);
   Check_Immediate_Buffer_Read ("a lightweight task", Flyology.Lightweight_Task);
   Check_Immediate_Read_Guards;

   declare
      Batch_Size : constant Positive := 64;

      protected Progress is
         procedure Finished (Passed : Boolean);
         entry Wait;
         function Passed return Boolean;
      private
         Completed : Natural := 0;
         All_OK    : Boolean := True;
      end Progress;

      protected body Progress is
         procedure Finished (Passed : Boolean) is
         begin
            Completed := Completed + 1;
            All_OK := All_OK and Passed;
         end Finished;

         entry Wait when Completed = Batch_Size is
         begin
            null;
         end Wait;

         function Passed return Boolean
         is (All_OK);
      end Progress;

      task type Parallel_Writer (Index : Positive) is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Parallel_Writer;

      task body Parallel_Writer is
         Item    : constant Stream_Element_Array := [1 => Stream_Element (Index mod 251)];
         Written : Stream_Element_Offset;
      begin
         Flyology.IO.Files.Write_At (File, Flyology.IO.Files.File_Offset (Index - 1), Item, Written);
         Progress.Finished (Written = Item'Last);
      exception
         when others =>
            Progress.Finished (False);
      end Parallel_Writer;

      type Writer_Access is access Parallel_Writer;
      Writers : array (1 .. Batch_Size) of Writer_Access;
      Batch   : Stream_Element_Array (1 .. Stream_Element_Offset (Batch_Size));
   begin
      for Index in Writers'Range loop
         Writers (Index) := new Parallel_Writer (Index);
      end loop;
      Progress.Wait;
      if not Progress.Passed then
         raise Program_Error with "parallel kernel file write failed";
      end if;

      Flyology.IO.Files.Read_At (File, 0, Batch, Last);
      if Last /= Batch'Last then
         raise Program_Error with "parallel kernel file read was short";
      end if;
      for Index in Writers'Range loop
         if Batch (Stream_Element_Offset (Index)) /= Stream_Element (Index mod 251) then
            raise Program_Error with "parallel positional write corrupted data";
         end if;
      end loop;
   end;
   Flyology.IO.Files.Close (File);

   File := Flyology.IO.Files.Open (Path, Mode => Flyology.IO.Files.Write_Only, Truncate => True);

   begin
      Flyology.IO.Files.Read_At (File, 0, Incoming, Last);
   exception
      when Flyology.IO.Device_Error =>
         Rejected := True;
   end;
   if not Rejected then
      raise Program_Error with "read from write-only file was accepted";
   end if;
   Flyology.IO.Files.Close (File);

   Rejected := False;
   File := Flyology.IO.Files.Open (Path, Mode => Flyology.IO.Files.Read_Only);
   Flyology.IO.Files.Read_At (File, 0, Incoming, Last);
   if Last >= Incoming'First then
      raise Program_Error with "truncate without create was ignored";
   end if;
   Flyology.IO.Files.Close (File);

   Remove_Test_File;
   File := Flyology.IO.Files.Open (Path, Mode => Flyology.IO.Files.Read_Only, Create => True);
   Flyology.IO.Files.Read_At (File, 0, Incoming, Last);
   if Last >= Incoming'First then
      raise Program_Error with "read-only create was not empty";
   end if;
   Flyology.IO.Files.Close (File);

   begin
      File := Flyology.IO.Files.Open (Path, Mode => Flyology.IO.Files.Read_Only, Truncate => True);
   exception
      when Flyology.IO.Device_Error =>
         Rejected := True;
   end;
   if not Rejected then
      Flyology.IO.Files.Close (File);
      raise Program_Error with "read-only truncate was accepted";
   end if;

   Remove_Test_File;
   declare
      Expected_Backend : constant String :=
        Ada.Environment_Variables.Value ("FLYOLOGY_EXPECT_FILE_BACKEND", "");
   begin
      if Expected_Backend = "io-uring" then
         if Selected_Linux_Backend /= 1 then
            raise Program_Error
              with "expected Linux io_uring backend, got" & Interfaces.C.int'Image (Selected_Linux_Backend);
         end if;
         Ada.Text_IO.Put_Line ("linux file backend: io_uring");
      elsif Expected_Backend = "native-aio" then
         if Selected_Linux_Backend /= 2 then
            raise Program_Error
              with "expected Linux native-AIO backend, got" & Interfaces.C.int'Image (Selected_Linux_Backend);
         end if;
         Ada.Text_IO.Put_Line ("linux file backend: native-aio");
      elsif Expected_Backend /= "" then
         raise Program_Error with "unknown expected Linux file backend: " & Expected_Backend;
      end if;
   end;
exception
   when others =>
      if File /= Flyology.IO.Files.Invalid_File then
         begin
            Flyology.IO.Files.Close (File);
         exception
            when others =>
               null;
         end;
      end if;
      Remove_Test_File;
      raise;
end Files_Smoke;
