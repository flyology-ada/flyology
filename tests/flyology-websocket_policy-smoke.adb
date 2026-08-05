procedure Flyology.WebSocket_Policy.Smoke is
   Key : constant Mask_Key := (0 => 16#10#, 1 => 16#20#,
                               2 => 16#30#, 3 => 16#40#);
   Cursor : Frame_Cursor;
begin
   --  An active connection may retry a finite receive quantum.
   pragma Assert
     (Classify_Timeout
        (Failed_Or_Terminal => False,
         Remaining          => 0.05) = Retry_Receive);

   --  The negative unlimited-deadline sentinel also retains retry budget.
   pragma Assert
     (Classify_Timeout
        (Failed_Or_Terminal => False,
         Remaining          => -1.0) = Retry_Receive);

   --  An exhausted request deadline is terminal for the handler.
   pragma Assert
     (Classify_Timeout
        (Failed_Or_Terminal => False,
         Remaining          => 0.0) = Propagate_Timeout);

   --  Control-write and other terminal failures propagate even when the
   --  request deadline still has time or is unlimited.
   pragma Assert
     (Classify_Timeout
        (Failed_Or_Terminal => True,
         Remaining          => 1.0) = Propagate_Timeout);
   pragma Assert
     (Classify_Timeout
        (Failed_Or_Terminal => True,
         Remaining          => -1.0) = Propagate_Timeout);

   --  A complete validated header enters payload state without consuming a
   --  payload byte. Payload bytes therefore cannot be reparsed as a header.
   Begin_Frame
     (Cursor, Text_Opcode, Final => False, Length => 5, Mask => Key);
   pragma Assert (Cursor.Phase = Reading_Payload);
   pragma Assert (Cursor.Position = 0 and then Cursor.Remaining = 5);
   pragma Assert (Cursor.Mask = Key);
   pragma Assert (Mask_Offset (Cursor, 0) = 0);
   pragma Assert (Mask_Offset (Cursor, 3) = 3);

   --  Chunk progress preserves the frame identity and advances the mask from
   --  the absolute payload position rather than restarting at zero.
   Advance (Cursor, 2);
   pragma Assert (Cursor.Phase = Reading_Payload);
   pragma Assert (Cursor.Opcode = Text_Opcode and then not Cursor.Final);
   pragma Assert (Cursor.Position = 2 and then Cursor.Remaining = 3);
   pragma Assert (Mask_Offset (Cursor, 0) = 2);
   pragma Assert (Mask_Offset (Cursor, 2) = 0);

   --  Completing the payload does not permit another header parse until the
   --  frame's semantic handling reaches its explicit reset boundary.
   Advance (Cursor, 3);
   pragma Assert (Cursor.Phase = Reading_Payload);
   pragma Assert (Cursor.Position = 5 and then Cursor.Remaining = 0);
   Complete_Frame (Cursor);
   pragma Assert (Cursor.Phase = Awaiting_Header);

   Begin_Frame
     (Cursor, Ping_Opcode, Final => True, Length => 1, Mask => Key);
   pragma Assert (Is_Control (Cursor.Opcode));
   Abandon_Frame (Cursor);
   pragma Assert (Cursor.Phase = Awaiting_Header);
end Flyology.WebSocket_Policy.Smoke;
