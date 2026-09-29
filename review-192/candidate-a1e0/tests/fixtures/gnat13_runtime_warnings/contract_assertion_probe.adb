with Ada.Assertions;
with Ada.Command_Line;
with Gnat13_Contract_Probe;

procedure Contract_Assertion_Probe is
   Value       : constant Integer := Ada.Command_Line.Argument_Count;
   Pre_Raised  : Boolean := False;
   Post_Raised : Boolean := False;
begin
   begin
      if Gnat13_Contract_Probe.Require_Positive (Value) = Integer'First then
         raise Program_Error with "unreachable precondition result";
      end if;
   exception
      when Ada.Assertions.Assertion_Error =>
         Pre_Raised := True;
   end;

   begin
      if Gnat13_Contract_Probe.Return_Positive (Value) = Integer'First then
         raise Program_Error with "unreachable postcondition result";
      end if;
   exception
      when Ada.Assertions.Assertion_Error =>
         Post_Raised := True;
   end;

   if not Pre_Raised or else not Post_Raised then
      raise Program_Error with "GNAT 13 backend inlining discarded a language-defined contract";
   end if;
end Contract_Assertion_Probe;
