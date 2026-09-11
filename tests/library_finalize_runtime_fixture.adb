with Interfaces.C;

package body Library_Finalize_Runtime_Fixture is

   use type Interfaces.C.int;

   Armed             : Boolean := False;
   Raise_On_Finalize : Boolean := False;

   function Arm_Finalization_Order return Interfaces.C.int;
   pragma
     Import
       (C, Arm_Finalization_Order, "flyology_test_arm_finalization_order");

   function Arm_Exceptional_Finalization_Order return Interfaces.C.int;
   pragma
     Import
       (C,
        Arm_Exceptional_Finalization_Order,
        "flyology_test_arm_exceptional_finalization_order");

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

   procedure Arm_Exceptional is
   begin
      if Arm_Exceptional_Finalization_Order /= 0 then
         raise Program_Error
           with "cannot arm exceptional finalization-order observation";
      end if;
      Raise_On_Finalize := True;
      Armed := True;
   end Arm_Exceptional;

   overriding
   procedure Finalize (Item : in out Probe) is
      pragma Unreferenced (Item);

   begin
      if Armed then
         Note_Library_Finalize;
         if Raise_On_Finalize then
            raise Library_Finalize_Error
              with "expected library finalizer exception";
         end if;
      end if;
   end Finalize;

end Library_Finalize_Runtime_Fixture;
