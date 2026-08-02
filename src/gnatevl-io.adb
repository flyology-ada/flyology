with GNAT.OS_Lib;
with Gnatevl.Time_Math;
with Gnatevl.Wait_Policy;
with System.OS_Constants;

package body Gnatevl.IO is
   package C renames Interfaces.C;

   use type C.int;
   use type C.short;

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
      Timeout_Nanoseconds : C.long_long;
      Interrupt_1         : C.int;
      Interrupt_2         : C.int;
      Interrupt_3         : C.int) return C.int;
   pragma Import (C, Runtime_Wait_IO, "gnatevl_runtime_wait_io");

   function Poll
     (Descriptors : System.Address;
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
      Outcome : constant Wait_Outcome :=
        Wait_Interruptibly (FD, Condition, Timeout);
   begin
      return Outcome = Ready;
   end Wait;

   function Wait_Interruptibly
     (FD          : Descriptor;
      Condition   : Wait_Kind;
      Timeout     : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor) return Wait_Outcome
   is
      type Poll_Descriptor_Array is
        array (Positive range <>) of aliased Poll_Descriptor
        with Convention => C;
      Started : constant Duration := Clock;
      Result  : C.int;
      Count   : Positive := 1;
   begin
      if FD < 0 then
         raise Device_Error with "invalid descriptor";
      end if;

      if Is_Evented_Task then
         Result :=
           Runtime_Wait_IO
              (FD,
              (if Condition = For_Write then 1 else 0),
              Time_Math.To_Nanoseconds (Timeout),
              Interrupt_1,
              Interrupt_2,
              Interrupt_3);
         if Result < 0 then
            raise Device_Error with "event-loop readiness wait failed";
         end if;
         return
           (case Result is
              when 0      => Ready,
              when 1      => Timed_Out,
              when 2 | 3 | 4 => Interrupted,
              when others => raise Device_Error with
                "invalid event-loop readiness result");
      end if;

      if Interrupt_1 >= 0 then
         Count := Count + 1;
      end if;
      if Interrupt_2 >= 0 then
         Count := Count + 1;
      end if;
      if Interrupt_3 >= 0 then
         Count := Count + 1;
      end if;

      loop
         declare
            Elapsed : constant Duration := Clock - Started;
            Remaining : constant Duration :=
              Time_Math.Remaining (Timeout, Elapsed);
            Items : Poll_Descriptor_Array (1 .. Count);
            Next  : Positive := 2;
         begin
            Items (1) :=
              (FD              => FD,
               Events          =>
                 (if Condition = For_Read then POLLIN else POLLOUT),
               Returned_Events => 0);
            if Interrupt_1 >= 0 then
               Items (Next) :=
                 (FD => Interrupt_1, Events => POLLIN, Returned_Events => 0);
               Next := Next + 1;
            end if;
            if Interrupt_2 >= 0 then
               Items (Next) :=
                 (FD => Interrupt_2, Events => POLLIN, Returned_Events => 0);
               Next := Next + 1;
            end if;
            if Interrupt_3 >= 0 then
               Items (Next) :=
                 (FD => Interrupt_3, Events => POLLIN, Returned_Events => 0);
            end if;
            Result :=
              Poll
                (Items'Address,
                 C.unsigned (Count),
                 Time_Math.To_Milliseconds (Remaining));
            if Result > 0 then
               if Items (1).Returned_Events /= 0 then
                  return Ready;
               end if;
               for Index in 2 .. Count loop
                  if Items (Index).Returned_Events /= 0 then
                     return Interrupted;
                  end if;
               end loop;
            end if;
         end;

         case Wait_Policy.Classify
           (Result,
            (if Result < 0 then C.int (GNAT.OS_Lib.Errno) else 0),
            C.int (System.OS_Constants.EINTR))
         is
            when Wait_Policy.Return_Ready =>
               --  Readiness was classified above so this cannot be reached.
               raise Device_Error with "poll returned no matching event";
            when Wait_Policy.Return_Timeout =>
               return Timed_Out;
            when Wait_Policy.Retry =>
               null;
            when Wait_Policy.Fail =>
               raise Device_Error with "poll failed";
         end case;
      end loop;
   end Wait_Interruptibly;

end Gnatevl.IO;
