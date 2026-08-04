with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with AWS.Messages;
with AWS.Response;
with AWS.Server;
with AWS.Status;

procedure AWS_Plain is
   Plaintext : constant String := "Hello, World!";
   One_KiB   : constant String (1 .. 1_024) := (others => 'x');

   Port : constant Natural :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Natural'Value (Ada.Command_Line.Argument (1)) else 18_092);
   Capacity : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Positive'Value (Ada.Command_Line.Argument (2)) else 256);

   function Respond (Request : AWS.Status.Data) return AWS.Response.Data is
      Target : constant String := AWS.Status.URI (Request);
   begin
      if Target = "/plaintext" then
         return AWS.Response.Build ("text/plain", Plaintext);
      elsif Target = "/response-1k" then
         return AWS.Response.Build ("application/octet-stream", One_KiB);
      else
         return AWS.Response.Build
           ("text/plain", "not found", Status_Code => AWS.Messages.S404);
      end if;
   end Respond;

   Server : AWS.Server.HTTP;
begin
   AWS.Server.Start
     (Server, "flyology-http-comparison", Respond'Unrestricted_Access,
      Max_Connection => Capacity,
      Admin_URI      => "",
      Host           => "127.0.0.1",
      Port           => Port,
      Security       => False,
      Session        => False);
   Ada.Text_IO.Put_Line
     ("READY aws http://127.0.0.1:"
      & Ada.Strings.Fixed.Trim (Natural'Image (Port), Ada.Strings.Both)
      & "/plaintext");
   Ada.Text_IO.Flush;
   AWS.Server.Wait (AWS.Server.Forever);
end AWS_Plain;
