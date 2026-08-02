with System.C_Time;

package System.Gnatevl.Time_ABI
  with Preelaborate
is
   subtype Timespec is System.C_Time.timespec;

   function To_Duration (Value : Timespec) return Duration
     renames System.C_Time.To_Duration;

   function To_Timespec (Value : Duration) return Timespec
     renames System.C_Time.To_Timespec;
end System.Gnatevl.Time_ABI;
