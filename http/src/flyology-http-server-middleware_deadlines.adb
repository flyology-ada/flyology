package body Flyology.HTTP.Server.Middleware_Deadlines is
   use type Ada.Real_Time.Time;

   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler)
   is
      Candidate : constant Ada.Real_Time.Time :=
        Clock + Ada.Real_Time.To_Time_Span (Duration'Max (0.0, Maximum));
   begin
      if Candidate < X.Deadline then
         X.Narrow_Deadline (Candidate);
      end if;
      Next.Call (Context, X);
   end Call;

end Flyology.HTTP.Server.Middleware_Deadlines;
