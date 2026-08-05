with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Methods;
with Flyology.IO;
with Flyology.IO.Sockets;

procedure HTTP_Client_Upload_Controls_Smoke is
   package Client renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
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

   type One_Shot_Source is new Client.Request_Body_Source with record
      Value      : Unbounded_String;
      Position   : Natural := 0;
      Chunk_Size : Positive := 1;
      Length     : Client.Body_Length := Client.Unknown_Length;
      Reads      : Natural := 0;
   end record;

   overriding function Declared_Length
     (Item : One_Shot_Source) return Client.Body_Length is (Item.Length);

   overriding procedure Read
     (Item     : in out One_Shot_Source;
      Data     : out Stream_Element_Array;
      Last     : out Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Text  : constant String := To_String (Item.Value);
      Count : Natural;
   begin
      Item.Reads := Item.Reads + 1;
      Last := Data'First - 1;
      if Item.Position >= Text'Length then
         Finished := True;
         return;
      end if;
      Count := Natural'Min
        (Natural (Data'Length),
         Natural'Min (Item.Chunk_Size, Text'Length - Item.Position));
      for Offset in 0 .. Count - 1 loop
         Data (Data'First + Stream_Element_Offset (Offset)) :=
           Stream_Element
             (Character'Pos (Text (Text'First + Item.Position + Offset)));
      end loop;
      Item.Position := Item.Position + Count;
      Last := Data'First + Stream_Element_Offset (Count) - 1;
      Finished := Item.Position = Text'Length;
   end Read;

   type Retry_Source is
     new Client.Rewindable_Request_Body_Source with record
      Value      : Unbounded_String;
      Position   : Natural := 0;
      Chunk_Size : Positive := 1;
      Length     : Client.Body_Length := Client.Unknown_Length;
      Reads      : Natural := 0;
      Rewinds    : Natural := 0;
   end record;

   overriding procedure Rewind (Item : in out Retry_Source);

   overriding function Declared_Length
     (Item : Retry_Source) return Client.Body_Length is (Item.Length);

   overriding procedure Read
     (Item     : in out Retry_Source;
      Data     : out Stream_Element_Array;
      Last     : out Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Text  : constant String := To_String (Item.Value);
      Count : Natural;
   begin
      Item.Reads := Item.Reads + 1;
      Last := Data'First - 1;
      if Item.Position >= Text'Length then
         Finished := True;
         return;
      end if;
      Count := Natural'Min
        (Natural (Data'Length),
         Natural'Min (Item.Chunk_Size, Text'Length - Item.Position));
      for Offset in 0 .. Count - 1 loop
         Data (Data'First + Stream_Element_Offset (Offset)) :=
           Stream_Element
             (Character'Pos (Text (Text'First + Item.Position + Offset)));
      end loop;
      Item.Position := Item.Position + Count;
      Last := Data'First + Stream_Element_Offset (Count) - 1;
      Finished := Item.Position = Text'Length;
   end Read;

   procedure Rewind (Item : in out Retry_Source) is
   begin
      Item.Position := 0;
      Item.Rewinds := Item.Rewinds + 1;
   end Rewind;

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

      procedure Accept_Peer is
      begin
         Sockets.Accept_Socket
           (Listener, Peer, Address, Timeout => 3.0, Status => Status);
         pragma Assert (Status = Sockets.Completed);
      end Accept_Peer;

      procedure Send (Value : String) is
      begin
         Sockets.Send_All (Peer, Bytes (Value), Timeout => 3.0);
      end Send;

      procedure Send_Empty (Status_Line : String := "200 OK") is
      begin
         Send
           ("HTTP/1.1 " & Status_Line & CRLF &
            "Content-Length: 0" & CRLF & CRLF);
      end Send_Empty;

      function Receive_Until (Marker : String) return String is
         Buffer : Stream_Element_Array (1 .. 2_048);
         Last   : Stream_Element_Offset;
         Result : Unbounded_String;
      begin
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
            pragma Assert (Last >= Buffer'First);
            for Index in Buffer'First .. Last loop
               Append (Result, Character'Val (Buffer (Index)));
            end loop;
            exit when Ada.Strings.Fixed.Index (To_String (Result), Marker) /= 0;
         end loop;
         return To_String (Result);
      end Receive_Until;

      procedure Expect_Head_Only
        (Target : String; Head : out Unbounded_String)
      is
         Text : constant String := Receive_Until (CRLF & CRLF);
         Mark : constant Natural := Ada.Strings.Fixed.Index
           (Text, CRLF & CRLF);
      begin
         pragma Assert
           (Ada.Strings.Fixed.Index
              (Text, "POST " & Target & " HTTP/1.1" & CRLF) = 1);
         pragma Assert (Mark + 3 = Text'Last);
         Head := To_Unbounded_String (Text);
      end Expect_Head_Only;

      procedure Expect_Close is
         Buffer : Stream_Element_Array (1 .. 32);
         Last   : Stream_Element_Offset;
      begin
         loop
            Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
            exit when Last < Buffer'First;
         end loop;
         Sockets.Close_Socket (Peer);
      end Expect_Close;

      procedure Serve_Lane is
         Head : Unbounded_String;
      begin
         Accept_Peer;

         Expect_Head_Only ("/expect", Head);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Head), "Expect: 100-continue" & CRLF) /= 0);
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Head), "Content-Length: 11" & CRLF) /= 0);
         Send
           ("HTTP/1.1 103 Early Hints" & CRLF &
            "Link: </upload>; rel=preload" & CRLF & CRLF &
            "HTTP/1.1 100 Continue" & CRLF & CRLF);
         declare
            Payload : constant String := Receive_Until ("expect-body");
         begin
            pragma Assert (Payload = "expect-body");
         end;
         Send_Empty;

         Expect_Head_Only ("/reject", Head);
         Send_Empty ("417 Expectation Failed");

         Expect_Head_Only ("/fallback", Head);
         declare
            Payload : constant String := Receive_Until ("fallback-body");
         begin
            pragma Assert (Payload = "fallback-body");
         end;
         Send_Empty;

         declare
            Request : constant String := Receive_Until
              ("0" & CRLF &
               "X-Checksum: abc123" & CRLF &
               "X-Note: complete" & CRLF & CRLF);
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Request, "POST /trailers HTTP/1.1" & CRLF) = 1);
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Request, "Transfer-Encoding: chunked" & CRLF) /= 0);
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Request, "Trailer: X-Checksum, X-Note" & CRLF) /= 0);
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Request,
                  CRLF & CRLF &
                  "5" & CRLF & "trail" & CRLF &
                  "5" & CRLF & "-body" & CRLF &
                  "0" & CRLF &
                  "X-Checksum: abc123" & CRLF &
                  "X-Note: complete" & CRLF & CRLF) /= 0);
         end;
         Send_Empty;

         declare
            Prime : constant String := Receive_Until (CRLF & CRLF);
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Prime, "GET /stale-prime HTTP/1.1" & CRLF) = 1);
         end;
         Send_Empty;
         Sockets.Close_Socket (Peer);

         Accept_Peer;
         declare
            Retried : constant String := Receive_Until
              (CRLF & CRLF & "retry-body");
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Retried, "PUT /rewind-retry HTTP/1.1" & CRLF) = 1);
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Retried, "Content-Length: 10" & CRLF) /= 0);
         end;
         Send_Empty;

         declare
            Prime : constant String := Receive_Until (CRLF & CRLF);
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Prime, "GET /one-shot-prime HTTP/1.1" & CRLF) = 1);
         end;
         Send_Empty;
         Sockets.Close_Socket (Peer);

         Accept_Peer;
         declare
            Final_Request : constant String := Receive_Until (CRLF & CRLF);
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Final_Request,
                  "GET /after-one-shot HTTP/1.1" & CRLF) = 1);
         end;
         Send
           ("HTTP/1.1 204 No Content" & CRLF &
            "Connection: close" & CRLF & CRLF);
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
           ("HTTP upload controls server failed: " &
            Ada.Exceptions.Exception_Information (Occurrence));
         if Sockets.Is_Open (Peer) then
            Sockets.Close_Socket (Peer);
         end if;
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
         Coordination.Finish (False);
   end Raw_Server;

   procedure Exercise (Port : Sockets.Port) is
      Origin : constant Flyology.HTTP.Origin := Flyology.HTTP.Parse_Origin
        ("http://127.0.0.1:" & Decimal (Natural (Port)));
      HTTP   : aliased Client.Client (Capacity => 1);

      procedure Require_Empty (Reply : Client.Response) is
      begin
         pragma Assert (Client.Body_Complete (Reply));
      end Require_Empty;

      procedure Execute_Empty (Target : String) is
         Request : Client.Request;
      begin
         Client.Set_Target (Request, Target);
         Require_Empty (Client.Execute (HTTP, Request));
      end Execute_Empty;
   begin
      Client.Configure (HTTP, Origin);

      declare
         Request : Client.Request;
         Source  : One_Shot_Source :=
           (Value      => To_Unbounded_String ("expect-body"),
            Position   => 0,
            Chunk_Size => 4,
            Length     => Client.Known_Length (11),
            Reads      => 0);
      begin
         Client.Set_Method (Request, Flyology.HTTP.Methods.POST);
         Client.Set_Target (Request, "/expect");
         Client.Set_Expect_Continue (Request, Wait_Timeout => 1.0);
         Require_Empty (Client.Execute (HTTP, Request, Source));
         pragma Assert (Source.Reads > 0 and then Source.Position = 11);
      end;

      declare
         Request : Client.Request;
         Source  : One_Shot_Source :=
           (Value      => To_Unbounded_String ("must-not-send"),
            Position   => 0,
            Chunk_Size => 4,
            Length     => Client.Known_Length (13),
            Reads      => 0);
      begin
         Client.Set_Method (Request, Flyology.HTTP.Methods.POST);
         Client.Set_Target (Request, "/reject");
         Client.Set_Expect_Continue (Request, Wait_Timeout => 1.0);
         declare
            Reply : constant Client.Response :=
              Client.Execute (HTTP, Request, Source);
         begin
            pragma Assert (Client.Status (Reply) = 417);
            pragma Assert (Client.Body_Complete (Reply));
         end;
         pragma Assert (Source.Reads = 0 and then Source.Position = 0);
      end;

      declare
         Request : Client.Request;
         Source  : One_Shot_Source :=
           (Value      => To_Unbounded_String ("fallback-body"),
            Position   => 0,
            Chunk_Size => 13,
            Length     => Client.Known_Length (13),
            Reads      => 0);
      begin
         Client.Set_Method (Request, Flyology.HTTP.Methods.POST);
         Client.Set_Target (Request, "/fallback");
         Client.Set_Expect_Continue (Request, Wait_Timeout => 0.02);
         Require_Empty (Client.Execute (HTTP, Request, Source));
         pragma Assert (Source.Reads = 1 and then Source.Position = 13);
      end;

      declare
         Request : Client.Request;
         Source  : One_Shot_Source :=
           (Value      => To_Unbounded_String ("trail-body"),
            Position   => 0,
            Chunk_Size => 5,
            Length     => Client.Unknown_Length,
            Reads      => 0);
      begin
         Client.Set_Method (Request, Flyology.HTTP.Methods.POST);
         Client.Set_Target (Request, "/trailers");
         Client.Add_Trailer (Request, "X-Checksum", "abc123");
         Client.Add_Trailer (Request, "X-Note", "complete");
         Require_Empty (Client.Execute (HTTP, Request, Source));
      end;

      Execute_Empty ("/stale-prime");
      declare
         Request : Client.Request;
         Source  : Retry_Source :=
           (Value      => To_Unbounded_String ("retry-body"),
            Position   => 0,
            Chunk_Size => 3,
            Length     => Client.Known_Length (10),
            Reads      => 0,
            Rewinds    => 0);
      begin
         Client.Set_Method (Request, Flyology.HTTP.Methods.PUT);
         Client.Set_Target (Request, "/rewind-retry");
         Require_Empty (Client.Execute (HTTP, Request, Source));
         pragma Assert
           (Source.Rewinds = 1 and then Source.Position = 10);
      end;

      Execute_Empty ("/one-shot-prime");
      declare
         Request : Client.Request;
         Source  : One_Shot_Source :=
           (Value      => To_Unbounded_String ("one-shot"),
            Position   => 0,
            Chunk_Size => 8,
            Length     => Client.Known_Length (8),
            Reads      => 0);
         Failed : Boolean := False;
      begin
         Client.Set_Method (Request, Flyology.HTTP.Methods.PUT);
         Client.Set_Target (Request, "/one-shot-no-retry");
         begin
            declare
               Unexpected : Client.Response :=
                 Client.Execute (HTTP, Request, Source);
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Flyology.HTTP.Protocol_Error |
                 Flyology.IO.Device_Error |
                 Flyology.IO.Sockets.Socket_Error =>
               Failed := True;
         end;
         pragma Assert (Failed);
      end;
      declare
         State : constant Client.Client_Diagnostics :=
           Client.Diagnostics (HTTP);
      begin
         pragma Assert (State.Stale_Retries = 1);
      end;
      Execute_Empty ("/after-one-shot");

      declare
         Request : Client.Request;
         Raised  : Boolean := False;
      begin
         begin
            Client.Add_Trailer (Request, "Content-Length", "1");
         exception
            when Constraint_Error => Raised := True;
         end;
         pragma Assert (Raised);
      end;

      declare
         Request : Client.Request;
         Source  : One_Shot_Source :=
           (Value      => To_Unbounded_String ("known"),
            Position   => 0,
            Chunk_Size => 5,
            Length     => Client.Known_Length (5),
            Reads      => 0);
         Raised : Boolean := False;
      begin
         Client.Set_Method (Request, Flyology.HTTP.Methods.POST);
         Client.Add_Trailer (Request, "X-Late", "value");
         begin
            declare
               Unexpected : Client.Response :=
                 Client.Execute (HTTP, Request, Source);
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Constraint_Error => Raised := True;
         end;
         pragma Assert (Raised and then Source.Reads = 0);
      end;

      declare
         Request : Client.Request;
         Raised  : Boolean := False;
      begin
         Client.Set_Expect_Continue (Request);
         begin
            declare
               Unexpected : Client.Response := Client.Execute (HTTP, Request);
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Constraint_Error => Raised := True;
         end;
         pragma Assert (Raised);
      end;

      Client.Shutdown (HTTP);
   end Exercise;

   Port      : Sockets.Port;
   Server_OK : Boolean;
begin
   Coordination.Wait_Ready (Port, Server_OK);
   pragma Assert (Server_OK and then Port /= Sockets.Any_Port);
   Exercise (Port);
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
         Exercise (Port);
         Result.Finish (True);
      exception
         when Occurrence : others =>
            Ada.Text_IO.Put_Line
              ("lightweight HTTP upload controls failed: " &
               Ada.Exceptions.Exception_Information (Occurrence));
            Result.Finish (False);
      end Lightweight_Caller;

      pragma Unreferenced (Lightweight_Caller);
      Passed : Boolean;
   begin
      select
         Result.Wait (Passed);
      or
         delay 15.0;
         raise Program_Error with
           "lightweight HTTP upload controls did not finish";
      end select;
      pragma Assert (Passed);
   end;
   Coordination.Wait_Done (Server_OK);
   pragma Assert (Server_OK);
end HTTP_Client_Upload_Controls_Smoke;
