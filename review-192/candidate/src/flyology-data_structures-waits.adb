with Flyology.Data_Structures.Clock_ABI;
with Flyology.Data_Structures.Clock_Policy;
with Interfaces.C;

package body Flyology.Data_Structures.Waits is
   package C renames Interfaces.C;
   package Clock_ABI renames Flyology.Data_Structures.Clock_ABI;
   package Clock_Policy renames Flyology.Data_Structures.Clock_Policy;

   use type Interfaces.Unsigned_64;

   Nanosecond : constant Duration := 0.000_000_001;

   type Native_Time is record
      Seconds     : C.long;
      Nanoseconds : C.long;
   end record
   with Convention => C;

   function Clock_Gettime (Clock_Id : C.int; Value : access Native_Time) return C.int;
   pragma Import (C, Clock_Gettime, "clock_gettime");

   function Now return Interfaces.Unsigned_64 is
      --  Initialize the out record so even a failed foreign call leaves a
      --  valid Ada value while Status still selects the failure sentinel.
      Sample : aliased Native_Time := (Seconds => 0, Nanoseconds => 0);
      Status : C.int;
      Value  : Interfaces.Unsigned_64;
   begin
      Status := Clock_Gettime (Clock_ABI.Clock_Monotonic, Sample'Access);
      Value := Clock_Policy.To_Nanoseconds (Status, Sample.Seconds, Sample.Nanoseconds);
      if Value = Clock_Policy.Clock_Failure then
         raise Program_Error with "monotonic clock is unavailable";
      end if;
      return Value;
   end Now;

   function Start (Timeout : Wait_Timeout) return Context
   is (Timeout => Timeout, Deadline => 0);

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
