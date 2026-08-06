with Flyology.HTTP.Server.Applications;

--  Supplies lazy request-component helpers above an application exchange.
package Flyology.HTTP.Server.Requests is

   --  Return one decoded query occurrence. Names and values use percent
   --  decoding, and plus represents space only in the query. Duplicate keys
   --  retain wire order. Malformed escapes raise Protocol_Error.
   --  @param X Request exchange
   --  @param Name Decoded case-sensitive key
   --  @param Occurrence One-based duplicate occurrence
   --  @return Decoded value or an empty string
   function Query
     (X          : Applications.Exchange;
      Name       : String;
      Occurrence : Positive := 1) return String;

   --  Report whether one decoded query occurrence exists.
   --  @param X Request exchange
   --  @param Name Decoded case-sensitive key
   --  @param Occurrence One-based duplicate occurrence
   --  @return True when the occurrence exists
   function Has_Query
     (X          : Applications.Exchange;
      Name       : String;
      Occurrence : Positive := 1) return Boolean;

   --  Return one cookie value. Cookie names are case-sensitive; the first
   --  duplicate wins. Fields above 4096 bytes or 64 pairs are rejected.
   --  @param X Request exchange
   --  @param Name Cookie name
   --  @return Cookie value or an empty string
   function Cookie (X : Applications.Exchange; Name : String) return String;

   --  Return the lowercase media type portion of Content-Type.
   --  @param X Request exchange
   --  @return Media type or an empty string
   function Media_Type (X : Applications.Exchange) return String;

   --  Return one case-insensitive Content-Type parameter with optional quoted
   --  string unescaping. The first duplicate wins.
   --  @param X Request exchange
   --  @param Name Parameter name
   --  @return Parameter value or an empty string
   function Content_Type_Parameter
     (X    : Applications.Exchange;
      Name : String) return String;

   --  Return the validated Host or request authority parsed by the core.
   --  @param X Request exchange
   --  @return Authority value
   function Authority (X : Applications.Exchange) return String;

end Flyology.HTTP.Server.Requests;
