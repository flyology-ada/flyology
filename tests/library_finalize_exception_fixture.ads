with Ada.Finalization;

package Library_Finalize_Exception_Fixture is

   procedure Arm;

private
   type Probe is new Ada.Finalization.Limited_Controlled with null record;

   overriding
   procedure Finalize (Item : in out Probe);

   Object : Probe;

end Library_Finalize_Exception_Fixture;
