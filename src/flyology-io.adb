with GNAT.OS_Lib;
with Flyology.Time_Math;
with Flyology.Wait_Policy;
with System.OS_Constants;

package body Flyology.IO is
   package C renames Interfaces.C;

   use type C.int;
   use type C.short;

   POLLIN  : constant C.short := 16#0001#;
   POLLOUT : constant C.short := 16#0004#;
   POLLNVAL : constant C.short := 16#0020#;

   type Poll_Descriptor is record
      FD      : C.int;
      Events  : C.short;
      Returned_Events : C.short;
   end record;
   pragma Convention (C, Poll_Descriptor);
   type Poll_Descriptor_Array is
     array (Positive range <>) of aliased Poll_Descriptor
     with Convention => C;

   type Runtime_Wait_Request is record
      FD        : C.int;
      For_Write : C.int;
   end record
     with Convention => C;
   type Runtime_Wait_Request_Array is
     array (Positive range <>) of aliased Runtime_Wait_Request
     with Convention => C;

   function Runtime_In_Lightweight_Task return C.int;
   pragma Import
     (C, Runtime_In_Lightweight_Task, "flyology_runtime_in_lightweight_task");

   function Runtime_Wait_IO
     (FD                  : C.int;
      For_Write           : C.int;
      Timeout_Nanoseconds : C.long_long;
      Interrupt_1         : C.int;
      Interrupt_2         : C.int;
      Interrupt_3         : C.int) return C.int;
   pragma Import (C, Runtime_Wait_IO, "flyology_runtime_wait_io");

   function Runtime_Wait_IO_Many
     (Requests            : System.Address;
      Count               : C.unsigned;
      Timeout_Nanoseconds : C.long_long) return C.int;
   pragma Import
     (C, Runtime_Wait_IO_Many, "flyology_runtime_wait_io_many");

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

   function Is_Lightweight_Task return Boolean is
     (Runtime_In_Lightweight_Task /= 0);

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

   function Wait_Any
     (Requests : Wait_Request_Array;
      Timeout  : Duration := Infinite) return Natural
   is
      Started : constant Duration := Clock;
      Result  : C.int;
   begin
      if Requests'Length = 0 then
         return 0;
      elsif Requests'Length > Max_Wait_Requests then
         raise Device_Error with "too many readiness descriptors";
      end if;

      declare
         Runtime_Items : Runtime_Wait_Request_Array (1 .. Requests'Length);
         Poll_Items    : Poll_Descriptor_Array (1 .. Requests'Length);
         Position      : Positive := 1;

         function Lowest_Ready return Natural;

         function Lowest_Ready return Natural is
         begin
            for Index in Poll_Items'Range loop
               if Poll_Items (Index).Returned_Events /= 0 then
                  if Natural (Poll_Items (Index).Returned_Events)
                    / Natural (POLLNVAL) mod 2 = 1
                  then
                     raise Device_Error with "invalid descriptor";
                  end if;
                  --  Some poll implementations report only one entry when
                  --  the same descriptor/event pair appears repeatedly.
                  --  Normalize that platform detail to the documented
                  --  lowest-index rule.
                  for Earlier in Poll_Items'First .. Index loop
                     if Poll_Items (Earlier).FD = Poll_Items (Index).FD
                       and then Poll_Items (Earlier).Events =
                         Poll_Items (Index).Events
                     then
                        return Requests'First + Earlier - 1;
                     end if;
                  end loop;
               end if;
            end loop;
            return 0;
         end Lowest_Ready;
      begin
         for Index in Requests'Range loop
            if Requests (Index).FD < 0 then
               raise Device_Error with "invalid descriptor";
            end if;
            Runtime_Items (Position) :=
              (FD        => Requests (Index).FD,
               For_Write =>
                 (if Requests (Index).Condition = For_Write then 1 else 0));
            Poll_Items (Position) :=
              (FD              => Requests (Index).FD,
               Events          =>
                 (if Requests (Index).Condition = For_Read
                  then POLLIN else POLLOUT),
               Returned_Events => 0);
            Position := Position + 1;
         end loop;

         --  A zero-time probe is itself nonblocking. Running poll(2) directly
         --  also preserves native/lightweight parity when readiness and an
         --  already-expired scheduler deadline coincide.
         if Is_Lightweight_Task and then Timeout /= 0.0 then
            Result := Runtime_Wait_IO_Many
              (Runtime_Items'Address,
               C.unsigned (Requests'Length),
               Time_Math.To_Nanoseconds (Timeout));
            if Result < 0
              or else Natural (Result) > Requests'Length
            then
               raise Device_Error with "event-loop readiness wait failed";
            elsif Result = 0 then
               return 0;
            else
               --  kqueue/epoll may deliver distinct ready descriptors in an
               --  order unrelated to the caller's array. Probe the whole set
               --  after resumption to normalize simultaneous readiness to
               --  the lowest caller index, matching native poll semantics.
               for Index in Poll_Items'Range loop
                  Poll_Items (Index).Returned_Events := 0;
               end loop;
               declare
                  Probe : constant C.int := Poll
                    (Poll_Items'Address,
                     C.unsigned (Poll_Items'Length), 0);
                  Lowest : Natural;
               begin
                  if Probe > 0 then
                     Lowest := Lowest_Ready;
                     if Lowest /= 0 then
                        return Lowest;
                     end if;
                  elsif Probe < 0
                    and then C.int (GNAT.OS_Lib.Errno) /=
                      C.int (System.OS_Constants.EINTR)
                  then
                     raise Device_Error with "readiness probe failed";
                  end if;
               end;
               --  Edge-triggered readiness can disappear between scheduler
               --  delivery and this level probe. Preserve the kernel result
               --  in that case rather than manufacturing a timeout.
               return Requests'First + Natural (Result) - 1;
            end if;
         end if;

         loop
            for Index in Poll_Items'Range loop
               Poll_Items (Index).Returned_Events := 0;
            end loop;
            declare
               Elapsed : constant Duration := Clock - Started;
               Remaining : constant Duration :=
                 Time_Math.Remaining (Timeout, Elapsed);
            begin
               Result := Poll
                 (Poll_Items'Address,
                  C.unsigned (Poll_Items'Length),
                  Time_Math.To_Milliseconds (Remaining));
            end;

            if Result > 0 then
               declare
                  Lowest : constant Natural := Lowest_Ready;
               begin
                  if Lowest /= 0 then
                     return Lowest;
                  end if;
               end;
            end if;

            case Wait_Policy.Classify
              (Result,
               (if Result < 0 then C.int (GNAT.OS_Lib.Errno) else 0),
               C.int (System.OS_Constants.EINTR))
            is
               when Wait_Policy.Return_Ready =>
                  raise Device_Error with "poll returned no matching event";
               when Wait_Policy.Return_Timeout =>
                  return 0;
               when Wait_Policy.Retry =>
                  null;
               when Wait_Policy.Fail =>
                  raise Device_Error with "poll failed";
            end case;
         end loop;
      end;
   end Wait_Any;

   function Wait_Interruptibly
     (FD          : Descriptor;
      Condition   : Wait_Kind;
      Timeout     : Duration := Infinite;
      Interrupt_1 : Descriptor := Invalid_Descriptor;
      Interrupt_2 : Descriptor := Invalid_Descriptor;
      Interrupt_3 : Descriptor := Invalid_Descriptor) return Wait_Outcome
   is
      Started : constant Duration := Clock;
      Result  : C.int;
      Count   : Positive := 1;
   begin
      if FD < 0 then
         raise Device_Error with "invalid descriptor";
      end if;

      --  A zero-time probe is nonblocking and must inspect readiness rather
      --  than let an already-expired scheduler timer win the race.  This is
      --  the same native/lightweight parity rule used by Wait_Any.
      if Is_Lightweight_Task and then Timeout /= 0.0 then
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

end Flyology.IO;
