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
   EVFILT_AIO  : constant C.short := C.short (-3);
   EVFILT_READ : constant C.short := C.short (-1);
   EVFILT_WRITE : constant C.short := C.short (-2);
   EV_ADD      : constant C.unsigned_short := 16#0001#;
   EV_ONESHOT  : constant C.unsigned_short := 16#0010#;
   EV_CLEAR    : constant C.unsigned_short := 16#0020#;
   NOTE_TRIGGER : constant C.unsigned := 16#0100_0000#;
   Wake_Ident   : constant SSE.Integer_Address := 1;

   type Extension_Array is array (1 .. 2) of C.long_long;
   pragma Convention (C, Extension_Array);

   type Kevent_Record is record
      Ident  : SSE.Integer_Address;
      Filter : C.short;
      Flags  : C.unsigned_short;
      Fflags : C.unsigned;
      Data   : C.long_long;
      Udata  : SSE.Integer_Address;
      Ext    : Extension_Array;
   end record;
   pragma Convention (C, Kevent_Record);

   type File_Completion is record
      Token      : SSE.Integer_Address;
      Result     : C.long_long;
      Error_Code : C.int;
      Reserved   : C.int;
   end record;
   pragma Convention (C, File_Completion);

   function File_Engine_Create
     (Poller_FD, Wake_FD : C.int) return System.Address;
   pragma Import
     (C, File_Engine_Create, "gnatevl_file_engine_create");

   procedure File_Engine_Destroy (Engine : System.Address);
   pragma Import
     (C, File_Engine_Destroy, "gnatevl_file_engine_destroy");

   function File_Engine_Submit
     (Engine      : System.Address;
      Descriptor  : C.int;
      Buffer      : System.Address;
      Length      : C.size_t;
      Offset      : C.long_long;
      For_Write   : C.int;
      Token       : SSE.Integer_Address;
      Error_Code  : access C.int) return C.int;
   pragma Import
     (C, File_Engine_Submit, "gnatevl_file_engine_submit");

   function File_Engine_Complete
     (Engine          : System.Address;
      Request_Address : SSE.Integer_Address;
      Result          : C.long_long;
      Error_Code      : C.int;
      Completion      : access File_Completion) return C.int;
   pragma Import
     (C, File_Engine_Complete, "gnatevl_file_engine_complete");

   function Kqueue return C.int;
   pragma Import (C, Kqueue, "kqueue");

   function Kevent
     (Queue       : C.int;
      Changes     : System.Address;
      Change_Count : C.int;
      Events       : System.Address;
      Event_Count  : C.int;
      Flags        : C.unsigned;
      Timeout      : System.Address) return C.int;
   pragma Import (C, Kevent, "kevent64");

   function Close (Descriptor : C.int) return C.int;
   pragma Import (C, Close, "close");

   function Initialize (Item : in out Poller) return Boolean is
      Change : aliased Kevent_Record :=
        (Ident  => Wake_Ident,
         Filter => EVFILT_USER,
         Flags  => EV_ADD + EV_CLEAR,
         Fflags => 0,
         Data   => 0,
         Udata  => 0,
         Ext    => (others => 0));
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
      Item.File_State :=
        File_Engine_Create (Item.Descriptor, -1);
      if Item.File_State = System.Null_Address then
         Result := Close (Item.Descriptor);
         Item.Descriptor := -1;
         return False;
      end if;
      return True;
   end Initialize;

   procedure Finalize (Item : in out Poller) is
      Result : C.int;
   begin
      if Item.File_State /= System.Null_Address then
         File_Engine_Destroy (Item.File_State);
         Item.File_State := System.Null_Address;
      end if;
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
         Udata  => 0,
         Ext    => (others => 0));
   begin
      return Kevent
        (Item.Descriptor,
         Change'Address,
         1,
         System.Null_Address,
         0,
         0,
         System.Null_Address) = 0;
   end Watch;

   function Submit_File
     (Item        : in out Poller;
      Descriptor  : C.int;
      Buffer      : System.Address;
      Length      : C.size_t;
      Offset      : C.long_long;
      For_Write   : Boolean;
      Token       : System.Address;
      Error_Code  : out C.int) return Boolean
   is
      Error  : aliased C.int := 0;
      Result : C.int;
   begin
      Result :=
        File_Engine_Submit
          (Item.File_State,
           Descriptor,
           Buffer,
           Length,
           Offset,
           (if For_Write then 1 else 0),
           SSE.To_Integer (Token),
           Error'Access);
      Error_Code := Error;
      return Result = 0;
   end Submit_File;

   function Wait
     (Item                : in out Poller;
      Timeout             : Duration;
      Event               : out Poll_Event) return Boolean
   is
      Events : Poll_Event_Array (1 .. 1);
      Count  : Natural;
   begin
      if not Wait_Batch (Item, Timeout, Events, Count) then
         Event :=
           (Kind => Timeout_Event, Descriptor => -1, others => <>);
         return False;
      end if;
      Event := (if Count = 0
                then (Kind => Timeout_Event, Descriptor => -1, others => <>)
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
      Completion    : aliased File_Completion;
      Kernel_Event  : Kevent_Record;
      Output_Event  : Poll_Event;
   begin
      Events :=
        (others => (Kind => Timeout_Event, Descriptor => -1, others => <>));
      Count := 0;
      if Timeout < 0.0 then
         Result :=
           Kevent
             (Item.Descriptor,
              System.Null_Address,
              0,
              Kernel_Events'Address,
              C.int (Events'Length),
              0,
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
              0,
              Limit'Address);
      end if;
      if Result > 0 then
         Count := Natural (Result);
         for Index in 1 .. Count loop
            Kernel_Event :=
              Kernel_Events (Kernel_Events'First + Index - 1);
            Output_Event :=
              (Kind       => Timeout_Event,
               Descriptor => -1,
               others     => <>);
            if Kernel_Event.Filter = EVFILT_USER
            then
               Output_Event.Kind := Wake_Event;
               Output_Event.Descriptor := C.int (Kernel_Event.Ident);
            elsif Kernel_Event.Filter = EVFILT_AIO then
               if File_Engine_Complete
                 (Item.File_State,
                  Kernel_Event.Ident,
                  Kernel_Event.Ext (2),
                  C.int (Kernel_Event.Ext (1)),
                  Completion'Access) /= 0
               then
                  return False;
               end if;
               Output_Event :=
                 (Kind       => File_Event,
                  Descriptor => -1,
                  Token      => SSE.To_Address (Completion.Token),
                  Result     => Completion.Result,
                  Error_Code => Completion.Error_Code);
            elsif Kernel_Event.Filter = EVFILT_READ
            then
               Output_Event.Kind := Readable_Event;
               Output_Event.Descriptor := C.int (Kernel_Event.Ident);
            elsif Kernel_Event.Filter = EVFILT_WRITE
            then
               Output_Event.Kind := Writable_Event;
               Output_Event.Descriptor := C.int (Kernel_Event.Ident);
            end if;
            Events (Events'First + Index - 1) := Output_Event;
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
         Udata  => 0,
         Ext    => (others => 0));
   begin
      return Kevent
        (Item.Descriptor,
         Change'Address,
         1,
         System.Null_Address,
         0,
         0,
         System.Null_Address) = 0;
   end Wake;

end System.Gnatevl.Poller;
