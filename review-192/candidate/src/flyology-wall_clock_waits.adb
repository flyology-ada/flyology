with Ada.Calendar.Formatting;
with Flyology.IO;
with Flyology.Time_Math;
with Flyology.Wall_Clock_Native_Policy;

package body Flyology.Wall_Clock_Waits is
   package C renames Interfaces.C;
   package Native renames Flyology.Wall_Clock_Native;
   package Policy renames Flyology.Wall_Clock_Native_Policy;
   use type Native.Arm_Outcome;
   use type Native.Consume_Outcome;

   procedure Open (Item : in out Source) is
   begin
      if not Native.Open (Item.Native) then
         raise Flyology.IO.Device_Error with "cannot create wall-clock wait source";
      end if;
   end Open;

   function Arm (Item : in out Source; Target : Ada.Calendar.Time; Maximum_Slice : Duration) return Boolean is
      Year        : Ada.Calendar.Year_Number;
      Month       : Ada.Calendar.Month_Number;
      Day         : Ada.Calendar.Day_Number;
      Hour        : Ada.Calendar.Formatting.Hour_Number;
      Minute      : Ada.Calendar.Formatting.Minute_Number;
      Second      : Ada.Calendar.Formatting.Second_Number;
      Sub_Second  : Ada.Calendar.Formatting.Second_Duration;
      Leap_Second : Boolean;
   begin
      Ada.Calendar.Formatting.Split
        (Date        => Target,
         Year        => Year,
         Month       => Month,
         Day         => Day,
         Hour        => Hour,
         Minute      => Minute,
         Second      => Second,
         Sub_Second  => Sub_Second,
         Leap_Second => Leap_Second,
         Time_Zone   => 0);

      declare
         Native_Target : constant Policy.Timestamp :=
           Policy.Civil_Timestamp
             (Integer (Year),
              Integer (Month),
              Integer (Day),
              Integer (Hour),
              Integer (Minute),
              Integer (Second),
              Policy.Nanosecond_Part (Flyology.Time_Math.To_Nanoseconds (Duration (Sub_Second))),
              Leap_Second);
         Result        : constant Native.Arm_Outcome :=
           Native.Arm
             (Item.Native,
              Native_Target,
              Interfaces.Integer_64 (Flyology.Time_Math.To_Nanoseconds (Maximum_Slice)));
      begin
         if Result = Native.Arm_Failed then
            raise Flyology.IO.Device_Error with "cannot arm wall-clock wait";
         end if;
         return Result = Native.Clock_Changed;
      end;
   end Arm;

   procedure Consume (Item : in out Source) is
      Result : constant Native.Consume_Outcome := Native.Consume (Item.Native);
   begin
      if Result = Native.Consume_Failed then
         raise Flyology.IO.Device_Error with "cannot consume wall-clock wait";
      end if;
   end Consume;

   function Descriptor (Item : Source) return C.int
   is (Item.Native.Wait_FD);

   function Cancels_On_Clock_Set (Item : Source) return Boolean
   is (Item.Native.Wait_FD >= 0 and then Item.Native.Change_FD = Item.Native.Wait_FD);

   overriding
   procedure Finalize (Item : in out Source) is
   begin
      Native.Close (Item.Native);
   end Finalize;
end Flyology.Wall_Clock_Waits;
