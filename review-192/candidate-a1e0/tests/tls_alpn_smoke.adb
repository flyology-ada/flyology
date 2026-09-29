with Flyology;
with Flyology.Cancellation;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Connections.TLS;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.IO.TLS.ALPN;
with TLS_ALPN_Test_Provider;

procedure TLS_ALPN_Smoke is
   package Connections renames Flyology.IO.Connections;
   package Connection_TLS renames Flyology.IO.Connections.TLS;
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;
   package ALPN renames Flyology.IO.TLS.ALPN;
   package Test_Provider renames TLS_ALPN_Test_Provider;

   use type Test_Provider.Offer_Kind;
   use type ALPN.Protocol_List;

   H2_Then_HTTP_1_1 : constant ALPN.Protocol_List := ALPN.Offer ("h2") & "http/1.1";

   procedure Run_Validation is
      Value    : ALPN.Protocol_List := ALPN.Empty_Protocol_List;
      Rejected : Natural := 0;
   begin
      pragma Assert (ALPN.Count (Value) = 0);
      ALPN.Append (Value, "h2");
      ALPN.Append (Value, "http/1.1");
      pragma Assert (ALPN.Count (Value) = 2);
      pragma Assert (ALPN.Identifier (Value, 1) = "h2");
      pragma Assert (ALPN.Identifier (Value, 2) = "http/1.1");

      begin
         Value := ALPN.Offer ("");
      exception
         when Constraint_Error =>
            Rejected := Rejected + 1;
      end;
      begin
         Value := ALPN.Offer (String'(1 .. 256 => 'x'));
      exception
         when Constraint_Error =>
            Rejected := Rejected + 1;
      end;
      begin
         Value := ALPN.Empty_Protocol_List;
         for Index in 1 .. 256 loop
            ALPN.Append (Value, String'(1 .. 255 => Character'Val (Index mod 256)));
         end loop;
      exception
         when Constraint_Error =>
            Rejected := Rejected + 1;
      end;
      pragma Assert (Rejected = 3);
   end Run_Validation;

   procedure Run_Selection
     (Model : Flyology.Execution_Model; Selection : Test_Provider.Selection_Kind; Expected : String)
   is
      Backend : Test_Provider.Provider;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Item    : TLS.Connection;
      Passed  : Boolean := False;
   begin
      Test_Provider.Reset_Observations;
      Test_Provider.Set_Selection (Backend, Selection);
      Sockets.Create_Socket_Pair (Socket, Peer);
      ALPN.Take (Backend, Socket, TLS.Client, "localhost", H2_Then_HTTP_1_1, Item);
      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
         begin
            TLS.Handshake (Item, Timeout => 1.0);
            Passed := True;
         exception
            when others =>
               Passed := False;
         end Worker;
      begin
         null;
      end;
      pragma Assert (Passed);
      pragma Assert (ALPN.Selected_Protocol (Item) = Expected);
      pragma Assert (Test_Provider.Last_Offer = Test_Provider.H2_Then_HTTP_1_1);
      TLS.Close (Item);
      Sockets.Close_Socket (Peer);
   end Run_Selection;

   procedure Run_Timeout (Model : Flyology.Execution_Model) is
      Backend   : Test_Provider.Provider;
      Socket    : Sockets.Socket_Type;
      Peer      : Sockets.Socket_Type;
      Item      : TLS.Connection;
      Timed_Out : Boolean := False;
   begin
      Test_Provider.Reset_Observations;
      Test_Provider.Set_Handshake_Status (Backend, TLS.Want_Read);
      Sockets.Create_Socket_Pair (Socket, Peer);
      ALPN.Take (Backend, Socket, TLS.Client, "localhost", ALPN.Offer ("h2"), Item);
      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
         begin
            TLS.Handshake (Item, Timeout => 0.030);
         exception
            when Flyology.IO.Timeout_Error =>
               Timed_Out := True;
         end Worker;
      begin
         null;
      end;
      pragma Assert (Timed_Out);
      TLS.Close (Item);
      Sockets.Close_Socket (Peer);
   end Run_Timeout;

   procedure Run_Cancellation (Model : Flyology.Execution_Model) is
      Backend   : Test_Provider.Provider;
      Socket    : Sockets.Socket_Type;
      Peer      : Sockets.Socket_Type;
      Item      : TLS.Connection;
      Token     : aliased Flyology.Cancellation.Token;
      Cancelled : Boolean := False;
   begin
      Test_Provider.Reset_Observations;
      Test_Provider.Set_Handshake_Status (Backend, TLS.Want_Read);
      Sockets.Create_Socket_Pair (Socket, Peer);
      ALPN.Take (Backend, Socket, TLS.Client, "localhost", ALPN.Offer ("h2"), Item);
      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;
         task Controller is
            pragma Task_Info (Flyology.Native_Task);
         end Controller;

         task body Worker is
         begin
            TLS.Handshake (Item, Token => Token'Access);
         exception
            when TLS.Operation_Cancelled =>
               Cancelled := True;
         end Worker;

         task body Controller is
         begin
            Test_Provider.Wait_For_Handshake;
            Token.Request;
         end Controller;
      begin
         null;
      end;
      pragma Assert (Cancelled);
      TLS.Close (Item);
      Sockets.Close_Socket (Peer);
   end Run_Cancellation;

   procedure Run_Connections_Upgrade (Model : Flyology.Execution_Model) is
      Manager : aliased Connections.Server (Capacity => 1);
      Backend : Test_Provider.Provider;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Item    : Connections.Connection;
      Passed  : Boolean := False;
   begin
      Test_Provider.Reset_Observations;
      Test_Provider.Set_Selection (Backend, Test_Provider.Select_H2);
      Sockets.Create_Socket_Pair (Socket, Peer);
      Connections.Take (Manager, Socket, Item);
      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
         begin
            Connection_TLS.Upgrade (Item, Backend, TLS.Client, "localhost", H2_Then_HTTP_1_1, Timeout => 1.0);
            Passed := Connection_TLS.Selected_Protocol (Item) = "h2";
         exception
            when others =>
               Passed := False;
         end Worker;
      begin
         null;
      end;
      pragma Assert (Passed);
      Connections.Close (Item);
      Sockets.Close_Socket (Peer);
   end Run_Connections_Upgrade;

   procedure Run_Retained_Provider is
      Backend  : Test_Provider.Provider;
      Retained : TLS.Provider_Access := Test_Provider.Retain (Backend);
      Socket   : Sockets.Socket_Type;
      Peer     : Sockets.Socket_Type;
      Item     : TLS.Connection;
   begin
      pragma Assert (Retained.all in ALPN.Provider'Class);
      Test_Provider.Set_Selection (Backend, Test_Provider.Select_H2);
      TLS.Release (Retained);
      Retained := Test_Provider.Retain (Backend);
      Sockets.Create_Socket_Pair (Socket, Peer);
      ALPN.Take
        (ALPN.Provider'Class (Retained.all), Socket, TLS.Client, "localhost", ALPN.Offer ("h2"), Item);
      TLS.Release (Retained);
      TLS.Handshake (Item, Timeout => 1.0);
      pragma Assert (ALPN.Selected_Protocol (Item) = "h2");
      TLS.Close (Item);
      Sockets.Close_Socket (Peer);
   end Run_Retained_Provider;

begin
   Run_Validation;
   Run_Selection (Flyology.Lightweight_Task, Test_Provider.No_Selection, "");
   Run_Selection (Flyology.Native_Task, Test_Provider.No_Selection, "");
   Run_Selection (Flyology.Lightweight_Task, Test_Provider.Select_H2, "h2");
   Run_Selection (Flyology.Native_Task, Test_Provider.Select_H2, "h2");
   Run_Selection (Flyology.Lightweight_Task, Test_Provider.Select_HTTP_1_1, "http/1.1");
   Run_Selection (Flyology.Native_Task, Test_Provider.Select_HTTP_1_1, "http/1.1");
   Run_Timeout (Flyology.Lightweight_Task);
   Run_Timeout (Flyology.Native_Task);
   Run_Cancellation (Flyology.Lightweight_Task);
   Run_Cancellation (Flyology.Native_Task);
   Run_Connections_Upgrade (Flyology.Lightweight_Task);
   Run_Connections_Upgrade (Flyology.Native_Task);
   Run_Retained_Provider;
end TLS_ALPN_Smoke;
