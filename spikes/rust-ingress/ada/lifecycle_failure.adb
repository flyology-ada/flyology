with Ada.Environment_Variables;
with Ada.Finalization;

package body Lifecycle_Failure is

   type Finalization_Sentinel is new Ada.Finalization.Limited_Controlled
   with null record;

   overriding
   procedure Finalize (Item : in out Finalization_Sentinel);

   overriding
   procedure Finalize (Item : in out Finalization_Sentinel) is
      pragma Unreferenced (Item);
   begin
      if Ada.Environment_Variables.Exists ("FLYOLOGY_SPIKE_FAIL_FINALIZE") then
         raise Program_Error with "requested finalization failure";
      end if;
   end Finalize;

   Sentinel : Finalization_Sentinel;
   pragma Unreferenced (Sentinel);

   function Touch return Interfaces.C.int
   is (0);

begin
   if Ada.Environment_Variables.Exists ("FLYOLOGY_SPIKE_FAIL_INITIALIZE") then
      raise Program_Error with "requested elaboration failure";
   end if;
end Lifecycle_Failure;
