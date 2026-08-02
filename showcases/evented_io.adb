with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Text_IO;
with GNAT.Sockets;
with Gnatevl;
with Gnatevl.IO.Files;
with Gnatevl.IO.Sockets;
with Gnatevl.IO.Timers;
with Showcase_Support;

procedure Evented_IO is
   use Ada.Streams;
   use Ada.Text_IO;

   Request_Text : constant String := "hello from native task";
   Reply_Text   : constant String := "hello from evented task";
   File_Text    : constant String := "file I/O completed through the kernel queue";
   File_Path    : constant String := "/tmp/gnatevl-evented-io-showcase.dat";

   function Bytes (Text : String) return Stream_Element_Array is
      Result : Stream_Element_Array
        (1 .. Stream_Element_Offset (Text'Length));
   begin
      for Index in Text'Range loop
         Result
           (Stream_Element_Offset (Index - Text'First + 1)) :=
             Stream_Element (Character'Pos (Text (Index)));
      end loop;
      return Result;
   end Bytes;

   function Text (Data : Stream_Element_Array) return String is
      Result : String (1 .. Integer (Data'Length));
   begin
      for Index in Data'Range loop
         Result (Integer (Index - Data'First + 1)) :=
           Character'Val (Data (Index));
      end loop;
      return Result;
   end Text;

   protected Results is
      procedure Server_Done (Passed : Boolean);
      procedure Client_Done (Passed : Boolean);
      procedure File_Done (Passed : Boolean);
      procedure Tick;
      entry Wait;
      function Passed return Boolean;
   private
      Server_OK : Boolean := False;
      Client_OK : Boolean := False;
      File_OK   : Boolean := False;
      Server_Reported : Boolean := False;
      Client_Reported : Boolean := False;
      File_Reported   : Boolean := False;
      Ticks           : Natural := 0;
   end Results;

   protected body Results is
      procedure Server_Done (Passed : Boolean) is
      begin
         Server_OK := Passed;
         Server_Reported := True;
      end Server_Done;

      procedure Client_Done (Passed : Boolean) is
      begin
         Client_OK := Passed;
         Client_Reported := True;
      end Client_Done;

      procedure File_Done (Passed : Boolean) is
      begin
         File_OK := Passed;
         File_Reported := True;
      end File_Done;

      procedure Tick is
      begin
         Ticks := Ticks + 1;
      end Tick;

      entry Wait
        when Server_Reported
          and Client_Reported
          and File_Reported
          and Ticks = 5
      is
      begin
         null;
      end Wait;

      function Passed return Boolean is
        (Server_OK and Client_OK and File_OK and Ticks = 5);
   end Results;

   Server         : GNAT.Sockets.Socket_Type;
   Server_Address : GNAT.Sockets.Sock_Addr_Type;

begin
   if Ada.Directories.Exists (File_Path) then
      Ada.Directories.Delete_File (File_Path);
   end if;

   GNAT.Sockets.Create_Socket (Server);
   GNAT.Sockets.Set_Socket_Option
     (Server,
      GNAT.Sockets.Socket_Level,
      (Name => GNAT.Sockets.Reuse_Address, Enabled => True));
   GNAT.Sockets.Bind_Socket
     (Server,
      (Family => GNAT.Sockets.Family_Inet,
       Addr   => GNAT.Sockets.Loopback_Inet_Addr,
       Port   => GNAT.Sockets.Any_Port));
   GNAT.Sockets.Listen_Socket (Server);
   Server_Address := GNAT.Sockets.Get_Socket_Name (Server);
   Put_Line
     ("listening on descriptor"
      & Gnatevl.IO.Descriptor'Image
          (Gnatevl.IO.Sockets.Native_Descriptor (Server))
      & " at " & GNAT.Sockets.Image (Server_Address));

   declare
      task Socket_Server;

      task Native_Client is
         pragma Task_Info (Gnatevl.Native_Thread);
      end Native_Client;

      task Ticker;

      task Native_File_Reader is
         pragma Task_Info (Gnatevl.Native_Thread);
         entry Start;
      end Native_File_Reader;

      task File_Writer;

      task body Socket_Server is
         Peer    : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
         Address : GNAT.Sockets.Sock_Addr_Type;
         Request : Stream_Element_Array := Bytes (Request_Text);
         Stage   : Natural := 0;
      begin
         Put_Line ("evented socket server waiting for connection");
         Stage := 1;
         Gnatevl.IO.Sockets.Accept_Connection
           (Server, Peer, Address, Timeout => 2.0);
         Stage := 2;
         Gnatevl.IO.Sockets.Receive_Exactly
           (Peer, Request, Timeout => 2.0);
         Stage := 3;
         Gnatevl.IO.Sockets.Send_All
           (Peer, Bytes (Reply_Text), Timeout => 2.0);
         Results.Server_Done (Text (Request) = Request_Text);
         Put_Line
           ("evented socket server resumed on thread="
            & Showcase_Support.Thread_Image);
         GNAT.Sockets.Close_Socket (Peer);
      exception
         when Occurrence : others =>
            Put_Line
              ("socket server failed at stage" & Stage'Image & ": "
               & Ada.Exceptions.Exception_Information (Occurrence));
            begin
               Put_Line
                 ("listening descriptor remains "
                  & GNAT.Sockets.Image
                      (GNAT.Sockets.Get_Socket_Name (Server)));
            exception
               when Nested : others =>
                  Put_Line
                    ("listening descriptor check failed: "
                     & Ada.Exceptions.Exception_Information (Nested));
            end;
            Results.Server_Done (False);
      end Socket_Server;

      task body Native_Client is
         Socket : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
         Reply  : Stream_Element_Array := Bytes (Reply_Text);
      begin
         Put_Line ("native socket client starting");
         Gnatevl.IO.Timers.Sleep_For (0.030);
         Put_Line ("native socket client timer completed");
         GNAT.Sockets.Create_Socket (Socket);
         Put_Line
           ("native socket client connecting with descriptor"
            & Gnatevl.IO.Descriptor'Image
                (Gnatevl.IO.Sockets.Native_Descriptor (Socket)));
         Gnatevl.IO.Sockets.Connect
           (Socket, Server_Address, Timeout => 2.0);
         Gnatevl.IO.Sockets.Send_All
           (Socket, Bytes (Request_Text), Timeout => 2.0);
         Gnatevl.IO.Sockets.Receive_Exactly
           (Socket, Reply, Timeout => 2.0);
         Results.Client_Done (Text (Reply) = Reply_Text);
         Put_Line
           ("native socket client completed on thread="
            & Showcase_Support.Thread_Image);
         GNAT.Sockets.Close_Socket (Socket);
      exception
         when Occurrence : others =>
            Put_Line
              ("socket client failed: "
               & Ada.Exceptions.Exception_Information (Occurrence));
            Results.Client_Done (False);
      end Native_Client;

      task body Ticker is
      begin
         for Tick in 1 .. 5 loop
            Gnatevl.IO.Timers.Sleep_For (0.010);
            Results.Tick;
            Put_Line
              ("evented timer tick" & Tick'Image & " on thread="
               & Showcase_Support.Thread_Image);
         end loop;
      exception
         when Occurrence : others =>
            Put_Line
              ("ticker failed: "
               & Ada.Exceptions.Exception_Information (Occurrence));
      end Ticker;

      task body Native_File_Reader is
         File : Gnatevl.IO.Files.File_Descriptor :=
           Gnatevl.IO.Files.Invalid_File;
         Data : Stream_Element_Array := Bytes (File_Text);
         Last : Stream_Element_Offset;
      begin
         Put_Line ("native file reader waiting for request");
         accept Start;
         Put_Line ("native file reader accepted request");
         File := Gnatevl.IO.Files.Open (File_Path);
         Put_Line ("native file reader opened file");
         Gnatevl.IO.Files.Read_At (File, 0, Data, Last);
         Gnatevl.IO.Files.Close (File);
         Results.File_Done
           (Last = Data'Last and then Text (Data) = File_Text);
         Put_Line
           ("native file reader completed on thread="
            & Showcase_Support.Thread_Image);
      exception
         when Occurrence : others =>
            Put_Line
              ("file reader failed: "
               & Ada.Exceptions.Exception_Information (Occurrence));
            Results.File_Done (False);
      end Native_File_Reader;

      task body File_Writer is
         File : Gnatevl.IO.Files.File_Descriptor :=
           Gnatevl.IO.Files.Invalid_File;
         Data : constant Stream_Element_Array := Bytes (File_Text);
         Last : Stream_Element_Offset;
      begin
         File :=
           Gnatevl.IO.Files.Open
             (File_Path,
              Mode     => Gnatevl.IO.Files.Write_Only,
              Create   => True,
              Truncate => True);
         Gnatevl.IO.Files.Write_At (File, 0, Data, Last);
         Gnatevl.IO.Files.Close (File);
         if Last /= Data'Last then
            raise Program_Error with "short showcase file write";
         end if;
         Put_Line
           ("evented file writer resumed on thread="
            & Showcase_Support.Thread_Image);
         Native_File_Reader.Start;
      exception
         when Occurrence : others =>
            Put_Line
              ("file writer failed: "
               & Ada.Exceptions.Exception_Information (Occurrence));
            Results.File_Done (False);
      end File_Writer;
   begin
      Results.Wait;
   end;

   GNAT.Sockets.Close_Socket (Server);
   Ada.Directories.Delete_File (File_Path);

   if not Results.Passed then
      raise Program_Error with "evented I/O showcase failed";
   end if;
   Put_Line
     ("timers, files, and sockets passed without hidden I/O workers");
end Evented_IO;
