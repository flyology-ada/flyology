with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with EWS.Dynamic;
with EWS.HTTP;
with EWS.Server;
with EWS.Types;
with GNAT.Sockets;

procedure EWS_Plain is
   Plaintext : constant String := "Hello, World!";
   One_KiB   : constant String (1 .. 1_024) := (others => 'x');

   Port : constant GNAT.Sockets.Port_Type :=
     (if Ada.Command_Line.Argument_Count >= 1
      then GNAT.Sockets.Port_Type'Value (Ada.Command_Line.Argument (1))
      else 18_093);

   function Plain
     (Request : EWS.HTTP.Request_P)
      return EWS.Dynamic.Dynamic_Response'Class
   is
      Result : EWS.Dynamic.Dynamic_Response (Request);
   begin
      EWS.Dynamic.Set_Content_Type (Result, EWS.Types.Plain);
      EWS.Dynamic.Set_Content (Result, Plaintext);
      return Result;
   end Plain;

   function Response_1K
     (Request : EWS.HTTP.Request_P)
      return EWS.Dynamic.Dynamic_Response'Class
   is
      Result : EWS.Dynamic.Dynamic_Response (Request);
   begin
      EWS.Dynamic.Set_Content_Type (Result, EWS.Types.Octet_Stream);
      EWS.Dynamic.Set_Content (Result, One_KiB);
      return Result;
   end Response_1K;

   procedure Discard_Log
     (Message : String; Level : EWS.Server.Error_Level) is
      pragma Unreferenced (Message, Level);
   begin
      null;
   end Discard_Log;
begin
   EWS.Dynamic.Register (Plain'Unrestricted_Access, "/plaintext");
   EWS.Dynamic.Register (Response_1K'Unrestricted_Access, "/response-1k");
   EWS.Server.Serve
     (Using_Port => Port,
      With_Stack => 64 * 1_024,
      Logging_Via => Discard_Log'Unrestricted_Access,
      Tracing => False);
   Ada.Text_IO.Put_Line
     ("READY ews http://127.0.0.1:"
      & Ada.Strings.Fixed.Trim
          (GNAT.Sockets.Port_Type'Image (Port), Ada.Strings.Both)
      & "/plaintext");
   Ada.Text_IO.Flush;
   loop
      delay 3_600.0;
   end loop;
end EWS_Plain;
