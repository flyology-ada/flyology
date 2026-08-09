with GNAT.OS_Lib;
with Interfaces;
with System;
with System.OS_Constants;
#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
with Flyology.Wall_Clock_Testing;
#end if;

package body Flyology.Wall_Clock_Native is
   use type C.long;
   use type Interfaces.Integer_64;

   type Timespec is record
      Seconds     : C.long;
      Nanoseconds : C.long;
   end record
     with Convention => C;

   type Itimerspec is record
      Interval : Timespec;
      Value    : Timespec;
   end record
     with Convention => C;

   function Clock_Realtime return C.int;
   pragma Import
     (C, Clock_Realtime, "flyology_wall_clock_clock_realtime");

   function Timerfd_Create_Flags return C.int;
   pragma Import
     (C, Timerfd_Create_Flags, "flyology_wall_clock_timerfd_create_flags");

   function Timerfd_Settime_Flags return C.int;
   pragma Import
     (C, Timerfd_Settime_Flags, "flyology_wall_clock_timerfd_settime_flags");

   function ECANCELED return C.int;
   pragma Import (C, ECANCELED, "flyology_wall_clock_ecanceled");

   function Timerfd_Create (Clock : C.int; Flags : C.int) return C.int;
   pragma Import (C, Timerfd_Create, "timerfd_create");

   function Timerfd_Settime
     (FD        : C.int;
      Flags     : C.int;
      New_Value : access Itimerspec;
      Old_Value : System.Address) return C.int;
   pragma Import (C, Timerfd_Settime, "timerfd_settime");

   function Clock_Gettime
     (Clock : C.int; Value : access Timespec) return C.int;
   pragma Import (C, Clock_Gettime, "clock_gettime");

   function Read
     (FD : C.int; Buffer : System.Address; Count : C.size_t) return C.long;
   pragma Import (C, Read, "read");

   function Close_FD (FD : C.int) return C.int;
   pragma Import (C, Close_FD, "close");

   function To_Policy (Value : Timespec) return Policy.Timestamp is
     (Seconds     => Interfaces.Integer_64 (Value.Seconds),
      Nanoseconds => Policy.Nanosecond_Part (Value.Nanoseconds));

   function To_Native (Value : Policy.Timestamp) return Timespec is
     (Seconds     => C.long (Value.Seconds),
      Nanoseconds => C.long (Value.Nanoseconds));

   function Open (State : in out Wait_State) return Boolean is
   begin
      State := (Wait_FD => -1, Change_FD => -1, Token => -1);
      State.Wait_FD := Timerfd_Create (Clock_Realtime, Timerfd_Create_Flags);
      State.Change_FD := State.Wait_FD;
      return State.Wait_FD >= 0;
   end Open;

   function Arm
     (State                     : in out Wait_State;
      Target                    : Policy.Timestamp;
      Maximum_Slice_Nanoseconds : Interfaces.Integer_64)
      return Arm_Outcome
   is
      Now_Native : aliased Timespec;
      Now        : Policy.Timestamp;
      Probe      : Policy.Timestamp_Result;
      Deadline   : Policy.Timestamp;
   begin
      if State.Wait_FD < 0 or else Maximum_Slice_Nanoseconds <= 0 then
         return Arm_Failed;
      end if;

#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
      declare
         Remaining : constant Interfaces.Integer_64 :=
           Flyology.Wall_Clock_Testing.Native_Remaining_Nanoseconds;
         Synthetic : Policy.Timestamp_Result;
      begin
         if Remaining >= 0 then
            Synthetic := Policy.Subtract_Nanoseconds (Target, Remaining);
            if not Synthetic.Fits then
               return Arm_Failed;
            end if;
            Now := Synthetic.Value;
         elsif Clock_Gettime (Clock_Realtime, Now_Native'Access) /= 0 then
            return Arm_Failed;
         else
            Now := To_Policy (Now_Native);
         end if;
      end;
#else
      if Clock_Gettime (Clock_Realtime, Now_Native'Access) /= 0 then
         return Arm_Failed;
      end if;
      Now := To_Policy (Now_Native);
#end if;

      Probe := Policy.Add_Nanoseconds (Now, Maximum_Slice_Nanoseconds);
      if not Probe.Fits then
         return Arm_Failed;
      end if;
      Deadline := Policy.Earlier (Target, Probe.Value);

      declare
         Timer : aliased Itimerspec :=
           (Interval => (Seconds => 0, Nanoseconds => 0),
            Value    => To_Native (Deadline));
         Result : constant C.int :=
           Timerfd_Settime
             (State.Wait_FD,
              Timerfd_Settime_Flags,
              Timer'Access,
              System.Null_Address);
         Error_Code : constant C.int :=
           (if Result < 0 then C.int (GNAT.OS_Lib.Errno) else 0);
      begin
         if Result = 0 then
            return Armed;
         end if;
         --  timerfd rearms the timer even when it reports a cancellation left
         --  unread from a race with the preceding consume.
         return (if Error_Code = ECANCELED then Clock_Changed else Arm_Failed);
      end;
   end Arm;

   function Consume (State : in out Wait_State) return Consume_Outcome is
      Expirations : aliased Interfaces.Unsigned_64;
      Result      : C.long;
      Error_Code  : C.int;
   begin
      loop
         Result := Read (State.Wait_FD, Expirations'Address, 8);
         Error_Code :=
           (if Result < 0 then C.int (GNAT.OS_Lib.Errno) else 0);
         exit when Result >= 0
           or else Error_Code /= C.int (System.OS_Constants.EINTR);
      end loop;
      if Result = 8 then
         return Timer_Ready;
      elsif Result < 0 and then Error_Code = ECANCELED then
         return Clock_Change_Ready;
      else
         return Consume_Failed;
      end if;
   end Consume;

   procedure Close (State : in out Wait_State) is
      Ignored : C.int;
   begin
      if State.Wait_FD >= 0 then
         Ignored := Close_FD (State.Wait_FD);
      end if;
      State := (Wait_FD => -1, Change_FD => -1, Token => -1);
   end Close;

   function Uses_Relative_Timer return Boolean is (False);
end Flyology.Wall_Clock_Native;
