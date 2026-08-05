with Interfaces.C;
with System.C_Time;

package System.Flyology.Time_ABI
  with Preelaborate
is
   subtype Timespec is System.C_Time.timespec;

   function To_Duration (Value : Timespec) return Duration
     renames System.C_Time.To_Duration;

   function To_Timespec (Value : Duration) return Timespec
     renames System.C_Time.To_Timespec;

   --  Read the platform monotonic clock through the narrow C bridge. Darwin
   --  uses Mach absolute time; Linux preserves CLOCK_MONOTONIC. Both match
   --  their platform wait primitives and pause while the system sleeps.
   function Read_Monotonic (Value : access Timespec) return Interfaces.C.int;
   pragma Import (C, Read_Monotonic, "flyology_monotonic_clock");
end System.Flyology.Time_ABI;
