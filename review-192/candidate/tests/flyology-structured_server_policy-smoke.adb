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

   pragma Assert (Accepting_After_Worker_Start (Serving));
   pragma Assert (not Accepting_After_Worker_Start (Idle));
   pragma Assert (not Accepting_After_Worker_Start (Stop_Requested));
   pragma Assert (Snapshot_Accepting (True, Serving));
   pragma Assert (not Snapshot_Accepting (False, Serving));
   pragma Assert (not Snapshot_Accepting (True, Stop_Requested));
end Flyology.Structured_Server_Policy.Smoke;
