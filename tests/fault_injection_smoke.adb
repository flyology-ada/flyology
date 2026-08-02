with Ada.Command_Line;
with Ada.Directories;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Fault_Control;
with GNAT.Sockets;
with Gnatevl;
with Gnatevl.IO;
with Gnatevl.IO.Connections;
with Gnatevl.IO.Files;
with Interfaces.C;

procedure Fault_Injection_Smoke is
   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Fault_Control.Point;
   use type GNAT.Sockets.Socket_Type;
   use type Interfaces.C.int;

   package IO renames Gnatevl.IO;
   package Connections renames Gnatevl.IO.Connections;
   package Files renames Gnatevl.IO.Files;

   Case_Name : constant String :=
     (if Ada.Command_Line.Argument_Count = 0
      then ""
      else Ada.Command_Line.Argument (1));

   task type Probe (Kind : Gnatevl.Execution_Model) is
      pragma Task_Info (Kind);
   end Probe;

   task body Probe is
   begin
      delay 0.001;
   end Probe;

   type Probe_Access is access Probe;
   procedure Free_Probe is new Ada.Unchecked_Deallocation
     (Probe, Probe_Access);

   procedure Await (Item : not null Probe_Access) is
      Limit : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
   begin
      while not Item.all'Terminated loop
         if Ada.Real_Time.Clock >= Limit then
            raise Program_Error with "task failed to terminate after fault";
         end if;
         delay 0.001;
      end loop;
   end Await;

   procedure Warm_Group is
      Item : Probe_Access := new Probe (Gnatevl.Event_Loop_Task);
   begin
      Await (Item);
      Free_Probe (Item);
   end Warm_Group;

   procedure Expect_Activation_Failure (At_Point : Fault_Control.Point) is
      Item     : Probe_Access := null;
      Rejected : Boolean := False;
   begin
      Fault_Control.Reset;
      Fault_Control.Arm (At_Point);
      begin
         Item := new Probe (Gnatevl.Event_Loop_Task);
         Await (Item);
      exception
         when Tasking_Error | Storage_Error =>
            Rejected := True;
      end;
      if Item /= null then
         Free_Probe (Item);
      end if;
      if not Rejected or else Fault_Control.Calls (At_Point) = 0 then
         raise Program_Error with "activation fault was not surfaced";
      end if;

      Fault_Control.Reset;
      Warm_Group;
   end Expect_Activation_Failure;

   procedure Test_Watch_Error is
      Reader : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Writer : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Failed_As_Device_Error : Boolean := False with Atomic;

      task type Waiter is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Waiter;

      task body Waiter is
      begin
         begin
            if IO.Wait
              (IO.Descriptor (GNAT.Sockets.To_C (Reader)),
               IO.For_Read,
               Timeout => 0.1)
            then
               null;
            end if;
         exception
            when IO.Device_Error =>
            Failed_As_Device_Error := True;
         end;
      end Waiter;

      type Waiter_Access is access Waiter;
      procedure Free_Waiter is new Ada.Unchecked_Deallocation
        (Waiter, Waiter_Access);
      Item : Waiter_Access;
   begin
      GNAT.Sockets.Create_Socket_Pair (Reader, Writer);
      Fault_Control.Reset;
      Fault_Control.Arm (Fault_Control.Poller_Watch);
      Item := new Waiter;
      declare
         Limit : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      begin
         while not Item.all'Terminated loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with "watch-fault waiter did not terminate";
            end if;
            delay 0.001;
         end loop;
      end;
      Free_Waiter (Item);
      GNAT.Sockets.Close_Socket (Reader);
      GNAT.Sockets.Close_Socket (Writer);
      if not Failed_As_Device_Error then
         raise Program_Error with "watch failure did not become Device_Error";
      end if;
      Fault_Control.Reset;
      Warm_Group;
   exception
      when others =>
         if Reader /= GNAT.Sockets.No_Socket then
            GNAT.Sockets.Close_Socket (Reader);
         end if;
         if Writer /= GNAT.Sockets.No_Socket then
            GNAT.Sockets.Close_Socket (Writer);
         end if;
         raise;
   end Test_Watch_Error;

   procedure Test_Multi_Watch_Rollback is
      type Socket_Array is array (Positive range <>) of GNAT.Sockets.Socket_Type;
      Readers : Socket_Array (1 .. 4) := (others => GNAT.Sockets.No_Socket);
      Writers : Socket_Array (Readers'Range) :=
        (others => GNAT.Sockets.No_Socket);
      Failed : Boolean := False with Atomic;
      Retry_Ready : Boolean := False with Atomic;
      Reused_FD : IO.Descriptor;

      task type Failed_Waiter is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Failed_Waiter;
      task body Failed_Waiter is
         Outcome : IO.Wait_Outcome;
         pragma Unreferenced (Outcome);
      begin
         begin
            Outcome := IO.Wait_Interruptibly
              (IO.Descriptor (GNAT.Sockets.To_C (Readers (1))),
               IO.For_Read,
               0.1,
               IO.Descriptor (GNAT.Sockets.To_C (Readers (2))),
               IO.Descriptor (GNAT.Sockets.To_C (Readers (3))),
               IO.Descriptor (GNAT.Sockets.To_C (Readers (4))));
         exception
            when IO.Device_Error =>
               Failed := True;
         end;
      end Failed_Waiter;

      type Failed_Waiter_Access is access Failed_Waiter;
      procedure Free is new Ada.Unchecked_Deallocation
        (Failed_Waiter, Failed_Waiter_Access);
      Item : Failed_Waiter_Access;
   begin
      for Index in Readers'Range loop
         GNAT.Sockets.Create_Socket_Pair (Readers (Index), Writers (Index));
      end loop;
      Reused_FD := IO.Descriptor (GNAT.Sockets.To_C (Readers (1)));
      Fault_Control.Reset;
      --  Let the primary and first interrupt arm, then fail the second
      --  interrupt. Both earlier kernel watches must be rolled back.
      Fault_Control.Arm (Fault_Control.Poller_Watch, First => 2);
      Item := new Failed_Waiter;
      declare
         Limit : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      begin
         while Item /= null and then not Item.all'Terminated loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "later-watch fault waiter did not terminate";
            end if;
            delay 0.001;
         end loop;
      end;
      Free (Item);
      if not Failed or else Fault_Control.Calls
        (Fault_Control.Poller_Watch) < 3
      then
         raise Program_Error with "later watch failure was not surfaced";
      end if;
      for Index in Readers'Range loop
         GNAT.Sockets.Close_Socket (Readers (Index));
         GNAT.Sockets.Close_Socket (Writers (Index));
      end loop;

      Fault_Control.Reset;
      GNAT.Sockets.Create_Socket_Pair (Readers (1), Writers (1));
      if IO.Descriptor (GNAT.Sockets.To_C (Readers (1))) /= Reused_FD then
         raise Program_Error with "descriptor reuse precondition failed";
      end if;
      declare
         Data : constant Ada.Streams.Stream_Element_Array (1 .. 1) :=
           (1 => 1);
         Last : Ada.Streams.Stream_Element_Offset;
         task Retry is
            pragma Task_Info (Gnatevl.Event_Loop_Task);
         end Retry;
         task body Retry is
         begin
            Retry_Ready := IO.Wait
              (Reused_FD, IO.For_Read, Timeout => 0.1);
         end Retry;
      begin
         GNAT.Sockets.Send_Socket (Writers (1), Data, Last);
      end;
      if not Retry_Ready then
         raise Program_Error with "rolled-back descriptor poisoned reuse";
      end if;
      GNAT.Sockets.Close_Socket (Readers (1));
      GNAT.Sockets.Close_Socket (Writers (1));
   end Test_Multi_Watch_Rollback;

   procedure Test_EINTR is
      Item : Probe_Access;
   begin
      Warm_Group;
      Fault_Control.Reset;
      Fault_Control.Arm (Fault_Control.Poller_EINTR, Count => 32);
      Item := new Probe (Gnatevl.Event_Loop_Task);
      Await (Item);
      Free_Probe (Item);
      if Fault_Control.Calls (Fault_Control.Poller_EINTR) < 32 then
         raise Program_Error with "synthetic EINTR path was not exercised";
      end if;
      Fault_Control.Reset;
   end Test_EINTR;

   procedure Test_File_Saturation is
      Path : constant String := "/tmp/gnatevl-fault-file.data";
      Count : constant Positive := 48;
      File : Files.File_Descriptor := Files.Invalid_File;

      protected Progress is
         procedure Done (OK : Boolean);
         entry Wait;
         function Passed return Boolean;
      private
         Finished : Natural := 0;
         All_OK   : Boolean := True;
      end Progress;

      protected body Progress is
         procedure Done (OK : Boolean) is
         begin
            Finished := Finished + 1;
            All_OK := All_OK and OK;
         end Done;

         entry Wait when Finished = Count is
         begin
            null;
         end Wait;

         function Passed return Boolean is (All_OK);
      end Progress;

      task type Writer (Index : Positive) is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Writer;

      task body Writer is
         Data : constant Ada.Streams.Stream_Element_Array :=
           [1 => Ada.Streams.Stream_Element (Index mod 251)];
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Files.Write_At
           (File, Files.File_Offset (Index - 1), Data, Last);
         Progress.Done (Last = Data'Last);
      exception
         when others =>
            Progress.Done (False);
      end Writer;

      type Writer_Access is access Writer;
      procedure Free_Writer is new Ada.Unchecked_Deallocation
        (Writer, Writer_Access);
      Writers : array (1 .. Count) of Writer_Access;
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      File := Files.Open
        (Path, Mode => Files.Read_Write, Create => True, Truncate => True);
      Fault_Control.Reset;
      Fault_Control.Arm
        (Fault_Control.File_Submission_Full, Count => Count * 3);
      for Index in Writers'Range loop
         Writers (Index) := new Writer (Index);
      end loop;
      Progress.Wait;
      if not Progress.Passed then
         raise Program_Error with "file queue did not recover from EAGAIN";
      end if;
      for Item of Writers loop
         while not Item.all'Terminated loop
            delay 0.001;
         end loop;
         Free_Writer (Item);
      end loop;
      if Fault_Control.Calls (Fault_Control.File_Submission_Full)
        <= Count * 3
      then
         raise Program_Error with "file saturation did not reach recovery";
      end if;
      Fault_Control.Reset;
      Files.Close (File);
      Ada.Directories.Delete_File (Path);
   exception
      when others =>
         Fault_Control.Reset;
         Files.Close (File);
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
         raise;
   end Test_File_Saturation;

   procedure Test_Cross_Domain_Cancellation is
      Path : constant String := "/tmp/gnatevl-cancel-file.data";
      File : Files.File_Descriptor := Files.Invalid_File;
      Reader : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Writer : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
      Manager : aliased Connections.Server (1);
      Connection : Connections.Connection;
      Token : aliased Connections.Cancellation_Token;

      protected Progress is
         procedure Done (Passed : Boolean);
         entry Wait;
         function Passed return Boolean;
      private
         Finished : Natural := 0;
         All_OK   : Boolean := True;
      end Progress;

      protected body Progress is
         procedure Done (Passed : Boolean) is
         begin
            Finished := Finished + 1;
            All_OK := All_OK and Passed;
         end Done;

         entry Wait when Finished = 2 is
         begin
            null;
         end Wait;

         function Passed return Boolean is (All_OK);
      end Progress;

      task type File_Waiter is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end File_Waiter;

      task body File_Waiter is
         Data : constant Ada.Streams.Stream_Element_Array := [1 => 42];
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Files.Write_At (File, 0, Data, Last, Token'Access);
         Progress.Done (False);
      exception
         --  The connection-qualified legacy name must catch the canonical
         --  exception raised from the file package.
         when Connections.Operation_Cancelled =>
            Progress.Done (True);
         when others =>
            Progress.Done (False);
      end File_Waiter;

      task type Connection_Waiter is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Connection_Waiter;

      task body Connection_Waiter is
         Data : Ada.Streams.Stream_Element_Array (1 .. 1);
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Connections.Receive
           (Connection,
            Data,
            Last,
            Timeout => IO.Infinite,
            Token   => Token'Access);
         Progress.Done (False);
      exception
         --  And the file-qualified legacy name must catch cancellation raised
         --  from the connection package.
         when Files.Operation_Cancelled =>
            Progress.Done (True);
         when others =>
            Progress.Done (False);
      end Connection_Waiter;

      type File_Waiter_Access is access File_Waiter;
      type Connection_Waiter_Access is access Connection_Waiter;
      procedure Free_File_Waiter is new Ada.Unchecked_Deallocation
        (File_Waiter, File_Waiter_Access);
      procedure Free_Connection_Waiter is new Ada.Unchecked_Deallocation
        (Connection_Waiter, Connection_Waiter_Access);
      File_Task : File_Waiter_Access;
      Connection_Task : Connection_Waiter_Access;
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      File := Files.Open
        (Path, Mode => Files.Read_Write, Create => True, Truncate => True);
      GNAT.Sockets.Create_Socket_Pair (Reader, Writer);
      Connections.Take (Manager, Reader, Connection);

      Fault_Control.Reset;
      Fault_Control.Arm
        (Fault_Control.File_Submission_Full, Count => 100_000);
      File_Task := new File_Waiter;
      Connection_Task := new Connection_Waiter;
      declare
         Limit : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      begin
         while Fault_Control.Calls (Fault_Control.File_Submission_Full) = 0
         loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "file cancellation waiter never entered pending queue";
            end if;
            delay 0.001;
         end loop;
      end;
      Token.Request;
      Progress.Wait;
      if not Progress.Passed then
         raise Program_Error with
           "shared token did not cancel both I/O domains";
      end if;

      while not File_Task.all'Terminated
        or else not Connection_Task.all'Terminated
      loop
         delay 0.001;
      end loop;
      Free_File_Waiter (File_Task);
      Free_Connection_Waiter (Connection_Task);

      --  The same one-shot token also cancels both legacy surfaces before a
      --  subsequent operation starts, without allocating another wake source.
      declare
         Data : Ada.Streams.Stream_Element_Array (1 .. 1) := [1 => 7];
         Last : Ada.Streams.Stream_Element_Offset;
         File_Caught : Boolean := False;
         Connection_Caught : Boolean := False;
      begin
         begin
            Files.Write_At (File, 0, Data, Last, Token'Access);
         exception
            when Connections.Operation_Cancelled => File_Caught := True;
         end;
         begin
            Connections.Receive
              (Connection,
               Data,
               Last,
               Timeout => 0.01,
               Token   => Token'Access);
         exception
            when Files.Operation_Cancelled => Connection_Caught := True;
         end;
         if not File_Caught or else not Connection_Caught then
            raise Program_Error with
              "shared token did not preserve serial cancellation identity";
         end if;
      end;

      Fault_Control.Reset;
      Connections.Close (Connection);
      if Writer /= GNAT.Sockets.No_Socket then
         GNAT.Sockets.Close_Socket (Writer);
      end if;
      Files.Close (File);
      Ada.Directories.Delete_File (Path);
   exception
      when others =>
         Fault_Control.Reset;
         Connections.Close (Connection);
         if Reader /= GNAT.Sockets.No_Socket then
            GNAT.Sockets.Close_Socket (Reader);
         end if;
         if Writer /= GNAT.Sockets.No_Socket then
            GNAT.Sockets.Close_Socket (Writer);
         end if;
         Files.Close (File);
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
         raise;
   end Test_Cross_Domain_Cancellation;

   procedure Test_File_Task_Abort is
      Path : constant String := "/tmp/gnatevl-abort-file.data";
      File : Files.File_Descriptor := Files.Invalid_File;

      task type Writer is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Writer;

      task body Writer is
         Data : constant Ada.Streams.Stream_Element_Array := [1 => 9];
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Files.Write_At (File, 0, Data, Last);
      end Writer;

      type Writer_Access is access Writer;
      procedure Free is new Ada.Unchecked_Deallocation
        (Writer, Writer_Access);
      Item : Writer_Access;
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      File := Files.Open
        (Path, Mode => Files.Read_Write, Create => True, Truncate => True);
      Fault_Control.Reset;
      Fault_Control.Arm
        (Fault_Control.File_Submission_Full, Count => 100_000);
      Item := new Writer;
      declare
         Limit : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      begin
         while Fault_Control.Calls (Fault_Control.File_Submission_Full) = 0
         loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "aborted file task never entered pending queue";
            end if;
            delay 0.001;
         end loop;
         abort Item.all;
         while not Item.all'Terminated loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "aborted file task retained its caller buffer";
            end if;
            delay 0.001;
         end loop;
      end;
      Free (Item);

      Fault_Control.Reset;
      Files.Close (File);
      File := Files.Open
        (Path, Mode => Files.Read_Write, Create => False, Truncate => False);
      declare
         Data : constant Ada.Streams.Stream_Element_Array := [1 => 10];
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Files.Write_At (File, 0, Data, Last);
         if Last /= Data'Last then
            raise Program_Error with
              "descriptor/request reuse failed after task abort";
         end if;
      end;
      Files.Close (File);
      Ada.Directories.Delete_File (Path);
   exception
      when others =>
         Fault_Control.Reset;
         Files.Close (File);
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
         raise;
   end Test_File_Task_Abort;

   procedure Test_File_Cancel_Fallback
     (Disposition : Fault_Control.Point)
   is
      Path : constant String := "/tmp/gnatevl-cancel-fallback.data";
      File : Files.File_Descriptor := Files.Invalid_File;

      task type Writer is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
      end Writer;

      task body Writer is
         Data : constant Ada.Streams.Stream_Element_Array
           (1 .. 64 * 1_024) := (others => 12);
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Files.Write_At (File, 0, Data, Last);
      end Writer;

      type Writer_Access is access Writer;
      procedure Free is new Ada.Unchecked_Deallocation
        (Writer, Writer_Access);
      Item : Writer_Access;
   begin
      if Disposition not in
        Fault_Control.File_Cancel_Not_Cancelable |
        Fault_Control.File_Cancel_Already_Completing
      then
         raise Program_Error with "invalid cancellation fallback fault";
      end if;
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      File := Files.Open
        (Path, Mode => Files.Read_Write, Create => True, Truncate => True);
      Fault_Control.Reset;
      --  Hold completion delivery, not kernel progress, so abort deterministically
      --  reaches the cancellation backend while the caller buffer is owned.
      Fault_Control.Arm (Fault_Control.Poller_EINTR, Count => 100_000);
      Fault_Control.Arm (Disposition);
      Item := new Writer;
      declare
         Limit : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      begin
         while Fault_Control.Calls (Fault_Control.File_Submission_Full) = 0
         loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "fallback test did not submit a kernel file request";
            end if;
            delay 0.001;
         end loop;
         abort Item.all;
         if Fault_Control.Calls (Disposition) /= 1 then
            raise Program_Error with
              "requested cancellation disposition was not exercised";
         end if;
         --  Whether cancellation is unsupported or completion has already
         --  started, buffer ownership persists until the ordinary event.
         Fault_Control.Reset;
         while not Item.all'Terminated loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "fallback cancellation resumed before terminal completion";
            end if;
            delay 0.001;
         end loop;
      end;
      Free (Item);
      Files.Close (File);
      Ada.Directories.Delete_File (Path);
   exception
      when others =>
         Fault_Control.Reset;
         Files.Close (File);
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
         raise;
   end Test_File_Cancel_Fallback;

   procedure Trigger_Fatal (At_Point : Fault_Control.Point) is
      Item : Probe_Access;
   begin
      if At_Point = Fault_Control.Poller_Wait then
         Warm_Group;
      end if;
      Fault_Control.Reset;
      Fault_Control.Arm (At_Point);
      Item := new Probe (Gnatevl.Event_Loop_Task);
      Await (Item);
      Free_Probe (Item);
      raise Program_Error with "fatal fault unexpectedly returned";
   end Trigger_Fatal;

begin
   if not Fault_Control.Enabled then
      raise Program_Error with
        "fault test requires GNATEVL_TEST_FAULTS=1 runtime";
   end if;

   if Case_Name = "fiber-allocation" then
      Warm_Group;
      Expect_Activation_Failure (Fault_Control.Fiber_Allocation);
   elsif Case_Name = "stack-map" then
      Warm_Group;
      Expect_Activation_Failure (Fault_Control.Stack_Mapping);
   elsif Case_Name = "group-startup" then
      Expect_Activation_Failure (Fault_Control.Group_Startup);
   elsif Case_Name = "watch-error" then
      Test_Watch_Error;
      Test_Multi_Watch_Rollback;
   elsif Case_Name = "eintr" then
      Test_EINTR;
   elsif Case_Name = "file-saturation" then
      Test_File_Saturation;
   elsif Case_Name = "file-cancellation" then
      Test_Cross_Domain_Cancellation;
   elsif Case_Name = "file-abort" then
      Test_File_Task_Abort;
   elsif Case_Name = "file-cancel-fallback" then
      Test_File_Cancel_Fallback
        (Fault_Control.File_Cancel_Not_Cancelable);
      Test_File_Cancel_Fallback
        (Fault_Control.File_Cancel_Already_Completing);
   elsif Case_Name = "fatal-wake" then
      Trigger_Fatal (Fault_Control.Poller_Wake);
   elsif Case_Name = "fatal-wait" then
      Trigger_Fatal (Fault_Control.Poller_Wait);
   else
      raise Program_Error with "unknown fault case: " & Case_Name;
   end if;

   Ada.Text_IO.Put_Line ("fault case passed: " & Case_Name);
end Fault_Injection_Smoke;
