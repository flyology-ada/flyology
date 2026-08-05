with Ada.Strings.Unbounded;

--  Defines protocol concepts shared by Flyology HTTP clients and servers.
package Flyology.HTTP is

   --  Raised for malformed or unsupported HTTP protocol input.
   Protocol_Error : exception;

   --  Parsed HTTP protocol version.
   --  @enum HTTP_1_0 HTTP/1.0 message
   --  @enum HTTP_1_1 HTTP/1.1 message
   type HTTP_Version is (HTTP_1_0, HTTP_1_1);

   --  Validated, case-sensitive HTTP method token. The representation is not
   --  an enumeration because HTTP permits extension methods.
   type Method is private;

   --  Construct a method while preserving its exact wire spelling.
   --  @param Value Nonempty HTTP token of at most 64 bytes
   --  @return Validated method
   --  @exception Constraint_Error Value is empty, oversized, or not a token
   function To_Method (Value : String) return Method;

   --  Return the exact method spelling.
   --  @param Value Method to format
   --  @return Original case-sensitive token
   function Image (Value : Method) return String;

   --  Report whether the standardized method has safe semantics. Unknown
   --  extension methods are conservatively classified as unsafe.
   --  @param Value Method to classify
   --  @return True for GET, HEAD, OPTIONS, or TRACE
   function Is_Safe (Value : Method) return Boolean;

   --  Report whether the standardized method has idempotent semantics.
   --  Unknown extension methods are conservatively classified as
   --  non-idempotent.
   --  @param Value Method to classify
   --  @return True for safe methods plus PUT and DELETE
   function Is_Idempotent (Value : Method) return Boolean;

   --  Scheme represented by an HTTP origin.
   --  @enum Plain_HTTP Cleartext HTTP
   --  @enum Secure_HTTPS HTTP over authenticated TLS
   type Origin_Scheme is (Plain_HTTP, Secure_HTTPS);

   --  Nonzero TCP port represented independently of socket implementation.
   type Port_Number is range 1 .. 65_535;

   --  Normalized HTTP origin containing only scheme, host, and port.
   type Origin is private;

   --  Parse an absolute HTTP(S) origin. The input must not contain userinfo,
   --  a path other than one trailing slash, a query, or a fragment. DNS names
   --  are lower-cased; bracketed IPv6 literals retain their bracket-free
   --  spelling. Omitted ports become 80 or 443.
   --  @param Value Absolute origin text
   --  @return Parsed normalized origin
   --  @exception Constraint_Error Value is not a supported HTTP(S) origin
   function Parse_Origin (Value : String) return Origin;

   --  Return the origin scheme.
   --  @param Value Origin to inspect
   --  @return Plain_HTTP or Secure_HTTPS
   function Scheme (Value : Origin) return Origin_Scheme;

   --  Return the normalized DNS name or numeric address without IPv6 brackets.
   --  @param Value Origin to inspect
   --  @return Origin host
   function Host (Value : Origin) return String;

   --  Return the effective origin port, including a scheme default.
   --  @param Value Origin to inspect
   --  @return TCP port
   function Port (Value : Origin) return Port_Number;

   --  Format the normalized origin, omitting a default port.
   --  @param Value Origin to format
   --  @return Absolute origin without a trailing slash
   function Image (Value : Origin) return String;

   --  Opaque negotiated HTTP protocol. Constants can grow without exposing an
   --  enumeration that forces exhaustive downstream case statements.
   type Protocol is private;

   --  Negotiated HTTP/1.1 protocol.
   HTTP_1_1_Protocol : constant Protocol;

   --  Return the conventional protocol spelling.
   --  @param Value Protocol to format
   --  @return Protocol name
   function Image (Value : Protocol) return String;

   --  Three-digit HTTP status code.
   subtype Status_Code is Positive range 100 .. 599;

private
   type Method is record
      Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Origin is record
      Scheme_Value : Origin_Scheme := Plain_HTTP;
      Host_Value   : Ada.Strings.Unbounded.Unbounded_String;
      Port_Value   : Port_Number := 80;
   end record;

   type Protocol is new Positive;
   HTTP_1_1_Protocol : constant Protocol := 1;

end Flyology.HTTP;
