with Flyology;
with Library_Finalize_Runtime_Fixture;

procedure Library_Finalize_Runtime_Smoke is

   task Starter
     with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Starter;

   task body Starter is
   begin
      null;
   end Starter;

begin
   Library_Finalize_Runtime_Fixture.Arm;
end Library_Finalize_Runtime_Smoke;
