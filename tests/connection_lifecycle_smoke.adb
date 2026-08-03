with Ada.Exceptions;
with Ada.Streams;
with GNAT.Sockets;
with Flyology;
with Flyology.IO.Connections;

procedure Connection_Lifecycle_Smoke is
   package Connections renames Flyology.IO.Connections;
   use type GNAT.Sockets.Socket_Type;

   Manager : aliased Connections.Server (Capacity => 1);
   Token   : aliased Connections.Cancellation_Token;

   Server_One, Peer_One : GNAT.Sockets.Socket_Type;
   Server_Two, Peer_Two : GNAT.Sockets.Socket_Type;
   Server_Three, Peer_Three : GNAT.Sockets.Socket_Type;
   Spare_Server, Spare_Peer : GNAT.Sockets.Socket_Type;

   protected State is
      procedure First_Admitted;
      procedure Release_First;
      procedure Second_Admitted;
      procedure Second_Finished (Was_Cancelled : Boolean);
      procedure Third_Admitted;
      procedure Third_Finished (Was_Cancelled : Boolean);
      entry Wait_First;
      entry Wait_First_Release;
      entry Wait_Second;
      entry Wait_Second_Finished;
      entry Wait_Third;
      entry Wait_Third_Finished;
      function Passed return Boolean;
   private
      First_In, Second_In, Second_Done : Boolean := False;
      First_Released : Boolean := False;
      Third_In, Third_Done : Boolean := False;
      All_OK : Boolean := True;
   end State;

   protected body State is
      procedure First_Admitted is
      begin
         First_In := True;
      end First_Admitted;

      procedure Release_First is
      begin
         First_Released := True;
      end Release_First;

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
      entry Wait_First_Release when First_Released is
      begin
         null;
      end Wait_First_Release;
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
      task First is
         pragma Task_Info (Flyology.Lightweight_Task);
      end First;

      task Second is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Second;

      task body First is
         Owned : Connections.Connection;
      begin
         Connections.Take (Manager, Server_One, Owned);
         State.First_Admitted;
         pragma Assert (Server_One = GNAT.Sockets.No_Socket);
         State.Wait_First_Release;
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
      begin
         select
            State.Wait_First;
         or
            delay 2.0;
            raise Program_Error with "first connection was not admitted";
         end select;
         pragma Assert (Manager.Active = 1);
         for Attempt in 1 .. 2_000 loop
            exit when Manager.Waiting = 1;
            delay 0.001;
         end loop;
         if Manager.Waiting /= 1 then
            raise Program_Error with
              "second connection did not reach admission queue";
         end if;
         State.Release_First;
         select
            State.Wait_Second;
         or
            delay 2.0;
            raise Program_Error with "second connection was not admitted";
         end select;
         Token.Request;
         select
            State.Wait_Second_Finished;
         or
            delay 2.0;
            raise Program_Error with "second connection did not cancel";
         end select;
      exception
         when Occurrence : others =>
            --  Do not let a test failure strand either dependent task while
            --  the enclosing master is being completed.
            State.Release_First;
            begin
               Token.Request;
            exception
               when others =>
                  null;
            end;
            --  Closing the peer is independent of the cancellation pipe and
            --  forces any admitted receiver to observe EOF if signaling was
            --  itself the failing operation.
            begin
               GNAT.Sockets.Close_Socket (Peer_Two);
               Peer_Two := GNAT.Sockets.No_Socket;
            exception
               when others =>
                  null;
            end;
            Ada.Exceptions.Reraise_Occurrence (Occurrence);
      end;
   end;

   pragma Assert (Manager.Active = 0);

   declare
      task Third is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Third;

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
      begin
         select
            State.Wait_Third;
         or
            delay 2.0;
            raise Program_Error with "third connection was not admitted";
         end select;
         Manager.Request_Shutdown;
         Manager.Await_Drained;
         select
            State.Wait_Third_Finished;
         or
            delay 2.0;
            raise Program_Error with "third connection did not shut down";
         end select;
      exception
         when Occurrence : others =>
            begin
               Manager.Request_Shutdown;
            exception
               when others =>
                  null;
            end;
            begin
               GNAT.Sockets.Close_Socket (Peer_Three);
               Peer_Three := GNAT.Sockets.No_Socket;
            exception
               when others =>
                  null;
            end;
            Ada.Exceptions.Reraise_Occurrence (Occurrence);
      end;
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
         task Acceptor is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Acceptor;

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
         begin
            for Attempt in 1 .. 2_000 loop
               exit when Accept_Manager.Active = 1;
               delay 0.001;
            end loop;
            if Accept_Manager.Active /= 1 then
               raise Program_Error with "acceptor did not reserve capacity";
            end if;
            Accept_Manager.Request_Shutdown;
            Accept_Manager.Await_Drained;
            select
               Result.Wait;
            or
               delay 2.0;
               raise Program_Error with "acceptor did not cancel";
            end select;
         exception
            when Occurrence : others =>
               begin
                  Accept_Manager.Request_Shutdown;
               exception
                  when others =>
                     null;
               end;
               begin
                  GNAT.Sockets.Close_Socket (Listener);
                  Listener := GNAT.Sockets.No_Socket;
               exception
                  when others =>
                     null;
               end;
               Ada.Exceptions.Reraise_Occurrence (Occurrence);
         end;
      end;

      pragma Assert (Result.Passed);
      if Listener /= GNAT.Sockets.No_Socket then
         GNAT.Sockets.Close_Socket (Listener);
      end if;
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
            pragma Task_Info (Flyology.Native_Task);
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
                  Cancellation_Quantum => 10.0,
                  Token => Native_Token'Access);
            exception
               when Connections.Operation_Cancelled =>
                  Was_Cancelled := True;
            end;
            Result.Finished (Was_Cancelled);
         end Native_Worker;
      begin
         begin
            delay 0.020;
            Native_Token.Request;
            select
               Result.Wait;
            or
               delay 2.0;
               raise Program_Error with "native connection did not cancel";
            end select;
         exception
            when Occurrence : others =>
               begin
                  Native_Token.Request;
               exception
                  when others =>
                     null;
               end;
               begin
                  GNAT.Sockets.Close_Socket (Native_Peer);
                  Native_Peer := GNAT.Sockets.No_Socket;
               exception
                  when others =>
                     null;
               end;
               Ada.Exceptions.Reraise_Occurrence (Occurrence);
         end;
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
