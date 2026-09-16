with Ada.Command_Line;
with Flyology;
with Flyology.Operations.ATC_Testing;

procedure Operations_ATC_Smoke is
begin
   if Ada.Command_Line.Argument (1) = "abort" then
      Flyology.Operations.ATC_Testing.Run_Abort;
   elsif Ada.Command_Line.Argument (1)'Length > 3
     and then Ada.Command_Line.Argument (1) (1 .. 3) = "lw-"
   then
      declare
         Scenario : constant String := Ada.Command_Line.Argument (1);
         Passed   : Boolean := False;
      begin
         declare
            task Worker is
               pragma Task_Info (Flyology.Lightweight_Task);
            end Worker;
            task body Worker is
            begin
               Flyology.Operations.ATC_Testing.Run
                 (Scenario (4 .. Scenario'Last));
               Passed := True;
            end Worker;
         begin
            null;
         end;
         if not Passed then
            raise Program_Error
              with "lightweight task did not complete probe assertions";
         end if;
      end;
   else
      Flyology.Operations.ATC_Testing.Run (Ada.Command_Line.Argument (1));
   end if;
end Operations_ATC_Smoke;
