with GNAT.OS_Lib;
with Gnatevl.Time_Math;
with Gnatevl.Wait_Policy;
with System.OS_Constants;

package body Gnatevl.IO is
   package C renames Interfaces.C;

   use type C.int;

   POLLIN  : constant C.short := 16#0001#;
   POLLOUT : constant C.short := 16#0004#;

   type Poll_Descriptor is record
      FD      : C.int;
      Events  : C.short;
      Returned_Events : C.short;
   end record;
   pragma Convention (C, Poll_Descriptor);

   function Runtime_In_Event_Task return C.int;
   pragma Import
     (C, Runtime_In_Event_Task, "gnatevl_runtime_in_event_task");

   function Runtime_Wait_IO
     (FD                  : C.int;
      For_Write           : C.int;
      Timeout_Nanoseconds : C.long_long) return C.int;
   pragma Import (C, Runtime_Wait_IO, "gnatevl_runtime_wait_io");

   function Poll
     (Descriptors : access Poll_Descriptor;
      Count       : C.unsigned;
      Timeout_MS  : C.int) return C.int;
   pragma Import (C, Poll, "poll");

   type Timespec is record
      Seconds     : C.long;
      Nanoseconds : C.long;
   end record
     with Convention => C;

   function Clock_Gettime
     (Clock_ID : C.int;
      Value    : access Timespec) return C.int;
   pragma Import (C, Clock_Gettime, "clock_gettime");

   function Clock return Duration is
      Now    : aliased Timespec;
      Result : C.int;
   begin
      Result :=
        Clock_Gettime
          (C.int (System.OS_Constants.CLOCK_RT_Ada), Now'Access);
      if Result /= 0 then
         raise Device_Error with "monotonic clock failed";
      end if;
      return
        Duration (Now.Seconds)
        + Duration (Now.Nanoseconds) / 1_000_000_000;
   end Clock;

   function Is_Evented_Task return Boolean is
     (Runtime_In_Event_Task /= 0);

   function Wait
     (FD        : Descriptor;
      Condition : Wait_Kind;
      Timeout   : Duration := Infinite) return Boolean
   is
      Started : constant Duration := Clock;
      Result  : C.int;
   begin
      if FD < 0 then
         raise Device_Error with "invalid descriptor";
      end if;

      if Is_Evented_Task then
         Result :=
           Runtime_Wait_IO
             (FD,
              (if Condition = For_Write then 1 else 0),
              Time_Math.To_Nanoseconds (Timeout));
         if Result < 0 then
            raise Device_Error with "event-loop readiness wait failed";
         end if;
         return Result = 0;
      end if;

      loop
         declare
            Elapsed : constant Duration := Clock - Started;
            Remaining : constant Duration :=
              Time_Math.Remaining (Timeout, Elapsed);
            Item : aliased Poll_Descriptor :=
              (FD              => FD,
               Events          =>
                 (if Condition = For_Read then POLLIN else POLLOUT),
               Returned_Events => 0);
         begin
            Result :=
              Poll
                (Item'Access,
                 1,
                 Time_Math.To_Milliseconds (Remaining));
         end;

         case Wait_Policy.Classify
           (Result,
            (if Result < 0 then C.int (GNAT.OS_Lib.Errno) else 0),
            C.int (System.OS_Constants.EINTR))
         is
            when Wait_Policy.Return_Ready =>
               return True;
            when Wait_Policy.Return_Timeout =>
               return False;
            when Wait_Policy.Retry =>
               null;
            when Wait_Policy.Fail =>
               raise Device_Error with "poll failed";
         end case;
      end loop;
   end Wait;

end Gnatevl.IO;
