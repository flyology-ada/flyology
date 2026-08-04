with Ada.Text_IO;
with Flyology.Execution_Groups;

--  Report the loop-pool size compiled into the linked Flyology runtime.
procedure HTTP_Benchmark_Runtime_Probe is
   package Groups renames Flyology.Execution_Groups;
begin
   Ada.Text_IO.Put_Line
     (Groups.Loop_Pool_Size'Image (Groups.Configured_Pool_Size));
end HTTP_Benchmark_Runtime_Probe;
