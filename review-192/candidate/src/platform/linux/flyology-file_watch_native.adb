with GNAT.OS_Lib;
with Flyology.IO;
with System;
with System.Address_To_Access_Conversions;
with System.Storage_Elements;

package body Flyology.File_Watch_Native is
   package SSE renames System.Storage_Elements;

   use type C.int;
   use type C.long;
   use type C.unsigned;
   use type SSE.Storage_Offset;

   IN_NONBLOCK : constant C.int := 16#0000_0800#;
   IN_CLOEXEC  : constant C.int := 16#0008_0000#;

   IN_MODIFY      : constant C.unsigned := 16#0000_0002#;
   IN_ATTRIB      : constant C.unsigned := 16#0000_0004#;
   IN_CLOSE_WRITE : constant C.unsigned := 16#0000_0008#;
   IN_MOVED_FROM  : constant C.unsigned := 16#0000_0040#;
   IN_MOVED_TO    : constant C.unsigned := 16#0000_0080#;
   IN_CREATE      : constant C.unsigned := 16#0000_0100#;
   IN_DELETE      : constant C.unsigned := 16#0000_0200#;
   IN_DELETE_SELF : constant C.unsigned := 16#0000_0400#;
   IN_MOVE_SELF   : constant C.unsigned := 16#0000_0800#;
   IN_UNMOUNT     : constant C.unsigned := 16#0000_2000#;
   IN_Q_OVERFLOW  : constant C.unsigned := 16#0000_4000#;
   IN_IGNORED     : constant C.unsigned := 16#0000_8000#;
   WATCH_MASK     : constant C.unsigned :=
     IN_MODIFY
     or IN_ATTRIB
     or IN_CLOSE_WRITE
     or IN_MOVED_FROM
     or IN_MOVED_TO
     or IN_CREATE
     or IN_DELETE
     or IN_DELETE_SELF
     or IN_MOVE_SELF;

   EINTR  : constant Integer := 4;
   EAGAIN : constant Integer := 11;
   EINVAL : constant Integer := 22;

   type Inotify_Event is record
      Watch       : C.int;
      Mask        : C.unsigned;
      Cookie      : C.unsigned;
      Name_Length : C.unsigned;
   end record
   with Convention => C, Size => 128;
   package Event_Conversions is new System.Address_To_Access_Conversions (Inotify_Event);

   Buffer_Size : constant := 16 * 1_024;
   type Byte_Array is array (Natural range <>) of aliased C.unsigned_char with Convention => C;

   function Inotify_Init (Flags : C.int) return C.int;
   pragma Import (C, Inotify_Init, "inotify_init1");
   function Inotify_Add (FD : C.int; Path : System.Address; Mask : C.unsigned) return C.int;
   pragma Import (C, Inotify_Add, "inotify_add_watch");
   function Inotify_Remove (FD : C.int; Watch : C.int) return C.int;
   pragma Import (C, Inotify_Remove, "inotify_rm_watch");
   function C_Read (FD : C.int; Buffer : System.Address; Length : C.size_t) return C.long;
   pragma Import (C, C_Read, "read");
   function C_Close (FD : C.int) return C.int;
   pragma Import (C, C_Close, "close");

   function Has (Value : C.unsigned; Flag : C.unsigned) return Boolean
   is ((Value and Flag) /= 0);

   procedure Open (Source : in out C.int) is
      New_Source : C.int;
   begin
      if Source >= 0 then
         return;
      end if;
      New_Source := Inotify_Init (IN_NONBLOCK + IN_CLOEXEC);
      if New_Source < 0 then
         raise Flyology.IO.Device_Error
           with "inotify file watcher creation failed, errno=" & GNAT.OS_Lib.Errno'Image;
      end if;
      Source := New_Source;
   end Open;

   function Add (Source : C.int; Path : String) return Handle is
      C_Path : aliased String (1 .. Path'Length + 1);
      Result : C.int;
   begin
      C_Path (1 .. Path'Length) := Path;
      C_Path (C_Path'Last) := ASCII.NUL;
      Result := Inotify_Add (Source, C_Path'Address, WATCH_MASK);
      if Result < 0 then
         raise Flyology.IO.Device_Error
           with "file watch registration failed, errno=" & GNAT.OS_Lib.Errno'Image;
      end if;
      return Handle (Result);
   end Add;

   procedure Remove (Source : C.int; Subject : Handle; Success : out Boolean) is
      Result : C.int;
   begin
      if Subject = Invalid_Handle then
         Success := True;
         return;
      end if;
      loop
         Result := Inotify_Remove (Source, C.int (Subject));
         exit when Result = 0 or else GNAT.OS_Lib.Errno /= EINTR;
      end loop;
      --  IN_DELETE_SELF, IN_MOVE_SELF, and IN_UNMOUNT can remove a watch
      --  before its owner consumes the invalidation hint.
      Success := Result = 0 or else GNAT.OS_Lib.Errno = EINVAL;
   end Remove;

   procedure Close (Source : in out C.int; Success : out Boolean) is
      Error : Integer;
   begin
      if Source < 0 then
         Success := True;
      else
         Success := C_Close (Source) = 0;
         Error := GNAT.OS_Lib.Errno;
         --  Linux releases the descriptor even when close reports EINTR.
         Success := Success or else Error = EINTR;
         Source := -1;
      end if;
   end Close;

   procedure Read (Source : C.int; Events : out Raw_Event_Array; Count : out Natural) is
      --  Linux defines each inotify_event header as four 32-bit fields, so
      --  the parse base must retain the ABI's four-byte alignment.
      Buffer : aliased Byte_Array (0 .. Buffer_Size - 1)
      with Alignment => 4;
      Bytes  : C.long;
      Offset : Natural := 0;

      No_Raw_Changes : constant Raw_Changes := (others => False);

      procedure Mark_Lost;
      procedure Append (Subject : Handle; Changes : Raw_Changes);

      procedure Mark_Lost is
      begin
         for Index in Events'First .. Events'First + Count - 1 loop
            if Events (Index).Subject = Invalid_Handle then
               Events (Index).Changes.Events_Lost := True;
               return;
            end if;
         end loop;
         if Count < Events'Length then
            Count := Count + 1;
            Events (Events'First + Count - 1) :=
              (Subject => Invalid_Handle, Changes => (Events_Lost => True, others => False));
         else
            Events (Events'Last) :=
              (Subject => Invalid_Handle, Changes => (Events_Lost => True, others => False));
         end if;
      end Mark_Lost;

      procedure Append (Subject : Handle; Changes : Raw_Changes) is
      begin
         if Changes = No_Raw_Changes then
            return;
         end if;
         for Index in Events'First .. Events'First + Count - 1 loop
            if Events (Index).Subject = Subject then
               Events (Index).Changes.Contents := Events (Index).Changes.Contents or else Changes.Contents;
               Events (Index).Changes.Metadata := Events (Index).Changes.Metadata or else Changes.Metadata;
               Events (Index).Changes.Identity := Events (Index).Changes.Identity or else Changes.Identity;
               Events (Index).Changes.Invalidated :=
                 Events (Index).Changes.Invalidated or else Changes.Invalidated;
               Events (Index).Changes.Events_Lost :=
                 Events (Index).Changes.Events_Lost or else Changes.Events_Lost;
               return;
            end if;
         end loop;
         if Count = Events'Length then
            Mark_Lost;
         else
            Count := Count + 1;
            Events (Events'First + Count - 1) := (Subject => Subject, Changes => Changes);
         end if;
      end Append;
   begin
      Events := (others => <>);
      Count := 0;
      loop
         Bytes := C_Read (Source, Buffer'Address, C.size_t (Buffer'Length));
         exit when Bytes >= 0 or else GNAT.OS_Lib.Errno /= EINTR;
      end loop;
      if Bytes < 0 then
         if GNAT.OS_Lib.Errno = EAGAIN then
            return;
         end if;
         raise Flyology.IO.Device_Error with "file watch drain failed, errno=" & GNAT.OS_Lib.Errno'Image;
      end if;

      while Offset < Natural (Bytes) loop
         if Natural (Bytes) - Offset < Inotify_Event'Size / System.Storage_Unit then
            raise Flyology.IO.Device_Error with "truncated inotify event header";
         end if;
         declare
            Header      : constant Event_Conversions.Object_Pointer :=
              Event_Conversions.To_Pointer (Buffer'Address + SSE.Storage_Offset (Offset));
            Header_Size : constant Natural := Inotify_Event'Size / System.Storage_Unit;
            Step        : constant Natural := Header_Size + Natural (Header.Name_Length);
            Changes     : Raw_Changes := (others => False);
         begin
            if Step < Header_Size or else Step > Natural (Bytes) - Offset then
               raise Flyology.IO.Device_Error with "invalid inotify event length";
            end if;

            if Has (Header.Mask, IN_Q_OVERFLOW) then
               Mark_Lost;
            else
               Changes.Contents :=
                 Has (Header.Mask, IN_MODIFY)
                 or else Has (Header.Mask, IN_CLOSE_WRITE)
                 or else Has (Header.Mask, IN_MOVED_FROM)
                 or else Has (Header.Mask, IN_MOVED_TO)
                 or else Has (Header.Mask, IN_CREATE)
                 or else Has (Header.Mask, IN_DELETE);
               Changes.Metadata := Has (Header.Mask, IN_ATTRIB);
               Changes.Identity := Has (Header.Mask, IN_DELETE_SELF) or else Has (Header.Mask, IN_MOVE_SELF);
               Changes.Invalidated :=
                 Changes.Identity or else Has (Header.Mask, IN_UNMOUNT) or else Has (Header.Mask, IN_IGNORED);
               Changes.Events_Lost := Has (Header.Mask, IN_UNMOUNT);
               Append (Handle (Header.Watch), Changes);
            end if;
            Offset := Offset + Step;
         end;
      end loop;
   end Read;
end Flyology.File_Watch_Native;
