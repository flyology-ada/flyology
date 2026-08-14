with GNAT.OS_Lib;
with Flyology.IO;
with System;
with System.Storage_Elements;

package body Flyology.File_Watch_Native is
   package SSE renames System.Storage_Elements;

   use type C.int;
   use type C.long_long;
   use type C.unsigned;
   use type C.unsigned_short;
   use type SSE.Integer_Address;

   EVFILT_VNODE : constant C.short := C.short (-4);
   EV_ADD       : constant C.unsigned_short := 16#0001#;
   EV_CLEAR     : constant C.unsigned_short := 16#0020#;
   EV_EOF       : constant C.unsigned_short := 16#8000#;
   EV_ERROR     : constant C.unsigned_short := 16#4000#;

   NOTE_DELETE : constant C.unsigned := 16#0001#;
   NOTE_WRITE  : constant C.unsigned := 16#0002#;
   NOTE_EXTEND : constant C.unsigned := 16#0004#;
   NOTE_ATTRIB : constant C.unsigned := 16#0008#;
   NOTE_LINK   : constant C.unsigned := 16#0010#;
   NOTE_RENAME : constant C.unsigned := 16#0020#;
   NOTE_REVOKE : constant C.unsigned := 16#0040#;
   VNODE_MASK  : constant C.unsigned :=
     NOTE_DELETE or NOTE_WRITE or NOTE_EXTEND or NOTE_ATTRIB or NOTE_LINK
     or NOTE_RENAME or NOTE_REVOKE;

   O_EVTONLY  : constant C.int := 16#0000_8000#;
   O_CLOEXEC  : constant C.int := 16#0100_0000#;
   F_SETFD    : constant C.int := 2;
   FD_CLOEXEC : constant C.int := 1;
   EINTR      : constant Integer := 4;

   type Extension_Array is array (1 .. 2) of C.long_long
     with Convention => C;
   type Kevent_Record is record
      Ident  : SSE.Integer_Address;
      Filter : C.short;
      Flags  : C.unsigned_short;
      Fflags : C.unsigned;
      Data   : C.long_long;
      Udata  : SSE.Integer_Address;
      Ext    : Extension_Array;
   end record
     with Convention => C;
   type Kevent_Array is array (Positive range <>) of aliased Kevent_Record
     with Convention => C;

   type Timespec is record
      Seconds     : C.long;
      Nanoseconds : C.long;
   end record
     with Convention => C;

   function Kqueue return C.int;
   pragma Import (C, Kqueue, "kqueue");
   function Kevent
     (Queue        : C.int;
      Changes      : System.Address;
      Change_Count : C.int;
      Events       : System.Address;
      Event_Count  : C.int;
      Flags        : C.unsigned;
      Timeout      : System.Address) return C.int;
   pragma Import (C, Kevent, "kevent64");
   function C_Open
     (Path : System.Address; Flags : C.int; Mode : C.int) return C.int;
   pragma Import (C_Variadic_2, C_Open, "open");
   function Fcntl_Set
     (FD : C.int; Command : C.int; Argument : C.int) return C.int
     with Import,
          Convention    => C_Variadic_2,
          External_Name => "fcntl";
   function C_Close (FD : C.int) return C.int;
   pragma Import (C, C_Close, "close");

   function Has
     (Value : C.unsigned; Flag : C.unsigned) return Boolean is
     ((Value and Flag) /= 0);
   function Has
     (Value : C.unsigned_short; Flag : C.unsigned_short) return Boolean is
     ((Value and Flag) /= 0);

   procedure Open (Source : in out C.int) is
      New_Source : C.int;
      Result     : C.int;
      Ignored    : C.int;
      Error      : Integer;
   begin
      if Source >= 0 then
         return;
      end if;
      New_Source := Kqueue;
      if New_Source < 0 then
         raise Flyology.IO.Device_Error with
           "kqueue file watcher creation failed, errno="
           & GNAT.OS_Lib.Errno'Image;
      end if;
      Result := Fcntl_Set (New_Source, F_SETFD, FD_CLOEXEC);
      if Result < 0 then
         Error := GNAT.OS_Lib.Errno;
         Ignored := C_Close (New_Source);
         raise Flyology.IO.Device_Error with
           "kqueue file watcher configuration failed, errno=" & Error'Image;
      end if;
      Source := New_Source;
   end Open;

   function Add (Source : C.int; Path : String) return Handle is
      C_Path : aliased String (1 .. Path'Length + 1);
      FD     : C.int;
      Change : aliased Kevent_Record;
      Result : C.int;
      Ignored : C.int;
   begin
      C_Path (1 .. Path'Length) := Path;
      C_Path (C_Path'Last) := ASCII.NUL;
      FD := C_Open (C_Path'Address, O_EVTONLY + O_CLOEXEC, 0);
      if FD < 0 then
         raise Flyology.IO.Device_Error with
           "file watch open failed, errno=" & GNAT.OS_Lib.Errno'Image;
      end if;

      Change :=
        (Ident  => SSE.Integer_Address (FD),
         Filter => EVFILT_VNODE,
         Flags  => EV_ADD + EV_CLEAR,
         Fflags => VNODE_MASK,
         Data   => 0,
         Udata  => 0,
         Ext    => (others => 0));
      Result :=
        Kevent
          (Source,
           Change'Address,
           1,
           System.Null_Address,
           0,
           0,
           System.Null_Address);
      if Result /= 0 then
         declare
            Error : constant Integer := GNAT.OS_Lib.Errno;
         begin
            Ignored := C_Close (FD);
            raise Flyology.IO.Device_Error with
              "file watch registration failed, errno=" & Error'Image;
         end;
      end if;
      return Handle (FD);
   end Add;

   procedure Remove
     (Source  : C.int;
      Subject : Handle;
      Success : out Boolean)
   is
      pragma Unreferenced (Source);
   begin
      if Subject = Invalid_Handle then
         Success := True;
      else
         --  Closing the vnode descriptor removes its knote atomically.
         Success := C_Close (C.int (Subject)) = 0;
      end if;
   end Remove;

   procedure Close (Source : in out C.int; Success : out Boolean) is
   begin
      if Source < 0 then
         Success := True;
      else
         Success := C_Close (Source) = 0;
         Source := -1;
      end if;
   end Close;

   procedure Read
     (Source : C.int;
      Events : out Raw_Event_Array;
      Count  : out Natural)
   is
      Native_Events : aliased Kevent_Array (Events'Range);
      Zero          : aliased Timespec := (Seconds => 0, Nanoseconds => 0);
      Result        : C.int;
      Position      : Natural;
      Changes       : Raw_Changes;
   begin
      Events := (others => <>);
      Count := 0;
      loop
         Result :=
           Kevent
             (Source,
              System.Null_Address,
              0,
              Native_Events'Address,
              C.int (Native_Events'Length),
              0,
              Zero'Address);
         exit when Result >= 0 or else GNAT.OS_Lib.Errno /= EINTR;
      end loop;
      if Result < 0 then
         raise Flyology.IO.Device_Error with
           "file watch drain failed, errno=" & GNAT.OS_Lib.Errno'Image;
      end if;

      for Index in 1 .. Natural (Result) loop
         Position := Events'First + Count;
         if Has (Native_Events (Index).Flags, EV_ERROR)
           and then Native_Events (Index).Data /= 0
         then
            raise Flyology.IO.Device_Error with
              "file watch event failed, errno="
              & Native_Events (Index).Data'Image;
         end if;

         Changes :=
           (Contents =>
              Has (Native_Events (Index).Fflags, NOTE_WRITE)
              or else Has (Native_Events (Index).Fflags, NOTE_EXTEND),
            Metadata =>
              Has (Native_Events (Index).Fflags, NOTE_ATTRIB)
              or else Has (Native_Events (Index).Fflags, NOTE_LINK),
            Identity =>
              Has (Native_Events (Index).Fflags, NOTE_DELETE)
              or else Has (Native_Events (Index).Fflags, NOTE_RENAME),
            Invalidated =>
              Has (Native_Events (Index).Fflags, NOTE_DELETE)
              or else Has (Native_Events (Index).Fflags, NOTE_RENAME)
              or else Has (Native_Events (Index).Fflags, NOTE_REVOKE)
              or else Has (Native_Events (Index).Flags, EV_EOF),
            Events_Lost => False);
         Events (Position) :=
           (Subject => Handle (Native_Events (Index).Ident),
            Changes => Changes);
         Count := Count + 1;
      end loop;
   end Read;
end Flyology.File_Watch_Native;
