with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Text_IO.Text_Streams;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Headers;
with Flyology.HTTP.Methods;
with Flyology.IO.TLS.OpenSSL;

procedure HTTP_Client_CLI is
   package CLI renames Ada.Command_Line;
   package Client renames Flyology.HTTP.Client;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package Stream_IO renames Ada.Streams.Stream_IO;
   package Text_IO renames Ada.Text_IO;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Ada.Streams.Stream_Element_Offset;
   use type Flyology.HTTP.Origin_Scheme;

   Usage_Error : exception;

   type URL_Parts is record
      Origin_Value : Flyology.HTTP.Origin;
      Target       : Unbounded.Unbounded_String;
   end record;

   function Image (Value : Natural) return String is
      Result : constant String := Natural'Image (Value);
   begin
      return Result (Result'First + 1 .. Result'Last);
   end Image;

   function Trim_OWS (Value : String) return String is
      First : Natural := Value'First;
      Last  : Natural := Value'Last;
   begin
      while First <= Last
        and then Value (First) in ' ' | Character'Val (9)
      loop
         First := First + 1;
      end loop;
      while Last >= First
        and then Value (Last) in ' ' | Character'Val (9)
      loop
         Last := Last - 1;
      end loop;
      return Value (First .. Last);
   end Trim_OWS;

   function Parse_URL (Value : String) return URL_Parts is
      Scheme_End : constant Natural :=
        Ada.Strings.Fixed.Index (Value, "://");
      Authority_First : constant Natural :=
        (if Scheme_End = 0 then Value'Last + 1 else Scheme_End + 3);
      Boundary : Natural := 0;
   begin
      if Scheme_End = 0
        or else Authority_First > Value'Last
        or else Ada.Strings.Fixed.Index (Value, "#") /= 0
      then
         raise Usage_Error with
           "URL must be an absolute http:// or https:// URL " &
           "without a fragment";
      end if;
      for Index in Authority_First .. Value'Last loop
         if Value (Index) in '/' | '?' then
            Boundary := Index;
            exit;
         end if;
      end loop;
      if Boundary = 0 then
         return
           (Origin_Value => Flyology.HTTP.Parse_Origin (Value),
            Target       => Unbounded.To_Unbounded_String ("/"));
      end if;
      return
        (Origin_Value =>
           Flyology.HTTP.Parse_Origin
             (Value (Value'First .. Boundary - 1)),
         Target       => Unbounded.To_Unbounded_String
           ((if Value (Boundary) = '?'
             then "/" & Value (Boundary .. Value'Last)
             else Value (Boundary .. Value'Last))));
   end Parse_URL;

   function Host_Field (Value : Flyology.HTTP.Origin) return String is
      Origin_Text : constant String := Flyology.HTTP.Image (Value);
      Scheme_End  : constant Natural :=
        Ada.Strings.Fixed.Index (Origin_Text, "://");
   begin
      return Origin_Text (Scheme_End + 3 .. Origin_Text'Last);
   end Host_Field;

   procedure Usage (File : Text_IO.File_Type) is
   begin
      Text_IO.Put_Line
        (File,
         "usage: http_client_cli [options] URL" & ASCII.LF &
         "  -X, --request METHOD     request method (default GET)" & ASCII.LF &
         "  -I, --head               send HEAD" & ASCII.LF &
         "  -H, --header 'N: value'  append a request header" & ASCII.LF &
         "  -d, --data DATA          send a body; defaults method to POST" &
           ASCII.LF &
         "  -o, --output PATH        write body to PATH instead of stdout" &
           ASCII.LF &
         "      --timeout SECONDS    whole-exchange timeout (default 30)" &
           ASCII.LF &
         "      --max-body BYTES     output bound; zero is unlimited" &
           ASCII.LF &
         "      --ca-file PATH       PEM trust file for HTTPS" & ASCII.LF &
         "  -f, --fail               fail without output for HTTP >= 400" &
           ASCII.LF &
         "  -v, --verbose            trace headers and transport diagnostics" &
           ASCII.LF &
         "  -h, --help               show this help");
   end Usage;

   procedure Run is
      HTTP            : aliased Client.Client (Capacity => 1);
      Backend         : aliased OpenSSL.OpenSSL_Provider;
      Request         : Client.Request;
      Trace_Headers   : Flyology.HTTP.Headers.List;
      Trace_Method    : Unbounded.Unbounded_String :=
        Unbounded.To_Unbounded_String ("GET");
      Trace_Body_Size : Natural := 0;
      URL             : Unbounded.Unbounded_String;
      Output_Path     : Unbounded.Unbounded_String;
      CA_File         : Unbounded.Unbounded_String;
      Timeout         : Duration := 30.0;
      Max_Body        : Natural := 64 * 1_024 * 1_024;
      Method_Explicit : Boolean := False;
      Fail_On_Status  : Boolean := False;
      HTTP_Failed     : Boolean := False;
      Verbose         : Boolean := False;
      Index           : Positive := 1;

      function Next_Value (Option : String) return String is
      begin
         if Index = CLI.Argument_Count then
            raise Usage_Error with Option & " requires a value";
         end if;
         Index := Index + 1;
         return CLI.Argument (Index);
      end Next_Value;

      procedure Add_Header (Value : String) is
         Colon : constant Natural := Ada.Strings.Fixed.Index (Value, ":");
      begin
         if Colon = 0 or else Colon = Value'First then
            raise Usage_Error with "header must have the form Name: value";
         end if;
         Client.Add_Header
           (Request,
            Trim_OWS (Value (Value'First .. Colon - 1)),
            Trim_OWS (Value (Colon + 1 .. Value'Last)));
         Flyology.HTTP.Headers.Add
           (Trace_Headers,
            Trim_OWS (Value (Value'First .. Colon - 1)),
            Trim_OWS (Value (Colon + 1 .. Value'Last)));
      end Add_Header;
   begin
      while Index <= CLI.Argument_Count loop
         declare
            Argument : constant String := CLI.Argument (Index);
         begin
            if Argument in "-h" | "--help" then
               Usage (Text_IO.Standard_Output);
               return;
            elsif Argument in "-X" | "--request" then
               declare
                  Method : constant Flyology.HTTP.Method :=
                    Flyology.HTTP.To_Method (Next_Value (Argument));
               begin
                  Client.Set_Method (Request, Method);
                  Trace_Method := Unbounded.To_Unbounded_String
                    (Flyology.HTTP.Image (Method));
               end;
               Method_Explicit := True;
            elsif Argument in "-I" | "--head" then
               Client.Set_Method (Request, Flyology.HTTP.Methods.HEAD);
               Trace_Method := Unbounded.To_Unbounded_String ("HEAD");
               Method_Explicit := True;
            elsif Argument in "-H" | "--header" then
               Add_Header (Next_Value (Argument));
            elsif Argument in "-d" | "--data" then
               declare
                  Data : constant String := Next_Value (Argument);
               begin
                  Client.Set_Body (Request, Data);
                  Trace_Body_Size := Data'Length;
                  if not Method_Explicit then
                     Client.Set_Method (Request, Flyology.HTTP.Methods.POST);
                     Trace_Method := Unbounded.To_Unbounded_String ("POST");
                  end if;
               end;
            elsif Argument in "-o" | "--output" then
               Output_Path := Unbounded.To_Unbounded_String
                 (Next_Value (Argument));
            elsif Argument = "--timeout" then
               Timeout := Duration'Value (Next_Value (Argument));
            elsif Argument = "--max-body" then
               Max_Body := Natural'Value (Next_Value (Argument));
            elsif Argument = "--ca-file" then
               CA_File := Unbounded.To_Unbounded_String
                 (Next_Value (Argument));
            elsif Argument in "-f" | "--fail" then
               Fail_On_Status := True;
            elsif Argument in "-v" | "--verbose" then
               Verbose := True;
            elsif Argument'Length > 0 and then Argument (Argument'First) = '-'
            then
               raise Usage_Error with "unknown option: " & Argument;
            elsif Unbounded.Length (URL) /= 0 then
               raise Usage_Error with "only one URL may be requested";
            else
               URL := Unbounded.To_Unbounded_String (Argument);
            end if;
         end;
         Index := Index + 1;
      end loop;

      if Unbounded.Length (URL) = 0 then
         raise Usage_Error with "a URL is required";
      end if;

      declare
         Parts : constant URL_Parts := Parse_URL (Unbounded.To_String (URL));
         Pool  : constant Client.Pool_Configuration :=
           (Max_Idle                    => 0,
            Idle_Timeout                => 0.0,
            Max_Connection_Age          => 0.0,
            Max_Requests_Per_Connection => 1);
      begin
         Client.Set_Target (Request, Unbounded.To_String (Parts.Target));
         if Verbose then
            Text_IO.Put_Line
              (Text_IO.Standard_Error,
               "> " & Unbounded.To_String (Trace_Method) & " " &
                 Unbounded.To_String (Parts.Target) & " HTTP/1.1");
            Text_IO.Put_Line
              (Text_IO.Standard_Error,
               "> Host: " & Host_Field (Parts.Origin_Value));
            for Header_Index in
              1 .. Flyology.HTTP.Headers.Count (Trace_Headers)
            loop
               Text_IO.Put_Line
                 (Text_IO.Standard_Error,
                  "> " & Flyology.HTTP.Headers.Name
                    (Trace_Headers, Header_Index) & ": " &
                    Flyology.HTTP.Headers.Value
                      (Trace_Headers, Header_Index));
            end loop;
            if Trace_Body_Size > 0 then
               Text_IO.Put_Line
                 (Text_IO.Standard_Error,
                  "> Content-Length: " & Image (Trace_Body_Size));
            end if;
            Text_IO.Put_Line (Text_IO.Standard_Error, ">");
         end if;
         if Flyology.HTTP.Scheme (Parts.Origin_Value) =
           Flyology.HTTP.Secure_HTTPS
         then
            OpenSSL.Initialize_Client
              (Backend, CA_File => Unbounded.To_String (CA_File));
            Client.Configure
              (HTTP, Parts.Origin_Value, Backend'Access, Pool);
         else
            Client.Configure (HTTP, Parts.Origin_Value, Pool);
         end if;

         declare
            Reply       : Client.Response :=
              Client.Execute (HTTP, Request, Timeout => Timeout);
            Status      : constant Flyology.HTTP.Status_Code :=
              Client.Status (Reply);
            Reason      : constant String := Client.Reason_Phrase (Reply);
            Output      : Stream_IO.File_Type;
            Output_Open : Boolean := False;
            Total       : Long_Long_Integer := 0;

            procedure Emit (Data : Ada.Streams.Stream_Element_Array) is
            begin
               if Output_Open then
                  Stream_IO.Write (Output, Data);
               else
                  Ada.Text_IO.Text_Streams.Stream
                    (Text_IO.Standard_Output).all.Write (Data);
               end if;
            end Emit;
         begin
            if Verbose then
               Text_IO.Put_Line
                 (Text_IO.Standard_Error,
                  "< " & Flyology.HTTP.Image
                    (Client.Negotiated_Protocol (Reply)) &
                    " " & Image (Natural (Status)) &
                    (if Reason'Length = 0
                     then ""
                     else " " & Reason));
               for Header_Index in 1 .. Client.Header_Count (Reply) loop
                  Text_IO.Put_Line
                    (Text_IO.Standard_Error,
                     "< " & Client.Header_Name (Reply, Header_Index) & ": " &
                       Client.Header_Value (Reply, Header_Index));
               end loop;
               Text_IO.Put_Line (Text_IO.Standard_Error, "<");
            end if;

            HTTP_Failed := Fail_On_Status and then Status >= 400;
            if HTTP_Failed then
               Text_IO.Put_Line
                 (Text_IO.Standard_Error,
                  "http_client_cli: HTTP status " & Image (Natural (Status)));
            else
               if Unbounded.Length (Output_Path) /= 0
                 and then Unbounded.To_String (Output_Path) /= "-"
               then
                  Stream_IO.Create
                    (Output, Stream_IO.Out_File,
                     Unbounded.To_String (Output_Path));
                  Output_Open := True;
               end if;
               loop
                  declare
                     Buffer   : Ada.Streams.Stream_Element_Array
                       (1 .. 16 * 1_024);
                     Last     : Ada.Streams.Stream_Element_Offset;
                     Finished : Boolean;
                  begin
                     Client.Read_Body (Reply, Buffer, Last, Finished);
                     if Last >= Buffer'First then
                        declare
                           Count : constant Natural :=
                             Natural (Last - Buffer'First + 1);
                        begin
                           if Max_Body /= 0
                             and then Long_Long_Integer (Count) >
                               Long_Long_Integer (Max_Body) - Total
                           then
                              raise Client.Response_Too_Large with
                                "response exceeds --max-body";
                           end if;
                           Emit (Buffer (Buffer'First .. Last));
                           Total := Total + Long_Long_Integer (Count);
                        end;
                     end if;
                     exit when Finished;
                  end;
               end loop;
               if Output_Open then
                  Stream_IO.Close (Output);
                  Output_Open := False;
               else
                  Text_IO.Flush (Text_IO.Standard_Output);
               end if;
               if Verbose then
                  for Trailer_Index in 1 .. Client.Trailer_Count (Reply) loop
                     Text_IO.Put_Line
                       (Text_IO.Standard_Error,
                        "< " & Client.Trailer_Name (Reply, Trailer_Index) &
                          ": " & Client.Trailer_Value
                            (Reply, Trailer_Index));
                  end loop;
               end if;
            end if;
         exception
            when others =>
               if Output_Open then
                  Stream_IO.Close (Output);
               end if;
               raise;
         end;

         if Verbose then
            declare
               State : constant Client.Client_Diagnostics :=
                 Client.Diagnostics (HTTP);
            begin
               Text_IO.Put_Line
                 (Text_IO.Standard_Error,
                  "* transports created=" &
                    Image (State.Transports_Created) &
                    " reused=" & Image (State.Transport_Reuses) &
                    " closed=" & Image (State.Transports_Closed));
            end;
         end if;
         Client.Shutdown (HTTP);
         if HTTP_Failed then
            CLI.Set_Exit_Status (CLI.Failure);
         end if;
      end;
   end Run;
begin
   Run;
exception
   when Error : Usage_Error =>
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "http_client_cli: " & Ada.Exceptions.Exception_Message (Error));
      Usage (Text_IO.Standard_Error);
      CLI.Set_Exit_Status (CLI.Failure);
   when Error : others =>
      Text_IO.Put_Line
        (Text_IO.Standard_Error,
         "http_client_cli: " & Ada.Exceptions.Exception_Message (Error));
      CLI.Set_Exit_Status (CLI.Failure);
end HTTP_Client_CLI;
