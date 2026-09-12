with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with System.Flyology.Faults;
with System.Flyology.Time_ABI;
with System.OS_Interface;

package body System.Flyology.Poller is
   package C renames Interfaces.C;
   package Faults renames System.Flyology.Faults;
   package Time_ABI renames System.Flyology.Time_ABI;
   package File_Engines renames System.Flyology.File_Engine;
   package Poller_Policy renames System.Flyology.Poller_Policy;
   package OSI renames System.OS_Interface;

   use type C.int;
   use type C.long;
   use type C.long_long;
   use type C.unsigned;

   EPOLL_CTL_ADD : constant C.int := 1;
   EPOLL_CTL_DEL : constant C.int := 2;
   EPOLL_CTL_MOD : constant C.int := 3;
   --  Linux UAPI eventpoll.h defines EPOLL_CLOEXEC as O_CLOEXEC;
   --  asm-generic/fcntl.h defines O_CLOEXEC as 16#0008_0000#.
   EPOLL_CLOEXEC : constant C.int := 16#0008_0000#;

   EPOLLIN      : constant C.unsigned := 16#0000_0001#;
   EPOLLOUT     : constant C.unsigned := 16#0000_0004#;
   EPOLLERR     : constant C.unsigned := 16#0000_0008#;
   EPOLLHUP     : constant C.unsigned := 16#0000_0010#;
   EPOLLRDHUP   : constant C.unsigned := 16#0000_2000#;
   EPOLLONESHOT : constant C.unsigned := 16#4000_0000#;

   EFD_NONBLOCK : constant C.int := 16#0000_0800#;
   EFD_CLOEXEC  : constant C.int := 16#0008_0000#;
   EAGAIN       : constant C.int := 11;

   type Epoll_Event is record
      Events     : C.unsigned;
      Descriptor : C.int;
   end record
   with Convention => C, Size => 64, Alignment => 4;

   type Epoll_Event_Array is array (Positive range <>) of Epoll_Event with Convention => C;

   type Watch_Record;
   type Watch_Access is access all Watch_Record;
   type Watch_Record is record
      Descriptor : C.int := -1;
      Readable   : Boolean := False;
      Writable   : Boolean := False;
   end record;

   type Watch_Array is array (Natural range <>) of Watch_Access;
   type Watch_Array_Access is access Watch_Array;
   type Watch_Table is record
      Slots : Watch_Array_Access;
   end record;
   type Watch_Table_Access is access Watch_Table;

   function Table_To_Address is new Ada.Unchecked_Conversion (Watch_Table_Access, System.Address);
   function Address_To_Table is new Ada.Unchecked_Conversion (System.Address, Watch_Table_Access);
   procedure Free_Watch is new Ada.Unchecked_Deallocation (Watch_Record, Watch_Access);
   procedure Free_Watch_Array is new Ada.Unchecked_Deallocation (Watch_Array, Watch_Array_Access);
   procedure Free_Watch_Table is new Ada.Unchecked_Deallocation (Watch_Table, Watch_Table_Access);

   function Epoll_Create1 (Flags : C.int) return C.int;
   pragma Import (C, Epoll_Create1, "epoll_create1");

   function Epoll_Ctl (Epoll_FD : C.int; Operation : C.int; FD : C.int; Events : C.unsigned) return C.int;
   pragma Import (C, Epoll_Ctl, "flyology_linux_epoll_ctl");

   function Epoll_Wait
     (Epoll_FD : C.int; Events : System.Address; Max_Events : C.int; Timeout_MS : C.int) return C.int;
   pragma Import (C, Epoll_Wait, "flyology_linux_epoll_wait");

   function Eventfd (Initial_Value : C.unsigned; Flags : C.int) return C.int;
   pragma Import (C, Eventfd, "eventfd");

   function Read (FD : C.int; Buffer : System.Address; Count : C.size_t) return C.long;
   pragma Import (C, Read, "read");

   function Write (FD : C.int; Buffer : System.Address; Count : C.size_t) return C.long;
   pragma Import (C, Write, "write");

   function Close (Descriptor : C.int) return C.int;
   pragma Import (C, Close, "close");

   procedure Set_Table (Item : in out Poller; Value : Watch_Table_Access);

   function Ensure_Slot (Item : in out Poller; Descriptor : C.int) return Boolean;

   function Find (Item : Poller; Descriptor : C.int) return Watch_Access;

   function Mask_For (Watch_Item : Watch_Access) return C.unsigned;

   procedure Remove (Item : in out Poller; Watch_Item : not null Watch_Access);

   function Control (Item : Poller; Operation : C.int; Descriptor : C.int; Events : C.unsigned) return C.int;

   function Timeout_Milliseconds (Timeout : Duration) return C.int;

   function Drain_File_Events
     (Item       : in out Poller;
      Events     : in out Poll_Event_Array;
      Count      : in out Natural;
      Limit      : Natural;
      May_Remain : out Boolean) return Boolean;

   function Table (Item : Poller) return Watch_Table_Access
   is (Address_To_Table (Item.State));

   procedure Set_Table (Item : in out Poller; Value : Watch_Table_Access) is
   begin
      Item.State := Table_To_Address (Value);
   end Set_Table;

   function Ensure_Slot (Item : in out Poller; Descriptor : C.int) return Boolean is
      Descriptor_Index : Natural;
      New_Last         : Natural := 0;
      New_Slots        : Watch_Array_Access;
      Old_Slots        : Watch_Array_Access;
      Table_Item       : Watch_Table_Access := Table (Item);
   begin
      if Descriptor < 0 then
         return False;
      end if;
      Descriptor_Index := Natural (Descriptor);

      if Table_Item = null then
         Table_Item := new Watch_Table'(Slots => null);
         Set_Table (Item, Table_Item);
      end if;
      if Table_Item.Slots /= null and then Descriptor_Index <= Table_Item.Slots'Last then
         return True;
      end if;

      --  The descriptor is the index. Grow to the smallest 2**k - 1 upper
      --  bound that covers it, without imposing a separate capacity policy.
      if Table_Item.Slots /= null then
         New_Last := Table_Item.Slots'Last;
      end if;
      while New_Last < Descriptor_Index loop
         if New_Last > (Natural'Last - 1) / 2 then
            New_Last := Descriptor_Index;
         else
            New_Last := 2 * New_Last + 1;
         end if;
      end loop;

      New_Slots := new Watch_Array (0 .. New_Last);
      if Table_Item.Slots /= null then
         New_Slots (Table_Item.Slots'Range) := Table_Item.Slots.all;
      end if;
      Old_Slots := Table_Item.Slots;
      Table_Item.Slots := New_Slots;
      Free_Watch_Array (Old_Slots);
      return True;
   exception
      when Storage_Error =>
         return False;
   end Ensure_Slot;

   function Find (Item : Poller; Descriptor : C.int) return Watch_Access is
      Table_Item : constant Watch_Table_Access := Table (Item);
   begin
      if Faults.Enabled then
         Faults.Note (Faults.Poller_Lookup);
      end if;
      if Descriptor < 0
        or else Table_Item = null
        or else Table_Item.Slots = null
        or else Natural (Descriptor) > Table_Item.Slots'Last
      then
         return null;
      end if;
      return Table_Item.Slots (Natural (Descriptor));
   end Find;

   function Mask_For (Watch_Item : Watch_Access) return C.unsigned is
      Result : C.unsigned := EPOLLONESHOT;
   begin
      if Watch_Item.Readable then
         Result := Result or EPOLLIN;
      end if;
      if Watch_Item.Writable then
         Result := Result or EPOLLOUT;
      end if;
      return Result;
   end Mask_For;

   function Has (Mask, Flag : C.unsigned) return Boolean
   is ((Mask and Flag) /= 0);

   procedure Remove (Item : in out Poller; Watch_Item : not null Watch_Access) is
      Table_Item : constant Watch_Table_Access := Table (Item);
      Victim     : Watch_Access := Watch_Item;
      Index      : Natural;
   begin
      if Watch_Item.Descriptor < 0 or else Table_Item = null or else Table_Item.Slots = null then
         return;
      end if;
      Index := Natural (Watch_Item.Descriptor);
      if Index > Table_Item.Slots'Last or else Table_Item.Slots (Index) /= Watch_Item then
         return;
      end if;
      Table_Item.Slots (Index) := null;
      if Faults.Enabled then
         Faults.Note (Faults.Poller_Record_Release);
      end if;
      Free_Watch (Victim);
   end Remove;

   function Control (Item : Poller; Operation : C.int; Descriptor : C.int; Events : C.unsigned) return C.int
   is
   begin
      if Faults.Enabled then
         case Operation is
            when EPOLL_CTL_ADD =>
               Faults.Note (Faults.Poller_Control_Add);

            when EPOLL_CTL_MOD =>
               Faults.Note (Faults.Poller_Control_Modify);

            when EPOLL_CTL_DEL =>
               Faults.Note (Faults.Poller_Control_Delete);

            when others        =>
               null;
         end case;
      end if;
      return Epoll_Ctl (Item.Descriptor, Operation, Descriptor, Events);
   end Control;

   function Timeout_Milliseconds (Timeout : Duration) return C.int is
      Limit : Time_ABI.Timespec;
      Value : C.long_long;
   begin
      if Timeout < 0.0 then
         return -1;
      elsif Timeout <= 0.0 then
         return 0;
      elsif Timeout >= Duration (C.int'Last) / 1_000.0 then
         return C.int'Last;
      end if;

      Limit := Time_ABI.To_Timespec (Timeout);
      Value := C.long_long (Limit.tv_sec) * 1_000 + (C.long_long (Limit.tv_nsec) + 999_999) / 1_000_000;
      return C.int (Value);
   end Timeout_Milliseconds;

   function Drain_File_Events
     (Item       : in out Poller;
      Events     : in out Poll_Event_Array;
      Count      : in out Natural;
      Limit      : Natural;
      May_Remain : out Boolean) return Boolean
   is
      Available   : constant Natural := Natural'Min (Events'Length - Count, Limit);
      Completions : File_Engines.Completion_Array (1 .. Natural'Max (1, Available));
      Drained     : Natural := 0;
   begin
      if Available = 0 then
         May_Remain := True;
         return True;
      end if;
      if Faults.Enabled and then Faults.Fail (Faults.Poller_File_Drain_Pause) then
         May_Remain := True;
         return True;
      end if;
      if not File_Engines.Drain (Item.File_State, Completions, Drained) or else Drained > Available then
         May_Remain := True;
         return False;
      end if;
      for Index in 1 .. Drained loop
         Count := Count + 1;
         Events (Events'First + Count - 1) :=
           (Kind       => File_Event,
            Descriptor => -1,
            Token      => Completions (Index).Token,
            Result     => Completions (Index).Result,
            Error_Code => Completions (Index).Error_Code);
      end loop;
      --  A full drain may have stopped at the caller's output budget. Keep a
      --  conservative obligation until a later drain observes spare room.
      May_Remain := Drained = Available;
      return True;
   end Drain_File_Events;

   function Initialize (Item : in out Poller) return Boolean is
      Result : C.int;
   begin
      Item.Descriptor := Epoll_Create1 (EPOLL_CLOEXEC);
      if Item.Descriptor < 0 then
         return False;
      end if;

      Item.Wake_Descriptor := Eventfd (0, EFD_NONBLOCK + EFD_CLOEXEC);
      if Item.Wake_Descriptor < 0 then
         Result := Close (Item.Descriptor);
         Item.Descriptor := -1;
         if Result /= 0 then
            raise Program_Error with "Flyology epoll cleanup failed";
         end if;
         return False;
      end if;

      Result := Epoll_Ctl (Item.Descriptor, EPOLL_CTL_ADD, Item.Wake_Descriptor, EPOLLIN);
      if Result /= 0 then
         Result := Close (Item.Wake_Descriptor);
         Result := Close (Item.Descriptor);
         Item.Wake_Descriptor := -1;
         Item.Descriptor := -1;
         return False;
      end if;
      if not File_Engines.Initialize (Item.File_State, Item.Descriptor, Item.Wake_Descriptor) then
         Result := Close (Item.Wake_Descriptor);
         Result := Close (Item.Descriptor);
         Item.Wake_Descriptor := -1;
         Item.Descriptor := -1;
         return False;
      end if;
      Item.File_Drain_State := (Pending => False, File_Only_Last_Batch => False);
      return True;
   end Initialize;

   procedure Finalize (Item : in out Poller) is
      Table_Item : Watch_Table_Access := Table (Item);
      Victim     : Watch_Access;
      Result     : C.int;
   begin
      if Table_Item /= null and then Table_Item.Slots /= null then
         for Index in Table_Item.Slots'Range loop
            if Table_Item.Slots (Index) /= null then
               Victim := Table_Item.Slots (Index);
               if Faults.Enabled then
                  Faults.Note (Faults.Poller_Record_Release);
               end if;
               Free_Watch (Victim);
            end if;
         end loop;
         Free_Watch_Array (Table_Item.Slots);
      end if;
      Free_Watch_Table (Table_Item);
      Item.State := System.Null_Address;

      File_Engines.Finalize (Item.File_State);
      Item.File_Drain_State := (Pending => False, File_Only_Last_Batch => False);

      if Item.Wake_Descriptor >= 0 then
         Result := Close (Item.Wake_Descriptor);
         Item.Wake_Descriptor := -1;
         if Result /= 0 then
            raise Program_Error with "Flyology eventfd close failed";
         end if;
      end if;
      if Item.Descriptor >= 0 then
         Result := Close (Item.Descriptor);
         Item.Descriptor := -1;
         if Result /= 0 then
            raise Program_Error with "Flyology epoll close failed";
         end if;
      end if;
   end Finalize;

   function Watch (Item : in out Poller; Descriptor : C.int; Condition : Interest) return Boolean is
      Watch_Item   : Watch_Access := Find (Item, Descriptor);
      Created      : Boolean := False;
      Was_Readable : Boolean;
      Was_Writable : Boolean;
      Result       : C.int;
   begin
      if Faults.Enabled and then Faults.Fail (Faults.Poller_Watch) then
         return False;
      end if;
      if Watch_Item = null then
         if not Ensure_Slot (Item, Descriptor) then
            return False;
         end if;
         Watch_Item := new Watch_Record'(Descriptor => Descriptor, others => <>);
         Table (Item).Slots (Natural (Descriptor)) := Watch_Item;
         if Faults.Enabled then
            Faults.Note (Faults.Poller_Record_Allocation);
         end if;
         Created := True;
      end if;

      Was_Readable := Watch_Item.Readable;
      Was_Writable := Watch_Item.Writable;
      if Condition = Readable then
         Watch_Item.Readable := True;
      else
         Watch_Item.Writable := True;
      end if;

      Result :=
        Control (Item, (if Created then EPOLL_CTL_ADD else EPOLL_CTL_MOD), Descriptor, Mask_For (Watch_Item));
      if Result /= 0 and then not Created and then Integer (OSI.errno) = Poller_Policy.Interest_Absent_Error
      then
         --  Closing a watched descriptor removes its epoll registration but
         --  leaves this process-side record until the old waiter departs. A
         --  reused descriptor therefore needs ADD after MOD reports ENOENT.
         Result := Control (Item, EPOLL_CTL_ADD, Descriptor, Mask_For (Watch_Item));
      end if;
      if Result /= 0 then
         Watch_Item.Readable := Was_Readable;
         Watch_Item.Writable := Was_Writable;
         if Created then
            Remove (Item, Watch_Item);
         end if;
         return False;
      end if;
      return True;
   exception
      when Storage_Error =>
         return False;
   end Watch;

   function Watch_Many (Item : in out Poller; Requests : Interest_Request_Array) return Boolean is
   begin
      for Index in Requests'Range loop
         if not Watch (Item, Requests (Index).Descriptor, Requests (Index).Condition) then
            return False;
         end if;
      end loop;
      return True;
   end Watch_Many;

   function Cancel (Item : in out Poller; Descriptor : C.int; Condition : Interest) return Boolean is
      Watch_Item : Watch_Access;
      Retained   : Boolean;
      Result     : C.int;
   begin
      if Faults.Enabled then
         Faults.Note_Poller_Cancel;
      end if;
      Watch_Item := Find (Item, Descriptor);
      if Watch_Item = null then
         return True;
      elsif Condition = Readable then
         Watch_Item.Readable := False;
      else
         Watch_Item.Writable := False;
      end if;

      Retained := Watch_Item.Readable or else Watch_Item.Writable;
      if Retained then
         Result := Control (Item, EPOLL_CTL_MOD, Descriptor, Mask_For (Watch_Item));
      else
         Result := Control (Item, EPOLL_CTL_DEL, Descriptor, 0);
      end if;

      --  EPOLL_CTL_MOD and EPOLL_CTL_DEL both answer EBADF once the owner has
      --  closed the descriptor, because the kernel drops the registration with
      --  it. That leaves no interest of either direction, so the whole
      --  bookkeeping record goes even when this call retained one.
      case Poller_Policy.Classify_Cancel (Result = 0, Integer (OSI.errno)) is
         when Poller_Policy.Interest_Cleared  =>
            if not Retained then
               Remove (Item, Watch_Item);
            end if;
            return True;

         when Poller_Policy.Registration_Gone =>
            Remove (Item, Watch_Item);
            return True;

         when Poller_Policy.Cancel_Failed     =>
            return False;
      end case;
   end Cancel;

   function Cancel_Many (Item : in out Poller; Requests : Interest_Request_Array) return Boolean is
      Succeeded : Boolean := True;
   begin
      for Request of Requests loop
         if not Cancel (Item, Request.Descriptor, Request.Condition) then
            Succeeded := False;
         end if;
      end loop;
      return Succeeded;
   end Cancel_Many;

   function Retains_Orphaned_One_Shots return Boolean
   is (False);

   function Submit_File
     (Item       : in out Poller;
      Descriptor : C.int;
      Buffer     : System.Address;
      Length     : C.size_t;
      Offset     : C.long_long;
      For_Write  : Boolean;
      Token      : System.Address;
      Error_Code : out C.int) return Boolean is
   begin
      if Faults.Enabled and then Faults.Fail (Faults.File_Submission_Full) then
         Error_Code := EAGAIN;
         return False;
      end if;
      return
        File_Engines.Submit
          (Item.File_State, Descriptor, Buffer, Length, Offset, For_Write, Token, Error_Code);
   end Submit_File;

   function Supports_Send_ZC (Item : Poller) return Boolean
   is (File_Engines.Supports_Send_ZC (Item.File_State));

   function Submit_Send_ZC
     (Item       : in out Poller;
      Descriptor : C.int;
      Buffer     : System.Address;
      Length     : C.size_t;
      Token      : System.Address;
      Error_Code : out C.int) return Boolean is
   begin
      if Faults.Enabled and then Faults.Fail (Faults.File_Submission_Full) then
         Error_Code := EAGAIN;
         return False;
      end if;
      return File_Engines.Submit_Send_ZC (Item.File_State, Descriptor, Buffer, Length, Token, Error_Code);
   end Submit_Send_ZC;

   function Cancel_File
     (Item           : in out Poller;
      Descriptor     : C.int;
      Token          : System.Address;
      Value          : out File_Engines.Completion;
      Has_Completion : out Boolean;
      Error_Code     : out C.int) return File_Engines.Cancellation_Disposition is
   begin
      if Faults.Enabled and then Faults.Fail (Faults.File_Cancel_Not_Cancelable) then
         Value := (others => <>);
         Has_Completion := False;
         Error_Code := 0;
         return File_Engines.Not_Cancelable;
      elsif Faults.Enabled and then Faults.Fail (Faults.File_Cancel_Already_Completing) then
         Value := (others => <>);
         Has_Completion := False;
         Error_Code := 0;
         return File_Engines.Already_Completing;
      end if;
      return File_Engines.Cancel (Item.File_State, Descriptor, Token, Value, Has_Completion, Error_Code);
   end Cancel_File;

   function File_Quiescent (Item : Poller) return Boolean
   is (File_Engines.Is_Quiescent (Item.File_State));

   function Wait (Item : in out Poller; Timeout : Duration; Event : out Poll_Event) return Boolean is
      Events : Poll_Event_Array (1 .. 1);
      Count  : Natural;
   begin
      if not Wait_Batch (Item, Timeout, Events, Count) then
         Event := (Kind => Timeout_Event, Descriptor => -1, others => <>);
         return False;
      end if;
      Event := (if Count = 0 then (Kind => Timeout_Event, Descriptor => -1, others => <>) else Events (1));
      return True;
   end Wait;

   function Wait_Batch
     (Item : in out Poller; Timeout : Duration; Events : out Poll_Event_Array; Count : out Natural)
      return Boolean
   is
      Kernel_Events  : aliased Epoll_Event_Array (Events'Range);
      Kernel_Count   : C.int;
      Descriptor     : C.int;
      Watch_Item     : Watch_Access;
      Mask           : C.unsigned;
      Error_Event    : Boolean;
      Read_Ready     : Boolean;
      Write_Ready    : Boolean;
      Result         : C.int;
      Read_Result    : C.long;
      Wake_Value     : aliased C.unsigned_long_long;
      May_Remain     : Boolean := False;
      Epoll_Capacity : Natural;
      Drain_Budget   : Poller_Policy.Drain_Budget;
      Plan           : Poller_Policy.Batch_Plan;
      Capacity       : constant Poller_Policy.Batch_Capacity := Poller_Policy.Batch_Capacity (Events'Length);
   begin
      Events := (others => (Kind => Timeout_Event, Descriptor => -1, others => <>));
      Count := 0;
      if Faults.Enabled and then Faults.Fail (Faults.Poller_Wait) then
         return False;
      elsif Faults.Enabled and then Faults.Fail (Faults.Poller_EINTR) then
         return True;
      end if;

      --  Consuming the shared eventfd creates a persistent file-drain
      --  obligation. Under a saturated epoll ready list, reserve one result
      --  slot for that obligation so a CQE cannot lose its only wake edge.
      --  A one-element caller alternates file and epoll turns; larger batches
      --  still leave all but one slot available to descriptors.
      Plan := Poller_Policy.Plan_Batch (Item.File_Drain_State, Capacity);
      Item.File_Drain_State := Plan.State;
      if Plan.Initial_Drain_Budget > 0 then
         if not Drain_File_Events (Item, Events, Count, Plan.Initial_Drain_Budget, May_Remain) then
            return False;
         end if;
         Item.File_Drain_State := Poller_Policy.After_Drain (Item.File_Drain_State, May_Remain);
         if Count = Events'Length then
            Item.File_Drain_State :=
              Poller_Policy.After_Batch
                (Item.File_Drain_State,
                 Capacity,
                 Poller_Policy.Batch_Count (Count),
                 Only_File_Events => True);
            return True;
         end if;
      end if;

      Drain_Budget := Poller_Policy.Remaining_Budget (Capacity, Poller_Policy.Batch_Count (Count));
      Epoll_Capacity := Natural (Drain_Budget);
      Kernel_Count := Epoll_Wait (Item.Descriptor, Kernel_Events'Address, C.int (Epoll_Capacity), 0);
      if Kernel_Count < 0 then
         return OSI.errno = OSI.EINTR;
      elsif Kernel_Count = 0 and then Count = 0 then
         if not Drain_File_Events (Item, Events, Count, Drain_Budget, May_Remain) then
            return False;
         end if;
         Item.File_Drain_State := Poller_Policy.After_Drain (Item.File_Drain_State, May_Remain);
         if Count > 0 then
            Item.File_Drain_State :=
              Poller_Policy.After_Batch
                (Item.File_Drain_State,
                 Capacity,
                 Poller_Policy.Batch_Count (Count),
                 Only_File_Events => True);
            return True;
         elsif Item.File_Drain_State.Pending then
            --  The test-only held-drain seam, or another conservative full
            --  drain, must be retried without sleeping on an edge already
            --  consumed from eventfd.
            return True;
         end if;
         Kernel_Count :=
           Epoll_Wait
             (Item.Descriptor, Kernel_Events'Address, C.int (Epoll_Capacity), Timeout_Milliseconds (Timeout));
         if Kernel_Count < 0 then
            return OSI.errno = OSI.EINTR;
         end if;
      end if;

      for Index in 1 .. Natural (Kernel_Count) loop
         Descriptor := Kernel_Events (Kernel_Events'First + Index - 1).Descriptor;
         Mask := Kernel_Events (Kernel_Events'First + Index - 1).Events;

         if Descriptor = Item.Wake_Descriptor then
            Read_Result :=
              Read (Item.Wake_Descriptor, Wake_Value'Address, C.size_t (C.unsigned_long_long'Size / 8));
            if Read_Result < 0 and then OSI.errno /= EAGAIN then
               return False;
            end if;
            Item.File_Drain_State := Poller_Policy.After_Wake (Item.File_Drain_State);
            Count := Count + 1;
            Events (Events'First + Count - 1) := (Kind => Wake_Event, Descriptor => Descriptor, others => <>);
         else
            if Faults.Enabled and then Faults.Fail (Faults.Poller_Translation_Pause) then
               Faults.Pause_Poller_Translation;
            end if;
            Watch_Item := Find (Item, Descriptor);
            if Watch_Item /= null then
               Error_Event :=
                 Has (Mask, EPOLLERR) or else Has (Mask, EPOLLHUP) or else Has (Mask, EPOLLRDHUP);
               Read_Ready := Watch_Item.Readable and then (Has (Mask, EPOLLIN) or Error_Event);
               Write_Ready := Watch_Item.Writable and then (Has (Mask, EPOLLOUT) or Error_Event);

               if Read_Ready then
                  Watch_Item.Readable := False;
               end if;
               if Write_Ready then
                  Watch_Item.Writable := False;
               end if;

               if Watch_Item.Readable or else Watch_Item.Writable then
                  Result := Control (Item, EPOLL_CTL_MOD, Descriptor, Mask_For (Watch_Item));
               else
                  --  EPOLLONESHOT has already disabled the kernel interest.
                  --  Retain the indexed record so a later wait rearms it with
                  --  MOD without allocator or kernel delete/add churn.
                  Result := 0;
               end if;
               if Result /= 0 then
                  return False;
               end if;

               if Read_Ready or else Write_Ready then
                  Count := Count + 1;
                  Events (Events'First + Count - 1) :=
                    (Kind       =>
                       (if Read_Ready and Write_Ready
                        then Read_Write_Event
                        elsif Read_Ready
                        then Readable_Event
                        else Writable_Event),
                     Descriptor => Descriptor,
                     others     => <>);
               end if;
            end if;
         end if;
      end loop;
      Drain_Budget := Poller_Policy.Remaining_Budget (Capacity, Poller_Policy.Batch_Count (Count));
      if Drain_Budget > 0 then
         if not Drain_File_Events (Item, Events, Count, Drain_Budget, May_Remain) then
            return False;
         end if;
         Item.File_Drain_State := Poller_Policy.After_Drain (Item.File_Drain_State, May_Remain);
      end if;
      Item.File_Drain_State :=
        Poller_Policy.After_Batch
          (Item.File_Drain_State,
           Capacity,
           Poller_Policy.Batch_Count (Count),
           Only_File_Events => Count = 1 and then Events (Events'First).Kind = File_Event);
      return True;
   end Wait_Batch;

   function Wake (Item : Poller) return Boolean is
      Value  : aliased C.unsigned_long_long := 1;
      Result : C.long;
   begin
      if Faults.Enabled and then Faults.Fail (Faults.Poller_Wake) then
         return False;
      end if;
      loop
         Result := Write (Item.Wake_Descriptor, Value'Address, C.size_t (C.unsigned_long_long'Size / 8));
         if Result >= 0 or else OSI.errno = EAGAIN then
            return True;
         elsif OSI.errno /= OSI.EINTR then
            return False;
         end if;
      end loop;
   end Wake;

end System.Flyology.Poller;
