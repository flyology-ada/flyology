with Ada.Streams;
with GNAT.Sockets;
with Gnatevl;
with Gnatevl.IO.Connections;

procedure Connection_Lifecycle_Smoke is
   package Connections renames Gnatevl.IO.Connections;
   use type GNAT.Sockets.Socket_Type;

   Manager : aliased Connections.Server (Capacity => 1);
   Token   : aliased Connections.Cancellation_Token;

   Server_One, Peer_One : GNAT.Sockets.Socket_Type;
   Server_Two, Peer_Two : GNAT.Sockets.Socket_Type;
   Server_Three, Peer_Three : GNAT.Sockets.Socket_Type;
   Spare_Server, Spare_Peer : GNAT.Sockets.Socket_Type;

   protected State is
      procedure First_Admitted;
      procedure Second_Admitted;
      procedure Second_Finished (Was_Cancelled : Boolean);
      procedure Third_Admitted;
      procedure Third_Finished (Was_Cancelled : Boolean);
      entry Wait_First;
      entry Wait_Second;
      entry Wait_Second_Finished;
      entry Wait_Third;
      entry Wait_Third_Finished;
      function Passed return Boolean;
   private
      First_In, Second_In, Second_Done : Boolean := False;
      Third_In, Third_Done : Boolean := False;
      All_OK : Boolean := True;
   end State;

   protected body State is
      procedure First_Admitted is
      begin
         First_In := True;
      end First_Admitted;

      procedure Second_Admitted is
      begin
         Second_In := True;
      end Second_Admitted;

      procedure Second_Finished (Was_Cancelled : Boolean) is
      begin
         All_OK := All_OK and Was_Cancelled;
         Second_Done := True;
      end Second_Finished;

      procedure Third_Admitted is
      begin
         Third_In := True;
      end Third_Admitted;

      procedure Third_Finished (Was_Cancelled : Boolean) is
      begin
         All_OK := All_OK and Was_Cancelled;
         Third_Done := True;
      end Third_Finished;

      entry Wait_First when First_In is begin null; end Wait_First;
      entry Wait_Second when Second_In is begin null; end Wait_Second;
      entry Wait_Second_Finished when Second_Done is
      begin
         null;
      end Wait_Second_Finished;
      entry Wait_Third when Third_In is begin null; end Wait_Third;
      entry Wait_Third_Finished when Third_Done is
      begin
         null;
      end Wait_Third_Finished;
      function Passed return Boolean is (All_OK);
   end State;

begin
   GNAT.Sockets.Create_Socket_Pair (Server_One, Peer_One);
   GNAT.Sockets.Create_Socket_Pair (Server_Two, Peer_Two);
   GNAT.Sockets.Create_Socket_Pair (Server_Three, Peer_Three);
   GNAT.Sockets.Create_Socket_Pair (Spare_Server, Spare_Peer);

   declare
      task First;
      task Second;

      task body First is
         Owned : Connections.Connection;
      begin
         Connections.Take (Manager, Server_One, Owned);
         pragma Assert (Server_One = GNAT.Sockets.No_Socket);
         State.First_Admitted;
         delay 0.050;
         Owned.Close;
      end First;

      task body Second is
         Owned    : Connections.Connection;
         Incoming : Ada.Streams.Stream_Element_Array (1 .. 1);
         Was_Cancelled : Boolean := False;
      begin
         Connections.Take (Manager, Server_Two, Owned);
         State.Second_Admitted;
         begin
            Owned.Receive_Exactly
              (Incoming,
               Cancellation_Quantum => 0.010,
               Token => Token'Access);
         exception
            when Connections.Operation_Cancelled =>
               Was_Cancelled := True;
         end;
         State.Second_Finished (Was_Cancelled);
      end Second;

      pragma Unreferenced (First, Second);
   begin
      State.Wait_First;
      delay 0.010;
      pragma Assert (Manager.Active = 1);
      pragma Assert (Manager.Waiting = 1);
      State.Wait_Second;
      Token.Request;
      State.Wait_Second_Finished;
   end;

   pragma Assert (Manager.Active = 0);

   declare
      task Third;

      task body Third is
         Owned    : Connections.Connection;
         Incoming : Ada.Streams.Stream_Element_Array (1 .. 1);
         Was_Cancelled : Boolean := False;
      begin
         Connections.Take (Manager, Server_Three, Owned);
         State.Third_Admitted;
         begin
            Owned.Receive_Exactly
              (Incoming, Cancellation_Quantum => 0.010);
         exception
            when Connections.Operation_Cancelled =>
               Was_Cancelled := True;
         end;
         State.Third_Finished (Was_Cancelled);
      end Third;

      pragma Unreferenced (Third);
   begin
      State.Wait_Third;
      Manager.Request_Shutdown;
      Manager.Await_Drained;
      State.Wait_Third_Finished;
   end;

   declare
      Owned : Connections.Connection;
      Closed : Boolean := False;
   begin
      begin
         Connections.Take (Manager, Spare_Server, Owned);
      exception
         when Connections.Admission_Closed =>
            Closed := True;
      end;
      pragma Assert (Closed);
      pragma Assert (Spare_Server /= GNAT.Sockets.No_Socket);
   end;

   pragma Assert (Manager.Active = 0);
   pragma Assert (State.Passed);

   declare
      Accept_Manager : aliased Connections.Server (Capacity => 1);
      Listener : GNAT.Sockets.Socket_Type;

      protected Result is
         procedure Finished (Cancelled : Boolean);
         entry Wait;
         function Passed return Boolean;
      private
         Done : Boolean := False;
         OK   : Boolean := False;
      end Result;

      protected body Result is
         procedure Finished (Cancelled : Boolean) is
         begin
            OK := Cancelled;
            Done := True;
         end Finished;

         entry Wait when Done is
         begin
            null;
         end Wait;

         function Passed return Boolean is (OK);
      end Result;
   begin
      GNAT.Sockets.Create_Socket (Listener);
      GNAT.Sockets.Bind_Socket
        (Listener,
         (Family => GNAT.Sockets.Family_Inet,
          Addr   => GNAT.Sockets.Loopback_Inet_Addr,
          Port   => GNAT.Sockets.Any_Port));
      GNAT.Sockets.Listen_Socket (Listener);

      declare
         task Acceptor;

         task body Acceptor is
            Owned : Connections.Connection;
            Peer  : GNAT.Sockets.Sock_Addr_Type;
            Was_Cancelled : Boolean := False;
         begin
            begin
               Connections.Accept_Connection
                 (Accept_Manager,
                  Listener,
                  Owned,
                  Peer,
                  Cancellation_Quantum => 0.010);
            exception
               when Connections.Operation_Cancelled =>
                  Was_Cancelled := True;
            end;
            Result.Finished (Was_Cancelled);
         end Acceptor;

         pragma Unreferenced (Acceptor);
      begin
         delay 0.020;
         pragma Assert (Accept_Manager.Active = 1);
         Accept_Manager.Request_Shutdown;
         Accept_Manager.Await_Drained;
         Result.Wait;
      end;

      pragma Assert (Result.Passed);
      GNAT.Sockets.Close_Socket (Listener);
   end;

   declare
      Native_Manager : aliased Connections.Server (Capacity => 1);
      Native_Token   : aliased Connections.Cancellation_Token;
      Native_Server, Native_Peer : GNAT.Sockets.Socket_Type;

      protected Result is
         procedure Finished (Cancelled : Boolean);
         entry Wait;
         function Passed return Boolean;
      private
         Done : Boolean := False;
         OK   : Boolean := False;
      end Result;

      protected body Result is
         procedure Finished (Cancelled : Boolean) is
         begin
            OK := Cancelled;
            Done := True;
         end Finished;
         entry Wait when Done is begin null; end Wait;
         function Passed return Boolean is (OK);
      end Result;
   begin
      GNAT.Sockets.Create_Socket_Pair (Native_Server, Native_Peer);
      declare
         task Native_Worker is
            pragma Task_Info (Gnatevl.Native_Thread);
         end Native_Worker;

         task body Native_Worker is
            Owned : Connections.Connection;
            Data  : Ada.Streams.Stream_Element_Array (1 .. 1);
            Was_Cancelled : Boolean := False;
         begin
            Connections.Take (Native_Manager, Native_Server, Owned);
            begin
               Owned.Receive_Exactly
                 (Data,
                  Cancellation_Quantum => 0.010,
                  Token => Native_Token'Access);
            exception
               when Connections.Operation_Cancelled =>
                  Was_Cancelled := True;
            end;
            Result.Finished (Was_Cancelled);
         end Native_Worker;
      begin
         delay 0.020;
         Native_Token.Request;
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
      pragma Assert (Native_Manager.Active = 0);
      GNAT.Sockets.Close_Socket (Native_Peer);
   end;

   GNAT.Sockets.Close_Socket (Peer_One);
   GNAT.Sockets.Close_Socket (Peer_Two);
   GNAT.Sockets.Close_Socket (Peer_Three);
   GNAT.Sockets.Close_Socket (Spare_Server);
   GNAT.Sockets.Close_Socket (Spare_Peer);
end Connection_Lifecycle_Smoke;
