with Ada.Text_IO;
with Native_Executor_Library_Finalize_Fixture;

procedure Native_Executor_Library_Finalize_Smoke is
begin
   Native_Executor_Library_Finalize_Fixture.Exercise;
   Ada.Text_IO.Put_Line
     ("native executor library finalization: main returned");
end Native_Executor_Library_Finalize_Smoke;
