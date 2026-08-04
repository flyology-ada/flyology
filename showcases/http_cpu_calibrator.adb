with Ada.Command_Line;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with HTTP_CPU_Work;

procedure HTTP_CPU_Calibrator is
   use type Ada.Real_Time.Time;

   Iterations : constant Natural :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Natural'Value (Ada.Command_Line.Argument (1)) else 100_000);
   Repetitions : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Positive'Value (Ada.Command_Line.Argument (2)) else 5);
   Input : constant HTTP_CPU_Work.Work_Input :=
     (Iterations => Iterations, Seed => <>);
   Result : HTTP_CPU_Work.Work_Result;
   Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
begin
   for Repetition in 1 .. Repetitions loop
      HTTP_CPU_Work.Execute
        (Input, null, Ada.Real_Time.Time_Last, Result);
   end loop;
   declare
      Elapsed : constant Duration := Ada.Real_Time.To_Duration
        (Ada.Real_Time.Clock - Started) / Repetitions;
   begin
      Ada.Text_IO.Put_Line
        ("seconds="
         & Ada.Strings.Fixed.Trim (Duration'Image (Elapsed), Ada.Strings.Both)
         & " " & HTTP_CPU_Work.Image (Result));
   end;
end HTTP_CPU_Calibrator;
