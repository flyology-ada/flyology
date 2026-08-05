with Interfaces.C;
with System.OS_Interface;

package System.Flyology.Time_ABI
  with Preelaborate
is
   subtype Timespec is System.OS_Interface.timespec;

   function To_Duration (Value : Timespec) return Duration
     renames System.OS_Interface.To_Duration;

   function To_Timespec (Value : Duration) return Timespec
     renames System.OS_Interface.To_Timespec;

   --  Read the platform monotonic clock through the narrow C bridge. Darwin
   --  uses its continuous raw clock; Linux preserves CLOCK_MONOTONIC.
   function Read_Monotonic (Value : access Timespec) return Interfaces.C.int;
   pragma Import (C, Read_Monotonic, "flyology_monotonic_clock");
end System.Flyology.Time_ABI;
