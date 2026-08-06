package body Flyology.IO.Connections.TLS is

   procedure Upgrade
     (Item        : in out Connection;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Timeout     : Duration := Infinite;
      Token       : access Cancellation_Token := null) is
      function Factory
        (FD : Flyology.IO.Descriptor) return Flyology.IO.TLS.Session_Access is
        (Flyology.IO.TLS.Create_Session
           (Backend, FD, Side, Server_Name));
   begin
      Upgrade_TLS
        (Item, Backend, Side, Server_Name, Factory'Access, Timeout, Token);
   end Upgrade;

   procedure Upgrade
     (Item        : in out Connection;
      Backend     : in out Flyology.IO.TLS.ALPN.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Protocols   : Flyology.IO.TLS.ALPN.Protocol_List;
      Timeout     : Duration := Infinite;
      Token       : access Cancellation_Token := null)
   is
      function Factory
        (FD : Flyology.IO.Descriptor) return Flyology.IO.TLS.Session_Access is
        (Flyology.IO.TLS.ALPN.Create_Session
           (Backend, FD, Side, Server_Name, Protocols));
   begin
      Upgrade_TLS
        (Item, Backend, Side, Server_Name, Factory'Access, Timeout, Token);
   end Upgrade;

   function Selected_Protocol (Item : in out Connection) return String is
      function Query
        (Value : Flyology.IO.TLS.Session'Class) return String is
      begin
         if Value not in Flyology.IO.TLS.ALPN.Session'Class then
            raise Flyology.IO.TLS.TLS_Error with
              "TLS session does not support ALPN";
         end if;
         return Flyology.IO.TLS.ALPN.Selected_Protocol
           (Flyology.IO.TLS.ALPN.Session'Class (Value));
      end Query;
   begin
      return Query_TLS_Session (Item, Query'Access);
   end Selected_Protocol;

   procedure Shutdown
     (Item    : in out Connection;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null) is
   begin
      Shutdown_TLS (Item, Timeout, Token);
   end Shutdown;

end Flyology.IO.Connections.TLS;
