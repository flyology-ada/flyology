with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Process_Generations;
with Flyology.Process_Generations.Protocol;
with Flyology.Process_Generations.Transport;
with Interfaces;

procedure Process_Generation_Transport_Smoke is
   package Generations renames Flyology.Process_Generations;
   package Protocol renames Flyology.Process_Generations.Protocol;
   package Sockets renames Flyology.IO.Sockets;
   package Transport renames Flyology.Process_Generations.Transport;

   use type Protocol.Message_Kind;
   use type Protocol.Octet;
   use type Generations.Image_Generation;
   use type Interfaces.Unsigned_64;

   Authority : constant Generations.Upgrade_Handle :=
     (Coordinator => 3, Upgrade => 5, Candidate => 7);

   procedure Round_Trip is
      Left_Socket  : Sockets.Socket_Type;
      Right_Socket : Sockets.Socket_Type;
      Left         : Transport.Control_Channel;
      Right        : Transport.Control_Channel;
      Frame        : Protocol.Frame;
      Payload      : Protocol.Payload_Buffer := (others => 0);
   begin
      Sockets.Create_Socket_Pair (Left_Socket, Right_Socket);
      Transport.Adopt (Left, Left_Socket, Authority);
      Transport.Adopt (Right, Right_Socket, Authority);
      Payload (0) := 16#AA#;
      Payload (1) := 16#BB#;
      Transport.Send (Left, Protocol.Provision, Payload, 2, Timeout => 1.0);
      Transport.Receive (Right, Frame, Timeout => 1.0);
      pragma Assert (Frame.Kind = Protocol.Provision);
      pragma Assert (Frame.Sequence = 1);
      pragma Assert (Frame.Length = 2);
      pragma Assert
        (Frame.Payload (0) = 16#AA# and then Frame.Payload (1) = 16#BB#);

      Transport.Send (Right, Protocol.Acknowledgment, Timeout => 1.0);
      Transport.Receive (Left, Frame, Timeout => 1.0);
      pragma Assert
        (Frame.Kind = Protocol.Acknowledgment and then Frame.Sequence = 1);

      Transport.Send (Left, Protocol.Prepared_Message, Timeout => 1.0);
      Transport.Receive (Right, Frame, Timeout => 1.0);
      pragma Assert (Frame.Sequence = 2);
   end Round_Trip;

   procedure Reject_Stale_Authority is
      Left_Socket  : Sockets.Socket_Type;
      Right_Socket : Sockets.Socket_Type;
      Left         : Transport.Control_Channel;
      Right        : Transport.Control_Channel;
      Frame        : Protocol.Frame;
      Rejected     : Boolean := False;
   begin
      Sockets.Create_Socket_Pair (Left_Socket, Right_Socket);
      Transport.Adopt (Left, Left_Socket, Authority);
      Transport.Adopt
        (Right, Right_Socket,
         (Coordinator => Authority.Coordinator,
          Upgrade => Authority.Upgrade,
          Candidate => Authority.Candidate + 1));
      Transport.Send (Left, Protocol.Hello, Timeout => 1.0);
      begin
         Transport.Receive (Right, Frame, Timeout => 1.0);
      exception
         when Transport.Protocol_Error => Rejected := True;
      end;
      pragma Assert (Rejected);
      pragma Assert (Transport.Is_Poisoned (Right));
      pragma Assert (not Transport.Is_Open (Right));
   end Reject_Stale_Authority;

   procedure Timeout_Poisons is
      Left_Socket  : Sockets.Socket_Type;
      Right_Socket : Sockets.Socket_Type;
      Left         : Transport.Control_Channel;
      Right        : Transport.Control_Channel;
      Frame        : Protocol.Frame;
      Timed_Out    : Boolean := False;
   begin
      Sockets.Create_Socket_Pair (Left_Socket, Right_Socket);
      Transport.Adopt (Left, Left_Socket, Authority);
      Transport.Adopt (Right, Right_Socket, Authority);
      begin
         Transport.Receive (Right, Frame, Timeout => 0.01);
      exception
         when Flyology.IO.Timeout_Error => Timed_Out := True;
      end;
      pragma Assert (Timed_Out);
      pragma Assert (Transport.Is_Poisoned (Right));
      pragma Assert (not Transport.Is_Open (Right));
   end Timeout_Poisons;

begin
   Round_Trip;
   Reject_Stale_Authority;
   Timeout_Poisons;
end Process_Generation_Transport_Smoke;
