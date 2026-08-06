--  Adds preemptive Basic and Bearer credentials to an HTTP client request.
--  The request retains the generated Authorization value. This package does
--  not discover protection spaces, react to challenges, refresh credentials,
--  or conceal secrets from application logging.
package Flyology.HTTP.Client.Authentication is

   --  Remove every Authorization field while preserving all other request
   --  fields and their order.
   --  @param Item Request whose credentials are removed
   procedure Clear (Item : in out Request);

   --  Replace every Authorization field with RFC 6750 Bearer credentials.
   --  Token must use b64token syntax: one or more letters, digits, '-', '.',
   --  '_', '~', '+', or '/', followed by optional '=' padding. The request
   --  retains a copy. Send bearer credentials only over authenticated TLS or
   --  another channel providing equivalent confidentiality and integrity.
   --  @param Item Request whose credentials are replaced
   --  @param Token Bearer access token without the scheme name
   --  @exception Constraint_Error Token is empty or has invalid syntax
   --  @exception Flyology.HTTP.Headers.Headers_Too_Large The generated field
   --     exceeds the request's retained field bounds
   procedure Set_Bearer (Item : in out Request; Token : String);

   --  Replace every Authorization field with RFC 7617 Basic credentials.
   --  User_Id and Password are treated as already encoded octet strings using
   --  Ada Character positions. A caller using the challenge's UTF-8 option
   --  must supply normalized UTF-8 bytes. The request retains the Base64
   --  result, not the original strings. Basic credentials are not encrypted;
   --  send them only over authenticated TLS or equivalent protection.
   --  @param Item Request whose credentials are replaced
   --  @param User_Id User identifier without a colon or control character
   --  @param Password Password without a control character
   --  @exception Constraint_Error User_Id contains ':' or either input
   --     contains a control character
   --  @exception Flyology.HTTP.Headers.Headers_Too_Large The generated field
   --     exceeds the request's retained field bounds
   procedure Set_Basic
     (Item : in out Request; User_Id : String; Password : String);

end Flyology.HTTP.Client.Authentication;
