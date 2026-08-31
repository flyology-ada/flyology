with Interfaces.C;
with System;

package Rust_Ingress_Probe is
   function Run
     (Registered_Id : System.Address;
      Caller_Id     : Interfaces.C.int;
      Iteration     : Interfaces.C.int) return Interfaces.C.int
   with Export, Convention => C, External_Name => "flyology_rust_ingress_run";

   function Completed return Interfaces.C.int
   with
     Export,
     Convention    => C,
     External_Name => "flyology_rust_ingress_completed";

   function Maximum_Concurrent return Interfaces.C.int
   with
     Export,
     Convention    => C,
     External_Name => "flyology_rust_ingress_maximum_concurrent";

   function Failures return Interfaces.C.int
   with
     Export,
     Convention    => C,
     External_Name => "flyology_rust_ingress_failures";

   function Activation_Incomplete return Interfaces.C.int
   with
     Export,
     Convention    => C,
     External_Name => "flyology_rust_ingress_activation_incomplete";
end Rust_Ingress_Probe;
