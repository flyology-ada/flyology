with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Flyology.Descriptor_Handoffs;
with Interfaces.C;

package body Flyology.Process_Generations.Transport is
   package Descriptor_Handoffs renames Flyology.Descriptor_Handoffs;

   use type Ada.Exceptions.Exception_Id;
   use type Ada.Real_Time.Time;
   use type Ada.Streams.Stream_Element_Offset;
   use type Interfaces.Unsigned_64;
   use type Interfaces.C.int;
   use type Protocol.Decode_Status;

   protected body Channel_Controller is
      procedure Adopt
        (Authority : Upgrade_Handle;
         Accepted  : out Boolean) is
      begin
         Accepted := State = Closed;
         if Accepted then
            Authority_Value := Authority;
            Next_Send := 1;
            Next_Receive := 1;
            State := Ready;
         end if;
      end Adopt;

      procedure Begin_Operation
        (Way       : Direction;
         Authority : out Upgrade_Handle;
         Sequence  : out Interfaces.Unsigned_64;
         Result    : out Begin_Result) is
      begin
         Authority := Authority_Value;
         Sequence := 1;
         case State is
            when Ready =>
               State := Busy;
               Sequence :=
                 (if Way = Sending then Next_Send else Next_Receive);
               Result := Acquired;
            when Closed => Result := Was_Closed;
            when Busy => Result := Was_Busy;
            when Poisoned => Result := Was_Poisoned;
            when Exhausted => Result := Was_Exhausted;
         end case;
      end Begin_Operation;

      procedure Finish (Way : Direction) is
      begin
         if State = Busy then
            if (Way = Sending and then Next_Send = Interfaces.Unsigned_64'Last)
              or else
                (Way = Receiving and then
                   Next_Receive = Interfaces.Unsigned_64'Last)
            then
               State := Exhausted;
            else
               if Way = Sending then
                  Next_Send := Next_Send + 1;
               else
                  Next_Receive := Next_Receive + 1;
               end if;
               State := Ready;
            end if;
         end if;
      end Finish;

      procedure Fail is
      begin
         State := Poisoned;
      end Fail;

      procedure Take_For_Close (Busy_Now : out Boolean) is
      begin
         Busy_Now := State = Busy;
         if not Busy_Now then
            State := Closed;
         end if;
      end Take_For_Close;

      function Open return Boolean is (State in Ready | Busy);
      function Failed return Boolean is (State in Poisoned | Exhausted);
   end Channel_Controller;

   procedure Raise_Begin (Result : Begin_Result) is
   begin
      case Result is
         when Acquired => null;
         when Was_Closed =>
            raise Validation_Error with "control channel is closed";
         when Was_Busy =>
            raise Channel_Busy with "control channel is already in use";
         when Was_Poisoned =>
            raise Protocol_Error with "control channel is poisoned";
         when Was_Exhausted =>
            raise Sequence_Error with "control sequence space is exhausted";
      end case;
   end Raise_Begin;

   procedure Poison (Item : in out Control_Channel) is
   begin
      Item.Controller.Fail;
      if Sockets.Is_Open (Item.Socket) then
         begin
            Sockets.Close_Socket (Item.Socket);
         exception
            when others => null;
         end;
      end if;
   end Poison;

   procedure Retire_If_Exhausted (Item : in out Control_Channel) is
   begin
      if Item.Controller.Failed and then Sockets.Is_Open (Item.Socket) then
         Sockets.Close_Socket (Item.Socket);
      end if;
   end Retire_If_Exhausted;

   function Remaining
     (Started : Ada.Real_Time.Time;
      Timeout : Duration) return Duration
   is
      Elapsed : constant Duration := Ada.Real_Time.To_Duration
        (Ada.Real_Time.Clock - Started);
   begin
      if Timeout < 0.0 then
         return Flyology.IO.Infinite;
      elsif Elapsed >= Timeout then
         return 0.0;
      else
         return Timeout - Elapsed;
      end if;
   end Remaining;

   procedure Reraise_Transport
     (Error : Ada.Exceptions.Exception_Occurrence) is
   begin
      if Ada.Exceptions.Exception_Identity (Error) = Protocol_Error'Identity
        or else Ada.Exceptions.Exception_Identity (Error) =
          Sequence_Error'Identity
        or else Ada.Exceptions.Exception_Identity (Error) =
          Channel_Busy'Identity
        or else Ada.Exceptions.Exception_Identity (Error) =
          Validation_Error'Identity
        or else Ada.Exceptions.Exception_Identity (Error) =
          Flyology.IO.Timeout_Error'Identity
      then
         Ada.Exceptions.Reraise_Occurrence (Error);
      else
         raise Transport_Error with Ada.Exceptions.Exception_Message (Error);
      end if;
   end Reraise_Transport;

   procedure Adopt
     (Item      : in out Control_Channel;
      Socket    : in out Sockets.Socket_Type;
      Authority : Upgrade_Handle)
   is
      Accepted : Boolean;
      Raw : Flyology.IO.Descriptor;
   begin
      if not Sockets.Is_Open (Socket) then
         raise Validation_Error with "control carrier is closed";
      elsif Is_Open (Item) then
         raise Validation_Error with "control channel is already open";
      elsif Is_Poisoned (Item) then
         raise Protocol_Error with "control channel is poisoned";
      end if;
      Raw := Sockets.Native_Descriptor (Socket);
      begin
         Descriptor_Handoffs.Validate_Carrier
           (Descriptor_Handoffs.Socket_Descriptor (Interfaces.C.int (Raw)),
            Descriptor_Handoffs.Trusted_Peer);
      exception
         when Error : others =>
            raise Validation_Error with
              Ada.Exceptions.Exception_Message (Error);
      end;
      Item.Controller.Adopt (Authority, Accepted);
      if not Accepted then
         raise Validation_Error with "control channel is already open";
      end if;
      begin
         Sockets.Move (Socket, Item.Socket);
      exception
         when others =>
            Item.Controller.Fail;
            raise;
      end;
   end Adopt;

   procedure Close (Item : in out Control_Channel) is
      Busy_Now : Boolean;
   begin
      Item.Controller.Take_For_Close (Busy_Now);
      if Busy_Now then
         raise Channel_Busy with "control channel is already in use";
      elsif Sockets.Is_Open (Item.Socket) then
         begin
            Sockets.Close_Socket (Item.Socket);
         exception
            when Error : others =>
               raise Transport_Error with
                 Ada.Exceptions.Exception_Message (Error);
         end;
      end if;
   end Close;

   function Is_Open (Item : Control_Channel) return Boolean is
     (Item.Controller.Open and then Sockets.Is_Open (Item.Socket));

   function Is_Poisoned (Item : Control_Channel) return Boolean is
     (Item.Controller.Failed);

   function Message_Available
     (Item    : Control_Channel;
      Timeout : Duration := Flyology.IO.Infinite;
      Token   : access Flyology.Cancellation.Token := null) return Boolean
   is
      Wake_FD   : Interfaces.C.int := -1;
      Requested : Boolean := False;
   begin
      if not Is_Open (Item) then
         raise Validation_Error with "control channel is closed";
      elsif Token = null then
         return Flyology.IO.Wait
           (Sockets.Native_Descriptor (Item.Socket), Flyology.IO.For_Read,
            Timeout);
      end if;

      Token.Wait_Source (Wake_FD, Requested);
      if Requested then
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;
      declare
         Interrupts : constant Flyology.IO.Interrupt_Set (1 .. 1) :=
           (1 => Wake_FD);
      begin
         case Flyology.IO.Wait_Interruptibly
           (Sockets.Native_Descriptor (Item.Socket), Flyology.IO.For_Read,
            Timeout, Interrupts)
         is
            when Flyology.IO.Ready => return True;
            when Flyology.IO.Timed_Out => return False;
            when Flyology.IO.Interrupted =>
               raise Flyology.Cancellation.Operation_Cancelled;
         end case;
      end;
   exception
      when Flyology.IO.Device_Error =>
         raise Transport_Error with "control readiness wait failed";
   end Message_Available;

   procedure Send
     (Item    : in out Control_Channel;
      Kind    : Protocol.Message_Kind;
      Payload : Protocol.Payload_Buffer;
      Length  : Protocol.Payload_Length;
      Timeout : Duration := Flyology.IO.Infinite)
   is
      Authority : Upgrade_Handle;
      Sequence  : Interfaces.Unsigned_64;
      Result    : Begin_Result;
   begin
      Item.Controller.Begin_Operation
        (Sending, Authority, Sequence, Result);
      Raise_Begin (Result);
      begin
         declare
            Frame : constant Protocol.Frame :=
              (Kind      => Kind,
               Authority => Authority,
               Sequence  => Sequence,
               Length    => Length,
               Payload   => Payload);
            Octets : Protocol.Octet_Array
              (0 .. Protocol.Encoded_Length (Frame) - 1);
            Bytes : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset
                (Protocol.Encoded_Length (Frame)));
         begin
            Protocol.Encode (Frame, Octets);
            for Index in Octets'Range loop
               Bytes
                 (Bytes'First + Ada.Streams.Stream_Element_Offset (Index)) :=
                   Ada.Streams.Stream_Element (Octets (Index));
            end loop;
            Sockets.Send_All (Item.Socket, Bytes, Timeout => Timeout);
         end;
         Item.Controller.Finish (Sending);
         Retire_If_Exhausted (Item);
      exception
         when Error : others =>
            Poison (Item);
            Reraise_Transport (Error);
      end;
   end Send;

   procedure Send
     (Item    : in out Control_Channel;
      Kind    : Protocol.Message_Kind;
      Timeout : Duration := Flyology.IO.Infinite) is
   begin
      Send (Item, Kind, (others => 0), 0, Timeout);
   end Send;

   procedure Receive
     (Item    : in out Control_Channel;
      Frame   : out Protocol.Frame;
      Timeout : Duration := Flyology.IO.Infinite)
   is
      Authority : Upgrade_Handle;
      Sequence  : Interfaces.Unsigned_64;
      Result    : Begin_Result;
      Header_Bytes : Ada.Streams.Stream_Element_Array
        (1 .. Ada.Streams.Stream_Element_Offset (Protocol.Header_Length));
      Header : Protocol.Octet_Array (0 .. Protocol.Header_Length - 1);
      Length : Protocol.Payload_Length;
      Status : Protocol.Decode_Status;
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      Frame :=
        (Kind      => Protocol.Hello,
         Authority => (Coordinator => 1, Upgrade => 1, Candidate => 1),
         Sequence  => 1,
         Length    => 0,
         Payload   => (others => 0));
      Item.Controller.Begin_Operation
        (Receiving, Authority, Sequence, Result);
      Raise_Begin (Result);
      begin
         Sockets.Receive_Exactly
           (Item.Socket, Header_Bytes,
            Timeout => Remaining (Started, Timeout));
         for Index in Header'Range loop
            Header (Index) := Protocol.Octet
              (Header_Bytes
                 (Header_Bytes'First +
                    Ada.Streams.Stream_Element_Offset (Index)));
         end loop;
         Protocol.Inspect_Header (Header, Length, Status);
         if Status /= Protocol.Decoded then
            raise Protocol_Error with
              "invalid control header: " &
              Protocol.Decode_Status'Image (Status);
         end if;
         declare
            Octets : Protocol.Octet_Array
              (0 .. Protocol.Header_Length + Length - 1);
         begin
            Octets (0 .. Protocol.Header_Length - 1) := Header;
            if Length > 0 then
               declare
                  Payload_Bytes : Ada.Streams.Stream_Element_Array
                    (1 .. Ada.Streams.Stream_Element_Offset (Length));
               begin
                  Sockets.Receive_Exactly
                    (Item.Socket, Payload_Bytes,
                     Timeout => Remaining (Started, Timeout));
                  for Index in 0 .. Length - 1 loop
                     Octets (Protocol.Header_Length + Index) := Protocol.Octet
                       (Payload_Bytes
                          (Payload_Bytes'First +
                             Ada.Streams.Stream_Element_Offset (Index)));
                  end loop;
               end;
            end if;
            Protocol.Decode (Octets, Frame, Status);
         end;
         if Status /= Protocol.Decoded then
            raise Protocol_Error with
              "invalid control frame: " &
              Protocol.Decode_Status'Image (Status);
         elsif not Same_Upgrade (Frame.Authority, Authority) then
            raise Protocol_Error with
              "control authority does not match channel";
         elsif Frame.Sequence /= Sequence then
            raise Sequence_Error with "control sequence is out of order";
         end if;
         Item.Controller.Finish (Receiving);
         Retire_If_Exhausted (Item);
      exception
         when Error : others =>
            Poison (Item);
            Reraise_Transport (Error);
      end;
   end Receive;
end Flyology.Process_Generations.Transport;
