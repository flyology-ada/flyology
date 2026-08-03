with Ada.Directories;
with Ada.Streams;
with Fault_Control;
with Flyology;
with GNAT.OS_Lib;
with GNAT.Sockets;
with Interfaces.C;
with System;
with System.Flyology.Poller;

procedure Linux_Poller_Fairness_Smoke is
   package Pollers renames System.Flyology.Poller;

   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_Element;
   use type GNAT.OS_Lib.File_Descriptor;
   use type GNAT.Sockets.Socket_Type;
   use type Interfaces.C.int;
   use type Pollers.Event_Kind;
   use type System.Address;

   function Selected_Linux_Backend return Interfaces.C.int;
   pragma Import
     (C, Selected_Linux_Backend, "flyology_linux_file_backend");

   Path : constant String := "/tmp/flyology-poller-fairness.data";
   Iterations : constant Positive := 128;

   Poller       : Pollers.Poller;
   Initialized  : Boolean := False;
   File         : GNAT.OS_Lib.File_Descriptor := GNAT.OS_Lib.Invalid_FD;
   Reader       : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
   Writer       : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
   Buffer       : aliased Ada.Streams.Stream_Element_Array (1 .. 1);
   Token        : aliased Interfaces.C.int := 0;
   Error_Code   : Interfaces.C.int;

   task Waker is
      pragma Task_Info (Flyology.Native_Task);
      entry Trigger (Succeeded : out Boolean);
      entry Stop;
   end Waker;

   task body Waker is
      Payload : constant Ada.Streams.Stream_Element_Array := [1 => 73];
      Last    : Ada.Streams.Stream_Element_Offset;
   begin
      loop
         select
            accept Trigger (Succeeded : out Boolean) do
               begin
                  GNAT.Sockets.Send_Socket (Writer, Payload, Last);
                  Succeeded :=
                    Last = Payload'Last and then Pollers.Wake (Poller);
               exception
                  when others =>
                     Succeeded := False;
               end;
            end Trigger;
         or
            accept Stop;
            exit;
         end select;
      end loop;
   end Waker;

   function Contains
     (Events     : Pollers.Poll_Event_Array;
      Count      : Natural;
      Kind       : Pollers.Event_Kind;
      Descriptor : Interfaces.C.int := -1) return Boolean
   is
   begin
      for Index in 1 .. Count loop
         if Events (Events'First + Index - 1).Kind = Kind
           and then
             (Descriptor < 0
              or else
                Events (Events'First + Index - 1).Descriptor = Descriptor)
         then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

   procedure Submit_One is
   begin
      Token := Token + 1;
      if not Pollers.Submit_File
        (Poller,
         Interfaces.C.int (File),
         Buffer'Address,
         Interfaces.C.size_t (Buffer'Length),
         0,
         False,
         Token'Address,
         Error_Code)
      then
         raise Program_Error with
           "file submission failed, errno=" & Error_Code'Image;
      end if;
   end Submit_One;

   procedure Hold_Completed_File
     (Events : out Pollers.Poll_Event_Array;
      Count  : out Natural)
   is
   begin
      Fault_Control.Arm
        (Fault_Control.Poller_File_Drain_Pause, Count => 1_000);
      Submit_One;
      if not Pollers.Wait_Batch (Poller, 2.0, Events, Count) then
         raise Program_Error with "poller failed while awaiting file eventfd";
      elsif not Contains (Events, Count, Pollers.Wake_Event) then
         raise Program_Error with "file completion did not signal eventfd";
      elsif Events'Length > 1
        and then Fault_Control.Calls
          (Fault_Control.Poller_File_Drain_Pause) = 0
      then
         raise Program_Error with "file completion drain was not held";
      end if;
      Fault_Control.Disarm (Fault_Control.Poller_File_Drain_Pause);
   exception
      when others =>
         Fault_Control.Disarm (Fault_Control.Poller_File_Drain_Pause);
         raise;
   end Hold_Completed_File;

   procedure Drain_For_Cleanup is
      Events : Pollers.Poll_Event_Array (1 .. 64);
      Count  : Natural;
   begin
      Fault_Control.Disarm (Fault_Control.Poller_File_Drain_Pause);
      for Attempt in 1 .. 500 loop
         exit when Pollers.File_Quiescent (Poller);
         if not Pollers.Wait_Batch (Poller, 0.01, Events, Count) then
            exit;
         end if;
      end loop;
   end Drain_For_Cleanup;

   procedure Remove_Test_File is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   end Remove_Test_File;

   procedure Cleanup is
      Status : Boolean;
      Quiescent : Boolean := not Initialized;
   begin
      Fault_Control.Disarm (Fault_Control.Poller_File_Drain_Pause);
      if Initialized then
         Drain_For_Cleanup;
         Quiescent := Pollers.File_Quiescent (Poller);
      end if;
      begin
         Waker.Stop;
      exception
         when Tasking_Error =>
            null;
      end;
      if Reader /= GNAT.Sockets.No_Socket then
         GNAT.Sockets.Close_Socket (Reader);
         Reader := GNAT.Sockets.No_Socket;
      end if;
      if Writer /= GNAT.Sockets.No_Socket then
         GNAT.Sockets.Close_Socket (Writer);
         Writer := GNAT.Sockets.No_Socket;
      end if;
      if File /= GNAT.OS_Lib.Invalid_FD then
         GNAT.OS_Lib.Close (File, Status);
         File := GNAT.OS_Lib.Invalid_FD;
      end if;
      if Initialized and then Quiescent then
         Pollers.Finalize (Poller);
         Initialized := False;
      end if;
      Remove_Test_File;
      Fault_Control.Reset;
      if not Quiescent then
         raise Program_Error with
           "poller fairness cleanup left kernel-owned file operations";
      end if;
   end Cleanup;

begin
   if not Fault_Control.Enabled then
      raise Program_Error with
        "poller fairness test requires FLYOLOGY_TEST_FAULTS=1";
   end if;

   Remove_Test_File;
   declare
      Seed : aliased Ada.Streams.Stream_Element_Array := [1 => 73];
      Written : Integer;
      Status  : Boolean;
   begin
      File := GNAT.OS_Lib.Create_File (Path, GNAT.OS_Lib.Binary);
      if File = GNAT.OS_Lib.Invalid_FD then
         raise Program_Error with "could not create poller fairness file";
      end if;
      Written := GNAT.OS_Lib.Write (File, Seed'Address, Seed'Length);
      GNAT.OS_Lib.Close (File, Status);
      File := GNAT.OS_Lib.Invalid_FD;
      if Written /= Seed'Length or else not Status then
         raise Program_Error with "could not seed poller fairness file";
      end if;
      File := GNAT.OS_Lib.Open_Read (Path, GNAT.OS_Lib.Binary);
      if File = GNAT.OS_Lib.Invalid_FD then
         raise Program_Error with "could not open poller fairness file";
      end if;
   end;

   GNAT.Sockets.Create_Socket_Pair (Reader, Writer);
   Fault_Control.Reset;
   Fault_Control.Arm (Fault_Control.File_Uring_Synchronous_Eventfd);
   if not Pollers.Initialize (Poller) then
      raise Program_Error with "could not initialize Linux poller";
   end if;
   Initialized := True;
   if Selected_Linux_Backend = 1 then
      if Fault_Control.Calls
        (Fault_Control.File_Uring_Synchronous_Eventfd) /= 1
      then
         raise Program_Error with
           "io_uring did not select synchronous eventfd for fairness test";
      end if;
   elsif Fault_Control.Calls
     (Fault_Control.File_Uring_Synchronous_Eventfd) /= 0
   then
      raise Program_Error with
        "native AIO reached the io_uring eventfd registration seam";
   end if;
   Fault_Control.Reset;

   --  A one-element batch can be filled by a file completion. Consuming the
   --  file engine's eventfd first must not strand that completion: the next
   --  nonblocking batch drains it even though there is no second epoll event.
   declare
      Events : Pollers.Poll_Event_Array (1 .. 1);
      Count  : Natural;
   begin
      Hold_Completed_File (Events, Count);
      if not Pollers.Wait_Batch (Poller, 0.0, Events, Count)
        or else Count /= Events'Length
        or else Events (Events'First).Kind /= Pollers.File_Event
        or else Events (Events'First).Token /= Token'Address
      then
         raise Program_Error with
           "one-element full file batch did not make progress";
      end if;
   end;

   --  Keep one completed file operation queued at every target call. A native
   --  pthread then makes both the socket and eventfd ready before Wait_Batch.
   --  Each iteration must return all three sources in the same batch; the old
   --  file-first early return reports only File_Event here.
   for Iteration in 1 .. Iterations loop
      declare
         Events : Pollers.Poll_Event_Array (1 .. 64);
         Count  : Natural;
         Woke   : Boolean;
         Payload : Ada.Streams.Stream_Element_Array (1 .. 1);
         Last    : Ada.Streams.Stream_Element_Offset;
         Reader_FD : constant Interfaces.C.int :=
           Interfaces.C.int (GNAT.Sockets.To_C (Reader));
      begin
         Hold_Completed_File (Events, Count);
         if not Pollers.Watch (Poller, Reader_FD, Pollers.Readable) then
            raise Program_Error with "could not arm socket readiness";
         end if;
         Waker.Trigger (Woke);
         if not Woke then
            raise Program_Error with "native eventfd/socket wake failed";
         elsif not Pollers.Wait_Batch (Poller, 0.0, Events, Count) then
            raise Program_Error with "mixed poller batch failed";
         elsif not Contains (Events, Count, Pollers.File_Event)
           or else not Contains (Events, Count, Pollers.Wake_Event)
           or else
             not Contains
               (Events, Count, Pollers.Readable_Event, Reader_FD)
         then
            raise Program_Error with
              "file completion hid socket readiness or eventfd wake at" &
              Iteration'Image;
         end if;
         GNAT.Sockets.Receive_Socket (Reader, Payload, Last);
         if Last /= Payload'Last or else Payload (Payload'First) /= 73 then
            raise Program_Error with "socket payload was corrupted";
         end if;
      end;
   end loop;

   Cleanup;
exception
   when others =>
      Cleanup;
      raise;
end Linux_Poller_Fairness_Smoke;
