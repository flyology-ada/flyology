with Interfaces.C;

package Rust_Host_Probe is
   function Run return Interfaces.C.int
   with Export, Convention => C, External_Name => "flyology_rust_host_run";
end Rust_Host_Probe;
