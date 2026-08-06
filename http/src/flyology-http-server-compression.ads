with Ada.Strings.Unbounded;

--  Defines the optional response-compression encoder boundary.
--
--  The current Exchange sends fixed responses directly, so compression
--  middleware is deliberately deferred until a bounded response-transform
--  hook can preserve streaming, HEAD, no-body statuses, and partial-response
--  safety. This interface fixes the provider boundary without selecting a
--  compression dependency. Encoders must enforce an output bound and must not
--  be installed for responses that mix secrets with attacker-controlled data
--  unless the application has assessed compression side channels.
package Flyology.HTTP.Server.Compression is

   --  Caller-owned bounded response encoder.
   type Encoder is limited interface;

   --  Return the HTTP content-coding token implemented by the encoder.
   --  @param Item Encoder
   --  @return Content-coding token such as gzip
   function Content_Coding (Item : Encoder) return String is abstract;

   --  Return the maximum accepted input size for one buffered transform.
   --  @param Item Encoder
   --  @return Maximum input bytes
   function Maximum_Input (Item : Encoder) return Natural is abstract;

   --  Encode one complete representation. Implementations replace Output and
   --  raise Resource_Exhausted when their configured output bound is exceeded.
   --  @param Item Encoder
   --  @param Input Unencoded representation
   --  @param Output Encoded representation
   procedure Encode
     (Item   : in out Encoder;
      Input  : String;
      Output : out Ada.Strings.Unbounded.Unbounded_String) is abstract;

end Flyology.HTTP.Server.Compression;
