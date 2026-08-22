with Interfaces.C;
with Flyology.Wall_Clock_Native_Policy;

--  Platform ABI boundary for one wall-clock readiness source. Implementations
--  import ordinary OS entry points directly; C supplies macro-only constants.

private package Flyology.Wall_Clock_Native is
   package C renames Interfaces.C;
   package Policy renames Flyology.Wall_Clock_Native_Policy;
   use type C.int;

   type Wait_State is record
      Wait_FD   : C.int := -1;
      Change_FD : C.int := -1;
      Token     : C.int := -1;
   end record
   with Convention => C;

   type Arm_Outcome is (Arm_Failed, Armed, Clock_Changed);
   type Consume_Outcome is (Consume_Failed, Timer_Ready, Clock_Change_Ready);

   function Open (State : in out Wait_State) return Boolean;

   function Arm
     (State : in out Wait_State; Target : Policy.Timestamp; Maximum_Slice_Nanoseconds : Interfaces.Integer_64)
      return Arm_Outcome;

   function Consume (State : in out Wait_State) return Consume_Outcome;

   procedure Close (State : in out Wait_State);

   function Uses_Relative_Timer return Boolean;
end Flyology.Wall_Clock_Native;
