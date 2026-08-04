package body Flyology.IO.Connections.TLS is

   procedure Upgrade
     (Item        : in out Connection;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Timeout     : Duration := Infinite;
      Token       : access Cancellation_Token := null) is
   begin
      Upgrade_TLS
        (Item, Backend, Side, Server_Name, Timeout, Token);
   end Upgrade;

   procedure Shutdown
     (Item    : in out Connection;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null) is
   begin
      Shutdown_TLS (Item, Timeout, Token);
   end Shutdown;

end Flyology.IO.Connections.TLS;
