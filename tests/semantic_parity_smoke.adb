with Ada.Text_IO;
with Gnatevl;
with Semantic_Scenarios;

procedure Semantic_Parity_Smoke is

   package Evented_Scenarios is new Semantic_Scenarios
     (Model      => Gnatevl.Event_Loop_Task,
      Peer_Model => Gnatevl.Native_Thread);

   package Native_Scenarios is new Semantic_Scenarios
     (Model      => Gnatevl.Native_Thread,
      Peer_Model => Gnatevl.Event_Loop_Task);

   Evented : constant Evented_Scenarios.Results := Evented_Scenarios.Run;
   Native  : constant Native_Scenarios.Results := Native_Scenarios.Run;

begin
   for Check in Evented_Scenarios.Check_Id loop
      if not Evented (Check) then
         raise Program_Error with
           "evented semantic check failed: "
           & Evented_Scenarios.Check_Id'Image (Check);
      end if;
   end loop;

   for Check in Native_Scenarios.Check_Id loop
      if not Native (Check) then
         raise Program_Error with
           "native semantic check failed: "
           & Native_Scenarios.Check_Id'Image (Check);
      end if;
   end loop;

   --  The generic suite is identical for both models.  This explicit parity
   --  comparison catches a future lane-specific semantic regression even if
   --  a newly added check accidentally accepts a false result in isolation.
   for Check in Evented_Scenarios.Check_Id loop
      if Evented (Check)
        /= Native (Native_Scenarios.Check_Id'Value
                     (Evented_Scenarios.Check_Id'Image (Check)))
      then
         raise Program_Error with
           "native/evented semantic mismatch: "
           & Evented_Scenarios.Check_Id'Image (Check);
      end if;
   end loop;

   Ada.Text_IO.Put_Line
     ("semantic parity smoke:"
      & Natural'Image
          (Natural'Succ
             (Evented_Scenarios.Check_Id'Pos
                (Evented_Scenarios.Check_Id'Last)))
      & " checks passed in both lanes");
end Semantic_Parity_Smoke;
