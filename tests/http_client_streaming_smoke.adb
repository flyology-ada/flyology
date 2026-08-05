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
with Flyology.IO.Sockets;

procedure HTTP_Client_Streaming_Smoke is
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
      for Offset in 0 .. Value'Length - 1 loop
         Result (Result'First + Stream_Element_Offset (Offset)) :=
           Stream_Element (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end Bytes;

   function Decimal (Value : Natural) return String is
      Result : constant String := Natural'Image (Value);
   begin
      return Result (Result'First + 1 .. Result'Last);
   end Decimal;

   type String_Source is new Client.Request_Body_Source with record
      Value      : Unbounded_String;
      Next       : Positive := 1;
      Chunk_Size : Positive := 1;
   end record;

   overriding procedure Read
     (Item     : in out String_Source;
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
      Last := Data'First - 1;
      if Item.Next > Text'Length then
         Finished := True;
         return;
      end if;
      Count := Natural'Min
        (Natural (Data'Length),
         Natural'Min (Item.Chunk_Size, Text'Length - Item.Next + 1));
      for Offset in 0 .. Count - 1 loop
         Data (Data'First + Stream_Element_Offset (Offset)) :=
           Stream_Element (Character'Pos (Text (Item.Next + Offset)));
      end loop;
      Last := Data'First + Stream_Element_Offset (Count - 1);
      Item.Next := Item.Next + Count;
      Finished := Item.Next > Text'Length;
   end Read;

   type Stalled_Source is new Client.Request_Body_Source with null record;

   overriding procedure Read
     (Item     : in out Stalled_Source;
      Data     : out Stream_Element_Array;
      Last     : out Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token) is
   begin
      pragma Unreferenced (Item, Timeout, Token);
      for Element of Data loop
         Element := 0;
      end loop;
      Last := Data'First - 1;
      Finished := False;
   end Read;

   Source_Failure : exception;

   type Failing_Source is new Client.Request_Body_Source with null record;

   overriding procedure Read
     (Item     : in out Failing_Source;
      Data     : out Stream_Element_Array;
      Last     : out Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token) is
   begin
      pragma Unreferenced
        (Item, Data, Last, Finished, Timeout, Token);
      raise Source_Failure;
   end Read;

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
           (Listener, Peer, Address, Timeout => 2.0, Status => Status);
         pragma Assert (Status = Sockets.Completed);
      end Accept_Peer;

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

      procedure Expect_Close is
         Buffer : Stream_Element_Array (1 .. 2_048);
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
         Accept_Peer;
         declare
            Request : constant String := Receive_Until (CRLF & CRLF & "abcdef");
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Request, "POST /known HTTP/1.1" & CRLF) /= 0);
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Request, "Content-Length: 6" & CRLF) /= 0);
         end;
         Send_Empty_Response;

         declare
            Request : constant String := Receive_Until
              ("0" & CRLF & CRLF);
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Request, "POST /unknown HTTP/1.1" & CRLF) /= 0);
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Request, "Transfer-Encoding: chunked" & CRLF) /= 0);
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Request,
                  CRLF & CRLF & "5" & CRLF & "hello" & CRLF &
                    "5" & CRLF & "world" & CRLF & "0" & CRLF & CRLF) /= 0);
         end;
         Send_Empty_Response;

         declare
            Request : constant String := Receive_Until (CRLF & CRLF);
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Request, "POST /short HTTP/1.1" & CRLF) /= 0);
         end;
         Expect_Close;

         Accept_Peer;
         declare
            Request : constant String := Receive_Until (CRLF & CRLF);
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Request, "POST /stalled HTTP/1.1" & CRLF) /= 0);
         end;
         Expect_Close;

         Accept_Peer;
         declare
            Request : constant String := Receive_Until (CRLF & CRLF);
         begin
            pragma Assert
              (Ada.Strings.Fixed.Index
                 (Request, "POST /failing HTTP/1.1" & CRLF) /= 0);
         end;
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
           ("streaming HTTP server failed: " &
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
      HTTP    : aliased Client.Client (Capacity => 1);
      Request : Client.Request;
   begin
      Client.Configure (HTTP, Origin);
      Client.Set_Method (Request, Flyology.HTTP.Methods.POST);

      Client.Set_Target (Request, "/known");
      declare
         Source   : String_Source :=
           (Value      => To_Unbounded_String ("abcdef"),
            Next       => 1,
            Chunk_Size => 2);
         Response : constant Client.Response := Client.Execute
           (HTTP, Request, Source, Client.Known_Length (6));
      begin
         pragma Assert (Client.Status (Response) = 200);
         pragma Assert (Client.Body_Complete (Response));
      end;

      Client.Set_Target (Request, "/unknown");
      declare
         Source   : String_Source :=
           (Value      => To_Unbounded_String ("helloworld"),
            Next       => 1,
            Chunk_Size => 5);
         Response : constant Client.Response :=
           Client.Execute (HTTP, Request, Source);
      begin
         pragma Assert (Client.Status (Response) = 200);
         pragma Assert (Client.Body_Complete (Response));
      end;

      Client.Set_Target (Request, "/short");
      declare
         Source : String_Source :=
           (Value      => To_Unbounded_String ("abc"),
            Next       => 1,
            Chunk_Size => 3);
         Raised : Boolean := False;
      begin
         begin
            declare
               Unexpected : Client.Response := Client.Execute
                 (HTTP, Request, Source, Client.Known_Length (5));
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Client.Request_Body_Error =>
               Raised := True;
         end;
         pragma Assert (Raised);
      end;

      Client.Set_Target (Request, "/stalled");
      declare
         Source : Stalled_Source;
         Raised : Boolean := False;
      begin
         begin
            declare
               Unexpected : Client.Response := Client.Execute
                 (HTTP, Request, Source);
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Client.Request_Body_Error =>
               Raised := True;
         end;
         pragma Assert (Raised);
      end;

      Client.Set_Target (Request, "/failing");
      declare
         Source : Failing_Source;
         Raised : Boolean := False;
      begin
         begin
            declare
               Unexpected : Client.Response := Client.Execute
                 (HTTP, Request, Source);
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Source_Failure =>
               Raised := True;
         end;
         pragma Assert (Raised);
      end;

      declare
         Source : Stalled_Source;
         Raised : Boolean := False;
      begin
         Client.Set_Body (Request, "retained");
         begin
            declare
               Unexpected : Client.Response := Client.Execute
                 (HTTP, Request, Source);
               pragma Unreferenced (Unexpected);
            begin
               null;
            end;
         exception
            when Constraint_Error =>
               Raised := True;
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
              ("lightweight streaming HTTP client failed: " &
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
           "lightweight streaming HTTP client did not finish";
      end select;
      pragma Assert (Passed);
   end;
   Coordination.Wait_Done (Server_OK);
   pragma Assert (Server_OK);
end HTTP_Client_Streaming_Smoke;
