package body HTTP_Client_RFC_Seeds is

   CRLF : constant String := Character'Val (13) & Character'Val (10);
   HTAB : constant Character := Character'Val (9);
   Bare_CR : constant Character := Character'Val (13);
   Backslash : constant Character := Character'Val (16#5C#);
   Obs_Text : constant Character := Character'Val (16#FF#);

   function Name (Index : Seed_Index) return String is
   begin
      case Index is
         when 1  => return "fixed-length response";
         when 2  => return "empty reason phrase separator";
         when 3  => return "obs-text reason phrase";
         when 4  => return "empty field with OWS";
         when 5  => return "obsolete folded response field";
         when 6  => return "equal Content-Length list";
         when 7  => return "case-insensitive chunked coding";
         when 8  => return "token and quoted chunk extensions";
         when 9  => return "last-chunk extension and trailer";
         when 10 => return "multiple informational responses";
         when 11 => return "304 representation length";
         when 12 => return "304 hypothetical transfer coding";
         when 13 => return "zero-length 205 response";
         when 14 => return "close-delimited response";
         when 15 => return "leading-zero chunk size";
         when 16 => return "obs-text field value";
         when 17 => return "repeated equal Content-Length fields";
         when 18 => return "HTAB reason phrase";
         when 19 => return "missing reason separator";
         when 20 => return "lowercase HTTP version";
         when 21 => return "out-of-range status code";
         when 22 => return "control in reason phrase";
         when 23 => return "bare CR in field value";
         when 24 => return "whitespace before field colon";
         when 25 => return "whitespace before first field";
         when 26 => return "empty Content-Length";
         when 27 => return "signed Content-Length";
         when 28 => return "empty Content-Length list member";
         when 29 => return "conflicting Content-Length values";
         when 30 => return "Transfer-Encoding with Content-Length";
         when 31 => return "HTTP/1.0 Transfer-Encoding";
         when 32 => return "repeated chunked transfer coding";
         when 33 => return "parameterized chunked coding";
         when 34 => return "leading whitespace in chunk size";
         when 35 => return "empty chunk extension name";
         when 36 => return "invalid chunk extension token";
         when 37 => return "unterminated quoted chunk extension";
         when 38 => return "bare CR in quoted chunk extension";
         when 39 => return "incomplete fixed-length body";
         when 40 => return "incomplete chunked body";
         when 41 => return "forbidden Content-Length trailer";
         when 42 => return "body framing on informational response";
      end case;
   end Name;

   function Reference (Index : Seed_Index) return String is
   begin
      case Index is
         when 1 | 14 | 39 =>
            return "RFC 9112 Section 6.3";
         when 2 | 3 | 18 | 19 | 22 =>
            return "RFC 9112 Section 4";
         when 4 | 16 | 23 =>
            return "RFC 9110 Section 5.5 and RFC 9112 Section 2.2";
         when 5 =>
            return "RFC 9112 Section 5.2";
         when 6 | 17 | 26 .. 29 =>
            return "RFC 9110 Section 8.6 and RFC 9112 Section 6.3";
         when 7 | 12 | 31 .. 33 =>
            return "RFC 9112 Section 6.1";
         when 8 | 9 | 15 | 34 .. 38 | 40 =>
            return "RFC 9112 Sections 7.1 through 7.1.2";
         when 10 =>
            return "RFC 9110 Section 15.2";
         when 11 =>
            return "RFC 9110 Sections 8.6 and 15.4.5";
         when 13 =>
            return "RFC 9110 Section 15.3.6";
         when 20 =>
            return "RFC 9112 Section 2.3";
         when 21 =>
            return "RFC 9110 Section 15";
         when 24 | 25 =>
            return "RFC 9112 Section 5.1";
         when 30 =>
            return "RFC 9112 Section 6.3";
         when 41 =>
            return "RFC 9110 Section 6.5.1";
         when 42 =>
            return "RFC 9110 Section 8.6";
      end case;
   end Reference;

   function Expected (Index : Seed_Index) return Expected_Result is
     (if Index <= 18 then Accept_Input else Reject_Input);

   function Payload (Index : Seed_Index) return String is
   begin
      case Index is
         when 1 =>
            return
              "HTTP/1.1 200 OK" & CRLF &
              "Content-Length: 5" & CRLF & CRLF & "hello";
         when 2 =>
            return "HTTP/1.1 200 " & CRLF & "Content-Length: 0" &
              CRLF & CRLF;
         when 3 =>
            return "HTTP/1.1 200 accepted" & Obs_Text & CRLF &
              "Content-Length: 0" & CRLF & CRLF;
         when 4 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "X-Empty:" & HTAB & " " & HTAB & CRLF &
              "Content-Length: 0" & CRLF & CRLF;
         when 5 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "X-Folded: first" & CRLF & HTAB & "second" & CRLF &
              "Content-Length: 0" & CRLF & CRLF;
         when 6 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Content-Length: 005 , 5" & CRLF & CRLF & "hello";
         when 7 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Transfer-Encoding: CHUNKED" & CRLF & CRLF &
              "1" & CRLF & "x" & CRLF & "0" & CRLF & CRLF;
         when 8 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Transfer-Encoding: chunked" & CRLF & CRLF &
              "1 ; foo = token ; quoted = ""a" & Backslash & "b""" &
              CRLF & "x" & CRLF & "0" & CRLF & CRLF;
         when 9 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Transfer-Encoding: chunked" & CRLF & CRLF &
              "0;done=yes" & CRLF & "X-Result: ok" & CRLF & CRLF;
         when 10 =>
            return "HTTP/1.1 100 Continue" & CRLF & CRLF &
              "HTTP/1.1 103 Early Hints" & CRLF &
              "Link: </style.css>" & CRLF & CRLF &
              "HTTP/1.1 200 OK" & CRLF & "Content-Length: 0" &
              CRLF & CRLF;
         when 11 =>
            return "HTTP/1.1 304 Not Modified" & CRLF &
              "Content-Length: 123" & CRLF & CRLF;
         when 12 =>
            return "HTTP/1.1 304 Not Modified" & CRLF &
              "Transfer-Encoding: chunked" & CRLF & CRLF;
         when 13 =>
            return "HTTP/1.1 205 Reset Content" & CRLF &
              "Content-Length: 0" & CRLF & CRLF;
         when 14 =>
            return "HTTP/1.1 200 OK" & CRLF & "Connection: close" &
              CRLF & CRLF & "until-close";
         when 15 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Transfer-Encoding: chunked" & CRLF & CRLF &
              "000A" & CRLF & "0123456789" & CRLF & "000" &
              CRLF & CRLF;
         when 16 =>
            return "HTTP/1.1 200 OK" & CRLF & "X-Bytes: " & Obs_Text &
              CRLF & "Content-Length: 0" & CRLF & CRLF;
         when 17 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Content-Length: 5" & CRLF &
              "Content-Length: 5, 005" & CRLF & CRLF & "hello";
         when 18 =>
            return "HTTP/1.1 200 " & HTAB & "Nope" & CRLF &
              "Content-Length: 0" & CRLF & CRLF;
         when 19 =>
            return "HTTP/1.1 200" & CRLF & "Content-Length: 0" &
              CRLF & CRLF;
         when 20 =>
            return "http/1.1 200 OK" & CRLF & "Content-Length: 0" &
              CRLF & CRLF;
         when 21 =>
            return "HTTP/1.1 099 Invalid" & CRLF &
              "Content-Length: 0" & CRLF & CRLF;
         when 22 =>
            return "HTTP/1.1 200 bad" & Character'Val (1) & CRLF &
              "Content-Length: 0" & CRLF & CRLF;
         when 23 =>
            return "HTTP/1.1 200 OK" & CRLF & "X-Bare: a" & Bare_CR &
              "b" & CRLF & "Content-Length: 0" & CRLF & CRLF;
         when 24 =>
            return "HTTP/1.1 200 OK" & CRLF & "Content-Length : 0" &
              CRLF & CRLF;
         when 25 =>
            return "HTTP/1.1 200 OK" & CRLF &
              " Content-Length: 0" & CRLF & CRLF;
         when 26 =>
            return "HTTP/1.1 200 OK" & CRLF & "Content-Length:" &
              CRLF & CRLF;
         when 27 =>
            return "HTTP/1.1 200 OK" & CRLF & "Content-Length: +5" &
              CRLF & CRLF & "hello";
         when 28 =>
            return "HTTP/1.1 200 OK" & CRLF & "Content-Length: 5," &
              CRLF & CRLF & "hello";
         when 29 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Content-Length: 5, 6" & CRLF & CRLF & "hello!";
         when 30 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Transfer-Encoding: chunked" & CRLF &
              "Content-Length: 0" & CRLF & CRLF & "0" & CRLF & CRLF;
         when 31 =>
            return "HTTP/1.0 200 OK" & CRLF &
              "Transfer-Encoding: chunked" & CRLF & CRLF &
              "0" & CRLF & CRLF;
         when 32 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Transfer-Encoding: chunked, chunked" & CRLF & CRLF &
              "0" & CRLF & CRLF;
         when 33 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Transfer-Encoding: chunked;level=1" & CRLF & CRLF &
              "0" & CRLF & CRLF;
         when 34 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Transfer-Encoding: chunked" & CRLF & CRLF &
              " 1" & CRLF & "x" & CRLF & "0" & CRLF & CRLF;
         when 35 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Transfer-Encoding: chunked" & CRLF & CRLF &
              "1;" & CRLF & "x" & CRLF & "0" & CRLF & CRLF;
         when 36 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Transfer-Encoding: chunked" & CRLF & CRLF &
              "1;bad name=x" & CRLF & "x" & CRLF &
              "0" & CRLF & CRLF;
         when 37 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Transfer-Encoding: chunked" & CRLF & CRLF &
              "1;q=""unterminated" & CRLF & "x" & CRLF &
              "0" & CRLF & CRLF;
         when 38 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Transfer-Encoding: chunked" & CRLF & CRLF &
              "1;q=""a" & Bare_CR & "b""" & CRLF & "x" & CRLF &
              "0" & CRLF & CRLF;
         when 39 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Content-Length: 5" & CRLF & CRLF & "four";
         when 40 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Transfer-Encoding: chunked" & CRLF & CRLF &
              "1" & CRLF & "x" & CRLF;
         when 41 =>
            return "HTTP/1.1 200 OK" & CRLF &
              "Transfer-Encoding: chunked" & CRLF & CRLF &
              "0" & CRLF & "Content-Length: 0" & CRLF & CRLF;
         when 42 =>
            return "HTTP/1.1 103 Early Hints" & CRLF &
              "Content-Length: 0" & CRLF & CRLF &
              "HTTP/1.1 200 OK" & CRLF & "Content-Length: 0" &
              CRLF & CRLF;
      end case;
   end Payload;

end HTTP_Client_RFC_Seeds;
