with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with System.Gnatevl.Faults;
with System.Gnatevl.Time_ABI;
with System.OS_Interface;

package body System.Gnatevl.Poller is
   package C renames Interfaces.C;
   package Faults renames System.Gnatevl.Faults;
   package Time_ABI renames System.Gnatevl.Time_ABI;
   package File_Engines renames System.Gnatevl.File_Engine;
   package OSI renames System.OS_Interface;

   use type C.int;
   use type C.long;
   use type C.long_long;
   use type C.unsigned;

   EPOLL_CTL_ADD : constant C.int := 1;
   EPOLL_CTL_DEL : constant C.int := 2;
   EPOLL_CTL_MOD : constant C.int := 3;

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
      Events : C.unsigned;
      Data   : C.unsigned_long_long;
   end record
     with Convention => C, Size => 96, Alignment => 1;
   for Epoll_Event use record
      Events at 0 range 0 .. 31;
      Data   at 4 range 0 .. 63;
   end record;

   type Epoll_Event_Array is array (Positive range <>) of Epoll_Event
     with Convention => C;

   type Watch_Record;
   type Watch_Access is access all Watch_Record;
   type Watch_Record is record
      Descriptor : C.int := -1;
      Readable   : Boolean := False;
      Writable   : Boolean := False;
      Next       : Watch_Access;
   end record;

   function Watch_To_Address is new Ada.Unchecked_Conversion
     (Watch_Access, System.Address);
   function Address_To_Watch is new Ada.Unchecked_Conversion
     (System.Address, Watch_Access);
   procedure Free_Watch is new Ada.Unchecked_Deallocation
     (Watch_Record, Watch_Access);

   function Epoll_Create1 (Flags : C.int) return C.int;
   pragma Import (C, Epoll_Create1, "epoll_create1");

   function Epoll_Ctl
     (Epoll_FD : C.int;
      Operation : C.int;
      FD         : C.int;
      Event      : System.Address) return C.int;
   pragma Import (C, Epoll_Ctl, "epoll_ctl");

   function Epoll_Wait
     (Epoll_FD  : C.int;
      Events    : System.Address;
      Max_Events : C.int;
      Timeout_MS : C.int) return C.int;
   pragma Import (C, Epoll_Wait, "epoll_wait");

   function Eventfd (Initial_Value : C.unsigned; Flags : C.int) return C.int;
   pragma Import (C, Eventfd, "eventfd");

   function Read
     (FD : C.int; Buffer : System.Address; Count : C.size_t) return C.long;
   pragma Import (C, Read, "read");

   function Write
     (FD : C.int; Buffer : System.Address; Count : C.size_t) return C.long;
   pragma Import (C, Write, "write");

   function Close (Descriptor : C.int) return C.int;
   pragma Import (C, Close, "close");

   procedure Set_Head (Item : in out Poller; Value : Watch_Access);

   function Find
     (Item : Poller; Descriptor : C.int) return Watch_Access;

   function Mask_For (Watch_Item : Watch_Access) return C.unsigned;

   procedure Remove
     (Item : in out Poller; Watch_Item : not null Watch_Access);

   function Timeout_Milliseconds (Timeout : Duration) return C.int;

   function Drain_File_Events
     (Item   : in out Poller;
      Events : in out Poll_Event_Array;
      Count  : in out Natural) return Boolean;

   function Head (Item : Poller) return Watch_Access is
     (Address_To_Watch (Item.State));

   procedure Set_Head (Item : in out Poller; Value : Watch_Access) is
   begin
      Item.State := Watch_To_Address (Value);
   end Set_Head;

   function Find
     (Item : Poller; Descriptor : C.int) return Watch_Access
   is
      Position : Watch_Access := Head (Item);
   begin
      while Position /= null and then Position.Descriptor /= Descriptor loop
         Position := Position.Next;
      end loop;
      return Position;
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

   function Has (Mask, Flag : C.unsigned) return Boolean is
     ((Mask and Flag) /= 0);

   function Descriptor_Event
     (Watch_Item : Watch_Access) return Epoll_Event
   is
     ((Events => Mask_For (Watch_Item),
       Data   => C.unsigned_long_long (Watch_Item.Descriptor)));

   procedure Remove
     (Item : in out Poller; Watch_Item : not null Watch_Access)
   is
      Position : Watch_Access := Head (Item);
      Previous : Watch_Access;
      Victim   : Watch_Access := Watch_Item;
   begin
      while Position /= null and then Position /= Watch_Item loop
         Previous := Position;
         Position := Position.Next;
      end loop;
      if Position = null then
         return;
      elsif Previous = null then
         Set_Head (Item, Position.Next);
      else
         Previous.Next := Position.Next;
      end if;
      Free_Watch (Victim);
   end Remove;

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
      Value :=
        C.long_long (Limit.tv_sec) * 1_000
        + (C.long_long (Limit.tv_nsec) + 999_999) / 1_000_000;
      return C.int (Value);
   end Timeout_Milliseconds;

   function Drain_File_Events
     (Item   : in out Poller;
      Events : in out Poll_Event_Array;
      Count  : in out Natural) return Boolean
   is
      Available   : constant Natural := Events'Length - Count;
      Completions : File_Engines.Completion_Array
        (1 .. Natural'Max (1, Available));
      Drained     : Natural;
   begin
      if Available = 0 then
         return True;
      end if;
      if not File_Engines.Drain
        (Item.File_State, Completions, Drained)
        or else Drained > Available
      then
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
      return True;
   end Drain_File_Events;

   function Initialize (Item : in out Poller) return Boolean is
      Event  : aliased Epoll_Event;
      Result : C.int;
   begin
      Item.Descriptor := Epoll_Create1 (0);
      if Item.Descriptor < 0 then
         return False;
      end if;

      Item.Wake_Descriptor := Eventfd (0, EFD_NONBLOCK + EFD_CLOEXEC);
      if Item.Wake_Descriptor < 0 then
         Result := Close (Item.Descriptor);
         Item.Descriptor := -1;
         if Result /= 0 then
            raise Program_Error with "GNATEVL epoll cleanup failed";
         end if;
         return False;
      end if;

      Event :=
        (Events => EPOLLIN,
         Data   => C.unsigned_long_long (Item.Wake_Descriptor));
      Result :=
        Epoll_Ctl
          (Item.Descriptor,
           EPOLL_CTL_ADD,
           Item.Wake_Descriptor,
           Event'Address);
      if Result /= 0 then
         Result := Close (Item.Wake_Descriptor);
         Result := Close (Item.Descriptor);
         Item.Wake_Descriptor := -1;
         Item.Descriptor := -1;
         return False;
      end if;
      if not File_Engines.Initialize
        (Item.File_State, Item.Descriptor, Item.Wake_Descriptor)
      then
         Result := Close (Item.Wake_Descriptor);
         Result := Close (Item.Descriptor);
         Item.Wake_Descriptor := -1;
         Item.Descriptor := -1;
         return False;
      end if;
      return True;
   end Initialize;

   procedure Finalize (Item : in out Poller) is
      Position : Watch_Access := Head (Item);
      Victim   : Watch_Access;
      Result   : C.int;
   begin
      while Position /= null loop
         Victim := Position;
         Position := Position.Next;
         Free_Watch (Victim);
      end loop;
      Item.State := System.Null_Address;

      File_Engines.Finalize (Item.File_State);

      if Item.Wake_Descriptor >= 0 then
         Result := Close (Item.Wake_Descriptor);
         Item.Wake_Descriptor := -1;
         if Result /= 0 then
            raise Program_Error with "GNATEVL eventfd close failed";
         end if;
      end if;
      if Item.Descriptor >= 0 then
         Result := Close (Item.Descriptor);
         Item.Descriptor := -1;
         if Result /= 0 then
            raise Program_Error with "GNATEVL epoll close failed";
         end if;
      end if;
   end Finalize;

   function Watch
     (Item       : in out Poller;
      Descriptor : C.int;
      Condition  : Interest) return Boolean
   is
      Watch_Item   : Watch_Access := Find (Item, Descriptor);
      Created      : Boolean := False;
      Was_Readable : Boolean;
      Was_Writable : Boolean;
      Event        : aliased Epoll_Event;
      Result       : C.int;
   begin
      if Faults.Fail (Faults.Poller_Watch) then
         return False;
      end if;
      if Watch_Item = null then
         Watch_Item :=
           new Watch_Record'(Descriptor => Descriptor, others => <>);
         Watch_Item.Next := Head (Item);
         Set_Head (Item, Watch_Item);
         Created := True;
      end if;

      Was_Readable := Watch_Item.Readable;
      Was_Writable := Watch_Item.Writable;
      if Condition = Readable then
         Watch_Item.Readable := True;
      else
         Watch_Item.Writable := True;
      end if;

      Event := Descriptor_Event (Watch_Item);
      Result :=
        Epoll_Ctl
          (Item.Descriptor,
           (if Created then EPOLL_CTL_ADD else EPOLL_CTL_MOD),
           Descriptor,
           Event'Address);
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
      if Faults.Fail (Faults.File_Submission_Full) then
         Error_Code := EAGAIN;
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
      Event :=
        (if Count = 0
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
      Kernel_Events : aliased Epoll_Event_Array (Events'Range);
      Kernel_Count  : C.int;
      Descriptor    : C.int;
      Watch_Item    : Watch_Access;
      Mask          : C.unsigned;
      Error_Event   : Boolean;
      Read_Ready    : Boolean;
      Write_Ready   : Boolean;
      Control_Event : aliased Epoll_Event;
      Result        : C.int;
      Read_Result   : C.long;
      Wake_Value    : aliased C.unsigned_long_long;
   begin
      Events :=
        (others => (Kind => Timeout_Event, Descriptor => -1, others => <>));
      Count := 0;
      if Faults.Fail (Faults.Poller_Wait) then
         return False;
      elsif Faults.Fail (Faults.Poller_EINTR) then
         return True;
      end if;
      if not Drain_File_Events (Item, Events, Count) then
         return False;
      elsif Count > 0 then
         return True;
      end if;
      Kernel_Count :=
        Epoll_Wait
          (Item.Descriptor,
           Kernel_Events'Address,
           C.int (Events'Length),
           Timeout_Milliseconds (Timeout));
      if Kernel_Count < 0 then
         return OSI.errno = OSI.EINTR;
      end if;

      for Index in 1 .. Natural (Kernel_Count) loop
         Descriptor :=
           C.int (Kernel_Events (Kernel_Events'First + Index - 1).Data);
         Mask := Kernel_Events (Kernel_Events'First + Index - 1).Events;

         if Descriptor = Item.Wake_Descriptor then
            Read_Result :=
              Read
                (Item.Wake_Descriptor,
                 Wake_Value'Address,
                 C.size_t (C.unsigned_long_long'Size / 8));
            if Read_Result < 0 and then OSI.errno /= EAGAIN then
               return False;
            end if;
            Count := Count + 1;
            Events (Events'First + Count - 1) :=
              (Kind => Wake_Event, Descriptor => Descriptor, others => <>);
         else
            Watch_Item := Find (Item, Descriptor);
            if Watch_Item /= null then
               Error_Event :=
                 Has (Mask, EPOLLERR)
                 or else Has (Mask, EPOLLHUP)
                 or else Has (Mask, EPOLLRDHUP);
               Read_Ready :=
                 Watch_Item.Readable
                   and then (Has (Mask, EPOLLIN) or Error_Event);
               Write_Ready :=
                 Watch_Item.Writable and then
                   (Has (Mask, EPOLLOUT) or Error_Event);

               if Read_Ready then
                  Watch_Item.Readable := False;
               end if;
               if Write_Ready then
                  Watch_Item.Writable := False;
               end if;

               if Watch_Item.Readable or else Watch_Item.Writable then
                  Control_Event := Descriptor_Event (Watch_Item);
                  Result :=
                    Epoll_Ctl
                      (Item.Descriptor,
                       EPOLL_CTL_MOD,
                       Descriptor,
                       Control_Event'Address);
               else
                  Result :=
                    Epoll_Ctl
                      (Item.Descriptor,
                       EPOLL_CTL_DEL,
                       Descriptor,
                       System.Null_Address);
                  Remove (Item, Watch_Item);
               end if;
               if Result /= 0 then
                  return False;
               end if;

               if Read_Ready or else Write_Ready then
                  Count := Count + 1;
                  Events (Events'First + Count - 1) :=
                     (Kind =>
                       (if Read_Ready and Write_Ready then Read_Write_Event
                        elsif Read_Ready then Readable_Event
                        else Writable_Event),
                     Descriptor => Descriptor,
                     others => <>);
               end if;
            end if;
         end if;
      end loop;
      return Drain_File_Events (Item, Events, Count);
   end Wait_Batch;

   function Wake (Item : Poller) return Boolean is
      Value  : aliased C.unsigned_long_long := 1;
      Result : C.long;
   begin
      if Faults.Fail (Faults.Poller_Wake) then
         return False;
      end if;
      loop
         Result :=
           Write
             (Item.Wake_Descriptor,
              Value'Address,
              C.size_t (C.unsigned_long_long'Size / 8));
         if Result >= 0 or else OSI.errno = EAGAIN then
            return True;
         elsif OSI.errno /= OSI.EINTR then
            return False;
         end if;
      end loop;
   end Wake;

end System.Gnatevl.Poller;
