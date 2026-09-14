with Ada.Finalization;

package Library_Finalize_Runtime_Fixture is

   procedure Arm;
   procedure Arm_Exceptional;

   Library_Finalize_Error : exception;

private

   type Probe is new Ada.Finalization.Limited_Controlled with null record;

   overriding
   procedure Finalize (Item : in out Probe);

   Object : Probe;

end Library_Finalize_Runtime_Fixture;
