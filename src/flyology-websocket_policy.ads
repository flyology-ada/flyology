with Ada.Streams;

--  Internal, proved WebSocket receive-state and timeout retry policy used by
--  the production framing core and high-level handlers.
private package Flyology.WebSocket_Policy
  with Preelaborate,
       SPARK_Mode => On
is

   type Timeout_Action is (Retry_Receive, Propagate_Timeout);

   type Frame_Opcode is
     (Continuation_Opcode,
      Text_Opcode,
      Binary_Opcode,
      Close_Opcode,
      Ping_Opcode,
      Pong_Opcode);

   function Is_Control (Opcode : Frame_Opcode) return Boolean is
     (Opcode in Close_Opcode | Ping_Opcode | Pong_Opcode);

   Max_Frame_Length : constant := 16 * 1_024 * 1_024;
   subtype Frame_Length is Natural range 0 .. Max_Frame_Length;
   subtype Mask_Index is Natural range 0 .. 3;
   type Mask_Key is array (Mask_Index) of Ada.Streams.Stream_Element;

   type Cursor_Phase is (Awaiting_Header, Reading_Payload);

   type Frame_Cursor (Phase : Cursor_Phase := Awaiting_Header) is record
      case Phase is
         when Awaiting_Header =>
            null;
         when Reading_Payload =>
            Opcode    : Frame_Opcode;
            Final     : Boolean;
            Total     : Frame_Length;
            Remaining : Frame_Length;
            Position  : Frame_Length;
            Mask      : Mask_Key;
      end case;
   end record
   with
     Dynamic_Predicate =>
       (Frame_Cursor.Phase = Awaiting_Header
        or else
          (Frame_Cursor.Position <= Frame_Cursor.Total
           and then Frame_Cursor.Remaining =
             Frame_Cursor.Total - Frame_Cursor.Position
           and then
             (not Is_Control (Frame_Cursor.Opcode)
              or else
                (Frame_Cursor.Final and then Frame_Cursor.Total <= 125))));

   --  Enter payload-reading state only after production has validated and
   --  retained a complete frame header and mask.
   procedure Begin_Frame
     (Cursor  : in out Frame_Cursor;
      Opcode  : Frame_Opcode;
      Final   : Boolean;
      Length  : Frame_Length;
      Mask    : Mask_Key)
   with
     Global => null,
     Pre    =>
       not Cursor'Constrained
       and then Cursor.Phase = Awaiting_Header
       and then
         (not Is_Control (Opcode) or else (Final and then Length <= 125)),
     Post   =>
       Cursor.Phase = Reading_Payload
       and then Cursor.Opcode = Opcode
       and then Cursor.Final = Final
       and then Cursor.Total = Length
       and then Cursor.Remaining = Length
       and then Cursor.Position = 0
       and then Cursor.Mask = Mask;

   --  Select the mask byte for a relative byte in the next payload chunk.
   --  The absolute masking position advances across receive calls.
   function Mask_Offset
     (Cursor   : Frame_Cursor;
      Relative : Natural) return Mask_Index
   with
     Global => null,
     Pre    =>
       Cursor.Phase = Reading_Payload
       and then Relative < Cursor.Remaining,
     Post   =>
       Mask_Offset'Result =
         (Cursor.Position mod 4 + Relative mod 4) mod 4;

   --  Commit payload bytes already removed from the pending input and placed
   --  in their destination. Reading_Payload remains active even when the
   --  frame becomes complete; only an explicit completion or abandonment
   --  transition permits another header parse.
   procedure Advance
     (Cursor : in out Frame_Cursor;
      Count  : Natural)
   with
     Global => null,
     Pre    =>
       Cursor.Phase = Reading_Payload
       and then Count in 1 .. Cursor.Remaining,
     Post   =>
       Cursor.Phase = Reading_Payload
       and then Cursor.Opcode = Cursor'Old.Opcode
       and then Cursor.Final = Cursor'Old.Final
       and then Cursor.Total = Cursor'Old.Total
       and then Cursor.Remaining = Cursor'Old.Remaining - Count
       and then Cursor.Position = Cursor'Old.Position + Count
       and then Cursor.Mask = Cursor'Old.Mask;

   --  Mark a fully consumed frame complete. Header parsing is legal again
   --  only after this explicit semantic boundary.
   procedure Complete_Frame (Cursor : in out Frame_Cursor)
   with
     Global => null,
     Pre    =>
       not Cursor'Constrained
       and then Cursor.Phase = Reading_Payload
       and then Cursor.Remaining = 0,
     Post   => Cursor.Phase = Awaiting_Header;

   --  Discard any partial cursor during initialization or terminal cleanup.
   procedure Abandon_Frame (Cursor : in out Frame_Cursor)
   with
     Global => null,
     Pre    => not Cursor'Constrained,
     Post   => Cursor.Phase = Awaiting_Header;

   --  Retry a receive-quantum timeout only while the connection remains
   --  active and the enclosing request still has retry budget. A negative
   --  remaining value denotes the existing unlimited-deadline sentinel.
   function Classify_Timeout
     (Failed_Or_Terminal : Boolean;
      Remaining          : Duration) return Timeout_Action
   with
     Global         => null,
     Contract_Cases =>
       (Failed_Or_Terminal or else Remaining = 0.0 =>
          Classify_Timeout'Result = Propagate_Timeout,
        others =>
          Classify_Timeout'Result = Retry_Receive);

end Flyology.WebSocket_Policy;
