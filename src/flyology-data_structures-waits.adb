package body Flyology.Data_Structures.Waits is
   use type Interfaces.Unsigned_64;

   Nanosecond : constant Duration := 0.000_000_001;
   Clock_Failure : constant Interfaces.Unsigned_64 :=
     Interfaces.Unsigned_64'Last;

   function Monotonic_Nanoseconds return Interfaces.Unsigned_64;
   pragma Import
     (C, Monotonic_Nanoseconds,
      "flyology_data_structures_monotonic_nanoseconds");

   function Now return Interfaces.Unsigned_64 is
      Value : constant Interfaces.Unsigned_64 := Monotonic_Nanoseconds;
   begin
      if Value = Clock_Failure then
         raise Program_Error with "monotonic clock is unavailable";
      end if;
      return Value;
   end Now;

   function Start (Timeout : Wait_Timeout) return Context is
     (Timeout => Timeout, Deadline => 0);

   procedure Retry (Item : in out Context) is
      Observed : constant Interfaces.Unsigned_64 := Now;
      Span     : Interfaces.Unsigned_64;
   begin
      if Item.Deadline = 0 then
         Span := Interfaces.Unsigned_64 (Item.Timeout / Nanosecond);
         Item.Deadline :=
           (if Span >= Interfaces.Unsigned_64'Last - Observed
            then Interfaces.Unsigned_64'Last - 1
            else Observed + Span);
      end if;
      if Observed >= Item.Deadline then
         raise Timeout_Error with "data-structure wait timed out";
      end if;
      delay 0.0;
   end Retry;
end Flyology.Data_Structures.Waits;
