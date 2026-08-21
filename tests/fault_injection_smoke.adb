with Ada.Command_Line;
with Ada.Directories;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Fault_Control;
with Flyology.IO.Sockets;
with Flyology;
with Flyology.Dormancy;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Files;
with Flyology.Observability;
with Flyology.Operations;
with Interfaces;
with Interfaces.C;

procedure Fault_Injection_Smoke is
   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;
   use type Fault_Control.File_Cancel_Backend;
   use type Fault_Control.Point;
   use type Interfaces.Unsigned_64;
   use type Interfaces.C.int;
   use type Flyology.Operations.Terminal_Outcome;

   package Dormancy renames Flyology.Dormancy;
   package IO renames Flyology.IO;
   package Connections renames Flyology.IO.Connections;
   package Files renames Flyology.IO.Files;
   package Observation renames Flyology.Observability;
   package Operations renames Flyology.Operations;

   function Selected_Linux_Backend return Interfaces.C.int;
   pragma Import
     (C, Selected_Linux_Backend, "flyology_linux_file_backend");

   function Open_FD_Count return Interfaces.C.int;
   pragma Import (C, Open_FD_Count, "flyology_test_open_fd_count");

   Case_Name : constant String :=
     (if Ada.Command_Line.Argument_Count = 0
      then ""
      else Ada.Command_Line.Argument (1));

   task type Probe (Kind : Flyology.Execution_Model) is
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
      Item : Probe_Access := new Probe (Flyology.Lightweight_Task);
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
         Item := new Probe (Flyology.Lightweight_Task);
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

   procedure Expect_Discard_Failure_Recovery is
   begin
      Fault_Control.Reset;
      Fault_Control.Arm (Fault_Control.Stack_Discard);
      Warm_Group;
      if Fault_Control.Calls (Fault_Control.Stack_Discard) = 0 then
         raise Program_Error with "stack discard fault was not reached";
      end if;
      Fault_Control.Reset;
      --  A second allocation/reap proves the ignored advice failure did not
      --  strand the stack-pool mutex or retain the empty arena.
      Warm_Group;
   end Expect_Discard_Failure_Recovery;

   procedure Test_Watch_Error is
      Reader : Flyology.IO.Sockets.Socket_Type;
      Writer : Flyology.IO.Sockets.Socket_Type;
      Failed_As_Device_Error : Boolean := False with Atomic;

      task type Waiter is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Waiter;

      task body Waiter is
      begin
         begin
            if IO.Wait
              (Flyology.IO.Sockets.Native_Descriptor (Reader),
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
      Flyology.IO.Sockets.Create_Socket_Pair (Reader, Writer);
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
      Flyology.IO.Sockets.Close_Socket (Reader);
      Flyology.IO.Sockets.Close_Socket (Writer);
      if not Failed_As_Device_Error then
         raise Program_Error with "watch failure did not become Device_Error";
      end if;
      Fault_Control.Reset;
      Warm_Group;
   exception
      when others =>
         if Flyology.IO.Sockets.Is_Open (Reader) then
            Flyology.IO.Sockets.Close_Socket (Reader);
         end if;
         if Flyology.IO.Sockets.Is_Open (Writer) then
            Flyology.IO.Sockets.Close_Socket (Writer);
         end if;
         raise;
   end Test_Watch_Error;

   procedure Test_Multi_Watch_Rollback is
      type Socket_Array is array
        (Positive range <>) of Flyology.IO.Sockets.Socket_Type;
      Readers : Socket_Array (1 .. 4);
      Writers : Socket_Array (Readers'Range);
      Failed : Boolean := False with Atomic;
      Retry_Ready : Boolean := False with Atomic;
      Reused_FD : IO.Descriptor;

      task type Failed_Waiter is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Failed_Waiter;
      task body Failed_Waiter is
         Outcome : IO.Wait_Outcome;
         pragma Unreferenced (Outcome);
      begin
         begin
            Outcome := IO.Wait_Interruptibly
              (Flyology.IO.Sockets.Native_Descriptor (Readers (1)),
               IO.For_Read,
               0.1,
               (1 => Flyology.IO.Sockets.Native_Descriptor (Readers (2)),
                2 => Flyology.IO.Sockets.Native_Descriptor (Readers (3)),
                3 => Flyology.IO.Sockets.Native_Descriptor (Readers (4))));
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
         Flyology.IO.Sockets.Create_Socket_Pair
           (Readers (Index), Writers (Index));
      end loop;
      Reused_FD := Flyology.IO.Sockets.Native_Descriptor (Readers (1));
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
         Flyology.IO.Sockets.Close_Socket (Readers (Index));
         Flyology.IO.Sockets.Close_Socket (Writers (Index));
      end loop;

      Fault_Control.Reset;
      Flyology.IO.Sockets.Create_Socket_Pair (Readers (1), Writers (1));
      if Flyology.IO.Sockets.Native_Descriptor (Readers (1)) /= Reused_FD then
         raise Program_Error with "descriptor reuse precondition failed";
      end if;
      declare
         Data : constant Ada.Streams.Stream_Element_Array (1 .. 1) :=
           (1 => 1);
         Last : Ada.Streams.Stream_Element_Offset;
         task Retry is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Retry;
         task body Retry is
         begin
            Retry_Ready := IO.Wait
              (Reused_FD, IO.For_Read, Timeout => 0.1);
         end Retry;
      begin
         Flyology.IO.Sockets.Send_Socket (Writers (1), Data, Last);
      end;
      if not Retry_Ready then
         raise Program_Error with "rolled-back descriptor poisoned reuse";
      end if;
      Flyology.IO.Sockets.Close_Socket (Readers (1));
      Flyology.IO.Sockets.Close_Socket (Writers (1));
   end Test_Multi_Watch_Rollback;

   procedure Test_EINTR is
      Item : Probe_Access;
   begin
      Warm_Group;
      Fault_Control.Reset;
      Fault_Control.Arm (Fault_Control.Poller_EINTR, Count => 32);
      Item := new Probe (Flyology.Lightweight_Task);
      Await (Item);
      Free_Probe (Item);
      if Fault_Control.Calls (Fault_Control.Poller_EINTR) < 32 then
         raise Program_Error with "synthetic EINTR path was not exercised";
      end if;
      Fault_Control.Reset;
   end Test_EINTR;

   procedure Test_File_Saturation is
      Path : constant String := "/tmp/flyology-fault-file.data";
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
         pragma Task_Info (Flyology.Lightweight_Task);
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

   procedure Test_Scoped_File_Saturation is
      Path : constant String := "/tmp/flyology-scoped-file-saturation.data";
      File : Files.File_Descriptor := Files.Invalid_File;
      Passed : Boolean := False with Atomic;

      task type Writer is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Writer;

      task body Writer is
         Data : aliased Ada.Streams.Stream_Element_Array :=
           [1 => 1, 2 => 2, 3 => 3, 4 => 4];
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         --  A transiently full submission queue must retain the operation and
         --  eventually publish its ordinary completion.
         declare
            Set : aliased Operations.Completion_Set (1);
            Write : Files.Write_Operation :=
              Files.Write_At (Set'Access, File, 0, Data'Access, 1.0);
            Batch : Operations.Completion_Batch (Set.Capacity);
         begin
            Operations.Wait_For_Success (Set, Batch);
            Files.Finish (Write, Last);
            Passed := Last = Data'Last;
         end;

         --  Cancellation of a queued write must terminalize the operation
         --  before its borrowed source buffer can leave scope.
         Fault_Control.Reset;
         Fault_Control.Arm
           (Fault_Control.File_Submission_Full, Count => 1_000_000);
         declare
            Set : aliased Operations.Completion_Set (1);
            Write : Files.Write_Operation :=
              Files.Write_At (Set'Access, File, 4, Data'Access, 1.0);
            Cancelled : Boolean := False;
         begin
            Operations.Cancel (Write);
            Operations.Wait_All (Set);
            begin
               Files.Finish (Write, Last);
            exception
               when Operations.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Passed := Passed and then Cancelled;
         end;

         --  Reads use the same queued-node cancellation path, but retain a
         --  writable borrow and distinct Finish result.
         Fault_Control.Reset;
         Fault_Control.Arm
           (Fault_Control.File_Submission_Full, Count => 1_000_000);
         declare
            Set : aliased Operations.Completion_Set (1);
            Input : aliased Ada.Streams.Stream_Element_Array :=
              [1 .. 4 => 0];
            Read : Files.Read_Operation :=
              Files.Read_At (Set'Access, File, 0, Input'Access, 1.0);
            Cancelled : Boolean := False;
         begin
            Operations.Cancel (Read);
            Operations.Wait_All (Set);
            begin
               Files.Finish (Read, Last);
            exception
               when Operations.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Passed := Passed and then Cancelled;
         end;

         --  A deadline on a definitely queued request must be retained as a
         --  provider failure and reported only by Finish.
         Fault_Control.Reset;
         Fault_Control.Arm
           (Fault_Control.File_Submission_Full, Count => 1_000_000);
         declare
            Set : aliased Operations.Completion_Set (1);
            Write : Files.Write_Operation :=
              Files.Write_At (Set'Access, File, 4, Data'Access, 0.01);
            Timed_Out : Boolean := False;
         begin
            Operations.Wait_All (Set);
            Passed := Passed
              and then Operations.Outcome (Write) = Operations.Failed;
            begin
               Files.Finish (Write, Last);
            exception
               when IO.Timeout_Error =>
                  Timed_Out := True;
            end;
            Passed := Passed and then Timed_Out;
         end;

         --  Leaving a queued operation's inner scope exercises controlled
         --  cancel-and-drain. Reusing the capacity-one set proves that the
         --  abandoned operation released its slot and runtime node.
         Fault_Control.Reset;
         Fault_Control.Arm
           (Fault_Control.File_Submission_Full, Count => 1_000_000);
         declare
            Set : aliased Operations.Completion_Set (1);
            Input : aliased Ada.Streams.Stream_Element_Array :=
              [1 .. 4 => 0];
         begin
            declare
               Abandoned : Files.Read_Operation :=
                 Files.Read_At (Set'Access, File, 0, Input'Access, 1.0);
               pragma Unreferenced (Abandoned);
            begin
               null;
            end;
            Fault_Control.Reset;
            declare
               Replacement : Files.Read_Operation :=
                 Files.Read_At (Set'Access, File, 0, Input'Access, 1.0);
            begin
               Operations.Wait_All (Set);
               Files.Finish (Replacement, Last);
               Passed := Passed
                 and then Last = Input'Last
                 and then Input = Data;
            end;
         end;

         --  Invalid initiation is a deterministic submission failure. The
         --  set wait reports terminal state; the provider exception remains
         --  retained until Finish.
         declare
            Set : aliased Operations.Completion_Set (1);
            Failed_Write : Files.Write_Operation :=
              Files.Write_At
                (Set'Access, Files.Invalid_File, 0, Data'Access, 1.0);
            Failed : Boolean := False;
         begin
            Operations.Wait_All (Set);
            Passed := Passed
              and then Operations.Outcome (Failed_Write) = Operations.Failed;
            begin
               Files.Finish (Failed_Write, Last);
            exception
               when IO.Device_Error =>
                  Failed := True;
            end;
            Passed := Passed and then Failed;
         end;

         --  EOF and a short positional read are successful terminal results,
         --  with Last retaining the synchronous overload's arithmetic.
         declare
            Set : aliased Operations.Completion_Set (2);
            Short_Data : aliased Ada.Streams.Stream_Element_Array :=
              [3 .. 8 => 0];
            EOF_Data : aliased Ada.Streams.Stream_Element_Array :=
              [5 .. 8 => 0];
            Short_Read : Files.Read_Operation :=
              Files.Read_At (Set'Access, File, 2, Short_Data'Access, 1.0);
            EOF_Read : Files.Read_Operation :=
              Files.Read_At (Set'Access, File, 100, EOF_Data'Access, 1.0);
            Short_Last, EOF_Last : Ada.Streams.Stream_Element_Offset;
         begin
            Operations.Wait_All (Set);
            Files.Finish (Short_Read, Short_Last);
            Files.Finish (EOF_Read, EOF_Last);
            Passed := Passed
              and then Short_Last = Short_Data'First + 1
              and then Short_Data (3 .. 4) = Data (3 .. 4)
              and then EOF_Last = EOF_Data'First - 1;
         end;

         --  Repeated full-capacity batches exercise one shared completion
         --  source with the maximum number of file operation slots. This
         --  catches stale wake counts surviving a completed batch and reuse.
         declare
            Capacity : constant Positive := 32;
            Set : aliased Operations.Completion_Set (Capacity);
            subtype Scoped_Write is Files.Write_Operation (Set'Access);
            type Write_Array is array (Positive range <>) of Scoped_Write;
            Writes : Write_Array (1 .. Capacity);
            One_Byte : aliased Ada.Streams.Stream_Element_Array := [1 => 0];
         begin
            for Round in 1 .. 16 loop
               One_Byte (1) :=
                 Ada.Streams.Stream_Element (Round mod 251);
               for Index in Writes'Range loop
                  Files.Write_At
                    (File,
                     Files.File_Offset (128 + Index - 1),
                     One_Byte'Access,
                     1.0,
                     Writes (Index));
               end loop;
               Operations.Wait_All (Set);
               for Index in Writes'Range loop
                  Files.Finish (Writes (Index), Last);
                  Passed := Passed and then Last = One_Byte'Last;
               end loop;
            end loop;
         end;
      exception
         when others =>
            Passed := False;
      end Writer;
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      File := Files.Open
        (Path, Mode => Files.Read_Write, Create => True, Truncate => True);
      Fault_Control.Reset;
      Fault_Control.Arm
        (Fault_Control.File_Submission_Full, Count => 8);
      declare
         Item : Writer;
         pragma Unreferenced (Item);
      begin
         null;
      end;
      if not Passed then
         raise Program_Error with
           "scoped file operation did not survive submission pressure";
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
   end Test_Scoped_File_Saturation;

   procedure Test_File_Dormancy_Exclusion is
      Path : constant String := "/tmp/flyology-file-dormancy.data";
      File : Files.File_Descriptor := Files.Invalid_File;
      Finished : Boolean := False with Atomic;
      Passed   : Boolean := False with Atomic;
      Observed : Boolean := False;
      Sample   : Observation.Group_Snapshot;

      task type Writer with CPU => 1 is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Writer;

      task body Writer is
         Data : constant Ada.Streams.Stream_Element_Array := [1 => 17];
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Dormancy.Set_Policy
           (Dormancy.Reclaimable, Minimum_Wait => 0.0);
         Files.Write_At (File, 0, Data, Last);
         Passed := Last = Data'Last;
         Finished := True;
      exception
         when others =>
            Finished := True;
      end Writer;

      type Writer_Access is access Writer;
      procedure Free_Writer is new Ada.Unchecked_Deallocation
        (Writer, Writer_Access);
      Item : Writer_Access := null;

      procedure Await_Item is
         Limit : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      begin
         while Item /= null and then not Item.all'Terminated loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with "file wait did not resume";
            end if;
            delay 0.001;
         end loop;
      end Await_Item;
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      File := Files.Open
        (Path, Mode => Files.Read_Write, Create => True, Truncate => True);
      Fault_Control.Reset;
      Fault_Control.Arm
        (Fault_Control.File_Submission_Full, Count => 1_000_000_000);
      Item := new Writer;

      for Attempt in 1 .. 2_000 loop
         Observed :=
           Fault_Control.Calls (Fault_Control.File_Submission_Full) > 0
           and then Observation.Snapshot (1, Sample)
           and then Sample.File_Waits = 1
           and then Sample.Pending_File_Submissions = 1;
         exit when Observed;
         delay 0.001;
      end loop;
      if not Observed then
         raise Program_Error with "pending file wait was not observed";
      elsif Sample.Dormancy_Candidates /= 0
        or else Sample.Cold_Stacks /= 0
        or else Sample.Cold_Advice_Attempts /= 0
      then
         raise Program_Error with
           "file wait was treated as a dormancy candidate";
      end if;

      Fault_Control.Reset;
      Await_Item;
      if not Finished or else not Passed then
         raise Program_Error with "resumed file operation failed";
      end if;
      Free_Writer (Item);
      Files.Close (File);
      Ada.Directories.Delete_File (Path);
   exception
      when others =>
         Fault_Control.Reset;
         Await_Item;
         if Item /= null then
            Free_Writer (Item);
         end if;
         Files.Close (File);
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
         raise;
   end Test_File_Dormancy_Exclusion;

   procedure Test_Uring_CQ_Backpressure is
      Path : constant String := "/tmp/flyology-uring-capacity.data";
      File : Files.File_Descriptor := Files.Invalid_File;
   begin
      Warm_Group;
      if Selected_Linux_Backend /= 1 then
         Ada.Text_IO.Put_Line
           ("io_uring CQ test skipped: backend is not io_uring");
         return;
      end if;

      declare
         Capacity : constant Natural := Fault_Control.Uring_CQ_Capacity;
         Writer_Count : constant Positive := Positive (Capacity + 64);

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

            entry Wait when Finished = Writer_Count is
            begin
               null;
            end Wait;

            function Passed return Boolean is (All_OK);
         end Progress;

         task type Writer (Index : Positive) is
            pragma Task_Info (Flyology.Lightweight_Task);
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
         type Writer_Array is array (Positive range <>) of Writer_Access;
         procedure Free_Writer is new Ada.Unchecked_Deallocation
           (Writer, Writer_Access);
         Writers : Writer_Array (1 .. Writer_Count);
         Data : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Writer_Count));
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         if Capacity = 0 then
            raise Program_Error with "io_uring reported zero CQ capacity";
         end if;
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
         File := Files.Open
           (Path, Mode => Files.Read_Write, Create => True, Truncate => True);
         Fault_Control.Reset;
         Fault_Control.Arm
           (Fault_Control.File_Uring_Drain_Pause, Count => 1_000_000);
         Fault_Control.Arm (Fault_Control.File_Uring_Submit_EBUSY);
         Fault_Control.Arm
           (Fault_Control.File_Uring_Overflow_Flush, Count => 2);
         Fault_Control.Arm (Fault_Control.File_Uring_Flush_EBUSY);

         for Index in Writers'Range loop
            Writers (Index) := new Writer (Index);
         end loop;
         Progress.Wait;
         if not Progress.Passed then
            raise Program_Error with
              "io_uring capacity queue lost a file completion";
         elsif Fault_Control.Calls (Fault_Control.File_Uring_Backpressure) = 0
         then
            raise Program_Error with
              "more-than-CQ-capacity load did not reach backpressure";
         elsif Fault_Control.Calls (Fault_Control.File_Uring_Submit_EBUSY) = 0
         then
            raise Program_Error with "io_uring EBUSY retry was not exercised";
         elsif Fault_Control.Calls (Fault_Control.File_Uring_Overflow_Flush) < 2
         then
            raise Program_Error with
              "io_uring overflow GETEVENTS flush was not exercised";
         elsif Fault_Control.Calls (Fault_Control.File_Uring_Flush_EBUSY) = 0
         then
            raise Program_Error with
              "io_uring overflow EBUSY retry was not exercised";
         end if;

         Files.Read_At (File, 0, Data, Last);
         if Last /= Data'Last then
            raise Program_Error with "io_uring capacity result was short";
         end if;
         for Index in Writers'Range loop
            if Data (Ada.Streams.Stream_Element_Offset (Index)) /=
              Ada.Streams.Stream_Element (Index mod 251)
            then
               raise Program_Error with
                 "io_uring capacity result was corrupted";
            end if;
         end loop;
         for Item of Writers loop
            while not Item.all'Terminated loop
               delay 0.001;
            end loop;
            Free_Writer (Item);
         end loop;
         Fault_Control.Reset;
         Files.Close (File);
         Ada.Directories.Delete_File (Path);
      end;
   exception
      when others =>
         Fault_Control.Reset;
         Files.Close (File);
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
         raise;
   end Test_Uring_CQ_Backpressure;

   procedure Test_Uring_Initialization_Fallback
     (At_Point : Fault_Control.Point)
   is
      Path : constant String :=
        "/tmp/flyology-uring-initialization-fallback.data";
      File : Files.File_Descriptor := Files.Invalid_File;
      Before_FDs : Interfaces.C.int;
      After_FDs  : Interfaces.C.int;
      Wrote      : Boolean := False with Atomic;
   begin
      if At_Point not in
        Fault_Control.File_Uring_Probe_Unsupported |
        Fault_Control.File_Uring_Post_Setup_Failure
      then
         raise Program_Error with "invalid io_uring initialization fault";
      end if;
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      File := Files.Open
        (Path, Mode => Files.Read_Write, Create => True, Truncate => True);
      Fault_Control.Reset;
      Fault_Control.Arm (At_Point);
      Before_FDs := Open_FD_Count;

      declare
         task Writer is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Writer;

         task body Writer is
            Data : constant Ada.Streams.Stream_Element_Array := [1 => 73];
            Last : Ada.Streams.Stream_Element_Offset;
         begin
            Files.Write_At (File, 0, Data, Last);
            Wrote := Last = Data'Last;
         end Writer;
      begin
         null;
      end;

      --  Darwin has no Linux backend marker and does not reach either Linux
      --  fault point.  Linux must reach the requested post-setup boundary,
      --  transfer to native AIO, and retain only epoll plus its wake eventfd.
      if Selected_Linux_Backend = 0 then
         Fault_Control.Reset;
         Files.Close (File);
         Ada.Directories.Delete_File (Path);
         Ada.Text_IO.Put_Line
           ("io_uring initialization fallback skipped on non-Linux host");
         return;
      elsif Fault_Control.Calls (At_Point) = 0 then
         raise Program_Error with
           "io_uring initialization fault was not reached";
      elsif Selected_Linux_Backend /= 2 then
         raise Program_Error with
           "io_uring initialization did not fall back to native AIO";
      elsif not Wrote then
         raise Program_Error with
           "native-AIO fallback did not complete file I/O";
      end if;

      After_FDs := Open_FD_Count;
      if After_FDs /= Before_FDs + 2 then
         raise Program_Error with
           "io_uring fallback retained a ring descriptor";
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
   end Test_Uring_Initialization_Fallback;

   procedure Test_Cross_Domain_Cancellation is
      Path : constant String := "/tmp/flyology-cancel-file.data";
      File : Files.File_Descriptor := Files.Invalid_File;
      Reader : Flyology.IO.Sockets.Socket_Type;
      Writer : Flyology.IO.Sockets.Socket_Type;
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
         pragma Task_Info (Flyology.Lightweight_Task);
      end File_Waiter;

      task body File_Waiter is
         Data : constant Ada.Streams.Stream_Element_Array := [1 => 42];
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Files.Write_At (File, 0, Data, Last, Token'Access);
         Progress.Done (False);
      exception
         --  The connection-qualified compatibility name must catch the
         --  canonical exception raised from the file package.
         when Connections.Operation_Cancelled =>
            Progress.Done (True);
         when others =>
            Progress.Done (False);
      end File_Waiter;

      task type Connection_Waiter is
         pragma Task_Info (Flyology.Lightweight_Task);
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
         --  The file-qualified compatibility name must catch cancellation
         --  raised from the connection package.
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
      Flyology.IO.Sockets.Create_Socket_Pair (Reader, Writer);
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

      --  The same one-shot token also cancels both package surfaces before a
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
      if Flyology.IO.Sockets.Is_Open (Writer) then
         Flyology.IO.Sockets.Close_Socket (Writer);
      end if;
      Files.Close (File);
      Ada.Directories.Delete_File (Path);
   exception
      when others =>
         Fault_Control.Reset;
         Connections.Close (Connection);
         if Flyology.IO.Sockets.Is_Open (Reader) then
            Flyology.IO.Sockets.Close_Socket (Reader);
         end if;
         if Flyology.IO.Sockets.Is_Open (Writer) then
            Flyology.IO.Sockets.Close_Socket (Writer);
         end if;
         Files.Close (File);
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
         raise;
   end Test_Cross_Domain_Cancellation;

   procedure Test_File_Task_Abort is
      Path : constant String := "/tmp/flyology-abort-file.data";
      File : Files.File_Descriptor := Files.Invalid_File;

      task type Writer is
         pragma Task_Info (Flyology.Lightweight_Task);
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

   procedure Test_File_Pre_Park_Abort is
      Path : constant String := "/tmp/flyology-pre-park-abort.data";
      File : Files.File_Descriptor := Files.Invalid_File;

      task type Writer is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Writer;

      task body Writer is
         Data : constant Ada.Streams.Stream_Element_Array := [1 => 11];
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Files.Write_At (File, 0, Data, Last);
      end Writer;

      type Writer_Access is access Writer;
      procedure Free_Writer is new Ada.Unchecked_Deallocation
        (Writer, Writer_Access);

      task type Aborter (Target : not null Writer_Access);

      task body Aborter is
      begin
         abort Target.all;
      end Aborter;

      type Aborter_Access is access Aborter;
      procedure Free_Aborter is new Ada.Unchecked_Deallocation
        (Aborter, Aborter_Access);

      Item   : Writer_Access;
      Killer : Aborter_Access;
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      File := Files.Open
        (Path, Mode => Files.Read_Write, Create => True, Truncate => True);
      Fault_Control.Reset;
      Fault_Control.Arm
        (Fault_Control.File_Pre_Park, Count => 1_000_000_000);
      Item := new Writer;
      declare
         Limit : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      begin
         while Fault_Control.Calls (Fault_Control.File_Pre_Park) = 0 loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "file operation did not reach the pre-park gate";
            end if;
            delay 0.001;
         end loop;

         --  Aborter blocks on the task lock held across the pending-ATC check.
         --  Releasing the gate forces the scheduler to publish Waiting before
         --  that lock becomes available, so Wake cannot be lost while Running.
         Killer := new Aborter (Item);
         delay 0.010;
         Fault_Control.Reset;
         while not Item.all'Terminated or else not Killer.all'Terminated loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "pre-park abort was lost before file suspension";
            end if;
            delay 0.001;
         end loop;
      end;
      Free_Aborter (Killer);
      Free_Writer (Item);
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
   end Test_File_Pre_Park_Abort;

   procedure Test_File_Backend_Cancel is
      Path : constant String := "/tmp/flyology-backend-cancel.data";
      File : Files.File_Descriptor := Files.Invalid_File;
      Backend : Fault_Control.File_Cancel_Backend := Fault_Control.Darwin_AIO;

      task type Writer is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Writer;

      task body Writer is
         type Data_Access is access Ada.Streams.Stream_Element_Array;
         Data : constant Data_Access :=
           new Ada.Streams.Stream_Element_Array'(1 .. 1_048_576 => 19);
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Files.Write_At (File, 0, Data.all, Last);
      end Writer;

      type Writer_Access is access Writer;
      procedure Free is new Ada.Unchecked_Deallocation
        (Writer, Writer_Access);
      Item : Writer_Access;

      function Total return Natural is
        (Fault_Control.File_Cancel_Count
           (Backend, Fault_Control.Submitted, False)
         + Fault_Control.File_Cancel_Count
             (Backend, Fault_Control.Submitted, True)
         + Fault_Control.File_Cancel_Count
             (Backend, Fault_Control.Already_Completing, False)
         + Fault_Control.File_Cancel_Count
             (Backend, Fault_Control.Not_Cancelable, False)
         + Fault_Control.File_Cancel_Count
             (Backend, Fault_Control.Failed, False));
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      File := Files.Open
        (Path, Mode => Files.Read_Write, Create => True, Truncate => True);
      Fault_Control.Reset;
      Fault_Control.Arm
        (Fault_Control.Poller_EINTR, Count => 1_000_000_000);
      Item := new Writer;
      case Selected_Linux_Backend is
         when 0 =>
            Backend := Fault_Control.Darwin_AIO;
         when 1 =>
            Backend := Fault_Control.Linux_IO_Uring;
         when 2 =>
            Backend := Fault_Control.Linux_Native_AIO;
         when others =>
            raise Program_Error with "unknown file cancellation backend";
      end case;
      declare
         Limit : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
      begin
         while Fault_Control.Calls (Fault_Control.File_Submission_Full) = 0
         loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "backend cancellation test did not submit file I/O";
            end if;
            delay 0.001;
         end loop;
         abort Item.all;
         while Total = 0 loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "owning loop did not invoke the file cancel backend";
            end if;
            delay 0.001;
         end loop;
         Fault_Control.Disarm (Fault_Control.Poller_EINTR);
         while not Item.all'Terminated loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "backend cancellation retained the file buffer";
            end if;
            delay 0.001;
         end loop;
      end;

      --  Darwin may report AIO_CANCELED, AIO_NOTCANCELED, or AIO_ALLDONE
      --  depending on whether the filesystem completed the request before
      --  the aborter ran. Total above proves that aio_cancel itself ran; the
      --  fallback tests exercise both nonterminal policy branches.
      if Backend = Fault_Control.Linux_IO_Uring
        and then
          Fault_Control.File_Cancel_Count
            (Backend, Fault_Control.Submitted, False) = 0
      then
         raise Program_Error with
           "io_uring asynchronous cancellation was not submitted";
      end if;

      --  Since Linux 3.11 io_cancel(2) reports EINVAL for iocbs that have no
      --  cancel handler, and positional read/write iocbs never have one. That
      --  is the platform's ordinary answer for this engine, so it must be
      --  classified as not-cancelable rather than as a cancellation transport
      --  failure. The armed Poller_EINTR keeps the operation in flight, so
      --  io_cancel is actually reached instead of the already-completing
      --  shortcut.
      if Backend = Fault_Control.Linux_Native_AIO then
         if Fault_Control.File_Cancel_Count
              (Backend, Fault_Control.Failed, False) /= 0
         then
            raise Program_Error with
              "native AIO cancellation reported a transport failure";
         end if;
         if Fault_Control.File_Cancel_Count
              (Backend, Fault_Control.Not_Cancelable, False) = 0
         then
            raise Program_Error with
              "native AIO cancellation never reported not-cancelable";
         end if;
      end if;

      Free (Item);
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
   end Test_File_Backend_Cancel;

   procedure Test_File_Cancel_Fallback
     (Disposition : Fault_Control.Point)
   is
      Path : constant String := "/tmp/flyology-cancel-fallback.data";
      File : Files.File_Descriptor := Files.Invalid_File;

      task type Writer is
         pragma Task_Info (Flyology.Lightweight_Task);
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
         while Fault_Control.Calls (Disposition) = 0 loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "owning loop did not exercise cancellation disposition";
            end if;
            delay 0.001;
         end loop;
         --  Whether cancellation is unsupported or completion has already
         --  started, buffer ownership persists until the ordinary event.
         Fault_Control.Disarm (Fault_Control.Poller_EINTR);
         while not Item.all'Terminated loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "fallback cancellation resumed before terminal completion";
            end if;
            delay 0.001;
         end loop;
         if Fault_Control.Calls (Disposition) /= 1 then
            raise Program_Error with
              "cancellation disposition was attempted more than once";
         end if;
      end;
      Free (Item);
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
   end Test_File_Cancel_Fallback;

   procedure Test_Uring_Request_Identity is
      Path  : constant String := "/tmp/flyology-uring-identity.data";
      File  : Files.File_Descriptor := Files.Invalid_File;
      Token : aliased Files.Cancellation_Token;
      Stage : Natural := 0 with Atomic;

      task type Writer is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Writer;

      task body Writer is
         type Data_Access is access Ada.Streams.Stream_Element_Array;
         First_Data : constant Data_Access :=
           new Ada.Streams.Stream_Element_Array'(1 .. 1_048_576 => 31);
         Second_Data : constant Ada.Streams.Stream_Element_Array :=
           [1 .. 4_096 => 47];
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         begin
            Files.Write_At (File, 0, First_Data.all, Last, Token'Access);
            Stage := 90;
         exception
            when Files.Operation_Cancelled =>
               Stage := 1;
         end;
         Files.Write_At (File, 1_048_576, Second_Data, Last);
         Stage := (if Last = Second_Data'Last then 2 else 91);
      exception
         when others =>
            Stage := 99;
      end Writer;

      type Writer_Access is access Writer;
      procedure Free is new Ada.Unchecked_Deallocation
        (Writer, Writer_Access);
      Item : Writer_Access;
   begin
      --  This ordering exists only on io_uring: defer submitting the cancel
      --  SQE, resume the fiber from operation one, and let that same fiber
      --  submit operation two while request one still owns its user_data.
      if Selected_Linux_Backend /= 1 then
         return;
      end if;
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      File := Files.Open
        (Path, Mode => Files.Read_Write, Create => True, Truncate => True);
      Fault_Control.Reset;
      Fault_Control.Arm
        (Fault_Control.Poller_EINTR, Count => 1_000_000_000);
      Fault_Control.Arm
        (Fault_Control.File_Cancel_Admin_Delay,
         Count => 1_000_000_000);
      Item := new Writer;
      declare
         Limit : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
      begin
         while Fault_Control.Calls (Fault_Control.File_Submission_Full) = 0
         loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with "io_uring operation was not submitted";
            end if;
            delay 0.001;
         end loop;
         Token.Request;
         while Fault_Control.File_Cancel_Count
           (Fault_Control.Linux_IO_Uring,
            Fault_Control.Submitted,
            False) = 0
         loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with "io_uring cancel was not submitted";
            end if;
            delay 0.001;
         end loop;
         Fault_Control.Disarm (Fault_Control.Poller_EINTR);
         while Fault_Control.Uring_Identity_Count (False) = 0 loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "io_uring follow-up did not overlap delayed cancellation";
            end if;
            delay 0.001;
         end loop;
         Fault_Control.Disarm (Fault_Control.File_Cancel_Admin_Delay);
         while not Item.all'Terminated loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "same-fiber io_uring follow-up did not terminate";
            end if;
            delay 0.001;
         end loop;
         while Fault_Control.Uring_Admin_Complete_Count = 0 loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "delayed io_uring cancellation did not become terminal";
            end if;
            delay 0.001;
         end loop;
      end;
      if Stage /= 2
        or else Fault_Control.Calls
          (Fault_Control.File_Cancel_Admin_Delay) = 0
        or else Fault_Control.Uring_Identity_Count (False) = 0
        or else Fault_Control.Uring_Identity_Count (True) /= 0
      then
         raise Program_Error with
           "io_uring reused an operation identity before cancel CQE terminality";
      end if;
      Free (Item);
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
   end Test_Uring_Request_Identity;

   procedure Test_Uring_Last_Fiber_Admin is
      Path  : constant String := "/tmp/flyology-uring-last-fiber.data";
      File  : Files.File_Descriptor := Files.Invalid_File;
      Token : aliased Files.Cancellation_Token;
      Stage : Natural := 0 with Atomic;

      task type Writer is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Writer;

      task body Writer is
         type Data_Access is access Ada.Streams.Stream_Element_Array;
         Data : constant Data_Access :=
           new Ada.Streams.Stream_Element_Array'(1 .. 1_048_576 => 61);
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         begin
            Files.Write_At (File, 0, Data.all, Last, Token'Access);
            Stage := 90;
         exception
            when Files.Operation_Cancelled =>
               Stage := 1;
         end;
      exception
         when others =>
            Stage := 99;
      end Writer;

      type Writer_Access is access Writer;
      procedure Free is new Ada.Unchecked_Deallocation
        (Writer, Writer_Access);
      Item : Writer_Access;
   begin
      Warm_Group;
      if Selected_Linux_Backend /= 1 then
         return;
      end if;
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      File := Files.Open
        (Path, Mode => Files.Read_Write, Create => True, Truncate => True);
      Fault_Control.Reset;
      Fault_Control.Arm
        (Fault_Control.Poller_File_Drain_Pause,
         Count => 1_000_000_000);
      --  The first hit defers Cancel; the second keeps it deferred while the
      --  data CQE resumes the only fiber. The idle loop must then submit and
      --  drain the administrative request before becoming quiescent.
      Fault_Control.Arm
        (Fault_Control.File_Cancel_Admin_Delay, Count => 2);
      Item := new Writer;
      declare
         Limit : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
      begin
         while Fault_Control.Calls (Fault_Control.File_Submission_Full) = 0
         loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with "io_uring operation was not submitted";
            end if;
            delay 0.001;
         end loop;
         Token.Request;
         while Fault_Control.File_Cancel_Count
           (Fault_Control.Linux_IO_Uring,
            Fault_Control.Submitted,
            False) = 0
         loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with "io_uring cancel was not deferred";
            end if;
            delay 0.001;
         end loop;
         Fault_Control.Disarm (Fault_Control.Poller_File_Drain_Pause);
         while not Item.all'Terminated loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with "last io_uring fiber did not terminate";
            end if;
            delay 0.001;
         end loop;
         while Fault_Control.Uring_Admin_Complete_Count = 0 loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "idle loop did not drain late io_uring cancellation";
            end if;
            delay 0.001;
         end loop;
      end;
      if Stage /= 1
        or else Fault_Control.Calls
          (Fault_Control.File_Cancel_Admin_Delay) < 3
      then
         raise Program_Error with
           "late io_uring cancellation did not cross last-fiber quiescence";
      end if;
      Free (Item);
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
   end Test_Uring_Last_Fiber_Admin;

   procedure Test_Darwin_Cancel_Cleanup (Delete_Fault : Fault_Control.Point) is
      Path : constant String := "/tmp/flyology-darwin-cancel-cleanup.data";
      File : Files.File_Descriptor := Files.Invalid_File;

      task type Writer is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Writer;

      task body Writer is
         type Data_Access is access Ada.Streams.Stream_Element_Array;
         Data : constant Data_Access :=
           new Ada.Streams.Stream_Element_Array'(1 .. 1_048_576 => 53);
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Files.Write_At (File, 0, Data.all, Last);
      end Writer;

      type Writer_Access is access Writer;
      procedure Free is new Ada.Unchecked_Deallocation
        (Writer, Writer_Access);
      Item : Writer_Access;
   begin
      if Selected_Linux_Backend /= 0 then
         return;
      elsif Delete_Fault not in
        Fault_Control.File_Cancel_Delete_EINTR |
        Fault_Control.File_Cancel_Delete_Failure
      then
         raise Program_Error with "invalid Darwin delete fault";
      end if;
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      File := Files.Open
        (Path, Mode => Files.Read_Write, Create => True, Truncate => True);
      Fault_Control.Reset;
      Fault_Control.Arm
        (Fault_Control.Poller_EINTR, Count => 1_000_000_000);
      Fault_Control.Arm (Fault_Control.File_Cancel_Synthetic);
      Fault_Control.Arm (Delete_Fault);
      Item := new Writer;
      declare
         Limit : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
      begin
         while Fault_Control.Calls (Fault_Control.File_Submission_Full) = 0
         loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with "Darwin AIO was not submitted";
            end if;
            delay 0.001;
         end loop;
         abort Item.all;
         while Fault_Control.Calls (Delete_Fault) = 0 loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "Darwin terminal cleanup fault was not exercised";
            end if;
            delay 0.001;
         end loop;
         Fault_Control.Disarm (Fault_Control.Poller_EINTR);
         while not Item.all'Terminated loop
            if Ada.Real_Time.Clock >= Limit then
               raise Program_Error with
                 "Darwin delete failure prevented terminal AIO reap";
            end if;
            delay 0.001;
         end loop;
         if Delete_Fault = Fault_Control.File_Cancel_Delete_Failure then
            while Fault_Control.Calls
              (Fault_Control.File_Cancel_Stale_Event) = 0
            loop
               if Ada.Real_Time.Clock >= Limit then
                  raise Program_Error with
                    "Darwin stale AIO event was not consumed";
               end if;
               delay 0.001;
            end loop;
         end if;
      end;
      Free (Item);
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
   end Test_Darwin_Cancel_Cleanup;

   procedure Trigger_Fatal (At_Point : Fault_Control.Point) is
      Item : Probe_Access;
   begin
      if At_Point = Fault_Control.Poller_Wait then
         Warm_Group;
      end if;
      Fault_Control.Reset;
      Fault_Control.Arm (At_Point);
      Item := new Probe (Flyology.Lightweight_Task);
      Await (Item);
      Free_Probe (Item);
      raise Program_Error with "fatal fault unexpectedly returned";
   end Trigger_Fatal;

   procedure Trigger_Stack_Release_Fatal is
      Item : Probe_Access := new Probe (Flyology.Lightweight_Task);
   begin
      Await (Item);
      Fault_Control.Reset;
      Fault_Control.Arm (Fault_Control.Stack_Protection);
      Free_Probe (Item);
      raise Program_Error with "stack release fault unexpectedly returned";
   end Trigger_Stack_Release_Fatal;

begin
   if not Fault_Control.Enabled then
      raise Program_Error with
        "fault test requires FLYOLOGY_TEST_FAULTS=1 runtime";
   end if;

   if Case_Name = "fiber-allocation" then
      Warm_Group;
      Expect_Activation_Failure (Fault_Control.Fiber_Allocation);
   elsif Case_Name = "stack-map" then
      Warm_Group;
      Expect_Activation_Failure (Fault_Control.Stack_Mapping);
   elsif Case_Name = "stack-protect" then
      Warm_Group;
      Expect_Activation_Failure (Fault_Control.Stack_Protection);
   elsif Case_Name = "stack-discard" then
      Warm_Group;
      Expect_Discard_Failure_Recovery;
   elsif Case_Name = "group-startup" then
      Expect_Activation_Failure (Fault_Control.Group_Startup);
   elsif Case_Name = "watch-error" then
      Test_Watch_Error;
      Test_Multi_Watch_Rollback;
   elsif Case_Name = "eintr" then
      Test_EINTR;
   elsif Case_Name = "file-saturation" then
      Test_File_Saturation;
   elsif Case_Name = "scoped-file-saturation" then
      Test_Scoped_File_Saturation;
   elsif Case_Name = "file-dormancy-exclusion" then
      Test_File_Dormancy_Exclusion;
   elsif Case_Name = "file-uring-cq-backpressure" then
      Test_Uring_CQ_Backpressure;
   elsif Case_Name = "file-uring-probe-fallback" then
      Test_Uring_Initialization_Fallback
        (Fault_Control.File_Uring_Probe_Unsupported);
   elsif Case_Name = "file-uring-post-setup-fallback" then
      Test_Uring_Initialization_Fallback
        (Fault_Control.File_Uring_Post_Setup_Failure);
   elsif Case_Name = "file-cancellation" then
      Test_Cross_Domain_Cancellation;
   elsif Case_Name = "file-abort" then
      Test_File_Task_Abort;
   elsif Case_Name = "file-pre-park-abort" then
      Test_File_Pre_Park_Abort;
   elsif Case_Name = "file-backend-cancel" then
      Test_File_Backend_Cancel;
   elsif Case_Name = "file-cancel-fallback" then
      Test_File_Cancel_Fallback
        (Fault_Control.File_Cancel_Not_Cancelable);
      Test_File_Cancel_Fallback
        (Fault_Control.File_Cancel_Already_Completing);
   elsif Case_Name = "file-uring-identity" then
      Test_Uring_Request_Identity;
   elsif Case_Name = "file-uring-last-fiber" then
      Test_Uring_Last_Fiber_Admin;
   elsif Case_Name = "file-darwin-cancel-cleanup" then
      Test_Darwin_Cancel_Cleanup
        (Fault_Control.File_Cancel_Delete_EINTR);
      Test_Darwin_Cancel_Cleanup
        (Fault_Control.File_Cancel_Delete_Failure);
   elsif Case_Name = "fatal-wake" then
      Trigger_Fatal (Fault_Control.Poller_Wake);
   elsif Case_Name = "fatal-wait" then
      Trigger_Fatal (Fault_Control.Poller_Wait);
   elsif Case_Name = "fatal-stack-release" then
      Trigger_Stack_Release_Fatal;
   else
      raise Program_Error with "unknown fault case: " & Case_Name;
   end if;

   Ada.Text_IO.Put_Line ("fault case passed: " & Case_Name);
end Fault_Injection_Smoke;
