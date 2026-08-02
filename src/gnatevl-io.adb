package body Gnatevl.IO is
   package C renames Interfaces.C;

   use type C.int;
   use type C.long_long;

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

   function To_Nanoseconds (Timeout : Duration) return C.long_long;
   function To_Milliseconds (Timeout : Duration) return C.int;

   function To_Nanoseconds (Timeout : Duration) return C.long_long is
   begin
      if Timeout < 0.0 then
         return -1;
      end if;
      return C.long_long (Timeout / Duration'Small);
   end To_Nanoseconds;

   function To_Milliseconds (Timeout : Duration) return C.int is
      Maximum_Nanoseconds : constant C.long_long :=
        C.long_long (C.int'Last) * 1_000_000;
      Nanoseconds : C.long_long;
   begin
      if Timeout < 0.0 then
         return -1;
      end if;

      Nanoseconds := To_Nanoseconds (Timeout);
      if Nanoseconds >= Maximum_Nanoseconds then
         return C.int'Last;
      end if;
      return C.int ((Nanoseconds + 999_999) / 1_000_000);
   end To_Milliseconds;

   function Is_Evented_Task return Boolean is
     (Runtime_In_Event_Task /= 0);

   function Wait
     (FD        : Descriptor;
      Condition : Wait_Kind;
      Timeout   : Duration := Infinite) return Boolean
   is
      Result : C.int;
   begin
      if FD < 0 then
         raise Device_Error with "invalid descriptor";
      end if;

      if Is_Evented_Task then
         Result :=
           Runtime_Wait_IO
             (FD,
              (if Condition = For_Write then 1 else 0),
              To_Nanoseconds (Timeout));
         if Result < 0 then
            raise Device_Error with "event-loop readiness wait failed";
         end if;
         return Result = 0;
      end if;

      declare
         Item : aliased Poll_Descriptor :=
           (FD              => FD,
            Events          =>
              (if Condition = For_Read then POLLIN else POLLOUT),
            Returned_Events => 0);
      begin
         Result := Poll (Item'Access, 1, To_Milliseconds (Timeout));
      end;
      if Result < 0 then
         raise Device_Error with "poll failed";
      end if;
      return Result > 0;
   end Wait;

end Gnatevl.IO;
