--  Supplies constants for standardized HTTP methods while the parent Method
--  type remains open to extension tokens.
package Flyology.HTTP.Methods is

   --  GET retrieval method.
   GET     : constant Method := To_Method ("GET");
   --  HEAD metadata-only retrieval method.
   HEAD    : constant Method := To_Method ("HEAD");
   --  POST representation-processing method.
   POST    : constant Method := To_Method ("POST");
   --  PUT representation-replacement method.
   PUT     : constant Method := To_Method ("PUT");
   --  DELETE resource-removal method.
   DELETE  : constant Method := To_Method ("DELETE");
   --  CONNECT tunnel-establishment method.
   CONNECT : constant Method := To_Method ("CONNECT");
   --  OPTIONS capability-discovery method.
   OPTIONS : constant Method := To_Method ("OPTIONS");
   --  TRACE diagnostic loop-back method.
   TRACE   : constant Method := To_Method ("TRACE");
   --  PATCH partial-modification method.
   PATCH   : constant Method := To_Method ("PATCH");

end Flyology.HTTP.Methods;
