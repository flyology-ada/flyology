with Flyology.WebSocket_Deflate_Policy;

procedure Flyology.WebSocket_Deflate_Policy_Smoke is
   package Policy renames Flyology.WebSocket_Deflate_Policy;
   use type Policy.Distance_Tree_Disposition;

begin
   pragma Assert (Policy.Encoder_Window_Bits = 15);
   pragma Assert (Policy.Encoder_Window_Bytes = 32 * 1_024);
   pragma Assert (Policy.Negotiated_Server_Window_Bits (8) = 0);
   pragma Assert (Policy.Negotiated_Server_Window_Bits (14) = 0);
   pragma Assert (Policy.Negotiated_Server_Window_Bits (15) = 15);
   pragma Assert (Policy.Negotiated_Server_Window_Bits (16) = 0);
   pragma Assert
     (Policy.Negotiated_Server_Window_Bits (Natural'Last) = 0);

   pragma Assert
     (Policy.Select_Distance_Tree (1, 0) = Policy.No_Tree);
   pragma Assert
     (Policy.Select_Distance_Tree (1, 1) = Policy.Decode_Tree);
   pragma Assert
     (Policy.Select_Distance_Tree (2, 0) = Policy.Decode_Tree);

   pragma Assert
     (Policy.Distance_Requirement_Is_Satisfied (Policy.No_Tree, 0));
   pragma Assert
     (Policy.Distance_Requirement_Is_Satisfied (Policy.No_Tree, 255));
   pragma Assert
     (Policy.Distance_Requirement_Is_Satisfied (Policy.No_Tree, 256));
   pragma Assert
     (not Policy.Distance_Requirement_Is_Satisfied (Policy.No_Tree, 257));
   pragma Assert
     (not Policy.Distance_Requirement_Is_Satisfied (Policy.No_Tree, 285));
   pragma Assert
     (Policy.Distance_Requirement_Is_Satisfied (Policy.No_Tree, 286));
   pragma Assert
     (Policy.Distance_Requirement_Is_Satisfied (Policy.No_Tree, 287));
   pragma Assert
     (Policy.Distance_Requirement_Is_Satisfied (Policy.Decode_Tree, 257));
end Flyology.WebSocket_Deflate_Policy_Smoke;
