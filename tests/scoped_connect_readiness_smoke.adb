with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Operations;

procedure Scoped_Connect_Readiness_Smoke is
   package Sock renames Flyology.IO.Sockets;
   package Ops renames Flyology.Operations;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Ops.Terminal_Outcome;

   type Filler_Array is array (1 .. 16) of Sock.Socket_Type;
   type Pending_Case is (Consumed_Interrupt, Unconsumed_Interrupt, Deadline);

   procedure Close (Socket : in out Sock.Socket_Type) is
   begin
      if Sock.Is_Open (Socket) then
         Sock.Close_Socket (Socket);
      end if;
   end Close;

   procedure Open_Listener
     (Listener : in out Sock.Socket_Type; Address : out Sock.Endpoint) is
   begin
      Sock.Create_Socket (Listener);
      Sock.Bind_Socket
        (Listener, Sock.Network_Endpoint (Sock.Loopback_IPv4, Sock.Any_Port));
      Sock.Listen_Socket (Listener, Length => 1);
      Address := Sock.Get_Socket_Name (Listener);
   end Open_Listener;

   procedure Saturate
     (Listener : in out Sock.Socket_Type;
      Fillers  : in out Filler_Array;
      Address  : out Sock.Endpoint)
   is
      Full : Boolean := False;
   begin
      Open_Listener (Listener, Address);
      --  Keep every caller-owned socket open and never accept. The bound is
      --  test storage, not an assumption about the host's actual queue size.
      for Filler of Fillers loop
         Sock.Create_Socket (Filler);
         begin
            Sock.Connect (Filler, Address, Timeout => 0.1);
         exception
            when Flyology.IO.Timeout_Error =>
               Full := True;
         end;
         exit when Full;
      end loop;
      pragma Assert (Full, "setup: bounded loopback backlog did not saturate");
   end Saturate;

   function Writable (Socket : Sock.Socket_Type) return Boolean is
      Requests : constant Flyology.IO.Wait_Request_Array :=
        (1 =>
           (FD        => Sock.Native_Descriptor (Socket),
            Condition => Flyology.IO.For_Write));
   begin
      return Flyology.IO.Wait_Any (Requests, Timeout => 0.0) /= 0;
   end Writable;

   procedure Assert_No_Peer (Socket : Sock.Socket_Type) is
      Present : Boolean := False;
   begin
      begin
         declare
            Peer : constant Sock.Endpoint := Sock.Get_Peer_Name (Socket);
         begin
            pragma Unreferenced (Peer);
            Present := True;
         end;
      exception
         when Sock.Socket_Error =>
            null;
      end;
      pragma Assert (not Present, "setup: pending socket already has a peer");
   end Assert_No_Peer;

   procedure Run_Pending (Kind : Pending_Case) is
      Listener, Client, Int_A, Int_B : aliased Sock.Socket_Type;
      Fillers                        : Filler_Array;
      Address                        : Sock.Endpoint;
      Set                            :
        aliased Ops.Completion_Set (Capacity => 2);
      Batch                          : Ops.Completion_Batch (Capacity => 2);
      Drain                          :
        aliased Ada.Streams.Stream_Element_Array := (1 .. 1 => 0);
      Signal                         :
        constant Ada.Streams.Stream_Element_Array := (1 .. 1 => 97);
      Last                           : Ada.Streams.Stream_Element_Offset;

      procedure Close_Owners is
      begin
         Close (Client);
         Close (Int_A);
         Close (Int_B);
         for Filler of Fillers loop
            Close (Filler);
         end loop;
         Close (Listener);
      end Close_Owners;
   begin
      Saturate (Listener, Fillers, Address);
      Sock.Create_Socket (Client);
      Sock.Create_Socket_Pair (Int_A, Int_B);
      declare
         Drainer : Sock.Receive_Operation (Set'Access);
      begin
         if Kind = Consumed_Interrupt then
            Sock.Receive (Int_A'Access, Drain'Access, 1.0, Drainer);
         end if;
         declare
            Conn : Sock.Connect_Operation :=
              Sock.Connect
                (Set'Access,
                 Client'Access,
                 Address,
                 0.2,
                 Interrupts => (1 => Sock.Native_Descriptor (Int_A)));
         begin
            pragma
              Assert
                (not Ops.Is_Terminal (Conn),
                 "setup: loopback connect must actually be pending");
            pragma
              Assert
                (not Writable (Client),
                 "setup: pending connect must not be writable");
            Assert_No_Peer (Client);
            if Kind /= Deadline then
               Sock.Send_Socket (Int_B, Signal, Last);
               pragma Assert (Last = 1);
            end if;
            Ops.Wait_Some (Set, Batch);
            if Kind = Consumed_Interrupt then
               pragma Assert (Ops.Is_Terminal (Drainer));
               Sock.Finish (Drainer, Last);
               pragma Assert (Last = 1 and then Drain (1) = Signal (1));
               pragma
                 Assert
                   (not Writable (Client),
                    "setup: connect completed before the regression cut");
               Assert_No_Peer (Client);
               pragma
                 Assert
                   (not Ops.Is_Terminal (Conn),
                    "consumed interrupt must not complete a pending connect");
               --  The re-arm retains the existing overall deadline. It does
               --  not create another connection attempt or restart the timeout.
               Ops.Wait_Some (Set, Batch);
            end if;
            pragma Assert (Ops.Outcome (Conn) = Ops.Failed);
            begin
               Sock.Finish (Conn);
               raise Program_Error
                 with "pending connect must report its retained failure";
            exception
               when Sock.Operation_Interrupted =>
                  pragma Assert (Kind = Unconsumed_Interrupt);
               when Flyology.IO.Timeout_Error =>
                  pragma Assert (Kind /= Unconsumed_Interrupt);
            end;
         end;
      end;
      Close_Owners;
   exception
      when others =>
         Close_Owners;
         raise;
   end Run_Pending;

   procedure Run_Resolved (Refused : Boolean) is
      Listener, Client, Accepted : aliased Sock.Socket_Type;
      Address, Peer              : Sock.Endpoint;
      Set                        : aliased Ops.Completion_Set (Capacity => 1);
      Batch                      : Ops.Completion_Batch (Capacity => 1);
   begin
      Open_Listener (Listener, Address);
      if Refused then
         Close (Listener);
      end if;
      Sock.Create_Socket (Client);
      declare
         Conn : Sock.Connect_Operation :=
           Sock.Connect (Set'Access, Client'Access, Address, 1.0);
      begin
         Ops.Wait_Some (Set, Batch);
         if Refused then
            pragma Assert (Ops.Outcome (Conn) = Ops.Failed);
            begin
               Sock.Finish (Conn);
               raise Program_Error
                 with "refused connect must raise Socket_Error";
            exception
               when Sock.Socket_Error =>
                  null;
            end;
         else
            pragma Assert (Ops.Outcome (Conn) = Ops.Succeeded);
            Sock.Finish (Conn);
            Peer := Sock.Get_Peer_Name (Client);
            pragma Assert (Sock.Image (Peer) = Sock.Image (Address));
            Sock.Accept_Connection (Listener, Accepted, Peer, Timeout => 1.0);
         end if;
      end;
      Close (Accepted);
      Close (Client);
      Close (Listener);
   exception
      when others =>
         Close (Accepted);
         Close (Client);
         Close (Listener);
         raise;
   end Run_Resolved;

   generic
      Model : Flyology.Execution_Model;
   procedure Run;

   procedure Run is
      Failed  : Boolean := False;
      Failure : Ada.Exceptions.Exception_Occurrence;
   begin
      declare
         task Caller is
            pragma Task_Info (Model);
         end Caller;
         task body Caller is
         begin
            Run_Resolved (False);
            Run_Resolved (True);
            Run_Pending (Unconsumed_Interrupt);
            Run_Pending (Deadline);
            Run_Pending (Consumed_Interrupt);
         exception
            when E : others =>
               Ada.Exceptions.Save_Occurrence (Failure, E);
               Failed := True;
         end Caller;
      begin
         null;
      end;
      if Failed then
         Ada.Exceptions.Reraise_Occurrence (Failure);
      end if;
      Ada.Text_IO.Put_Line
        ("scoped connect readiness controls and regression passed");
   end Run;

   procedure Run_Native is new Run (Flyology.Native_Task);
   procedure Run_Lightweight is new Run (Flyology.Lightweight_Task);
begin
   if Ada.Command_Line.Argument_Count = 0 then
      Run_Native;
      Run_Lightweight;
   elsif Ada.Command_Line.Argument_Count = 1
     and then Ada.Command_Line.Argument (1) = "native"
   then
      Run_Native;
   elsif Ada.Command_Line.Argument_Count = 1
     and then Ada.Command_Line.Argument (1) = "lightweight"
   then
      Run_Lightweight;
   else
      raise Program_Error with "expected native or lightweight test lane";
   end if;
end Scoped_Connect_Readiness_Smoke;
