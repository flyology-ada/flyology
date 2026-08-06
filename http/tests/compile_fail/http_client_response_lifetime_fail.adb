with Flyology.HTTP;
with Flyology.HTTP.Client;

procedure HTTP_Client_Response_Lifetime_Fail is
   package Client renames Flyology.HTTP.Client;

   function Escape_Response return Client.Response is
      Item  : aliased Client.Client;
      Value : Client.Request;
   begin
      Client.Configure
        (Item, Flyology.HTTP.Parse_Origin ("http://127.0.0.1"));
      return Client.Execute (Item, Value);
   end Escape_Response;

   Escaped : Client.Response := Escape_Response;
   pragma Unreferenced (Escaped);
begin
   null;
end HTTP_Client_Response_Lifetime_Fail;
