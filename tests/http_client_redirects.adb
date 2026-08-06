with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Methods;
with Flyology.IO;
with Flyology.IO.Sockets;
with Interfaces.C;

procedure HTTP_Client_Redirects is
   package Client renames Flyology.HTTP.Client;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Streams;
   use Ada.Strings.Unbounded;
   use type Interfaces.C.int;
   use type Sockets.Selector_Status;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

   function Open_FD_Count return Interfaces.C.int
     with Import, Convention => C,
          External_Name => "flyology_test_open_fd_count";

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

   type One_Shot_Source is new Client.Request_Body_Source with record
      Position : Natural := 0;
   end record;

   overriding function Declared_Length
     (Item : One_Shot_Source) return Client.Body_Length is
     (Client.Known_Length (3));

   overriding procedure Read
     (Item     : in out One_Shot_Source;
      Data     : out Stream_Element_Array;
      Last     : out Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Text : constant String := "one";
      Count : constant Natural := Natural'Min
        (Natural (Data'Length), Text'Length - Item.Position);
   begin
      Last := Data'First - 1;
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
      Position : Natural := 0;
      Rewinds  : Natural := 0;
   end record;

   overriding procedure Rewind (Item : in out Retry_Source);

   overriding function Declared_Length
     (Item : Retry_Source) return Client.Body_Length is
     (Client.Known_Length (6));

   overriding procedure Read
     (Item     : in out Retry_Source;
      Data     : out Stream_Element_Array;
      Last     : out Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token)
   is
      pragma Unreferenced (Timeout, Token);
      Text : constant String := "replay";
      Count : constant Natural := Natural'Min
        (Natural (Data'Length), Text'Length - Item.Position);
   begin
      Last := Data'First - 1;
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

   generic
      Model : Flyology.Execution_Model;
   procedure Run_Lane;

   procedure Run_Lane is
      Listener : Sockets.Socket_Type;
      Address  : Sockets.Endpoint;

      protected Outcome is
         procedure Finish (Passed : Boolean);
         entry Wait (Passed : out Boolean);
      private
         Done : Boolean := False;
         OK   : Boolean := True;
      end Outcome;

      protected body Outcome is
         procedure Finish (Passed : Boolean) is
         begin
            OK := OK and Passed;
            Done := True;
         end Finish;

         entry Wait (Passed : out Boolean) when Done is
         begin
            Passed := OK;
         end Wait;
      end Outcome;
   begin
      Sockets.Create_Socket (Listener, Sockets.IPv4);
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener);
      Address := Sockets.Get_Socket_Name (Listener);

      declare
         task Server_Task;
         task Client_Task is
            pragma Task_Info (Model);
         end Client_Task;

         task body Server_Task is
            Peer : Sockets.Socket_Type;
            Peer_Address : Sockets.Endpoint;
            Status : Sockets.Selector_Status;

            function Read_Request return String is
               Buffer : Stream_Element_Array (1 .. 4_096);
               Last : Stream_Element_Offset;
               Data : Unbounded_String;
               Header_End : Natural := 0;
               Content_Length : Natural := 0;
            begin
               loop
                  Sockets.Receive (Peer, Buffer, Last, Timeout => 3.0);
                  pragma Assert (Last >= Buffer'First);
                  for Index in Buffer'First .. Last loop
                     Append (Data, Character'Val (Buffer (Index)));
                  end loop;
                  declare
                     Text : constant String := To_String (Data);
                     Marker : constant Natural :=
                       Ada.Strings.Fixed.Index (Text, CRLF & CRLF);
                  begin
                     if Marker /= 0 and then Header_End = 0 then
                        Header_End := Marker + 3;
                        declare
                           Prefix : constant String := "Content-Length: ";
                           Found : constant Natural :=
                             Ada.Strings.Fixed.Index (Text, Prefix);
                        begin
                           if Found /= 0 then
                              declare
                                 Stop : constant Natural :=
                                   Ada.Strings.Fixed.Index
                                     (Text, CRLF, From => Found);
                              begin
                                 Content_Length := Natural'Value
                                   (Text
                                      (Found + Prefix'Length .. Stop - 1));
                              end;
                           end if;
                        end;
                     end if;
                     exit when Header_End /= 0
                       and then Text'Length >= Header_End + Content_Length;
                  end;
               end loop;
               return To_String (Data);
            end Read_Request;

            procedure Accept_Peer is
            begin
               Sockets.Accept_Socket
                 (Listener, Peer, Peer_Address, Timeout => 3.0,
                  Status => Status);
               pragma Assert (Status = Sockets.Completed);
            end Accept_Peer;

            procedure Send (Value : String) is
            begin
               Sockets.Send_All (Peer, Bytes (Value), Timeout => 3.0);
            end Send;

            procedure Close_Peer is
            begin
               if Sockets.Is_Open (Peer) then
                  Sockets.Close_Socket (Peer);
               end if;
            exception
               when others => null;
            end Close_Peer;

            procedure Assert_Line (Wire, Line : String) is
            begin
               pragma Assert
                 (Ada.Strings.Fixed.Index (Wire, Line & CRLF) /= 0);
            end Assert_Line;
         begin
            --  Default policy returns the redirect and its body.
            Accept_Peer;
            Assert_Line (Read_Request, "GET /default HTTP/1.1");
            Send
              ("HTTP/1.1 302 Found" & CRLF &
               "Location: /unused" & CRLF &
               "Content-Length: 4" & CRLF &
               "Connection: close" & CRLF & CRLF & "stay");
            Close_Peer;

            --  302 rewrites POST to GET, resolves dot segments, strips the
            --  fragment, drains the body, and follows an absolute same-origin
            --  303 on the reused transport.
            Accept_Peer;
            declare
               Wire : constant String := Read_Request;
            begin
               Assert_Line (Wire, "POST /dir/start?old=1 HTTP/1.1");
               Assert_Line (Wire, "Content-Length: 3");
               pragma Assert (Wire (Wire'Last - 2 .. Wire'Last) = "abc");
            end;
            Send
              ("HTTP/1.1 302 Found" & CRLF &
               "Location: ../next?x=1#ignored" & CRLF &
               "Content-Length: 4" & CRLF & CRLF & "skip");
            declare
               Wire : constant String := Read_Request;
            begin
               Assert_Line (Wire, "GET /next?x=1 HTTP/1.1");
               pragma Assert
                 (Ada.Strings.Fixed.Index (Wire, "Content-Type:") = 0);
               pragma Assert
                 (Ada.Strings.Fixed.Index (Wire, "Content-Length:") = 0);
            end;
            Send
              ("HTTP/1.1 303 See Other" & CRLF & "Location: http://127.0.0.1:" &
               Decimal (Natural (Address.Port)) &
               "/final" & CRLF & "Content-Length: 0" & CRLF & CRLF);
            Assert_Line (Read_Request, "GET /final HTTP/1.1");
            Send
              ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 2" & CRLF &
               "Connection: close" & CRLF & CRLF & "ok");
            Close_Peer;

            --  307 preserves PUT and rewinds a repeatable source.
            Accept_Peer;
            declare
               Wire : constant String := Read_Request;
            begin
               Assert_Line (Wire, "PUT /upload HTTP/1.1");
               pragma Assert (Wire (Wire'Last - 5 .. Wire'Last) = "replay");
            end;
            Send
              ("HTTP/1.1 307 Temporary Redirect" & CRLF &
               "Location: /upload-again" & CRLF &
               "Content-Length: 0" & CRLF & CRLF);
            declare
               Wire : constant String := Read_Request;
            begin
               Assert_Line (Wire, "PUT /upload-again HTTP/1.1");
               pragma Assert (Wire (Wire'Last - 5 .. Wire'Last) = "replay");
            end;
            Send
              ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 0" & CRLF &
               "Connection: close" & CRLF & CRLF);
            Close_Peer;

            --  The remaining failures are rejected before another request.
            Accept_Peer;
            Assert_Line (Read_Request, "PUT /one-shot HTTP/1.1");
            Send
              ("HTTP/1.1 307 Temporary Redirect" & CRLF &
               "Location: /again" & CRLF & "Content-Length: 0" & CRLF & CRLF);
            Close_Peer;

            Accept_Peer;
            Assert_Line (Read_Request, "GET /cross HTTP/1.1");
            Send
              ("HTTP/1.1 302 Found" & CRLF &
               "Location: http://127.0.0.1:1/elsewhere" & CRLF &
               "Content-Length: 5" & CRLF & "Connection: close" & CRLF &
               CRLF & "cross");
            Close_Peer;

            Accept_Peer;
            Assert_Line (Read_Request, "GET /cycle HTTP/1.1");
            Send
              ("HTTP/1.1 308 Permanent Redirect" & CRLF &
               "Location: /cycle" & CRLF & "Content-Length: 0" & CRLF & CRLF);
            Close_Peer;

            Accept_Peer;
            Assert_Line (Read_Request, "GET /limit HTTP/1.1");
            Send
              ("HTTP/1.1 301 Moved Permanently" & CRLF &
               "Location: /next" & CRLF & "Content-Length: 0" & CRLF & CRLF);
            Close_Peer;

            Accept_Peer;
            Assert_Line (Read_Request, "GET /duplicate HTTP/1.1");
            Send
              ("HTTP/1.1 302 Found" & CRLF & "Location: /one" & CRLF &
               "Location: /two" & CRLF & "Content-Length: 0" & CRLF & CRLF);
            Close_Peer;

            --  One deadline spans time spent before both response heads.
            Accept_Peer;
            Assert_Line (Read_Request, "GET /deadline HTTP/1.1");
            delay 0.12;
            Send
              ("HTTP/1.1 302 Found" & CRLF &
               "Location: /deadline-final" & CRLF &
               "Content-Length: 0" & CRLF & CRLF);
            Assert_Line (Read_Request, "GET /deadline-final HTTP/1.1");
            delay 0.12;
            begin
               Send
                 ("HTTP/1.1 200 OK" & CRLF & "Content-Length: 0" & CRLF &
                  "Connection: close" & CRLF & CRLF);
            exception
               when others => null;
            end;
            Close_Peer;
         exception
            when Error : others =>
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "redirect server: " & Ada.Exceptions.Exception_Information
                    (Error));
               Close_Peer;
               Outcome.Finish (False);
         end Server_Task;

         task body Client_Task is
            HTTP : aliased Client.Client (Capacity => 1);
            Origin : constant Flyology.HTTP.Origin :=
              Flyology.HTTP.Parse_Origin
                ("http://127.0.0.1:" &
                 Decimal (Natural (Address.Port)));
            Follow : constant Client.Redirect_Configuration :=
              Client.Default_Same_Origin_Redirects;
            Passed : Boolean := True;

            procedure Expect_Redirect_Error
              (Target : String; Limit : Client.Redirect_Limit := 5)
            is
               Request : Client.Request;
            begin
               Client.Set_Target (Request, Target);
               Client.Set_Redirects
                 (Request,
                  (Mode => Client.Follow_Same_Origin,
                   Maximum_Hops => Limit));
               declare
                  Reply : Client.Response := Client.Execute (HTTP, Request);
                  pragma Unreferenced (Reply);
               begin
                  Passed := False;
               end;
            exception
               when Client.Redirect_Error => null;
               when others => Passed := False;
            end Expect_Redirect_Error;
         begin
            Client.Configure (HTTP, Origin);

            declare
               Request : Client.Request;
            begin
               Client.Set_Target (Request, "/default");
               declare
                  Reply : Client.Response := Client.Execute (HTTP, Request);
               begin
                  Passed := Passed and then Client.Status (Reply) = 302
                    and then Flyology.Bytes.To_Byte_String
                      (Client.Read_All (Reply)) = "stay";
               end;
            end;

            declare
               Request : Client.Request;
            begin
               Client.Set_Method (Request, Flyology.HTTP.Methods.POST);
               Client.Set_Target (Request, "/dir/start?old=1");
               Client.Add_Header (Request, "Content-Type", "text/plain");
               Client.Set_Body (Request, "abc");
               Client.Set_Redirects (Request, Follow);
               declare
                  Reply : Client.Response := Client.Execute (HTTP, Request);
               begin
                  Passed := Passed and then Client.Status (Reply) = 200
                    and then Flyology.Bytes.To_Byte_String
                      (Client.Read_All (Reply)) = "ok";
               end;
            end;

            declare
               Request : Client.Request;
               Source : Retry_Source;
            begin
               Client.Set_Method (Request, Flyology.HTTP.Methods.PUT);
               Client.Set_Target (Request, "/upload");
               Client.Set_Redirects (Request, Follow);
               declare
                  Reply : Client.Response :=
                    Client.Execute (HTTP, Request, Source);
               begin
                  Passed := Passed and then Client.Status (Reply) = 200
                    and then Source.Rewinds = 1;
                  declare
                     Ignored : constant Flyology.Bytes.Unbounded_Bytes :=
                       Client.Read_All (Reply);
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
               end;
            end;

            declare
               Request : Client.Request;
               Source : One_Shot_Source;
               Rejected : Boolean := False;
            begin
               Client.Set_Method (Request, Flyology.HTTP.Methods.PUT);
               Client.Set_Target (Request, "/one-shot");
               Client.Set_Redirects (Request, Follow);
               begin
                  declare
                     Reply : Client.Response :=
                       Client.Execute (HTTP, Request, Source);
                     pragma Unreferenced (Reply);
                  begin
                     null;
                  end;
               exception
                  when Client.Redirect_Error => Rejected := True;
                  when others => null;
               end;
               Passed := Passed and then Rejected;
            end;

            declare
               Request : Client.Request;
            begin
               Client.Set_Target (Request, "/cross");
               Client.Set_Redirects (Request, Follow);
               declare
                  Reply : Client.Response := Client.Execute (HTTP, Request);
               begin
                  Passed := Passed and then Client.Status (Reply) = 302
                    and then Flyology.Bytes.To_Byte_String
                      (Client.Read_All (Reply)) = "cross";
               end;
            end;

            Expect_Redirect_Error ("/cycle");
            Expect_Redirect_Error ("/limit", 0);
            Expect_Redirect_Error ("/duplicate");
            declare
               Request : Client.Request;
            begin
               Client.Set_Target (Request, "/deadline");
               Client.Set_Redirects (Request, Follow);
               declare
                  Reply : Client.Response :=
                    Client.Execute (HTTP, Request, Timeout => 0.2);
                  pragma Unreferenced (Reply);
               begin
                  Passed := False;
               end;
            exception
               when Flyology.IO.Timeout_Error => null;
               when others => Passed := False;
            end;
            Client.Shutdown (HTTP);
            declare
               Snapshot : constant Client.Client_Diagnostics :=
                 Client.Diagnostics (HTTP);
            begin
               Passed := Passed
                 and then Snapshot.Pending_Transports = 0
                 and then Snapshot.Active_Exchanges = 0
                 and then Snapshot.Reusable_Transports = 0
                 and then Snapshot.Closing_Transports = 0;
            end;
            Outcome.Finish (Passed);
         exception
            when Error : others =>
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "redirect client: " & Ada.Exceptions.Exception_Information
                    (Error));
               Outcome.Finish (False);
         end Client_Task;
      begin
         null;
      end;

      declare
         Passed : Boolean;
      begin
         Outcome.Wait (Passed);
         if Sockets.Is_Open (Listener) then
            Sockets.Close_Socket (Listener);
         end if;
         pragma Assert (Passed);
      end;
   end Run_Lane;

   procedure Run_Native is new Run_Lane (Flyology.Native_Task);
   procedure Run_Lightweight is new Run_Lane (Flyology.Lightweight_Task);
begin
   Run_Native;
   Run_Lightweight;
   declare
      Baseline : constant Interfaces.C.int := Open_FD_Count;
   begin
      Run_Native;
      Run_Lightweight;
      pragma Assert (Open_FD_Count = Baseline);
   end;
   Ada.Text_IO.Put_Line ("HTTP client redirects passed");
end HTTP_Client_Redirects;
