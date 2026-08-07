with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with System.Flyology.Faults;
with System.OS_Interface;
with System.Storage_Elements;

package body System.Flyology.File_Engine is
   package C renames Interfaces.C;
   package Faults renames System.Flyology.Faults;
   package OSI renames System.OS_Interface;
   package SSE renames System.Storage_Elements;

   use type C.int;
   use type C.long;
   use type C.long_long;
   use type C.unsigned_short;

   SIGEV_KEVENT : constant C.int := 4;
   EVFILT_USER  : constant C.short := C.short (-10);
   EVFILT_AIO   : constant C.short := C.short (-3);
   EV_ADD       : constant C.unsigned_short := 16#0001#;
   EV_DELETE    : constant C.unsigned_short := 16#0002#;
   EV_ONESHOT   : constant C.unsigned_short := 16#0010#;
   NOTE_TRIGGER : constant C.unsigned := 16#0100_0000#;
   ENOENT       : constant C.int := 2;
   EIO          : constant C.int := 5;

   function Send_ZC_Copy_Fallback return C.int is (0);
   pragma Export
     (C, Send_ZC_Copy_Fallback, "flyology_send_zc_copy_fallback");

   --  A hard EV_DELETE failure is not recoverable enough to permit immediate
   --  aiocb-address reuse. Keep terminal records stable until a stale event
   --  consumes them or the owning poller is destroyed. Bound the exceptional
   --  path so a persistently broken kqueue cannot grow memory without limit.
   Max_Retired_Requests : constant Natural := 1_024;

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

   type Signal_Event is record
      Notify            : C.int;
      Signo             : C.int;
      Value             : System.Address;
      Notify_Function   : System.Address;
      Notify_Attributes : System.Address;
   end record
     with Convention => C, Size => 256, Alignment => 8;
   for Signal_Event use record
      Notify            at 0  range 0 .. 31;
      Signo             at 4  range 0 .. 31;
      Value             at 8  range 0 .. 63;
      Notify_Function   at 16 range 0 .. 63;
      Notify_Attributes at 24 range 0 .. 63;
   end record;

   type AIO_Control_Block is record
      Descriptor   : C.int;
      Offset       : C.long_long;
      Buffer       : System.Address;
      Length       : C.size_t;
      Priority     : C.int;
      Signal       : Signal_Event;
      List_Opcode  : C.int;
   end record
     with Convention => C, Size => 640, Alignment => 8;
   for AIO_Control_Block use record
      Descriptor  at 0  range 0 .. 31;
      Offset      at 8  range 0 .. 63;
      Buffer      at 16 range 0 .. 63;
      Length      at 24 range 0 .. 63;
      Priority    at 32 range 0 .. 31;
      Signal      at 40 range 0 .. 255;
      List_Opcode at 72 range 0 .. 31;
   end record;

   type AIO_Request;
   type AIO_Request_Access is access all AIO_Request;

   type AIO_Request is record
      Control : aliased AIO_Control_Block;
      Token   : System.Address;
      Synthetic : Boolean;
      Next_Free : AIO_Request_Access;
      Next_Active : AIO_Request_Access;
   end record
     with Size => 896, Alignment => 8;
   for AIO_Request use record
      Control   at 0  range 0 .. 639;
      Token     at 80 range 0 .. 63;
      Synthetic at 88 range 0 .. 7;
      Next_Free at 96 range 0 .. 63;
      Next_Active at 104 range 0 .. 63;
   end record;

   type Engine_State is record
      Kqueue_FD    : C.int := -1;
      Free_Requests : AIO_Request_Access;
      Active_Requests : AIO_Request_Access;
      Active_Count    : Natural with Atomic;
      Retired_Requests : AIO_Request_Access;
      Retired_Count    : Natural := 0;
   end record;
   type Engine_State_Access is access all Engine_State;

   function To_State is new Ada.Unchecked_Conversion
     (System.Address, Engine_State_Access);
   function To_Address is new Ada.Unchecked_Conversion
     (Engine_State_Access, System.Address);
   function To_Request is new Ada.Unchecked_Conversion
     (System.Address, AIO_Request_Access);
   procedure Free_State is new Ada.Unchecked_Deallocation
     (Engine_State, Engine_State_Access);
   procedure Free_Request is new Ada.Unchecked_Deallocation
     (AIO_Request, AIO_Request_Access);

   procedure C_Abort;
   pragma Import (C, C_Abort, "abort");
   pragma No_Return (C_Abort);

   function Acquire_Request
     (State : not null Engine_State_Access) return AIO_Request_Access;

   procedure Recycle_Request
     (State   : not null Engine_State_Access;
      Request : in out AIO_Request_Access);

   procedure Unlink_Active
     (State   : not null Engine_State_Access;
      Request : not null AIO_Request_Access);

   procedure Retire_Request
     (State   : not null Engine_State_Access;
      Request : in out AIO_Request_Access);

   function Acquire_Request
     (State : not null Engine_State_Access) return AIO_Request_Access
   is
      Request : constant AIO_Request_Access := State.Free_Requests;
   begin
      if Request = null then
         return new AIO_Request;
      end if;
      State.Free_Requests := Request.Next_Free;
      Request.Next_Free := null;
      Request.Next_Active := null;
      return Request;
   end Acquire_Request;

   procedure Recycle_Request
     (State   : not null Engine_State_Access;
      Request : in out AIO_Request_Access)
   is
   begin
      Request.Next_Free := State.Free_Requests;
      State.Free_Requests := Request;
      Request := null;
   end Recycle_Request;

   procedure Unlink_Active
     (State   : not null Engine_State_Access;
      Request : not null AIO_Request_Access)
   is
      Position : AIO_Request_Access := State.Active_Requests;
      Previous : AIO_Request_Access;
   begin
      while Position /= null and then Position /= Request loop
         Previous := Position;
         Position := Position.Next_Active;
      end loop;
      if Position = null then
         raise Program_Error with "unknown Darwin AIO completion";
      elsif Previous = null then
         State.Active_Requests := Request.Next_Active;
      else
         Previous.Next_Active := Request.Next_Active;
      end if;
      Request.Next_Active := null;
   end Unlink_Active;

   procedure Retire_Request
     (State   : not null Engine_State_Access;
      Request : in out AIO_Request_Access)
   is
   begin
      if State.Retired_Count = Max_Retired_Requests then
         --  Reusing Request would make a later stale event alias unrelated
         --  storage. Fail closed instead of allowing unbounded quarantine.
         C_Abort;
      end if;
      Request.Next_Free := State.Retired_Requests;
      State.Retired_Requests := Request;
      State.Retired_Count := State.Retired_Count + 1;
      Request := null;
   end Retire_Request;

   function AIO_Read (Control : access AIO_Control_Block) return C.int;
   pragma Import (C, AIO_Read, "aio_read");

   function AIO_Write (Control : access AIO_Control_Block) return C.int;
   pragma Import (C, AIO_Write, "aio_write");

   function AIO_Cancel
     (Descriptor : C.int; Control : access AIO_Control_Block) return C.int;
   pragma Import (C, AIO_Cancel, "aio_cancel");

   function AIO_Return (Control : access AIO_Control_Block) return C.long;
   pragma Import (C, AIO_Return, "aio_return");

   function Kevent
     (Queue        : C.int;
      Changes      : System.Address;
      Change_Count : C.int;
      Events       : System.Address;
      Event_Count  : C.int;
      Flags        : C.unsigned;
      Timeout      : System.Address) return C.int;
   pragma Import (C, Kevent, "kevent64");

   procedure Note_Cancellation
     (Backend     : C.int;
      Disposition : C.int;
      Terminal    : C.int);
   pragma Import
     (C, Note_Cancellation, "flyology_test_note_file_cancel");

   procedure Note
     (Disposition : Cancellation_Disposition; Terminal : Boolean);

   procedure Note
     (Disposition : Cancellation_Disposition; Terminal : Boolean) is
   begin
      if Faults.Enabled then
         Note_Cancellation
           (1,
            C.int (Cancellation_Disposition'Pos (Disposition) + 1),
            Boolean'Pos (Terminal));
      end if;
   end Note;

   --  Darwin's values are bit flags, unlike several other POSIX targets.
   AIO_ALLDONE     : constant C.int := 16#1#;
   AIO_CANCELED    : constant C.int := 16#2#;
   AIO_NOTCANCELED : constant C.int := 16#4#;

   function Initialize
     (Item      : in out Engine;
      Poller_FD : C.int;
      Wake_FD   : C.int) return Boolean
   is
      State : Engine_State_Access;
   begin
      pragma Unreferenced (Wake_FD);
      State :=
        new Engine_State'
          (Kqueue_FD     => Poller_FD,
           Free_Requests => null,
           Active_Requests => null,
           Active_Count    => 0,
           Retired_Requests => null,
           Retired_Count    => 0);
      Item.State := To_Address (State);
      return True;
   exception
      when Storage_Error =>
         return False;
   end Initialize;

   procedure Finalize (Item : in out Engine) is
      State : Engine_State_Access := To_State (Item.State);
      Request : AIO_Request_Access;
   begin
      if State /= null then
         if State.Active_Requests /= null then
            raise Program_Error with
              "FLYOLOGY finalized with active Darwin AIO requests";
         end if;
         while State.Free_Requests /= null loop
            Request := State.Free_Requests;
            State.Free_Requests := Request.Next_Free;
            Free_Request (Request);
         end loop;
         while State.Retired_Requests /= null loop
            Request := State.Retired_Requests;
            State.Retired_Requests := Request.Next_Free;
            Free_Request (Request);
         end loop;
         Free_State (State);
         Item.State := System.Null_Address;
      end if;
   end Finalize;

   function Supports_Send_ZC (Item : Engine) return Boolean is
   begin
      pragma Unreferenced (Item);
      return False;
   end Supports_Send_ZC;

   function Submit_Send_ZC
     (Item        : in out Engine;
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

   function Submit
     (Item        : in out Engine;
      Descriptor  : C.int;
      Buffer      : System.Address;
      Length      : C.size_t;
      Offset      : C.long_long;
      For_Write   : Boolean;
      Token       : System.Address;
      Error_Code  : out C.int) return Boolean
   is
      State   : constant Engine_State_Access := To_State (Item.State);
      Request : AIO_Request_Access;
      Result  : C.int;
   begin
      if State = null then
         Error_Code := C.int (OSI.EINVAL);
         return False;
      end if;

      Request := Acquire_Request (State);
      Request.all :=
        (Control =>
           (Descriptor  => Descriptor,
            Offset      => Offset,
            Buffer      => Buffer,
            Length      => Length,
            Priority    => 0,
            Signal      =>
              (Notify            => SIGEV_KEVENT,
               Signo             => State.Kqueue_FD,
               Value             => Token,
               Notify_Function   => System.Null_Address,
               Notify_Attributes => System.Null_Address),
            List_Opcode => 0),
         Token     => Token,
         Synthetic => False,
         Next_Free => null,
         Next_Active => null);
      if Faults.Enabled
        and then Faults.Fail (Faults.File_Cancel_Synthetic)
      then
         Request.Synthetic := True;
         Result := 0;
      else
         Result :=
           (if For_Write
            then AIO_Write (Request.Control'Access)
            else AIO_Read (Request.Control'Access));
      end if;
      if Result /= 0 then
         Error_Code := C.int (OSI.errno);
         Recycle_Request (State, Request);
         return False;
      end if;
      Request.Next_Active := State.Active_Requests;
      State.Active_Requests := Request;
      State.Active_Count := State.Active_Count + 1;
      Error_Code := 0;
      return True;
   exception
      when Storage_Error =>
         Error_Code := C.int (OSI.ENOMEM);
         return False;
   end Submit;

   function Cancel
     (Item           : in out Engine;
      Descriptor     : C.int;
      Token          : System.Address;
      Value          : out Completion;
      Has_Completion : out Boolean;
      Error_Code     : out C.int)
      return Cancellation_Disposition
   is
      State   : constant Engine_State_Access := To_State (Item.State);
      Request : AIO_Request_Access;
      Result  : C.int;
      Returned : C.long;
      Registration_Removed : Boolean := True;
   begin
      Value := (others => <>);
      Has_Completion := False;
      Error_Code := 0;
      if State = null or else Token = System.Null_Address then
         Error_Code := C.int (OSI.EINVAL);
         return Cancellation_Failed;
      end if;

      Request := State.Active_Requests;
      while Request /= null
        and then
          (Request.Token /= Token
           or else Request.Control.Descriptor /= Descriptor)
      loop
         Request := Request.Next_Active;
      end loop;
      if Request = null then
         Note (Already_Completing, False);
         return Already_Completing;
      end if;

      Result :=
        (if Request.Synthetic
         then AIO_CANCELED
         else AIO_Cancel (Descriptor, Request.Control'Access));
      case Result is
         when AIO_CANCELED =>
            --  Darwin can omit SIGEV_KEVENT after an immediate cancellation.
            --  Delete any pending registration before this aiocb address can
            --  be reused, then perform the mandatory one-time reap. Only this
            --  terminal path permits the caller buffer to be released early.
            declare
               Change : aliased Kevent_Record :=
                 (Ident  => SSE.To_Integer (Request.Control'Address),
                  Filter => EVFILT_AIO,
                  Flags  => EV_DELETE,
                  Fflags => 0,
                  Data   => 0,
                  Udata  => 0,
                  Ext    => (others => 0));
               Deleted     : C.int;
               Delete_Error : C.int := 0;
            begin
               loop
                  if Faults.Enabled
                    and then Faults.Fail (Faults.File_Cancel_Delete_EINTR)
                  then
                     Deleted := -1;
                     Delete_Error := C.int (OSI.EINTR);
                  elsif Faults.Enabled
                    and then Faults.Fail (Faults.File_Cancel_Delete_Failure)
                  then
                     Deleted := -1;
                     Delete_Error := EIO;
                  else
                     Deleted :=
                       Kevent
                         (State.Kqueue_FD,
                          Change'Address,
                          1,
                          System.Null_Address,
                          0,
                          0,
                          System.Null_Address);
                     Delete_Error :=
                       (if Deleted = 0 then 0 else C.int (OSI.errno));
                  end if;
                  exit when Deleted = 0
                    or else Delete_Error /= C.int (OSI.EINTR);
               end loop;
               --  AIO_CANCELED is already terminal. Failure to remove a
               --  stale registration is diagnostic only: returning here
               --  before aio_return would leak the request permanently
               --  because Darwin need not deliver a cancellation event.
               if Deleted /= 0 and then Delete_Error /= ENOENT then
                  Error_Code := Delete_Error;
                  Registration_Removed := False;
               end if;
            end;
            Returned :=
              (if Request.Synthetic
               then 0
               else AIO_Return (Request.Control'Access));
            pragma Unreferenced (Returned);
            Value :=
              (Token      => Request.Token,
               Result     => 0,
               Error_Code => 0);
            Unlink_Active (State, Request);
            State.Active_Count := State.Active_Count - 1;
            if Registration_Removed then
               Recycle_Request (State, Request);
            else
               --  The task may resume because aio_return made the operation
               --  terminal, but keep this aiocb address out of the free list
               --  when kqueue could still hold its old registration.
               Retire_Request (State, Request);
            end if;

            --  The fault-only synthetic request has no kernel AIO operation.
            --  Deliver a one-shot marker through the real kqueue so the test
            --  exercises poller dispatch and quarantine consumption rather
            --  than calling Complete_Event directly.
            if Faults.Enabled
              and then not Registration_Removed
              and then Request = null
            then
               declare
                  Retired : constant AIO_Request_Access :=
                    State.Retired_Requests;
                  Change  : aliased Kevent_Record :=
                    (Ident  => SSE.To_Integer (Retired.Control'Address),
                     Filter => EVFILT_USER,
                     Flags  => EV_ADD + EV_ONESHOT,
                     Fflags => NOTE_TRIGGER,
                     Data   => 0,
                     Udata  => SSE.To_Integer (Retired.Control'Address),
                     Ext    => (others => 0));
                  Queued : C.int;
               begin
                  if Retired.Synthetic then
                     Queued :=
                       Kevent
                         (State.Kqueue_FD,
                          Change'Address,
                          1,
                          System.Null_Address,
                          0,
                          0,
                          System.Null_Address);
                     if Queued /= 0 then
                        raise Program_Error with
                          "synthetic Darwin stale event registration failed";
                     end if;
                  end if;
               end;
            end if;
            Has_Completion := True;
            Note (Cancellation_Submitted, True);
            return Cancellation_Submitted;
         when AIO_NOTCANCELED =>
            Note (Not_Cancelable, False);
            return Not_Cancelable;
         when AIO_ALLDONE =>
            Note (Already_Completing, False);
            return Already_Completing;
         when others =>
            Error_Code := C.int (OSI.errno);
            Note (Cancellation_Failed, False);
            return Cancellation_Failed;
      end case;
   end Cancel;

   function Complete_Event
     (Item            : in out Engine;
      Request_Address : System.Address;
      Kernel_Result   : C.long_long;
      Kernel_Error    : C.int;
      Value           : out Completion) return Event_Completion_Disposition
   is
      State   : constant Engine_State_Access := To_State (Item.State);
      Request : AIO_Request_Access := To_Request (Request_Address);
      Position : AIO_Request_Access;
      Previous : AIO_Request_Access;
      Result  : C.long;
   begin
      Value := (others => <>);
      if State = null or else Request = null then
         return Completion_Failed;
      end if;
      Position := State.Active_Requests;
      while Position /= null and then Position /= Request loop
         Position := Position.Next_Active;
      end loop;
      if Position = null then
         --  A failed EV_DELETE may leave a stale event for a terminal request.
         --  Retired request records keep that address stable until this event
         --  is consumed. Unknown payloads remain poller failures.
         Position := State.Retired_Requests;
         while Position /= null and then Position /= Request loop
            Previous := Position;
            Position := Position.Next_Free;
         end loop;
         if Position = null then
            return Completion_Failed;
         elsif Previous = null then
            State.Retired_Requests := Position.Next_Free;
         else
            Previous.Next_Free := Position.Next_Free;
         end if;
         Position.Next_Free := null;
         State.Retired_Count := State.Retired_Count - 1;
         if Faults.Enabled then
            declare
               Counted : constant Boolean :=
                 Faults.Fail (Faults.File_Cancel_Stale_Event);
            begin
               pragma Unreferenced (Counted);
            end;
         end if;
         Recycle_Request (State, Position);
         return Completion_Ignored;
      end if;
      --  kevent is the readiness notification, but aio_return is the one
      --  mandatory reap operation that relinquishes Darwin's kernel AIO
      --  resources. It must happen exactly once before this aiocb is reused.
      Result := AIO_Return (Request.Control'Access);
      --  Darwin's SIGEV_KEVENT path may reap the request while producing the
      --  event; aio_return then reports EINVAL and ext[1..2] carry the saved
      --  errno/result. Other completion paths return the result directly.
      Value :=
        (Token      => Request.Token,
         Result     =>
           (if Result >= 0 then C.long_long (Result)
            elsif C.int (OSI.errno) = C.int (OSI.EINVAL)
            and then Kernel_Result >= 0
            then Kernel_Result
            else 0),
         Error_Code =>
           (if Result >= 0 then 0
            elsif C.int (OSI.errno) = C.int (OSI.EINVAL)
            then Kernel_Error
            else C.int (OSI.errno)));
      Unlink_Active (State, Request);
      State.Active_Count := State.Active_Count - 1;
      Recycle_Request (State, Request);
      return Completion_Produced;
   end Complete_Event;

   function Is_Quiescent (Item : Engine) return Boolean is
      State : constant Engine_State_Access := To_State (Item.State);
   begin
      return State = null or else State.Active_Count = 0;
   end Is_Quiescent;

   function Drain
     (Item   : in out Engine;
      Values : out Completion_Array;
      Count  : out Natural) return Boolean
   is
   begin
      pragma Unreferenced (Item);
      Values := (others => <>);
      Count := 0;
      return True;
   end Drain;

end System.Flyology.File_Engine;
