package body Flyology.IO.TLS.ALPN is

   Maximum_Encoded_Length : constant := 65_535;

   procedure Append (Item : in out Protocol_List; Identifier : String) is
      Added : constant Natural := Identifier'Length + 1;
   begin
      if Identifier'Length not in 1 .. 255 then
         raise Constraint_Error with "ALPN identifiers must contain 1 .. 255 bytes";
      elsif Added > Maximum_Encoded_Length - Item.Encoded_Length then
         raise Constraint_Error with "ALPN protocol list is too long";
      end if;
      Item.Values.Append (Identifier);
      Item.Encoded_Length := Item.Encoded_Length + Added;
   end Append;

   function Offer (Identifier : String) return Protocol_List is
      Result : Protocol_List;
   begin
      Append (Result, Identifier);
      return Result;
   end Offer;

   function "&" (Left : Protocol_List; Right : String) return Protocol_List is
      Result : Protocol_List := Left;
   begin
      Append (Result, Right);
      return Result;
   end "&";

   function Count (Item : Protocol_List) return Natural
   is (Natural (Item.Values.Length));

   function Identifier (Item : Protocol_List; Index : Positive) return String
   is (Item.Values.Element (Index));

   procedure Take
     (Backend     : in out Provider'Class;
      Socket      : in out Flyology.IO.Sockets.Socket_Type;
      Side        : Role;
      Server_Name : String;
      Protocols   : Protocol_List;
      Item        : in out Connection)
   is
      function Factory (FD : Descriptor) return Session_Access
      is (Create_Session (Backend, FD, Side, Server_Name, Protocols));
   begin
      Take_With_Factory (Backend, Socket, Side, Server_Name, Factory'Access, Item);
      if Item.Session.all not in Session'Class then
         Close (Item);
         raise TLS_Error with Name (Backend) & " returned a session without ALPN capability";
      end if;
   end Take;

   function Selected_Protocol (Item : in out Connection) return String is
      function Query (Value : Flyology.IO.TLS.Session'Class) return String is
      begin
         if Value not in Session'Class then
            raise TLS_Error with "TLS session does not support ALPN";
         end if;
         return Selected_Protocol (Session'Class (Value));
      end Query;
   begin
      return Query_Session (Item, Query'Access);
   end Selected_Protocol;

end Flyology.IO.TLS.ALPN;
