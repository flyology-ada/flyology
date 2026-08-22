with Interfaces;
with Flyology.Process_Generations;

--  Internal scalar state machine for one process-upgrade transaction.
--  Process creation, I/O, callbacks, clocks, diagnostics, and descriptor
--  ownership remain in the controller that consumes these decisions.

private package Flyology.Process_Generation_Policy
  with Preelaborate, SPARK_Mode
is
   --  @exclude Internal proof policy, not part of the public API.

   package Public renames Flyology.Process_Generations;

   use type Interfaces.Unsigned_64;
   use type Public.Upgrade_Phase;
   use type Public.Upgrade_Command;
   use type Public.Upgrade_Handle;

   --  Report whether Command is legal in Phase.
   --  @param Phase Current lifecycle phase
   --  @param Command Proposed transition command
   --  @return True when the transition is legal
   function Command_Allowed (Phase : Public.Upgrade_Phase; Command : Public.Upgrade_Command) return Boolean
   with Global => null;

   --  Return the phase committed by an allowed command.
   --  @param Phase Current lifecycle phase
   --  @param Command Allowed transition command
   --  @return Phase committed by the command
   function Phase_After
     (Phase : Public.Upgrade_Phase; Command : Public.Upgrade_Command) return Public.Upgrade_Phase
   with
     Global => null,
     Pre    => Command_Allowed (Phase, Command),
     Post   => Phase_After'Result /= Public.Stable or else Command = Public.Start_Upgrade;

   --  Report whether a transaction phase accepts no later command.
   --  @param Phase Lifecycle phase
   --  @return True when the transaction accepts no later command
   function Terminal (Phase : Public.Upgrade_Phase) return Boolean
   with
     Global => null,
     Post   =>
       Terminal'Result
       = (Phase in Public.Cancelled | Public.Completed | Public.Failed | Public.Rollback_Required);

   --  Cancellation is reversible deployment control only before promotion.
   --  @param Phase Lifecycle phase
   --  @return True when cancellation has not crossed the promotion boundary
   function Cancellation_Allowed (Phase : Public.Upgrade_Phase) return Boolean
   with
     Global => null,
     Post   =>
       Cancellation_Allowed'Result
       = (Phase in Public.Starting | Public.Provisioning | Public.Prepared | Public.Canary);

   --  Report whether promotion has crossed its commitment boundary.
   --  @param Phase Lifecycle phase
   --  @return True when reversal requires a fresh rollback transaction
   function Promotion_Committed (Phase : Public.Upgrade_Phase) return Boolean
   with
     Global => null,
     Post   =>
       Promotion_Committed'Result
       = (Phase
          in Public.Promoting
           | Public.Draining_Previous
           | Public.Committing
           | Public.Completed
           | Public.Rollback_Required);

   --  Qualify a command with the exact current transaction authority.
   --  @param Expected Current transaction authority
   --  @param Supplied Authority supplied with the command
   --  @return True when both authorities are identical
   function Authority_Matches (Expected, Supplied : Public.Upgrade_Handle) return Boolean
   with Global => null, Post => Authority_Matches'Result = (Expected = Supplied);

   --  Advance a nonwrapping wire or event sequence.
   --  @param Value Current sequence
   --  @return True when a successor is representable
   function Can_Advance (Value : Interfaces.Unsigned_64) return Boolean
   is (Value < Interfaces.Unsigned_64'Last)
   with Global => null;

   --  Return the next nonwrapping sequence value.
   --  @param Value Current sequence
   --  @return Exact successor
   function Advanced (Value : Interfaces.Unsigned_64) return Interfaces.Unsigned_64
   with
     Global => null,
     Pre    => Can_Advance (Value),
     Post   => Advanced'Result = Value + 1 and then Advanced'Result > Value;

end Flyology.Process_Generation_Policy;
