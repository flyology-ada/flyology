package body Flyology.Data_Structures.Clock_Policy
  with SPARK_Mode => On
is
   function To_Nanoseconds
     (Status      : C.int;
      Seconds     : C.long;
      Nanoseconds : C.long) return Interfaces.Unsigned_64
   is
   begin
      if Status /= 0
        or else Seconds < 0
        or else Nanoseconds < 0
        or else Nanoseconds >= C.long (Nanoseconds_Per_Second)
        or else Interfaces.Unsigned_64 (Seconds) >
          Interfaces.Unsigned_64'Last / Nanoseconds_Per_Second
      then
         return Clock_Failure;
      end if;

      return
        Interfaces.Unsigned_64 (Seconds) * Nanoseconds_Per_Second
        + Interfaces.Unsigned_64 (Nanoseconds);
   end To_Nanoseconds;
end Flyology.Data_Structures.Clock_Policy;
