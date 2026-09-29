with Ada.Text_IO;
with Flyology;
with Semantic_Scenarios;

procedure Semantic_Parity_Smoke is

   package Lightweight_Scenarios is new
     Semantic_Scenarios (Model => Flyology.Lightweight_Task, Peer_Model => Flyology.Native_Task);

   package Native_Scenarios is new
     Semantic_Scenarios (Model => Flyology.Native_Task, Peer_Model => Flyology.Lightweight_Task);

   Lightweight : constant Lightweight_Scenarios.Results := Lightweight_Scenarios.Run;
   Native      : constant Native_Scenarios.Results := Native_Scenarios.Run;

begin
   for Check in Lightweight_Scenarios.Check_Id loop
      if not Lightweight (Check) then
         raise Program_Error
           with "lightweight semantic check failed: " & Lightweight_Scenarios.Check_Id'Image (Check);
      end if;
   end loop;

   for Check in Native_Scenarios.Check_Id loop
      if not Native (Check) then
         raise Program_Error with "native semantic check failed: " & Native_Scenarios.Check_Id'Image (Check);
      end if;
   end loop;

   --  The generic suite is identical for both models.  This explicit parity
   --  comparison catches a future lane-specific semantic regression even if
   --  a newly added check accidentally accepts a false result in isolation.
   for Check in Lightweight_Scenarios.Check_Id loop
      if Lightweight (Check)
        /= Native (Native_Scenarios.Check_Id'Value (Lightweight_Scenarios.Check_Id'Image (Check)))
      then
         raise Program_Error
           with "native/lightweight semantic mismatch: " & Lightweight_Scenarios.Check_Id'Image (Check);
      end if;
   end loop;

   Ada.Text_IO.Put_Line
     ("semantic parity smoke:"
      & Natural'Image
          (Natural'Succ (Lightweight_Scenarios.Check_Id'Pos (Lightweight_Scenarios.Check_Id'Last)))
      & " checks passed in both lanes");
end Semantic_Parity_Smoke;
