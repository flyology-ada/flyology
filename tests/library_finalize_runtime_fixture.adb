with Interfaces.C;

package body Library_Finalize_Runtime_Fixture is

   use type Interfaces.C.int;

   Armed : Boolean := False;

   function Arm_Finalization_Order return Interfaces.C.int;
   pragma
     Import
       (C, Arm_Finalization_Order, "flyology_test_arm_finalization_order");

   procedure Note_Library_Finalize;
   pragma
     Import (C, Note_Library_Finalize, "flyology_test_note_library_finalize");

   procedure Arm is
   begin
      if Arm_Finalization_Order /= 0 then
         raise Program_Error with "cannot arm finalization-order observation";
      end if;
      Armed := True;
   end Arm;

   overriding
   procedure Finalize (Item : in out Probe) is
      pragma Unreferenced (Item);

   begin
      if Armed then
         Note_Library_Finalize;
         raise Program_Error with "review-only exceptional library finalizer";
      end if;
   end Finalize;

end Library_Finalize_Runtime_Fixture;
