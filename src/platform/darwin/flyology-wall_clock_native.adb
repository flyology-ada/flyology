with GNAT.OS_Lib;
with Interfaces;
with System;
with System.OS_Constants;
with System.Storage_Elements;
#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
with Flyology.Wall_Clock_Testing;
#end if;

package body Flyology.Wall_Clock_Native is
   package SSE renames System.Storage_Elements;

   use type C.long;
   use type C.short;
   use type C.unsigned;
   use type C.unsigned_short;
   use type Interfaces.Integer_64;
   use type SSE.Integer_Address;

   type Timespec is record
      Seconds     : C.long;
      Nanoseconds : C.long;
   end record
     with Convention => C;

   type Kevent_Record is record
      Ident  : SSE.Integer_Address;
      Filter : C.short;
      Flags  : C.unsigned_short;
      Fflags : C.unsigned;
      Data   : C.long;
      Udata  : System.Address;
   end record
     with Convention => C;

   function Clock_Realtime return C.int;
   pragma Import
     (C, Clock_Realtime, "flyology_wall_clock_clock_realtime");
   function Notify_Key return System.Address;
   pragma Import (C, Notify_Key, "flyology_wall_clock_notify_key");
   function Notify_Status_OK return C.unsigned;
   pragma Import
     (C, Notify_Status_OK, "flyology_wall_clock_notify_status_ok");
   function EVFILT_READ return C.short;
   pragma Import (C, EVFILT_READ, "flyology_wall_clock_evfilt_read");
   function EVFILT_TIMER return C.short;
   pragma Import (C, EVFILT_TIMER, "flyology_wall_clock_evfilt_timer");
   function EV_ADD_ENABLE return C.unsigned_short;
   pragma Import
     (C, EV_ADD_ENABLE, "flyology_wall_clock_ev_add_enable");
   function EV_ADD_ENABLE_ONESHOT return C.unsigned_short;
   pragma Import
     (C,
      EV_ADD_ENABLE_ONESHOT,
      "flyology_wall_clock_ev_add_enable_oneshot");
   function EV_ERROR return C.unsigned_short;
   pragma Import (C, EV_ERROR, "flyology_wall_clock_ev_error");
   function NOTE_NSECONDS return C.unsigned;
   pragma Import (C, NOTE_NSECONDS, "flyology_wall_clock_note_nseconds");
   function Native_Kevent_Size return Interfaces.Unsigned_64;
   pragma Import
     (C, Native_Kevent_Size, "flyology_wall_clock_kevent_size");

   function Kqueue return C.int;
   pragma Import (C, Kqueue, "kqueue");
   function Kevent
     (Queue        : C.int;
      Changes      : System.Address;
      Change_Count : C.int;
      Events       : System.Address;
      Event_Count  : C.int;
      Timeout      : System.Address) return C.int;
   pragma Import (C, Kevent, "kevent");
   function Notify_Register_File_Descriptor
     (Name  : System.Address;
      FD    : access C.int;
      Flags : C.int;
      Token : access C.int) return C.unsigned;
   pragma Import
     (C, Notify_Register_File_Descriptor, "notify_register_file_descriptor");
   function Notify_Cancel (Token : C.int) return C.unsigned;
   pragma Import (C, Notify_Cancel, "notify_cancel");
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

   function Open (State : in out Wait_State) return Boolean is
      Change : aliased Kevent_Record;
      Status : C.unsigned;
      Ignored : C.unsigned;
      Change_FD : aliased C.int := -1;
      Token     : aliased C.int := -1;
   begin
      State := (Wait_FD => -1, Change_FD => -1, Token => -1);
      if Kevent_Record'Size /= Natural (Native_Kevent_Size) * 8 then
         return False;
      end if;
      State.Wait_FD := Kqueue;
      if State.Wait_FD < 0 then
         return False;
      end if;

      Status := Notify_Register_File_Descriptor
        (Notify_Key, Change_FD'Access, 0, Token'Access);
      State.Change_FD := Change_FD;
      State.Token := Token;
      if Status /= Notify_Status_OK then
         State.Change_FD := -1;
         State.Token := -1;
         return True;
      end if;

      Change :=
        (Ident  => SSE.Integer_Address (State.Change_FD),
         Filter => EVFILT_READ,
         Flags  => EV_ADD_ENABLE,
         Fflags => 0,
         Data   => 0,
         Udata  => System.Null_Address);
      if Kevent
        (State.Wait_FD,
         Change'Address,
         1,
         System.Null_Address,
         0,
         System.Null_Address) < 0
      then
         Ignored := Notify_Cancel (State.Token);
         State.Change_FD := -1;
         State.Token := -1;
      end if;
      return True;
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
         Difference : constant Policy.Difference_Result :=
           Policy.Difference_Nanoseconds (Deadline, Now);
         Timeout : Interfaces.Integer_64;
         Change  : aliased Kevent_Record;
      begin
         if not Difference.Fits then
            return Arm_Failed;
         end if;
         Timeout := Interfaces.Integer_64'Max (Difference.Nanoseconds, 1);
#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
         Flyology.Wall_Clock_Testing.Note_Native_Arm (Timeout);
#end if;
         Change :=
           (Ident  => 1,
            Filter => EVFILT_TIMER,
            Flags  => EV_ADD_ENABLE_ONESHOT,
            Fflags => NOTE_NSECONDS,
            Data   => C.long (Timeout),
            Udata  => System.Null_Address);
         return
           (if Kevent
              (State.Wait_FD,
               Change'Address,
               1,
               System.Null_Address,
               0,
               System.Null_Address) < 0
            then Arm_Failed
            else Armed);
      end;
   end Arm;

   function Consume (State : in out Wait_State) return Consume_Outcome is
      Event      : aliased Kevent_Record;
      Zero       : aliased Timespec := (Seconds => 0, Nanoseconds => 0);
      Result     : C.int;
      Error_Code : C.int;
   begin
      loop
#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
         if Flyology.Wall_Clock_Testing.Take_Native_Consume_EINTR then
            Result := -1;
            Error_Code := C.int (System.OS_Constants.EINTR);
         else
#end if;
            Result := Kevent
              (State.Wait_FD,
               System.Null_Address,
               0,
               Event'Address,
               1,
               Zero'Address);
            Error_Code :=
              (if Result < 0 then C.int (GNAT.OS_Lib.Errno) else 0);
#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
         end if;
#end if;
         exit when Result >= 0
           or else Error_Code /= C.int (System.OS_Constants.EINTR);
      end loop;

      if Result /= 1 then
         return Consume_Failed;
      elsif (Event.Flags and EV_ERROR) /= 0 then
         return Consume_Failed;
      elsif Event.Filter = EVFILT_TIMER then
         return Timer_Ready;
      elsif Event.Filter = EVFILT_READ
        and then Event.Ident = SSE.Integer_Address (State.Change_FD)
      then
         declare
            Delivered_Token : aliased C.int;
            Bytes           : C.long;
         begin
            loop
               Bytes := Read
                 (State.Change_FD,
                  Delivered_Token'Address,
                  C.size_t (C.int'Size / System.Storage_Unit));
               exit when Bytes >= 0
                 or else C.int (GNAT.OS_Lib.Errno) /=
                   C.int (System.OS_Constants.EINTR);
            end loop;
            return
              (if Bytes = C.long (C.int'Size / System.Storage_Unit)
               then Clock_Change_Ready
               else Consume_Failed);
         end;
      else
         return Consume_Failed;
      end if;
   end Consume;

   procedure Close (State : in out Wait_State) is
      Ignored_Notify : C.unsigned;
      Ignored_Close  : C.int;
   begin
      if State.Token >= 0 then
         Ignored_Notify := Notify_Cancel (State.Token);
      end if;
      if State.Wait_FD >= 0 then
         Ignored_Close := Close_FD (State.Wait_FD);
      end if;
      State := (Wait_FD => -1, Change_FD => -1, Token => -1);
   end Close;

   function Uses_Relative_Timer return Boolean is (True);
end Flyology.Wall_Clock_Native;
