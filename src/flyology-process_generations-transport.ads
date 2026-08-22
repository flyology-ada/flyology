with Flyology.IO.Sockets;
with Flyology.Cancellation;
with Flyology.Process_Generations.Protocol;
with Interfaces;

--  Lockstep framed control transport for one exact upgrade authority. One
--  send or receive may be active at a time. This deliberate serialization
--  keeps partial-frame failure, close, and poisoning ownership unambiguous.
package Flyology.Process_Generations.Transport is
   package Protocol renames Flyology.Process_Generations.Protocol;
   package Sockets renames Flyology.IO.Sockets;

   --  Frame structure or message ordering is invalid.
   Protocol_Error  : exception;
   --  A peer sequence is stale, skipped, or exhausted.
   Sequence_Error  : exception;
   --  A second operation attempted to use the serialized channel.
   Channel_Busy    : exception;
   --  The frame authority does not match the adopted transaction.
   Validation_Error : exception;
   --  Socket I/O or timeout prevented a complete operation.
   Transport_Error : exception;

   --  Sole owner of an authority-bound framed control stream.
   type Control_Channel is limited private;

   --  Transfer a connected AF_UNIX stream socket into a closed control
   --  channel and bind every future frame to Authority.
   --  @param Item Closed destination channel
   --  @param Socket Connected stream socket whose ownership is transferred
   --  @param Authority Exact transaction required on every frame
   procedure Adopt
     (Item      : in out Control_Channel;
      Socket    : in out Sockets.Socket_Type;
      Authority : Upgrade_Handle)
   with Post => not Sockets.Is_Open (Socket);

   --  Close the stream and consume its channel ownership.
   --  @param Item Channel to close
   procedure Close (Item : in out Control_Channel);
   --  Report whether the channel currently owns an open stream.
   --  @param Item Channel to inspect
   --  @return True when the stream is open
   function Is_Open (Item : Control_Channel) return Boolean;
   --  Report whether an earlier failed operation poisoned the channel.
   --  @param Item Channel to inspect
   --  @return True when failure made the stream unusable
   function Is_Poisoned (Item : Control_Channel) return Boolean;

   --  Wait for the start of the next frame without consuming stream bytes.
   --  Cancellation is therefore safe: a caller may send a compensating command
   --  on the same channel after Operation_Cancelled is raised.
   --  @param Item Open authority-bound channel
   --  @param Timeout Maximum readiness wait
   --  @param Token Optional one-shot cancellation source
   --  @return True when a frame or peer closure is readable; False on timeout
   --  @exception Operation_Cancelled Token is requested
   function Message_Available
     (Item    : Control_Channel;
      Timeout : Duration := Flyology.IO.Infinite;
      Token   : access Flyology.Cancellation.Token := null) return Boolean;

   --  Send one frame with a bounded payload.
   --  @param Item Authority-bound destination channel
   --  @param Kind Control message kind
   --  @param Payload Payload storage
   --  @param Length Significant payload bytes
   --  @param Timeout Total operation timeout
   procedure Send
     (Item    : in out Control_Channel;
      Kind    : Protocol.Message_Kind;
      Payload : Protocol.Payload_Buffer;
      Length  : Protocol.Payload_Length;
      Timeout : Duration := Flyology.IO.Infinite);

   --  Send one frame with an empty payload.
   --  @param Item Authority-bound destination channel
   --  @param Kind Control message kind
   --  @param Timeout Total operation timeout
   procedure Send
     (Item    : in out Control_Channel;
      Kind    : Protocol.Message_Kind;
      Timeout : Duration := Flyology.IO.Infinite);

   --  Receive exactly one frame. Invalid framing, stale authority, unexpected
   --  sequence, partial I/O failure, and timeout poison and close the channel.
   --  @param Item Authority-bound source channel
   --  @param Frame Received frame
   --  @param Timeout Total operation timeout
   procedure Receive
     (Item    : in out Control_Channel;
      Frame   : out Protocol.Frame;
      Timeout : Duration := Flyology.IO.Infinite);

private
   type Direction is (Sending, Receiving);
   type Channel_State is (Closed, Ready, Busy, Poisoned, Exhausted);
   type Begin_Result is
     (Acquired, Was_Closed, Was_Busy, Was_Poisoned, Was_Exhausted);

   protected type Channel_Controller is
      procedure Adopt
        (Authority : Upgrade_Handle;
         Accepted  : out Boolean);
      procedure Begin_Operation
        (Way       : Direction;
         Authority : out Upgrade_Handle;
         Sequence  : out Interfaces.Unsigned_64;
         Result    : out Begin_Result);
      procedure Finish (Way : Direction);
      procedure Fail;
      procedure Take_For_Close (Busy_Now : out Boolean);
      function Open return Boolean;
      function Failed return Boolean;
   private
      State : Channel_State := Closed;
      Authority_Value : Upgrade_Handle :=
        (Coordinator => 1, Upgrade => 1, Candidate => 1);
      Next_Send    : Interfaces.Unsigned_64 := 1;
      Next_Receive : Interfaces.Unsigned_64 := 1;
   end Channel_Controller;

   type Control_Channel is limited record
      Socket     : Sockets.Socket_Type;
      Controller : Channel_Controller;
   end record;
end Flyology.Process_Generations.Transport;
