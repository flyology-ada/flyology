with Ada.Calendar.Formatting;
with Flyology.IO;
with Flyology.Time_Math;
with System;

package body Flyology.Wall_Clock_Waits is
   package C renames Interfaces.C;

   function Native_Open (State : System.Address) return C.int;
   pragma Import (C, Native_Open, "flyology_wall_wait_open");

   function Native_Arm
     (State                     : System.Address;
      Target_Year               : C.int;
      Target_Month              : C.int;
      Target_Day                : C.int;
      Target_Hour               : C.int;
      Target_Minute             : C.int;
      Target_Second             : C.int;
      Target_Nanoseconds        : C.long;
      Target_Is_Leap_Second     : C.int;
      Maximum_Slice_Nanoseconds : C.long_long) return C.int;
   pragma Import (C, Native_Arm, "flyology_wall_wait_arm");

   function Native_Consume (State : System.Address) return C.int;
   pragma Import (C, Native_Consume, "flyology_wall_wait_consume");

   procedure Native_Close (State : System.Address);
   pragma Import (C, Native_Close, "flyology_wall_wait_close");

   procedure Open (Item : in out Source) is
   begin
      if Native_Open (Item.Native'Address) /= 0 then
         raise Flyology.IO.Device_Error with
           "cannot create wall-clock wait source";
      end if;
   end Open;

   function Arm
     (Item          : in out Source;
      Target        : Ada.Calendar.Time;
      Maximum_Slice : Duration) return Boolean
   is
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
         Result : constant C.int :=
           Native_Arm
             (Item.Native'Address,
              C.int (Year),
              C.int (Month),
              C.int (Day),
              C.int (Hour),
              C.int (Minute),
              C.int (Second),
              C.long
                (Flyology.Time_Math.To_Nanoseconds
                   (Duration (Sub_Second))),
              C.int (Boolean'Pos (Leap_Second)),
              Flyology.Time_Math.To_Nanoseconds (Maximum_Slice));
      begin
         if Result < 0 then
            raise Flyology.IO.Device_Error with "cannot arm wall-clock wait";
         end if;
         return Result /= 0;
      end;
   end Arm;

   procedure Consume (Item : in out Source) is
      Result : constant C.int := Native_Consume (Item.Native'Address);
   begin
      if Result < 0 then
         raise Flyology.IO.Device_Error with "cannot consume wall-clock wait";
      end if;
   end Consume;

   function Descriptor (Item : Source) return C.int is
     (Item.Native.Wait_FD);

   function Cancels_On_Clock_Set (Item : Source) return Boolean is
     (Item.Native.Wait_FD >= 0
      and then Item.Native.Change_FD = Item.Native.Wait_FD);

   overriding procedure Finalize (Item : in out Source) is
   begin
      Native_Close (Item.Native'Address);
   end Finalize;
end Flyology.Wall_Clock_Waits;
