package body Flyology.IO.Connections.TLS is

   use type Flyology.IO.TLS.Role;

   procedure Check_Upgrade_Arguments (Side : Flyology.IO.TLS.Role; Server_Name : String) is
   begin
      if Side = Flyology.IO.TLS.Client and then Server_Name'Length = 0 then
         raise Program_Error with "TLS client requires a server name";
      elsif Side = Flyology.IO.TLS.Server and then Server_Name'Length /= 0 then
         raise Program_Error with "TLS server does not accept a server name";
      end if;
   end Check_Upgrade_Arguments;

   function Upgrade
     (Set         : not null access Flyology.Operations.Completion_Set'Class;
      Item        : not null access Connection'Class;
      Backend     : not null access Flyology.IO.TLS.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Timeout     : Duration := Infinite;
      Token       : access Cancellation_Token := null) return Upgrade_Operation
   is
      function Factory (FD : Flyology.IO.Descriptor) return Flyology.IO.TLS.Session_Access is
      begin
         if not Flyology.IO.TLS.Is_Available (Backend.all) then
            raise Flyology.IO.TLS.TLS_Error
              with Flyology.IO.TLS.Name (Backend.all) & " provider is unavailable";
         end if;
         return Flyology.IO.TLS.Create_Session (Backend.all, FD, Side, Server_Name);
      end Factory;
   begin
      Check_Upgrade_Arguments (Side, Server_Name);
      return Result : Upgrade_Operation (Set) do
         Start_Scoped_TLS_Upgrade (Result, Item, Factory'Access, Timeout, Token);
      end return;
   end Upgrade;

   procedure Upgrade
     (Item        : not null access Connection'Class;
      Backend     : not null access Flyology.IO.TLS.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Timeout     : Duration := Infinite;
      Token       : access Cancellation_Token := null;
      Operation   : in out Upgrade_Operation)
   is
      function Factory (FD : Flyology.IO.Descriptor) return Flyology.IO.TLS.Session_Access is
      begin
         if not Flyology.IO.TLS.Is_Available (Backend.all) then
            raise Flyology.IO.TLS.TLS_Error
              with Flyology.IO.TLS.Name (Backend.all) & " provider is unavailable";
         end if;
         return Flyology.IO.TLS.Create_Session (Backend.all, FD, Side, Server_Name);
      end Factory;
   begin
      Check_Upgrade_Arguments (Side, Server_Name);
      Start_Scoped_TLS_Upgrade (Operation, Item, Factory'Access, Timeout, Token);
   end Upgrade;

   function Upgrade
     (Set         : not null access Flyology.Operations.Completion_Set'Class;
      Item        : not null access Connection'Class;
      Backend     : not null access Flyology.IO.TLS.ALPN.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Protocols   : Flyology.IO.TLS.ALPN.Protocol_List;
      Timeout     : Duration := Infinite;
      Token       : access Cancellation_Token := null) return Upgrade_Operation
   is
      function Factory (FD : Flyology.IO.Descriptor) return Flyology.IO.TLS.Session_Access is
      begin
         if not Flyology.IO.TLS.Is_Available (Flyology.IO.TLS.Provider'Class (Backend.all)) then
            raise Flyology.IO.TLS.TLS_Error
              with
                Flyology.IO.TLS.Name (Flyology.IO.TLS.Provider'Class (Backend.all))
                & " provider is unavailable";
         end if;
         return Flyology.IO.TLS.ALPN.Create_Session (Backend.all, FD, Side, Server_Name, Protocols);
      end Factory;
   begin
      Check_Upgrade_Arguments (Side, Server_Name);
      return Result : Upgrade_Operation (Set) do
         Start_Scoped_TLS_Upgrade (Result, Item, Factory'Access, Timeout, Token);
      end return;
   end Upgrade;

   procedure Upgrade
     (Item        : not null access Connection'Class;
      Backend     : not null access Flyology.IO.TLS.ALPN.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Protocols   : Flyology.IO.TLS.ALPN.Protocol_List;
      Timeout     : Duration := Infinite;
      Token       : access Cancellation_Token := null;
      Operation   : in out Upgrade_Operation)
   is
      function Factory (FD : Flyology.IO.Descriptor) return Flyology.IO.TLS.Session_Access is
      begin
         if not Flyology.IO.TLS.Is_Available (Flyology.IO.TLS.Provider'Class (Backend.all)) then
            raise Flyology.IO.TLS.TLS_Error
              with
                Flyology.IO.TLS.Name (Flyology.IO.TLS.Provider'Class (Backend.all))
                & " provider is unavailable";
         end if;
         return Flyology.IO.TLS.ALPN.Create_Session (Backend.all, FD, Side, Server_Name, Protocols);
      end Factory;
   begin
      Check_Upgrade_Arguments (Side, Server_Name);
      Start_Scoped_TLS_Upgrade (Operation, Item, Factory'Access, Timeout, Token);
   end Upgrade;

   procedure Finish (Operation : in out Upgrade_Operation) is
   begin
      Finish_Connection_Operation (Operation);
   end Finish;

   procedure Upgrade
     (Item        : in out Connection;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Timeout     : Duration := Infinite;
      Token       : access Cancellation_Token := null)
   is
      function Factory (FD : Flyology.IO.Descriptor) return Flyology.IO.TLS.Session_Access
      is (Flyology.IO.TLS.Create_Session (Backend, FD, Side, Server_Name));
   begin
      Upgrade_TLS (Item, Backend, Side, Server_Name, Factory'Access, Timeout, Token);
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
      function Factory (FD : Flyology.IO.Descriptor) return Flyology.IO.TLS.Session_Access
      is (Flyology.IO.TLS.ALPN.Create_Session (Backend, FD, Side, Server_Name, Protocols));
   begin
      Upgrade_TLS (Item, Backend, Side, Server_Name, Factory'Access, Timeout, Token);
   end Upgrade;

   function Selected_Protocol (Item : in out Connection) return String is
      function Query (Value : Flyology.IO.TLS.Session'Class) return String is
      begin
         if Value not in Flyology.IO.TLS.ALPN.Session'Class then
            raise Flyology.IO.TLS.TLS_Error with "TLS session does not support ALPN";
         end if;
         return Flyology.IO.TLS.ALPN.Selected_Protocol (Flyology.IO.TLS.ALPN.Session'Class (Value));
      end Query;
   begin
      return Query_TLS_Session (Item, Query'Access);
   end Selected_Protocol;

   procedure Shutdown
     (Item : in out Connection; Timeout : Duration := Infinite; Token : access Cancellation_Token := null) is
   begin
      Shutdown_TLS (Item, Timeout, Token);
   end Shutdown;

end Flyology.IO.Connections.TLS;
