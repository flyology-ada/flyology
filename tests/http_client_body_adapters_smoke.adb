with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Buffers;
with Flyology.Buffers.Channels;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Client.Request_Bodies;
with Flyology.HTTP.Client.Request_Bodies.Channels;
with Flyology.HTTP.Client.Request_Bodies.Files;
with Flyology.HTTP.Methods;
with Flyology.IO;
with Flyology.IO.Files;
with Flyology.IO.Sockets;

procedure HTTP_Client_Body_Adapters_Smoke is
   package Client renames Flyology.HTTP.Client;
   package Bodies renames Flyology.HTTP.Client.Request_Bodies;
   package Channel_Bodies renames
     Flyology.HTTP.Client.Request_Bodies.Channels;
   package File_Bodies renames Flyology.HTTP.Client.Request_Bodies.Files;
   package Buffers renames Flyology.Buffers;
   package Buffer_Channels renames Flyology.Buffers.Channels;
   package Files renames Flyology.IO.Files;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use type Buffers.Pool_Snapshot;
   use type Sockets.Port;
   use type Sockets.Selector_Status;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

   function Bytes (Value : String) return Stream_Element_Array is
      Result : Stream_Element_Array
        (1 .. Stream_Element_Offset (Value'Length));
   begin
      if Value'Length > 0 then
         for Offset in 0 .. Value'Length - 1 loop
            Result (Result'First + Stream_Element_Offset (Offset)) :=
              Stream_Element (Character'Pos (Value (Value'First + Offset)));
         end loop;
      end if;
      return Result;
   end Bytes;

   function Decimal (Value : Natural) return String is
      Result : constant String := Natural'Image (Value);
   begin
      return Result (Result'First + 1 .. Result'Last);
   end Decimal;

   protected Coordination is
      procedure Publish (Value : Sockets.Port);
      procedure Finish (Passed : Boolean);
      entry Wait_Ready (Value : out Sockets.Port; Passed : out Boolean);
      entry Wait_Done (Passed : out Boolean);
   private
      Port_Value : Sockets.Port := Sockets.Any_Port;
      Ready      : Boolean := False;
      Done       : Boolean := False;
      OK         : Boolean := True;
   end Coordination;

   protected body Coordination is
      procedure Publish (Value : Sockets.Port) is
      begin
         Port_Value := Value;
         Ready := True;
      end Publish;

      procedure Finish (Passed : Boolean) is
      begin
         OK := OK and Passed;
         Done := True;
      end Finish;

      entry Wait_Ready
        (Value : out Sockets.Port; Passed : out Boolean)
        when Ready or Done
      is
      begin
         Value := Port_Value;
         Passed := OK;
      end Wait_Ready;

      entry Wait_Done (Passed : out Boolean) when Done is
      begin
         Passed := OK;
      end Wait_Done;
   end Coordination;

   task Raw_Server is
      pragma Task_Info (Flyology.Native_Task);
   end Raw_Server;

   task body Raw_Server is
      Listener : Sockets.Socket_Type;
      Peer     : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;
      Status   : Sockets.Selector_Status;

      procedure Send_Empty_Response is
      begin
         Sockets.Send_All
           (Peer,
            Bytes
              ("HTTP/1.1 200 OK" & CRLF &
               "Content-Length: 0" & CRLF & CRLF),
            Timeout => 2.0);
      end Send_Empty_Response;

      function Receive_Until (Marker : String) return String is
         Buffer : Stream_Element_Array (1 .. 2_048);
         Last   : Stream_Element_Offset;
         Result : Unbounded_String;
      begin
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 2.0);
            pragma Assert (Last >= Buffer'First);
            for Index in Buffer'First .. Last loop
               Append (Result, Character'Val (Buffer (Index)));
            end loop;
            exit when Ada.Strings.Fixed.Index (To_String (Result), Marker) /= 0;
         end loop;
         return To_String (Result);
      end Receive_Until;

      procedure Expect_Fixed (Target : String; Payload : String) is
         Request : constant String := Receive_Until (CRLF & CRLF & Payload);
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Request, "POST " & Target & " HTTP/1.1" & CRLF) /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
               (Request,
               "Content-Length: " & Decimal (Payload'Length) & CRLF) /= 0);
         Send_Empty_Response;
      end Expect_Fixed;

      procedure Expect_Channel is
         Request : constant String := Receive_Until ("0" & CRLF & CRLF);
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Request, "POST /channel HTTP/1.1" & CRLF) /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Request, "Transfer-Encoding: chunked" & CRLF) /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Request, CRLF & CRLF &
                 "4" & CRLF & "one-" & CRLF &
                 "3" & CRLF & "two" & CRLF &
                 "0" & CRLF & CRLF) /= 0);
         Send_Empty_Response;
      end Expect_Channel;

      procedure Expect_Known_Channel is
      begin
         Expect_Fixed ("/channel-known", "known");
      end Expect_Known_Channel;

      procedure Expect_Close is
         Buffer : Stream_Element_Array (1 .. 32);
         Last   : Stream_Element_Offset;
      begin
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 2.0);
            exit when Last < Buffer'First;
         end loop;
         Sockets.Close_Socket (Peer);
      end Expect_Close;

      procedure Serve_Lane is
      begin
         Sockets.Accept_Socket
           (Listener, Peer, Address, Timeout => 2.0, Status => Status);
         pragma Assert (Status = Sockets.Completed);
         Expect_Fixed ("/array", "array!");
         Expect_Fixed ("/array-rewind", "array!");
         Expect_Fixed ("/string", "string!");
         Expect_Fixed ("/bytes", "bytes!");
         Expect_Fixed ("/buffer", "buffer!");
         Expect_Fixed ("/file", "FILE-RANGE");
         Expect_Channel;
         Expect_Known_Channel;
         Expect_Close;
      end Serve_Lane;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Coordination.Publish (Sockets.Get_Socket_Name (Listener).Port);
      Serve_Lane;
      Serve_Lane;
      Sockets.Close_Socket (Listener);
      Coordination.Finish (True);
   exception
      when Occurrence : others =>
         Ada.Text_IO.Put_Line
           ("HTTP body adapter server failed: " &
            Ada.Exceptions.Exception_Information (Occurrence));
         if Sockets.Is_Open (Peer) then
            Sockets.Close_Socket (Peer);
         end if;
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
         Coordination.Finish (False);
   end Raw_Server;

   procedure Prepare_File (Path : String) is
      File : Files.File_Descriptor := Files.Open
        (Path, Mode => Files.Write_Only, Create => True, Truncate => True);
      Data : constant Stream_Element_Array := Bytes ("xxFILE-RANGEyy");
      Last : Stream_Element_Offset;
   begin
      Files.Write_At (File, 0, Data, Last);
      pragma Assert (Last = Data'Last);
      Files.Close (File);
   exception
      when others =>
         Files.Close (File);
         raise;
   end Prepare_File;

   procedure Exercise (Port : Sockets.Port; Path : String) is
      Origin : constant Flyology.HTTP.Origin := Flyology.HTTP.Parse_Origin
        ("http://127.0.0.1:" & Decimal (Natural (Port)));
      HTTP    : aliased Client.Client (Capacity => 1);
      Request : Client.Request;

      procedure Check (Reply : Client.Response) is
      begin
         pragma Assert (Client.Status (Reply) = 200);
         pragma Assert (Client.Body_Complete (Reply));
      end Check;
   begin
      Client.Configure (HTTP, Origin);
      Client.Set_Method (Request, Flyology.HTTP.Methods.POST);

      declare
         Payload : aliased constant Stream_Element_Array :=
           (5 => Stream_Element (Character'Pos ('a')),
            6 => Stream_Element (Character'Pos ('r')),
            7 => Stream_Element (Character'Pos ('r')),
            8 => Stream_Element (Character'Pos ('a')),
            9 => Stream_Element (Character'Pos ('y')),
            10 => Stream_Element (Character'Pos ('!')));
         Source : Bodies.Array_Source (Payload'Access);
      begin
         Client.Set_Target (Request, "/array");
         Check (Client.Execute (HTTP, Request, Source));
         Bodies.Rewind (Source);
         Client.Set_Target (Request, "/array-rewind");
         Check (Client.Execute (HTTP, Request, Source));
      end;

      declare
         Payload : aliased constant String := "string!";
         Source  : Bodies.Byte_String_Source (Payload'Access);
      begin
         Client.Set_Target (Request, "/string");
         Check (Client.Execute (HTTP, Request, Source));
      end;

      declare
         Payload : aliased Flyology.Bytes.Unbounded_Bytes :=
           Flyology.Bytes.From_Byte_String ("bytes!");
         Source : Bodies.Bytes_Source (Payload'Access);
      begin
         Client.Set_Target (Request, "/bytes");
         Check (Client.Execute (HTTP, Request, Source));
      end;

      declare
         Pool    : aliased Buffers.Pool (Block_Size => 16, Capacity => 1);
         Payload : aliased Buffers.Unique_Buffer (Pool'Access);
      begin
         Buffers.Acquire (Payload);
         Buffers.Copy_From (Payload, Bytes ("buffer!"));
         declare
            Source : Bodies.Buffer_Source (Payload'Access);
         begin
            Client.Set_Target (Request, "/buffer");
            Check (Client.Execute (HTTP, Request, Source));
         end;
         pragma Assert
           (Buffers.Has_Buffer (Payload)
              and then Buffers.Length (Payload) = 7);
         Buffers.Release (Payload);
         pragma Assert
           (Buffers.Current (Pool) =
              (Available => 1, Outstanding => 0));
      end;

      declare
         File   : aliased Files.File_Descriptor :=
           Files.Open (Path, Mode => Files.Read_Only);
         Source : File_Bodies.Range_Source
           (File'Access, Offset => 2, Count => 10);
      begin
         Client.Set_Target (Request, "/file");
         Check (Client.Execute (HTTP, Request, Source));
         declare
            Buffer : Stream_Element_Array (1 .. 1);
            Last   : Stream_Element_Offset;
            Raised : Boolean := False;
         begin
            begin
               Files.Read_At
                 (File, 0, Buffer, Last, Timeout => 0.0);
            exception
               when Flyology.IO.Timeout_Error =>
                  Raised := True;
            end;
            pragma Assert (Raised);
         end;
         Files.Close (File);
      exception
         when others =>
            Files.Close (File);
            raise;
      end;

      declare
         Pool  : aliased Buffers.Pool (Block_Size => 8, Capacity => 2);
         Queue : aliased Buffer_Channels.Channel
           (Owner => Pool'Access, Capacity => 1);
         Source : Channel_Bodies.Channel_Source
           (Pool'Access, Queue'Access);

         task Producer;

         task body Producer is
            Item : Buffers.Unique_Buffer (Pool'Access);
         begin
            Buffers.Acquire (Item);
            Buffers.Copy_From (Item, Bytes ("one-"));
            Buffer_Channels.Send_Move (Queue, Item);
            delay 0.01;
            Buffers.Acquire (Item);
            Buffers.Copy_From (Item, Bytes ("two"));
            Buffer_Channels.Send_Move (Queue, Item);
            Buffer_Channels.Close (Queue);
         end Producer;
         pragma Unreferenced (Producer);
      begin
         Client.Set_Target (Request, "/channel");
         Check (Client.Execute (HTTP, Request, Source));
         Buffer_Channels.Await_Drained (Queue);
         pragma Assert
           (Buffers.Current (Pool) =
              (Available => 2, Outstanding => 0));
      end;

      declare
         Pool  : aliased Buffers.Pool (Block_Size => 8, Capacity => 1);
         Queue : aliased Buffer_Channels.Channel
           (Owner => Pool'Access, Capacity => 1);
         Item   : Buffers.Unique_Buffer (Pool'Access);
         Source : Channel_Bodies.Channel_Source
           (Pool'Access, Queue'Access);
      begin
         Buffers.Acquire (Item);
         Buffers.Copy_From (Item, Bytes ("known"));
         Buffer_Channels.Send_Move (Queue, Item);
         Channel_Bodies.Set_Declared_Length
           (Source, Client.Known_Length (5));
         Client.Set_Target (Request, "/channel-known");
         Check (Client.Execute (HTTP, Request, Source));
         Buffer_Channels.Close (Queue);
         Buffer_Channels.Await_Drained (Queue);
         pragma Assert
           (Buffers.Current (Pool) =
              (Available => 1, Outstanding => 0));
      end;

      declare
         Pool  : aliased Buffers.Pool (Block_Size => 8, Capacity => 1);
         Queue : aliased Buffer_Channels.Channel
           (Owner => Pool'Access, Capacity => 1);
         Source : Channel_Bodies.Channel_Source
           (Pool'Access, Queue'Access);
         Token    : aliased Flyology.Cancellation.Token;
         Data     : Stream_Element_Array (1 .. 8);
         Last     : Stream_Element_Offset;
         Finished : Boolean;
         Raised   : Boolean := False;
      begin
         begin
            Channel_Bodies.Read
              (Source, Data, Last, Finished, 0.0, null);
         exception
            when Flyology.IO.Timeout_Error =>
               Raised := True;
         end;
         pragma Assert (Raised);
         Raised := False;
         Token.Request;
         begin
            Channel_Bodies.Read
              (Source, Data, Last, Finished, 1.0, Token'Access);
         exception
            when Flyology.Cancellation.Operation_Cancelled =>
               Raised := True;
         end;
         pragma Assert (Raised);
         Buffer_Channels.Close (Queue);
         pragma Assert
           (Buffers.Current (Pool) =
              (Available => 1, Outstanding => 0));
      end;

      Client.Shutdown (HTTP);
   end Exercise;

   Port      : Sockets.Port;
   Server_OK : Boolean;
begin
   Coordination.Wait_Ready (Port, Server_OK);
   pragma Assert (Server_OK and then Port /= Sockets.Any_Port);
   declare
      Path : constant String :=
        "/tmp/flyology-http-body-adapters-" & Decimal (Natural (Port));
   begin
      Prepare_File (Path);
      Exercise (Port, Path);
      declare
         protected Result is
            procedure Finish (Passed : Boolean);
            entry Wait (Passed : out Boolean);
         private
            Done : Boolean := False;
            OK   : Boolean := False;
         end Result;

         protected body Result is
            procedure Finish (Passed : Boolean) is
            begin
               OK := Passed;
               Done := True;
            end Finish;

            entry Wait (Passed : out Boolean) when Done is
            begin
               Passed := OK;
            end Wait;
         end Result;

         task Lightweight_Caller is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Lightweight_Caller;

         task body Lightweight_Caller is
         begin
            Exercise (Port, Path);
            Result.Finish (True);
         exception
            when Occurrence : others =>
               Ada.Text_IO.Put_Line
                 ("lightweight HTTP body adapters failed: " &
                  Ada.Exceptions.Exception_Information (Occurrence));
               Result.Finish (False);
         end Lightweight_Caller;

         pragma Unreferenced (Lightweight_Caller);
         Passed : Boolean;
      begin
         select
            Result.Wait (Passed);
         or
            delay 10.0;
            raise Program_Error with
              "lightweight HTTP body adapters did not finish";
         end select;
         pragma Assert (Passed);
      end;
      Coordination.Wait_Done (Server_OK);
      pragma Assert (Server_OK);
      Ada.Directories.Delete_File (Path);
   exception
      when others =>
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
         raise;
   end;
end HTTP_Client_Body_Adapters_Smoke;
