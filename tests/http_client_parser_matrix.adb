with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.HTTP;
with Flyology.HTTP.Client;
with Flyology.HTTP.Client.Testing;
with Flyology.HTTP.Headers;

procedure HTTP_Client_Parser_Matrix is
   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;

   CRLF : constant String := Character'Val (13) & Character'Val (10);

   function Bytes (Value : String) return Ada.Streams.Stream_Element_Array is
      Result : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Value'Length));
   begin
      for Offset in 0 .. Value'Length - 1 loop
         Result (Result'First + Ada.Streams.Stream_Element_Offset (Offset)) :=
           Ada.Streams.Stream_Element
             (Character'Pos (Value (Value'First + Offset)));
      end loop;
      return Result;
   end Bytes;

   procedure Validate (Value : String) is
   begin
      Flyology.HTTP.Client.Testing.Validate_Response (Bytes (Value));
   end Validate;

   procedure Reject_Protocol (Value : String) is
      Raised : Boolean := False;
   begin
      begin
         Validate (Value);
      exception
         when Flyology.HTTP.Protocol_Error =>
            Raised := True;
      end;
      pragma Assert (Raised);
   end Reject_Protocol;

   procedure Reject_Size (Value : String) is
      Raised : Boolean := False;
   begin
      begin
         Validate (Value);
      exception
         when Flyology.HTTP.Client.Response_Too_Large =>
            Raised := True;
      end;
      pragma Assert (Raised);
   end Reject_Size;

   function Decimal (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
   begin
      return Image (Image'First + 1 .. Image'Last);
   end Decimal;

   function Header_Block (Count : Natural) return String is
      Result : Unbounded_String := To_Unbounded_String
        ("HTTP/1.1 200 OK" & CRLF);
   begin
      for Index in 1 .. Count loop
         Append (Result, "X-" & Decimal (Index) & ": value" & CRLF);
      end loop;
      Append (Result, "Content-Length: 0" & CRLF & CRLF);
      return To_String (Result);
   end Header_Block;

   Head_Prefix : constant String :=
     "HTTP/1.1 200 OK" & CRLF & "X: ";
   Head_Suffix : constant String := CRLF;
   Exact_Value_Length : constant Natural :=
     Flyology.HTTP.Headers.Default_Max_Bytes
       - Head_Prefix'Length - Head_Suffix'Length;
begin
   Validate
     ("HTTP/1.1 200 OK" & CRLF &
      "Content-Length: 5" & CRLF & CRLF & "hello");
   Validate
     ("HTTP/1.1 200 OK" & CRLF &
      "Content-Length: 5" & CRLF &
      "Content-Length: 5" & CRLF & CRLF & "hello");
   Validate
     ("HTTP/1.1 200 OK" & CRLF &
      "Content-Length: 5, 5" & CRLF & CRLF & "hello");
   Validate
     ("HTTP/1.1 200 OK" & CRLF &
      "Content-Length: 0" & CRLF & CRLF);
   Validate
     ("HTTP/1.1 200 OK" & CRLF &
      "Transfer-Encoding: chunked" & CRLF & CRLF &
      "A" & CRLF & "0123456789" & CRLF &
      "a;extension=yes" & CRLF & "abcdefghij" & CRLF &
      "0" & CRLF & "X-Trailer: value" & CRLF & CRLF);
   Validate
     ("HTTP/1.1 103 Early Hints" & CRLF &
      "Link: </x>" & CRLF & CRLF &
      "HTTP/1.1 304 Not Modified" & CRLF &
      "Content-Length: 17" & CRLF & CRLF);

   Reject_Protocol ("HTTP/1.1 200 OK" & CRLF);
   Reject_Protocol
     ("HTTP/1.1 200 OK" & CRLF & ": value" & CRLF & CRLF);
   Reject_Protocol
     ("HTTP/1.1 200 OK" & CRLF & "Bad Name: x" & CRLF & CRLF);
   Reject_Protocol
     ("HTTP/1.1 200 OK" & CRLF & "X: " & Character'Val (1) &
      CRLF & CRLF);
   Reject_Protocol
     ("HTTP/1.1 200 OK" & CRLF &
      "Content-Length: 5, 6" & CRLF & CRLF & "hello!");
   Reject_Protocol
     ("HTTP/1.1 200 OK" & CRLF &
      "Content-Length: 999999999999999999999999999999999999" &
      CRLF & CRLF);
   Reject_Protocol
     ("HTTP/1.1 200 OK" & CRLF &
      "Transfer-Encoding: gzip, chunked" & CRLF & CRLF &
      "0" & CRLF & CRLF);
   Reject_Protocol
     ("HTTP/1.1 200 OK" & CRLF &
      "Transfer-Encoding: chunked" & CRLF & CRLF &
      "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF" & CRLF);
   Reject_Protocol
     ("HTTP/1.1 200 OK" & CRLF &
      "Transfer-Encoding: chunked" & CRLF & CRLF &
      "1" & CRLF & "xX");
   Reject_Protocol
     ("HTTP/1.1 200 OK" & CRLF &
      "Transfer-Encoding: chunked" & CRLF & CRLF &
      "0" & CRLF & "Content-Length: 0" & CRLF & CRLF);
   Reject_Protocol
     ("HTTP/1.1 200 OK" & CRLF &
      "Transfer-Encoding: chunked" & CRLF & CRLF &
      "0" & CRLF & "X: incomplete" & CRLF);
   Reject_Protocol
     ("HTTP/1.1 204 No Content" & CRLF &
      "Content-Length: 0" & CRLF & CRLF);
   Reject_Protocol
     ("HTTP/1.1 103 Early Hints" & CRLF &
      "Content-Length: 0" & CRLF & CRLF &
      "HTTP/1.1 200 OK" & CRLF & "Content-Length: 0" & CRLF & CRLF);

   Validate
     (Head_Prefix & String'(1 .. Exact_Value_Length => 'a') &
      Head_Suffix & CRLF);
   Reject_Size
     (Head_Prefix & String'(1 .. Exact_Value_Length + 1 => 'a') &
      Head_Suffix & CRLF);
   Validate (Header_Block (Flyology.HTTP.Headers.Default_Capacity - 1));
   Reject_Size (Header_Block (Flyology.HTTP.Headers.Default_Capacity));
end HTTP_Client_Parser_Matrix;
