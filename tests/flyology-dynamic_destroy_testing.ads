package Flyology.Dynamic_Destroy_Testing is

   --  Reset the dynamic-destroy contention injection.
   procedure Reset;

   --  Make the next current-allocation release report arena contention.
   procedure Arm_Current_Release_Contention;

end Flyology.Dynamic_Destroy_Testing;
