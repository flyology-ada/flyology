with Ada.Directories;
with Ada.Streams;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Wake_Sources;
with Flyology_Config;
with Interfaces.C;

procedure Unix_Stream_Socket_Smoke is
   package Sockets renames Flyology.IO.Sockets;

   use type Ada.Streams.Stream_Element_Array;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.C.int;
   use type Interfaces.C.unsigned;

   Path_Text : constant String := "/tmp/flyology-unix-stream-smoke.sock";
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
      Accepted    : Sockets.Socket_Type;
      Wake        : Flyology.Wake_Sources.Source;
      Timed_Out   : Boolean := False;
      Interrupted : Boolean := False;
      Client_OK   : Boolean := False with Atomic;
      Request     : constant Ada.Streams.Stream_Element_Array (1 .. 4) :=
        (16#50#, 16#49#, 16#4E#, 16#47#);
      Response    : constant Ada.Streams.Stream_Element_Array (1 .. 4) :=
        (16#50#, 16#4F#, 16#4E#, 16#47#);
   begin
      Open_Listener (Listener);

      begin
         Sockets.Accept_Connection (Listener, Accepted, Timeout => 0.020);
      exception
         when Flyology.IO.Timeout_Error =>
            Timed_Out := True;
      end;
      pragma Assert (Timed_Out and then not Sockets.Is_Open (Accepted));

      Flyology.Wake_Sources.Ensure (Wake);
      Flyology.Wake_Sources.Signal (Wake);
      begin
         Sockets.Accept_Connection
           (Listener, Accepted, Timeout => 1.0,
            Interrupts =>
              (1 => Flyology.Wake_Sources.Descriptor (Wake)));
      exception
         when Sockets.Operation_Interrupted =>
            Interrupted := True;
      end;
      pragma Assert (Interrupted and then not Sockets.Is_Open (Accepted));
      Flyology.Wake_Sources.Consume (Wake);

      declare
         task Client is
            pragma Task_Info (Model);
         end Client;

         task body Client is
            Socket : Sockets.Socket_Type;
            Reply  : Ada.Streams.Stream_Element_Array (Response'Range);
            Closed : Ada.Streams.Stream_Element_Array (1 .. 1);
            Last   : Ada.Streams.Stream_Element_Offset;
         begin
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

         Incoming : Ada.Streams.Stream_Element_Array (Request'Range);
      begin
         Sockets.Accept_Connection (Listener, Accepted, Timeout => 2.0);
         Sockets.Receive_Exactly (Accepted, Incoming, Timeout => 2.0);
         pragma Assert (Incoming = Request);
         Sockets.Send_All (Accepted, Response, Timeout => 2.0);
         Sockets.Close_Socket (Accepted);
      end;

      pragma Assert (Client_OK);
      Sockets.Close_Socket (Listener);
   exception
      when others =>
         Close_If_Open (Accepted);
         Close_If_Open (Listener);
         raise;
   end Run_Round;

   procedure Run_Native is new Run_Round (Flyology.Native_Task);
   procedure Run_Lightweight is new Run_Round (Flyology.Lightweight_Task);

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

   procedure Check_Connect_Deadline_And_Interrupt is
      type Socket_Array is
        array (Positive range <>) of Sockets.Socket_Type;
      Listener   : Sockets.Socket_Type;
      Fillers    : Socket_Array (1 .. 8);
      Probe      : Sockets.Socket_Type;
      Wake       : Flyology.Wake_Sources.Source;
      Last       : Natural := 0;
      Timed_Out  : Boolean := False;
      Interrupted : Boolean := False;
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
      Remove_Path;
      Open_Listener (Listener);

      --  Fill the bounded local accept queue without accepting. The first
      --  connection that cannot enter it must remain governed by Connect's
      --  caller deadline rather than blocking its task lane.
      for Index in Fillers'Range loop
         Last := Index;
         Sockets.Create_Unix_Stream_Socket (Fillers (Index));
         begin
            Sockets.Connect (Fillers (Index), Path, Timeout => 0.030);
         exception
            when Flyology.IO.Timeout_Error =>
               Timed_Out := True;
               exit;
         end;
      end loop;
      pragma Assert (Timed_Out);

      --  Keep the saturated queue and timed-out attempt alive. A second
      --  pending connect must observe a readable interrupt source.
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
      for Index in 1 .. Last loop
         Close_If_Open (Fillers (Index));
      end loop;
      Close_If_Open (Listener);
      Remove_Path;
   exception
      when others =>
         Close_If_Open (Probe);
         for Index in 1 .. Last loop
            Close_If_Open (Fillers (Index));
         end loop;
         Close_If_Open (Listener);
         Remove_Path;
         raise;
   end Check_Connect_Deadline_And_Interrupt;

   function C_Change_Mode
     (Path : Interfaces.C.char_array;
      Mode : Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (C, C_Change_Mode, "chmod");

   function C_Effective_User return Interfaces.C.unsigned;
   pragma Import (C, C_Effective_User, "geteuid");

   procedure Check_Permission_Failure is
      Directory : constant String := "/tmp/flyology-unix-stream-denied";
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
   Remove_Path;
   Check_Path_Validation;
   Check_Missing_Path;

   Run_Native;
   Remove_Path;

   Run_Lightweight;
   Remove_Path;

   Check_Listener_Replacement;
   Check_Connect_Deadline_And_Interrupt;
   Check_Permission_Failure;
exception
   when others =>
      Remove_Path;
      raise;
end Unix_Stream_Socket_Smoke;
