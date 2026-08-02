with System.C_Time;
with System.OS_Interface;
with System.Storage_Elements;

package body System.Gnatevl.Poller is
   package C renames Interfaces.C;
   package C_Time renames System.C_Time;
   package OSI renames System.OS_Interface;
   package SSE renames System.Storage_Elements;

   use type C.int;
   use type C.short;
   use type C.unsigned_short;

   EVFILT_USER : constant C.short := C.short (-10);
   EVFILT_READ : constant C.short := C.short (-1);
   EVFILT_WRITE : constant C.short := C.short (-2);
   EV_ADD      : constant C.unsigned_short := 16#0001#;
   EV_ONESHOT  : constant C.unsigned_short := 16#0010#;
   EV_CLEAR    : constant C.unsigned_short := 16#0020#;
   NOTE_TRIGGER : constant C.unsigned := 16#0100_0000#;
   Wake_Ident   : constant SSE.Integer_Address := 1;

   type Kevent_Record is record
      Ident  : SSE.Integer_Address;
      Filter : C.short;
      Flags  : C.unsigned_short;
      Fflags : C.unsigned;
      Data   : C.long;
      Udata  : System.Address;
   end record;
   pragma Convention (C, Kevent_Record);

   function Kqueue return C.int;
   pragma Import (C, Kqueue, "kqueue");

   function Kevent
     (Queue       : C.int;
      Changes     : System.Address;
      Change_Count : C.int;
      Events       : System.Address;
      Event_Count  : C.int;
      Timeout      : System.Address) return C.int;
   pragma Import (C, Kevent, "kevent");

   function Close (Descriptor : C.int) return C.int;
   pragma Import (C, Close, "close");

   function Initialize (Item : in out Poller) return Boolean is
      Change : aliased Kevent_Record :=
        (Ident  => Wake_Ident,
         Filter => EVFILT_USER,
         Flags  => EV_ADD + EV_CLEAR,
         Fflags => 0,
         Data   => 0,
         Udata  => System.Null_Address);
      Result : C.int;
   begin
      Item.Descriptor := Kqueue;
      if Item.Descriptor < 0 then
         return False;
      end if;

      Result :=
        Kevent
          (Item.Descriptor,
           Change'Address,
           1,
           System.Null_Address,
           0,
           System.Null_Address);
      if Result /= 0 then
         Result := Close (Item.Descriptor);
         Item.Descriptor := -1;
         if Result /= 0 then
            raise Program_Error with "GNATEVL poller cleanup failed";
         end if;
         return False;
      end if;
      return True;
   end Initialize;

   procedure Finalize (Item : in out Poller) is
      Result : C.int;
   begin
      if Item.Descriptor >= 0 then
         Result := Close (Item.Descriptor);
         Item.Descriptor := -1;
         if Result /= 0 then
            raise Program_Error with "GNATEVL poller close failed";
         end if;
      end if;
   end Finalize;

   function Watch
     (Item       : in out Poller;
      Descriptor : C.int;
      Condition  : Interest) return Boolean
   is
      Change : aliased Kevent_Record :=
        (Ident  => SSE.Integer_Address (Descriptor),
         Filter =>
           (if Condition = Readable then EVFILT_READ else EVFILT_WRITE),
         Flags  => EV_ADD + EV_ONESHOT,
         Fflags => 0,
         Data   => 0,
         Udata  => System.Null_Address);
   begin
      return Kevent
        (Item.Descriptor,
         Change'Address,
         1,
         System.Null_Address,
         0,
         System.Null_Address) = 0;
   end Watch;

   function Wait
     (Item                : in out Poller;
      Timeout             : Duration;
      Event               : out Poll_Event) return Boolean
   is
      Events : Poll_Event_Array (1 .. 1);
      Count  : Natural;
   begin
      if not Wait_Batch (Item, Timeout, Events, Count) then
         Event := (Kind => Timeout_Event, Descriptor => -1);
         return False;
      end if;
      Event := (if Count = 0
                then (Kind => Timeout_Event, Descriptor => -1)
                else Events (1));
      return True;
   end Wait;

   function Wait_Batch
     (Item                : in out Poller;
      Timeout             : Duration;
      Events              : out Poll_Event_Array;
      Count               : out Natural) return Boolean
   is
      type Kevent_Array is array (Positive range <>) of Kevent_Record;
      pragma Convention (C, Kevent_Array);
      Kernel_Events : aliased Kevent_Array (Events'Range);
      Limit         : aliased C_Time.timespec;
      Result        : C.int;
   begin
      Events := (others => (Kind => Timeout_Event, Descriptor => -1));
      Count := 0;
      if Timeout < 0.0 then
         Result :=
           Kevent
             (Item.Descriptor,
              System.Null_Address,
              0,
              Kernel_Events'Address,
              C.int (Events'Length),
              System.Null_Address);
      else
         Limit := C_Time.To_Timespec (Timeout);
         Result :=
           Kevent
             (Item.Descriptor,
              System.Null_Address,
              0,
              Kernel_Events'Address,
              C.int (Events'Length),
              Limit'Address);
      end if;
      if Result > 0 then
         Count := Natural (Result);
         for Index in 1 .. Count loop
            Events (Events'First + Index - 1).Descriptor :=
              C.int (Kernel_Events (Kernel_Events'First + Index - 1).Ident);
            if Kernel_Events (Kernel_Events'First + Index - 1).Filter =
              EVFILT_USER
            then
               Events (Events'First + Index - 1).Kind := Wake_Event;
            elsif Kernel_Events (Kernel_Events'First + Index - 1).Filter =
              EVFILT_READ
            then
               Events (Events'First + Index - 1).Kind := Readable_Event;
            elsif Kernel_Events (Kernel_Events'First + Index - 1).Filter =
              EVFILT_WRITE
            then
               Events (Events'First + Index - 1).Kind := Writable_Event;
            end if;
         end loop;
      end if;
      return Result >= 0 or else OSI.errno = OSI.EINTR;
   end Wait_Batch;

   function Wake (Item : Poller) return Boolean is
      Change : aliased Kevent_Record :=
        (Ident  => Wake_Ident,
         Filter => EVFILT_USER,
         Flags  => 0,
         Fflags => NOTE_TRIGGER,
         Data   => 0,
         Udata  => System.Null_Address);
   begin
      return Kevent
        (Item.Descriptor,
         Change'Address,
         1,
         System.Null_Address,
         0,
         System.Null_Address) = 0;
   end Wake;

end System.Gnatevl.Poller;
