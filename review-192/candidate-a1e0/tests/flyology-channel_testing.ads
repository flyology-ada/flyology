--  Exposes deterministic channel fault points to runtime tests.
--  Applications should not depend on this child package.
--  @exclude
package Flyology.Channel_Testing is

   procedure Reset;
   procedure Arm_Before_Send;
   procedure Wait_Before_Send;
   procedure Release_Before_Send;

end Flyology.Channel_Testing;
