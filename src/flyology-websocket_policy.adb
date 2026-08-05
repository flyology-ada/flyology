package body Flyology.WebSocket_Policy
  with SPARK_Mode => On
is

   procedure Begin_Frame
     (Cursor  : in out Frame_Cursor;
      Opcode  : Frame_Opcode;
      Final   : Boolean;
      Length  : Frame_Length;
      Mask    : Mask_Key)
   is
   begin
      Cursor :=
        (Phase     => Reading_Payload,
         Opcode    => Opcode,
         Final     => Final,
         Total     => Length,
         Remaining => Length,
         Position  => 0,
         Mask      => Mask);
   end Begin_Frame;

   function Mask_Offset
     (Cursor   : Frame_Cursor;
      Relative : Natural) return Mask_Index
   is
     (Mask_Index ((Cursor.Position mod 4 + Relative mod 4) mod 4));

   procedure Advance
     (Cursor : in out Frame_Cursor;
      Count  : Natural)
   is
   begin
      Cursor :=
        (Phase     => Reading_Payload,
         Opcode    => Cursor.Opcode,
         Final     => Cursor.Final,
         Total     => Cursor.Total,
         Remaining => Cursor.Remaining - Count,
         Position  => Cursor.Position + Count,
         Mask      => Cursor.Mask);
   end Advance;

   procedure Complete_Frame (Cursor : in out Frame_Cursor) is
   begin
      Cursor := (Phase => Awaiting_Header);
   end Complete_Frame;

   procedure Abandon_Frame (Cursor : in out Frame_Cursor) is
   begin
      Cursor := (Phase => Awaiting_Header);
   end Abandon_Frame;

   function Classify_Timeout
     (Failed_Or_Terminal : Boolean;
      Remaining          : Duration) return Timeout_Action
   is
     (if Failed_Or_Terminal or else Remaining = 0.0
      then Propagate_Timeout
      else Retry_Receive);

end Flyology.WebSocket_Policy;
