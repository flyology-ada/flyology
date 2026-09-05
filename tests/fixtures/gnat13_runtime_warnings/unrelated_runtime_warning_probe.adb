with Ada.Command_Line;

procedure Unrelated_Runtime_Warning_Probe is
   Value : Integer := Ada.Command_Line.Argument_Count;
begin
   Value := Value;
   if Value = Integer'First then
      raise Program_Error;
   end if;
end Unrelated_Runtime_Warning_Probe;
