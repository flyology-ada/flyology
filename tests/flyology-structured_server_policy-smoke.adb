with Interfaces.C;

procedure Flyology.Structured_Server_Policy.Smoke is
   Value : Interfaces.C.int;
begin
   --  Zero is a valid descriptor number and must lose ownership after the
   --  attempt regardless of the system call's separately interpreted result.
   Value := 0;
   Consume_After_Close_Attempt (Value);
   pragma Assert (Value = -1);

   --  The transition is independent of the particular valid descriptor.
   Value := Interfaces.C.int'Last;
   Consume_After_Close_Attempt (Value);
   pragma Assert (Value = -1);
end Flyology.Structured_Server_Policy.Smoke;
