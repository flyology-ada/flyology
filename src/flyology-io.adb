with GNAT.OS_Lib;
with Flyology.Time_Math;
with Flyology.Wait_Policy;
with Flyology.Operations.Drivers;
with System.OS_Constants;
#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
with Flyology.Wall_Clock_IO_Testing;
#end if;

package body Flyology.IO is
   package C renames Interfaces.C;

   use type C.int;
   use type Flyology.Operations.Driver_Event;
   use type C.short;
#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
   use type Interfaces.Integer_64;
#end if;

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

   function Runtime_Wait_IO_Many
     (Requests            : System.Address;
      Count               : C.unsigned;
      Timeout_Nanoseconds : C.long_long;
      Interrupt_Wait      : C.int) return C.int;
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

   function Read_Monotonic (Value : access Timespec) return C.int;
   pragma Import (C, Read_Monotonic, "flyology_monotonic_clock");

#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
   function Test_Clock_Offset return Duration is
      Nanoseconds : constant Interfaces.Integer_64 :=
        Flyology.Wall_Clock_IO_Testing.Steady_Adjustment;
   begin
      return
        Duration (Nanoseconds / 1_000_000_000)
        + Duration (Nanoseconds rem 1_000_000_000) / 1_000_000_000;
   end Test_Clock_Offset;
#end if;

   function Clock return Duration is
      Now    : aliased Timespec;
      Result : C.int;
   begin
      Result := Read_Monotonic (Now'Access);
      if Result /= 0 then
         raise Device_Error with "monotonic clock failed";
      end if;
      return
        Duration (Now.Seconds)
        + Duration (Now.Nanoseconds) / 1_000_000_000
#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
        + Test_Clock_Offset
#end if;
        ;
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

   function Wait_Any_Internal
     (Requests : Wait_Request_Array;
      Timeout  : Duration;
      Interrupt_Wait : Boolean) return Natural
   is
      Started : constant Duration := Clock;
      Result     : C.int;
      Error_Code : C.int := 0;
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
               Time_Math.To_Nanoseconds (Timeout),
               (if Interrupt_Wait then 1 else 0));
            if Result < 0
              or else Natural (Result) > Requests'Length
            then
               raise Device_Error with "event-loop readiness wait failed";
            elsif Result = 0 then
               return 0;
            elsif Result = 1 then
               --  The first request is already the lowest possible caller
               --  index, so the parity probe below cannot change the result.
               --  Later results still probe the whole set to preserve
               --  simultaneous-readiness and interrupt priority semantics.
               return Requests'First;
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
#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
               if Flyology.Wall_Clock_IO_Testing.Take_EINTR then
                  Result := -1;
                  Error_Code := C.int (System.OS_Constants.EINTR);
               else
#end if;
                  Result := Poll
                    (Poll_Items'Address,
                     C.unsigned (Poll_Items'Length),
                     Time_Math.To_Milliseconds (Remaining));
                  Error_Code :=
                    (if Result < 0
                     then C.int (GNAT.OS_Lib.Errno)
                     else 0);
#if FLYOLOGY_WALL_CLOCK_TEST_HOOKS then
               end if;
#end if;
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
               Error_Code,
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
   end Wait_Any_Internal;

   function Wait_Any
     (Requests : Wait_Request_Array;
      Timeout  : Duration := Infinite) return Natural is
     (Wait_Any_Internal (Requests, Timeout, False));

   procedure Wait_Some
     (Requests  : Wait_Request_Array;
      Completed : out Wait_Batch;
      Timeout   : Duration := Infinite)
   is
      Selected : Natural;
   begin
      Completed.Count := 0;
      Completed.Indexes := (others => Positive'First);
      if Requests'Length = 0 then
         return;
      end if;

      Selected := Wait_Any_Internal (Requests, Timeout, False);
      if Selected = 0 then
         return;
      end if;

      declare
         Poll_Items : Poll_Descriptor_Array (1 .. Requests'Length);
         Ready      : array (Requests'Range) of Boolean := (others => False);
         Position   : Positive := Poll_Items'First;
         Result     : C.int;
      begin
         Ready (Selected) := True;
         for Index in Requests'Range loop
            if Requests (Index).FD < 0 then
               raise Device_Error with "invalid descriptor";
            end if;
            Poll_Items (Position) :=
              (FD              => Requests (Index).FD,
               Events          =>
                 (if Requests (Index).Condition = For_Read
                  then POLLIN else POLLOUT),
               Returned_Events => 0);
            Position := Position + 1;
         end loop;

         Result := Poll
           (Poll_Items'Address, C.unsigned (Poll_Items'Length), 0);
         if Result < 0
           and then C.int (GNAT.OS_Lib.Errno) /=
             C.int (System.OS_Constants.EINTR)
         then
            raise Device_Error with "readiness batch probe failed";
         elsif Result > 0 then
            Position := Poll_Items'First;
            for Index in Requests'Range loop
               if Poll_Items (Position).Returned_Events /= 0 then
                  if Natural (Poll_Items (Position).Returned_Events)
                    / Natural (POLLNVAL) mod 2 = 1
                  then
                     raise Device_Error with "invalid descriptor";
                  end if;
                  Ready (Index) := True;
               end if;
               Position := Position + 1;
            end loop;
         end if;

         for Index in Requests'Range loop
            if Ready (Index) then
               Completed.Count := Completed.Count + 1;
               Completed.Indexes (Completed.Count) := Index;
            end if;
         end loop;
      end;
   end Wait_Some;

   function Wait_Interruptibly
     (FD          : Descriptor;
      Condition   : Wait_Kind;
      Timeout     : Duration := Infinite;
      Interrupts  : Interrupt_Set := No_Interrupts) return Wait_Outcome
   is
   begin
      if FD < 0 then
         raise Device_Error with "invalid descriptor";
      elsif Interrupts'Length >= Max_Wait_Requests then
         raise Device_Error with "too many interrupt descriptors";
      end if;

      declare
         Requests : Wait_Request_Array (1 .. Interrupts'Length + 1);
         Result   : Natural;
      begin
         Requests (1) := (FD => FD, Condition => Condition);
         for Index in Interrupts'Range loop
            Requests (Index - Interrupts'First + 2) :=
              (FD => Interrupts (Index), Condition => For_Read);
         end loop;

         Result := Wait_Any_Internal
           (Requests, Timeout, Interrupts'Length > 0);

         if Result = 0 then
            return Timed_Out;
         elsif Result = Requests'First then
            return Ready;
         else
            return Interrupted;
         end if;
      end;
   end Wait_Interruptibly;

   function Wait
     (Set       : not null access Flyology.Operations.Completion_Set'Class;
      FD        : Descriptor;
      Condition : Wait_Kind) return Readiness_Operation
   is
   begin
      return Result : Readiness_Operation (Set) do
         Flyology.Operations.Drivers.Start (Result);
         Flyology.Operations.Drivers.Arm_Readiness
           (Result, FD, Condition = For_Write);
      end return;
   end Wait;

   procedure Rearm
     (FD        : Descriptor;
      Condition : Wait_Kind;
      Operation : in out Readiness_Operation)
   is
   begin
      Flyology.Operations.Drivers.Start (Operation);
      Flyology.Operations.Drivers.Arm_Readiness
        (Operation, FD, Condition = For_Write);
   exception
      when others =>
         if Flyology.Operations.Is_Active (Operation) then
            Flyology.Operations.Drivers.Rollback_Start (Operation);
         end if;
         raise;
   end Rearm;

   overriding procedure Drive
     (Item  : in out Readiness_Operation;
      Event : Flyology.Operations.Driver_Event)
   is
   begin
      if Event /= Flyology.Operations.Source_Ready then
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Failed);
      else
         Flyology.Operations.Drivers.Complete
           (Item, Flyology.Operations.Succeeded);
      end if;
   end Drive;

   overriding procedure Request_Cancellation
     (Item : in out Readiness_Operation)
   is
   begin
      Flyology.Operations.Drivers.Complete
        (Item, Flyology.Operations.Cancelled);
   end Request_Cancellation;

   procedure Finish (Operation : in out Readiness_Operation) is
      Result : constant Flyology.Operations.Terminal_Outcome :=
        Flyology.Operations.Outcome (Operation);
   begin
      Flyology.Operations.Consume (Operation);
      case Result is
         when Flyology.Operations.Succeeded =>
            null;
         when Flyology.Operations.Cancelled =>
            raise Flyology.Operations.Operation_Cancelled;
         when Flyology.Operations.Failed =>
            raise Device_Error with "readiness operation failed";
      end case;
   end Finish;

end Flyology.IO;
