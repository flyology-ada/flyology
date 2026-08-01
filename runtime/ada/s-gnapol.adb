with System.C_Time;
with System.OS_Interface;
with System.Storage_Elements;

package body System.Gnatevl.Poller is
   package C renames Interfaces.C;
   package C_Time renames System.C_Time;
   package OSI renames System.OS_Interface;
   package SSE renames System.Storage_Elements;

   use type C.int;
   use type C.unsigned_short;

   EVFILT_USER : constant C.short := C.short (-10);
   EV_ADD      : constant C.unsigned_short := 16#0001#;
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
         pragma Assert (Result = 0);
         Item.Descriptor := -1;
         return False;
      end if;
      return True;
   end Initialize;

   procedure Finalize (Item : in out Poller) is
      Result : C.int;
   begin
      if Item.Descriptor >= 0 then
         Result := Close (Item.Descriptor);
         pragma Unreferenced (Result);
         Item.Descriptor := -1;
      end if;
   end Finalize;

   function Wait
     (Item                : Poller;
      Timeout             : Duration) return Boolean
   is
      Event   : aliased Kevent_Record;
      Limit   : aliased C_Time.timespec;
      Result  : C.int;
   begin
      if Timeout < 0.0 then
         Result :=
           Kevent
             (Item.Descriptor,
              System.Null_Address,
              0,
              Event'Address,
              1,
              System.Null_Address);
      else
         Limit := C_Time.To_Timespec (Timeout);
         Result :=
           Kevent
             (Item.Descriptor,
              System.Null_Address,
              0,
              Event'Address,
              1,
              Limit'Address);
      end if;
      return Result >= 0 or else OSI.errno = OSI.EINTR;
   end Wait;

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
