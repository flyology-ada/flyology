with System.Flyology.Faults;
with System.Flyology.Time_ABI;
with System.OS_Interface;
with System.Storage_Elements;

package body System.Flyology.Poller is
   package C renames Interfaces.C;
   package Faults renames System.Flyology.Faults;
   package Time_ABI renames System.Flyology.Time_ABI;
   package File_Engines renames System.Flyology.File_Engine;
   package OSI renames System.OS_Interface;
   package SSE renames System.Storage_Elements;

   use type C.int;
   use type C.long_long;
   use type C.short;
   use type C.unsigned_short;
   use type SSE.Integer_Address;
   use type Poller_Policy.Cancel_Outcome;

   EVFILT_USER : constant C.short := C.short (-10);
   EVFILT_AIO  : constant C.short := C.short (-3);
   EVFILT_READ : constant C.short := C.short (-1);
   EVFILT_WRITE : constant C.short := C.short (-2);
   EV_ADD      : constant C.unsigned_short := 16#0001#;
   EV_ENABLE   : constant C.unsigned_short := 16#0004#;
   EV_DELETE   : constant C.unsigned_short := 16#0002#;
   EV_DISPATCH : constant C.unsigned_short := 16#0080#;
   EV_CLEAR    : constant C.unsigned_short := 16#0020#;
   EV_RECEIPT  : constant C.unsigned_short := 16#0040#;
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
   type Kevent_Array is array (Positive range <>) of Kevent_Record;
   pragma Convention (C, Kevent_Array);

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
            raise Program_Error with "Flyology poller cleanup failed";
         end if;
         return False;
      end if;
      if not File_Engines.Initialize
        (Item.File_State, Item.Descriptor, -1)
      then
         Result := Close (Item.Descriptor);
         Item.Descriptor := -1;
         return False;
      end if;
      return True;
   end Initialize;

   procedure Finalize (Item : in out Poller) is
      Result : C.int;
   begin
      File_Engines.Finalize (Item.File_State);
      if Item.Descriptor >= 0 then
         Result := Close (Item.Descriptor);
         Item.Descriptor := -1;
         if Result /= 0 then
            raise Program_Error with "Flyology poller close failed";
         end if;
      end if;
   end Finalize;

   function Watch
     (Item       : in out Poller;
      Descriptor : C.int;
      Condition  : Interest) return Boolean
   is
      Requests : constant Interest_Request_Array :=
        [1 => (Descriptor => Descriptor, Condition => Condition)];
   begin
      return Watch_Many (Item, Requests);
   end Watch;

   function Watch_Many
     (Item     : in out Poller;
      Requests : Interest_Request_Array) return Boolean
   is
      Changes : aliased Kevent_Array (Requests'Range);
      Result  : C.int;
   begin
      for Index in Requests'Range loop
         --  Keep fault-injection accounting per logical interest even though
         --  the production path submits the completed change list once.
         if Faults.Enabled and then Faults.Fail (Faults.Poller_Watch) then
            return False;
         end if;
         Changes (Index) :=
           (Ident  => SSE.Integer_Address (Requests (Index).Descriptor),
            Filter =>
              (if Requests (Index).Condition = Readable
               then EVFILT_READ else EVFILT_WRITE),
            --  Dispatch disables the knote after delivery without deleting
            --  it. A later EV_ADD + EV_ENABLE rearms the same descriptor and
            --  filter pair, while close still removes the knote in the kernel.
            Flags  => EV_ADD + EV_ENABLE + EV_DISPATCH,
            Fflags => 0,
            Data   => 0,
            Udata  => 0,
            Ext    => (others => 0));
      end loop;
      Result := Kevent
        (Item.Descriptor,
         Changes'Address,
         C.int (Changes'Length),
         System.Null_Address,
         0,
         0,
         System.Null_Address);
      if Result = 0 then
         return True;
      end if;

      --  kevent applies a change list in order and can stop after a later
      --  invalid descriptor. The scheduler clears the complete request set
      --  and treats a failed rollback as a fatal poller error.
      return False;
   end Watch_Many;

   function Cancel
     (Item       : in out Poller;
      Descriptor : C.int;
      Condition  : Interest) return Boolean
   is
      Requests : constant Interest_Request_Array :=
        [1 => (Descriptor => Descriptor, Condition => Condition)];
   begin
      return Cancel_Many (Item, Requests);
   end Cancel;

   function Cancel_Many
     (Item     : in out Poller;
      Requests : Interest_Request_Array) return Boolean
   is
      Changes  : aliased Kevent_Array (Requests'Range);
      Receipts : aliased Kevent_Array (Requests'Range);
      Result   : C.int;
      Succeeded : Boolean := True;
   begin
      for Index in Requests'Range loop
         Changes (Index) :=
           (Ident  => SSE.Integer_Address (Requests (Index).Descriptor),
            Filter =>
              (if Requests (Index).Condition = Readable
               then EVFILT_READ else EVFILT_WRITE),
            Flags  => EV_DELETE + EV_RECEIPT,
            Fflags => 0,
            Data   => 0,
            Udata  => 0,
            Ext    => (others => 0));
      end loop;
      Result := Kevent
        (Item.Descriptor,
         Changes'Address,
         C.int (Changes'Length),
         Receipts'Address,
         C.int (Receipts'Length),
         0,
         System.Null_Address);
      if Result /= C.int (Requests'Length) then
         return False;
      end if;
      for Index in Receipts'Range loop
         --  XNU drops a knote when its descriptor closes and reports ENOENT
         --  (or occasionally EBADF) for its receipt. Both mean that no
         --  registration remains and are successful cancellation outcomes.
         if Poller_Policy.Classify_Cancel
              (Receipts (Index).Data = 0,
               Integer (Receipts (Index).Data)) =
            Poller_Policy.Cancel_Failed
         then
            Succeeded := False;
         end if;
      end loop;
      return Succeeded;
   end Cancel_Many;

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
   begin
      if Faults.Enabled
        and then Faults.Fail (Faults.File_Submission_Full)
      then
         Error_Code := C.int (OSI.EAGAIN);
         return False;
      end if;
      return File_Engines.Submit
        (Item.File_State,
         Descriptor,
         Buffer,
         Length,
         Offset,
         For_Write,
         Token,
         Error_Code);
   end Submit_File;

   function Supports_Send_ZC (Item : Poller) return Boolean is
     (File_Engines.Supports_Send_ZC (Item.File_State));

   function Submit_Send_ZC
     (Item        : in out Poller;
      Descriptor  : C.int;
      Buffer      : System.Address;
      Length      : C.size_t;
      Token       : System.Address;
      Error_Code  : out C.int) return Boolean
   is
   begin
      pragma Unreferenced (Item, Descriptor, Buffer, Length, Token);
      Error_Code := C.int (OSI.EINVAL);
      return False;
   end Submit_Send_ZC;

   function Cancel_File
     (Item           : in out Poller;
      Descriptor     : C.int;
      Token          : System.Address;
      Value          : out File_Engines.Completion;
      Has_Completion : out Boolean;
      Error_Code     : out C.int)
      return File_Engines.Cancellation_Disposition
   is
   begin
      if Faults.Enabled
        and then Faults.Fail (Faults.File_Cancel_Not_Cancelable)
      then
         Value := (others => <>);
         Has_Completion := False;
         Error_Code := 0;
         return File_Engines.Not_Cancelable;
      elsif Faults.Enabled
        and then Faults.Fail (Faults.File_Cancel_Already_Completing)
      then
         Value := (others => <>);
         Has_Completion := False;
         Error_Code := 0;
         return File_Engines.Already_Completing;
      end if;
      return File_Engines.Cancel
        (Item.File_State,
         Descriptor,
         Token,
         Value,
         Has_Completion,
         Error_Code);
   end Cancel_File;

   function File_Quiescent (Item : Poller) return Boolean is
     (File_Engines.Is_Quiescent (Item.File_State));

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
      Kernel_Events : aliased Kevent_Array (Events'Range);
      Limit         : aliased Time_ABI.Timespec;
      Result        : C.int;
      Completion    : File_Engines.Completion;
      Completion_Status : File_Engines.Event_Completion_Disposition;
      Kernel_Event  : Kevent_Record;
      Output_Event  : Poll_Event;
      Output_Count  : Natural := 0;
      Emit          : Boolean;
   begin
      Events :=
        (others => (Kind => Timeout_Event, Descriptor => -1, others => <>));
      Count := 0;
      if Faults.Enabled and then Faults.Fail (Faults.Poller_Wait) then
         return False;
      elsif Faults.Enabled and then Faults.Fail (Faults.Poller_EINTR) then
         return True;
      end if;
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
         Limit := Time_ABI.To_Timespec (Timeout);
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
         for Index in 1 .. Natural (Result) loop
            Kernel_Event :=
              Kernel_Events (Kernel_Events'First + Index - 1);
            Emit := True;
            Output_Event :=
              (Kind       => Timeout_Event,
               Descriptor => -1,
               others     => <>);
            if Kernel_Event.Filter = EVFILT_USER
            then
               if Faults.Enabled and then Kernel_Event.Udata /= 0 then
                  Completion_Status := File_Engines.Complete_Event
                    (Item.File_State,
                     SSE.To_Address (Kernel_Event.Udata),
                     0,
                     0,
                     Completion);
                  case Completion_Status is
                     when File_Engines.Completion_Produced =>
                        Output_Event :=
                          (Kind       => File_Event,
                           Descriptor => -1,
                           Token      => Completion.Token,
                           Result     => Completion.Result,
                           Error_Code => Completion.Error_Code);
                     when File_Engines.Completion_Ignored =>
                        Emit := False;
                     when File_Engines.Completion_Failed =>
                        return False;
                  end case;
               else
                  Output_Event.Kind := Wake_Event;
                  Output_Event.Descriptor := C.int (Kernel_Event.Ident);
               end if;
            elsif Kernel_Event.Filter = EVFILT_AIO then
               Completion_Status := File_Engines.Complete_Event
                 (Item.File_State,
                  SSE.To_Address (Kernel_Event.Ident),
                  Kernel_Event.Ext (2),
                  C.int (Kernel_Event.Ext (1)),
                  Completion);
               case Completion_Status is
                  when File_Engines.Completion_Produced =>
                     Output_Event :=
                       (Kind       => File_Event,
                        Descriptor => -1,
                        Token      => Completion.Token,
                        Result     => Completion.Result,
                        Error_Code => Completion.Error_Code);
                  when File_Engines.Completion_Ignored =>
                     Emit := False;
                  when File_Engines.Completion_Failed =>
                     return False;
               end case;
            elsif Kernel_Event.Filter = EVFILT_READ
            then
               Output_Event.Kind := Readable_Event;
               Output_Event.Descriptor := C.int (Kernel_Event.Ident);
            elsif Kernel_Event.Filter = EVFILT_WRITE
            then
               Output_Event.Kind := Writable_Event;
               Output_Event.Descriptor := C.int (Kernel_Event.Ident);
            end if;
            if Emit then
               Output_Count := Output_Count + 1;
               Events (Events'First + Output_Count - 1) := Output_Event;
            end if;
         end loop;
         Count := Output_Count;
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
      if Faults.Enabled and then Faults.Fail (Faults.Poller_Wake) then
         return False;
      end if;
      return Kevent
        (Item.Descriptor,
         Change'Address,
         1,
         System.Null_Address,
         0,
         0,
         System.Null_Address) = 0;
   end Wake;

end System.Flyology.Poller;
