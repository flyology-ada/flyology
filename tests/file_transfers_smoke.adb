with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.Buffers;
with Flyology.IO.Files;
with Flyology.IO.Files.Transfers;
with Flyology.IO.Sockets;

procedure File_Transfers_Smoke is
   package Files renames Flyology.IO.Files;
   package Sockets renames Flyology.IO.Sockets;
   package Transfers renames Flyology.IO.Files.Transfers;

   use Ada.Streams;
   use type Files.File_Descriptor;
   use type Files.File_Offset;
   use type Transfers.Byte_Count;

   Path : constant String :=
     Ada.Environment_Variables.Value ("FLYOLOGY_TEST_TEMP_ROOT")
       & "/file-transfers-smoke.data";
   Size : constant Positive := 256 * 1_024;
   Data : Stream_Element_Array (1 .. Stream_Element_Offset (Size));
   File : Files.File_Descriptor := Files.Invalid_File;

   procedure Remove_Test_File is
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
   end Remove_Test_File;

   procedure Run (Kind : Flyology.Execution_Model; Lane : String) is
      Sender_Socket   : Sockets.Socket_Type;
      Receiver_Socket : Sockets.Socket_Type;
      Listener        : Sockets.Socket_Type;
      Server          : Sockets.Endpoint;
      Peer            : Sockets.Endpoint;
      Received        : Stream_Element_Array (Data'Range);
      Outcome         : Natural := 0 with Atomic;

      task type Sender is
         pragma Task_Info (Kind);
      end Sender;

      task body Sender is
         Storage : aliased Flyology.Buffers.Pool
           (Block_Size => 64 * 1_024, Capacity => 1);
         Scratch : Flyology.Buffers.Unique_Buffer (Storage'Access);
         Offset  : Files.File_Offset := 0;
         Sent    : Transfers.Byte_Count;
      begin
         Flyology.Buffers.Acquire (Scratch);
         while Offset < Files.File_Offset (Size) loop
            Transfers.Send_Chunk
              (File,
               Sender_Socket,
               Offset,
               Transfers.Byte_Count (Size - Natural (Offset)),
               Scratch,
               Sent,
               Timeout => 5.0);
            if Sent = 0 then
               raise Program_Error with "file transfer stopped before EOF";
            end if;
            Offset := Offset + Files.File_Offset (Sent);
         end loop;

         Transfers.Send_Chunk
           (File, Sender_Socket, Offset, 64, Scratch, Sent, Timeout => 5.0);
         if Sent /= 0 then
            raise Program_Error with "file transfer passed EOF";
         end if;
         Transfers.Send_Chunk
           (File, Sender_Socket, 0, 0, Scratch, Sent, Timeout => 5.0);
         if Sent /= 0 then
            raise Program_Error with "zero-length transfer made progress";
         end if;
         declare
            Stop   : aliased Files.Cancellation_Token;
            Caught : Boolean := False;
         begin
            Stop.Request;
            begin
               Transfers.Send_Chunk
                 (File,
                  Sender_Socket,
                  0,
                  64,
                  Scratch,
                  Sent,
                  Timeout => 5.0,
                  Token => Stop'Access);
            exception
               when Files.Operation_Cancelled => Caught := True;
            end;
            if not Caught then
               raise Program_Error with
                 "pre-cancelled transfer was not cancelled";
            end if;
         end;
         Outcome := 1;
      exception
         when others =>
            Outcome := 2;
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
        (Listener, Receiver_Socket, Peer, Timeout => 5.0);
      Sockets.Close_Socket (Listener);
      declare
         Worker : Sender;
      begin
         Sockets.Receive_Exactly
           (Receiver_Socket, Received, Timeout => 5.0);
      end;
      Sockets.Close_Socket (Sender_Socket);
      Sockets.Close_Socket (Receiver_Socket);
      if Outcome /= 1 then
         raise Program_Error with Lane & " file-transfer task failed";
      elsif Received /= Data then
         raise Program_Error with Lane & " file-transfer payload mismatch";
      end if;
   end Run;

   type Edge_Mode is (Post_Submit_Cancel, Backpressure_Timeout, Closed_Peer);

   procedure Run_Edge
     (Kind : Flyology.Execution_Model;
      Lane : String;
      Mode : Edge_Mode)
   is
      Sender_Socket   : Sockets.Socket_Type;
      Receiver_Socket : Sockets.Socket_Type;
      Listener        : Sockets.Socket_Type;
      Server          : Sockets.Endpoint;
      Peer            : Sockets.Endpoint;
      Stop            : aliased Files.Cancellation_Token;
      Outcome         : Natural := 0 with Atomic;

      task type Sender is
         pragma Task_Info (Kind);
      end Sender;

      task body Sender is
         Storage : aliased Flyology.Buffers.Pool
           (Block_Size => 64 * 1_024, Capacity => 1);
         Scratch : Flyology.Buffers.Unique_Buffer (Storage'Access);
         Sent    : Transfers.Byte_Count;
         Made_Progress : Boolean := False;
         Expected      : Boolean := False;

         procedure Touch
           (Buffer : in out Stream_Element_Array;
            Length : in out Natural)
         is
         begin
            Buffer (Buffer'First) := 42;
            Length := 1;
         end Touch;
      begin
         Flyology.Buffers.Acquire (Scratch);
         for Attempt in 1 .. 4_096 loop
            begin
               Transfers.Send_Chunk
                 (File,
                  Sender_Socket,
                  0,
                  Transfers.Byte_Count (Size),
                  Scratch,
                  Sent,
                  Timeout =>
                    (if Mode = Backpressure_Timeout then 0.05 else 5.0),
                  Token =>
                    (if Mode = Post_Submit_Cancel then Stop'Access else null));
               if Sent = 0 then
                  raise Program_Error with
                    "edge transfer made no progress before EOF";
               end if;
               Made_Progress := True;
            exception
               when Files.Operation_Cancelled =>
                  Expected := Mode = Post_Submit_Cancel and then Made_Progress;
                  exit;
               when Files.Timeout_Error =>
                  Expected := Mode = Backpressure_Timeout and then Made_Progress;
                  exit;
               when Sockets.Socket_Error =>
                  Expected := Mode = Closed_Peer;
                  exit;
            end;
         end loop;

         --  An exceptional completion must still be terminal with respect to
         --  kernel ownership of the submitted scratch storage.
         Flyology.Buffers.With_Writable_Data (Scratch, Touch'Access);
         Outcome := (if Expected then 1 else 2);
      exception
         when others => Outcome := 2;
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
        (Listener, Receiver_Socket, Peer, Timeout => 5.0);
      Sockets.Close_Socket (Listener);
      if Mode = Closed_Peer then
         Sockets.Close_Socket (Receiver_Socket);
      end if;
      declare
         Worker : Sender;
      begin
         if Mode = Post_Submit_Cancel then
            delay 0.05;
            Stop.Request;
         end if;
      end;
      Sockets.Close_Socket (Sender_Socket);
      if Mode /= Closed_Peer then
         Sockets.Close_Socket (Receiver_Socket);
      end if;
      if Outcome /= 1 then
         raise Program_Error with
           Lane & " file-transfer " & Mode'Image & " edge failed";
      end if;
   end Run_Edge;

begin
   Remove_Test_File;
   for Index in Data'Range loop
      Data (Index) := Stream_Element ((Index * 31 + 7) mod 251);
   end loop;

   File :=
     Files.Open
       (Path, Files.Read_Write, Create => True, Truncate => True);
   declare
      Offset : Files.File_Offset := 0;
      First  : Stream_Element_Offset := Data'First;
      Stop   : Stream_Element_Offset;
   begin
      while First <= Data'Last loop
         Files.Write_At (File, Offset, Data (First .. Data'Last), Stop);
         if Stop < First then
            raise Program_Error with "could not populate transfer fixture";
         end if;
         Offset := Offset + Files.File_Offset (Stop - First + 1);
         First := Stop + 1;
      end loop;
   end;

   Ada.Text_IO.Put_Line ("file transfer smoke: BEGIN native payload");
   Run (Flyology.Native_Task, "native");
   Ada.Text_IO.Put_Line ("file transfer smoke: PASS native payload");
   Ada.Text_IO.Put_Line ("file transfer smoke: BEGIN lightweight payload");
   Run (Flyology.Lightweight_Task, "lightweight");
   Ada.Text_IO.Put_Line ("file transfer smoke: PASS lightweight payload");
   for Mode in Edge_Mode loop
      Ada.Text_IO.Put_Line
        ("file transfer smoke: BEGIN native " & Mode'Image);
      Run_Edge (Flyology.Native_Task, "native", Mode);
      Ada.Text_IO.Put_Line
        ("file transfer smoke: PASS native " & Mode'Image);
      Ada.Text_IO.Put_Line
        ("file transfer smoke: BEGIN lightweight " & Mode'Image);
      Run_Edge (Flyology.Lightweight_Task, "lightweight", Mode);
      Ada.Text_IO.Put_Line
        ("file transfer smoke: PASS lightweight " & Mode'Image);
   end loop;
   Files.Close (File);
   Remove_Test_File;
   Ada.Text_IO.Put_Line ("file transfer smoke: OK");
exception
   when others =>
      if File /= Files.Invalid_File then
         Files.Close (File);
      end if;
      Remove_Test_File;
      raise;
end File_Transfers_Smoke;
