with Ada.Directories;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Streams;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Operations;
with Flyology.Wake_Sources;
with Flyology_Config;
with Interfaces.C;

procedure Unix_Stream_Socket_Smoke is
   package Sockets renames Flyology.IO.Sockets;

   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.C.int;
   use type Interfaces.C.unsigned;

   function C_Process_ID return Interfaces.C.int;
   pragma Import (C, C_Process_ID, "getpid");

   Process_ID : constant String :=
     Ada.Strings.Fixed.Trim
       (Interfaces.C.int'Image (C_Process_ID), Ada.Strings.Both);
   Test_Root : constant String := "/tmp/flyology-unix-" & Process_ID;
   Path_Text : constant String := Test_Root & "/listener.sock";
   Path      : constant Sockets.Unix_Path :=
     Sockets.Unix_Pathname (Path_Text);

   function C_Unlink (Path : Interfaces.C.char_array) return Interfaces.C.int;
   pragma Import (C, C_Unlink, "unlink");

   procedure Remove_Path is
      Result : constant Interfaces.C.int :=
        C_Unlink (Interfaces.C.To_C (Path_Text));
      pragma Unreferenced (Result);
   begin
      null;
   end Remove_Path;

   procedure Prepare_Test_Root is
   begin
      if Ada.Directories.Exists (Test_Root) then
         Ada.Directories.Delete_Tree (Test_Root);
      end if;
      Ada.Directories.Create_Directory (Test_Root);
   end Prepare_Test_Root;

   procedure Remove_Test_Root is
   begin
      if Ada.Directories.Exists (Test_Root) then
         Ada.Directories.Delete_Tree (Test_Root);
      end if;
   exception
      when others =>
         null;
   end Remove_Test_Root;

   procedure Close_If_Open (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   exception
      when others =>
         null;
   end Close_If_Open;

   procedure Open_Listener (Listener : in out Sockets.Socket_Type) is
   begin
      Sockets.Create_Unix_Stream_Socket (Listener);
      Sockets.Bind_Socket (Listener, Path);
      Sockets.Listen_Socket (Listener, Length => 1);
   end Open_Listener;

   procedure Check_Path_Validation is
      Failed : Boolean;
   begin
      pragma Assert (Sockets.Image (Path) = Path_Text);
      pragma Assert (Sockets.Maximum_Unix_Path_Length >= Path_Text'Length);

      Failed := False;
      begin
         declare
            Ignored : constant Sockets.Unix_Path := Sockets.Unix_Pathname ("");
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Constraint_Error =>
            Failed := True;
      end;
      pragma Assert (Failed);

      Failed := False;
      begin
         declare
            Ignored : constant Sockets.Unix_Path :=
              Sockets.Unix_Pathname ("bad" & Character'Val (0) & "path");
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Constraint_Error =>
            Failed := True;
      end;
      pragma Assert (Failed);

      Failed := False;
      begin
         declare
            Ignored : constant Sockets.Unix_Path :=
              Sockets.Unix_Pathname
                ((1 .. Sockets.Maximum_Unix_Path_Length + 1 => 'x'));
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when Constraint_Error =>
            Failed := True;
      end;
      pragma Assert (Failed);
   end Check_Path_Validation;

   generic
      Model : Flyology.Execution_Model;
   procedure Run_Round;

   procedure Run_Round is
      Listener    : Sockets.Socket_Type;
      Wake        : Flyology.Wake_Sources.Source;
      Server_OK   : Boolean := False with Atomic;
      Client_OK   : Boolean := False with Atomic;
      Request     : constant Ada.Streams.Stream_Element_Array (1 .. 4) :=
        (16#50#, 16#49#, 16#4E#, 16#47#);
      Response    : constant Ada.Streams.Stream_Element_Array (1 .. 4) :=
        (16#50#, 16#4F#, 16#4E#, 16#47#);

      protected Gate is
         procedure Release;
         entry Await_Release;
      private
         Released : Boolean := False;
      end Gate;

      protected body Gate is
         procedure Release is
         begin
            Released := True;
         end Release;

         entry Await_Release when Released is
         begin
            null;
         end Await_Release;
      end Gate;
   begin
      Open_Listener (Listener);
      Flyology.Wake_Sources.Ensure (Wake);
      Flyology.Wake_Sources.Signal (Wake);

      declare
         task Server is
            pragma Task_Info (Model);
         end Server;

         task Client is
            pragma Task_Info (Model);
         end Client;

         task body Server is
            Accepted    : Sockets.Socket_Type;
            Incoming    : Ada.Streams.Stream_Element_Array (Request'Range);
            Timed_Out   : Boolean := False;
            Interrupted : Boolean := False;
         begin
            begin
               Sockets.Accept_Connection
                 (Listener, Accepted, Timeout => 0.020);
            exception
               when Flyology.IO.Timeout_Error =>
                  Timed_Out := True;
            end;
            pragma Assert
              (Timed_Out and then not Sockets.Is_Open (Accepted));

            begin
               Sockets.Accept_Connection
                 (Listener, Accepted, Timeout => 1.0,
                  Interrupts =>
                    (1 => Flyology.Wake_Sources.Descriptor (Wake)));
            exception
               when Sockets.Operation_Interrupted =>
                  Interrupted := True;
            end;
            pragma Assert
              (Interrupted and then not Sockets.Is_Open (Accepted));
            Flyology.Wake_Sources.Consume (Wake);

            Gate.Release;
            Sockets.Accept_Connection (Listener, Accepted, Timeout => 2.0);
            Sockets.Receive_Exactly (Accepted, Incoming, Timeout => 2.0);
            pragma Assert (Incoming = Request);
            Sockets.Send_All (Accepted, Response, Timeout => 2.0);
            Sockets.Close_Socket (Accepted);
            Server_OK := True;
         exception
            when others =>
               Gate.Release;
               Close_If_Open (Accepted);
         end Server;

         task body Client is
            Socket : Sockets.Socket_Type;
            Reply  : Ada.Streams.Stream_Element_Array (Response'Range);
            Closed : Ada.Streams.Stream_Element_Array (1 .. 1);
            Last   : Ada.Streams.Stream_Element_Offset;
         begin
            Gate.Await_Release;
            Sockets.Create_Unix_Stream_Socket (Socket);
            Sockets.Connect (Socket, Path, Timeout => 2.0);
            Sockets.Send_All (Socket, Request, Timeout => 2.0);
            Sockets.Receive_Exactly (Socket, Reply, Timeout => 2.0);
            Sockets.Receive (Socket, Closed, Last, Timeout => 2.0);
            Client_OK := Reply = Response and then Last = Closed'First - 1;
            Sockets.Close_Socket (Socket);
         exception
            when others =>
               Close_If_Open (Socket);
         end Client;
      begin
         null;
      end;

      pragma Assert (Server_OK and then Client_OK);
      Sockets.Close_Socket (Listener);
   exception
      when others =>
         Close_If_Open (Listener);
         raise;
   end Run_Round;

   procedure Run_Native is new Run_Round (Flyology.Native_Task);
   procedure Run_Lightweight is new Run_Round (Flyology.Lightweight_Task);

   generic
      Model : Flyology.Execution_Model;
   procedure Check_Scoped_Round;

   procedure Check_Scoped_Round is
      Passed : Boolean := False with Atomic;
   begin
      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            Listener, Client : aliased Sockets.Socket_Type;
            Accepted : Sockets.Socket_Type;
         begin
            Remove_Path;
            Open_Listener (Listener);
            Sockets.Create_Unix_Stream_Socket (Client);
            declare
               Set : aliased Flyology.Operations.Completion_Set (3);
               Acceptance : aliased Sockets.Unix_Accept_Operation :=
                 Sockets.Accept_Connection
                   (Set'Access, Listener'Access, 1.0);
               Connection : aliased Sockets.Connect_Operation :=
                 Sockets.Connect (Set'Access, Client'Access, Path, 1.0);
               Both : Flyology.Operations.Gate_Operation :=
                 Flyology.Operations.Wait_For_Successes
                   (Set'Access,
                    [Flyology.Operations.Reference (Acceptance),
                     Flyology.Operations.Reference (Connection)],
                    2);
               Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
            begin
               Flyology.Operations.Wait_All (Set);
               Flyology.Operations.Finish (Both, Batch);
               Sockets.Finish (Connection);
               Sockets.Finish (Acceptance, Accepted);
               Passed := Sockets.Is_Open (Accepted) and then Batch.Count = 2;
            end;
            Close_If_Open (Accepted);
            Close_If_Open (Client);
            Close_If_Open (Listener);
            Remove_Path;
         exception
            when others =>
               Close_If_Open (Accepted);
               Close_If_Open (Client);
               Close_If_Open (Listener);
               Remove_Path;
         end Worker;
      begin
         null;
      end;
      pragma Assert (Passed);
   end Check_Scoped_Round;

   procedure Check_Native_Scoped_Round is new
     Check_Scoped_Round (Flyology.Native_Task);
   procedure Check_Lightweight_Scoped_Round is new
     Check_Scoped_Round (Flyology.Lightweight_Task);

   procedure Check_Missing_Path is
      Socket : Sockets.Socket_Type;
      Failed : Boolean := False;
   begin
      Remove_Path;
      Sockets.Create_Unix_Stream_Socket (Socket);
      begin
         Sockets.Connect (Socket, Path, Timeout => 0.1);
      exception
         when Sockets.Socket_Error =>
            Failed := True;
      end;
      pragma Assert (Failed);
      Sockets.Close_Socket (Socket);
   end Check_Missing_Path;

   procedure Check_Listener_Replacement is
      Existing : Sockets.Socket_Type;
      Rebound  : Sockets.Socket_Type;
      Failed   : Boolean := False;
   begin
      Remove_Path;
      Open_Listener (Existing);
      Sockets.Close_Socket (Existing);

      Sockets.Create_Unix_Stream_Socket (Rebound);
      begin
         Sockets.Bind_Socket (Rebound, Path);
      exception
         when Sockets.Socket_Error =>
            Failed := True;
      end;
      pragma Assert (Failed);
      Sockets.Close_Socket (Rebound);

      Remove_Path;
      Open_Listener (Rebound);
      Sockets.Close_Socket (Rebound);
      Remove_Path;
   exception
      when others =>
         Close_If_Open (Existing);
         Close_If_Open (Rebound);
         Remove_Path;
         raise;
   end Check_Listener_Replacement;

   generic
      Model : Flyology.Execution_Model;
   procedure Check_Connect_Deadline_And_Interrupt;

   procedure Check_Connect_Deadline_And_Interrupt is
      Passed : Boolean := False with Atomic;
      pragma Warnings (Off, """Host_OS"" is not modified");
      Host_OS    : String := Flyology_Config.Alire_Host_OS with Volatile;
      pragma Warnings (On, """Host_OS"" is not modified");
   begin
      --  Linux reports a full AF_UNIX accept queue as a pending nonblocking
      --  connect. Darwin reports ECONNREFUSED immediately, so its deterministic
      --  deadline and interrupt coverage is supplied by Accept_Connection
      --  above rather than pretending the connect is pending.
      if Host_OS /= "linux" then
         return;
      end if;

      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
            type Socket_Array is
              array (Positive range <>) of Sockets.Socket_Type;
            Listener    : Sockets.Socket_Type;
            Fillers     : Socket_Array (1 .. 8);
            Probe       : Sockets.Socket_Type;
            Scoped_Probe : aliased Sockets.Socket_Type;
            Wake        : Flyology.Wake_Sources.Source;
            Last        : Natural := 0;
            Timed_Out   : Boolean := False;
            Interrupted : Boolean := False;
         begin
            Remove_Path;
            Open_Listener (Listener);

            --  Fill the bounded local accept queue without accepting. The
            --  first connection that cannot enter it must remain governed by
            --  Connect's caller deadline rather than blocking its task lane.
            for Index in Fillers'Range loop
               Last := Index;
               Sockets.Create_Unix_Stream_Socket (Fillers (Index));
               begin
                  Sockets.Connect
                    (Fillers (Index), Path, Timeout => 0.030);
               exception
                  when Flyology.IO.Timeout_Error =>
                     Timed_Out := True;
                     exit;
               end;
            end loop;
            pragma Assert (Timed_Out);

            --  Keep the saturated queue intact. A second retrying connect
            --  must observe a readable interrupt source.
            Flyology.Wake_Sources.Ensure (Wake);
            Flyology.Wake_Sources.Signal (Wake);
            Sockets.Create_Unix_Stream_Socket (Probe);
            begin
               Sockets.Connect
                 (Probe, Path, Timeout => 1.0,
                  Interrupts =>
                    (1 => Flyology.Wake_Sources.Descriptor (Wake)));
            exception
               when Sockets.Operation_Interrupted =>
                  Interrupted := True;
            end;
            pragma Assert (Interrupted);
            Flyology.Wake_Sources.Consume (Wake);
            Close_If_Open (Probe);

            --  The scoped overload uses a retry-timer phase for the same
            --  Linux EAGAIN queue-full state and retains timeout for Finish.
            Sockets.Create_Unix_Stream_Socket (Scoped_Probe);
            declare
               Set : aliased Flyology.Operations.Completion_Set (1);
               Connection : Sockets.Connect_Operation :=
                 Sockets.Connect
                   (Set'Access, Scoped_Probe'Access, Path, 0.030);
               Scoped_Timed_Out : Boolean := False;
            begin
               Flyology.Operations.Wait_All (Set);
               begin
                  Sockets.Finish (Connection);
               exception
                  when Flyology.IO.Timeout_Error =>
                     Scoped_Timed_Out := True;
               end;
               pragma Assert (Scoped_Timed_Out);
            end;

            Close_If_Open (Scoped_Probe);
            for Index in 1 .. Last loop
               Close_If_Open (Fillers (Index));
            end loop;
            Close_If_Open (Listener);
            Remove_Path;
            Passed := True;
         exception
            when others =>
               Close_If_Open (Probe);
               Close_If_Open (Scoped_Probe);
               for Index in 1 .. Last loop
                  Close_If_Open (Fillers (Index));
               end loop;
               Close_If_Open (Listener);
               Remove_Path;
         end Worker;
      begin
         null;
      end;

      pragma Assert (Passed);
   end Check_Connect_Deadline_And_Interrupt;

   procedure Check_Native_Connect_Deadline is new
     Check_Connect_Deadline_And_Interrupt (Flyology.Native_Task);
   procedure Check_Lightweight_Connect_Deadline is new
     Check_Connect_Deadline_And_Interrupt (Flyology.Lightweight_Task);

   function C_Change_Mode
     (Path : Interfaces.C.char_array;
      Mode : Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (C, C_Change_Mode, "chmod");

   function C_Effective_User return Interfaces.C.unsigned;
   pragma Import (C, C_Effective_User, "geteuid");

   procedure Check_Permission_Failure is
      Directory : constant String := Test_Root & "/denied";
      Denied    : constant String := Directory & "/listener.sock";
      C_Dir     : constant Interfaces.C.char_array :=
        Interfaces.C.To_C (Directory);
      Socket    : Sockets.Socket_Type;
      Failed    : Boolean := False;
      Result    : Interfaces.C.int;
   begin
      if C_Effective_User = 0 then
         return;
      end if;
      if Ada.Directories.Exists (Directory) then
         Ada.Directories.Delete_Tree (Directory);
      end if;
      Ada.Directories.Create_Directory (Directory);
      Result := C_Change_Mode (C_Dir, 0);
      pragma Assert (Result = 0);
      Sockets.Create_Unix_Stream_Socket (Socket);
      begin
         Sockets.Bind_Socket (Socket, Sockets.Unix_Pathname (Denied));
      exception
         when Sockets.Socket_Error =>
            Failed := True;
      end;
      pragma Assert (Failed);
      Sockets.Close_Socket (Socket);
      Result := C_Change_Mode (C_Dir, 8#700#);
      pragma Assert (Result = 0);
      Ada.Directories.Delete_Directory (Directory);
   exception
      when others =>
         Close_If_Open (Socket);
         Result := C_Change_Mode (C_Dir, 8#700#);
         pragma Assert (Result = 0);
         if Ada.Directories.Exists (Directory) then
            Ada.Directories.Delete_Tree (Directory);
         end if;
         raise;
   end Check_Permission_Failure;

begin
   Prepare_Test_Root;
   Remove_Path;
   Check_Path_Validation;
   Check_Missing_Path;

   Run_Native;
   Remove_Path;

   Run_Lightweight;
   Remove_Path;

   Check_Native_Scoped_Round;
   Check_Lightweight_Scoped_Round;

   Check_Listener_Replacement;
   Check_Native_Connect_Deadline;
   Check_Lightweight_Connect_Deadline;
   Check_Permission_Failure;
   Remove_Test_Root;
exception
   when others =>
      Remove_Path;
      Remove_Test_Root;
      raise;
end Unix_Stream_Socket_Smoke;
