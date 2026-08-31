with Interfaces.C;

package Lifecycle_Failure is
   function Touch return Interfaces.C.int
   with
     Export,
     Convention    => C,
     External_Name => "flyology_lifecycle_failure_touch";
end Lifecycle_Failure;
