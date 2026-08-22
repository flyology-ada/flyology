with Flyology_Cachelines.Platform;

--  Shared translation from Linux detection into the platform contract.
--
--  Both Linux platform bodies present the same core classes.  They differ
--  only in how they describe a host that publishes no usable class: the
--  x86-64 body can still read the calling CPU's geometry through CPUID.

package Flyology_Cachelines.Linux.Facts is

   --  Translate the detected core classes into platform facts.
   --
   --  Fallback describes the one class to report when sysfs yields none, and
   --  is No_Cache_Parameters when the caller has nothing better to offer.
   function Detected
     (Fallback : Cache_Parameters := No_Cache_Parameters) return Flyology_Cachelines.Platform.Host_Facts;

end Flyology_Cachelines.Linux.Facts;
