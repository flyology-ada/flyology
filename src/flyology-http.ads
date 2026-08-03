--  Defines protocol concepts shared by Flyology HTTP clients and servers.
package Flyology.HTTP is

   --  Raised for malformed or unsupported HTTP protocol input.
   Protocol_Error : exception;

   --  Parsed HTTP protocol version.
   --  @enum HTTP_1_0 HTTP/1.0 message
   --  @enum HTTP_1_1 HTTP/1.1 message
   type HTTP_Version is (HTTP_1_0, HTTP_1_1);

end Flyology.HTTP;
