with Ada.Real_Time;
with Flyology;

procedure Past_Deadline_Smoke is
   Timed_Out : Boolean := False;
begin
   declare
      task Server is
         entry Never;
         entry Stop;
      end Server;

      pragma Warnings (Off, "no accept for entry ""Never""");
      task body Server is
      begin
         accept Stop;
      end Server;
      pragma Warnings (On, "no accept for entry ""Never""");

      task Caller is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Caller;

      task body Caller is
      begin
         select
            Server.Never;
         or
            delay until Ada.Real_Time.Time_First;
            Timed_Out := True;
         end select;
         Server.Stop;
      end Caller;
   begin
      null;
   end;

   if not Timed_Out then
      raise Program_Error with "past-deadline timed entry did not time out";
   end if;
end Past_Deadline_Smoke;
