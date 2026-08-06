with Ada.Streams;
with Flyology.HTTP.Client.Request_Bodies;

procedure HTTP_Client_Body_Source_Lifetime_Fail is
   package Bodies renames Flyology.HTTP.Client.Request_Bodies;

   function Escape_Source return Bodies.Array_Source is
      Payload : aliased constant Ada.Streams.Stream_Element_Array :=
        (1 => 42);
   begin
      return Result : Bodies.Array_Source (Payload'Access) do
         null;
      end return;
   end Escape_Source;

   Escaped : Bodies.Array_Source := Escape_Source;
   pragma Unreferenced (Escaped);
begin
   null;
end HTTP_Client_Body_Source_Lifetime_Fail;
