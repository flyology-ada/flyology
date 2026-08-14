with Interfaces.C;

--  Platform notification boundary for Flyology.IO.File_Watches. The source
--  descriptor is always readable through Flyology.IO: Linux uses the inotify
--  descriptor directly, while Darwin exposes a private kqueue containing
--  persistent EVFILT_VNODE registrations.
private package Flyology.File_Watch_Native with Preelaborate is
   package C renames Interfaces.C;

   type Handle is new C.int;
   Invalid_Handle : constant Handle := Handle (-1);

   type Raw_Changes is record
      Contents    : Boolean := False;
      Metadata    : Boolean := False;
      Identity    : Boolean := False;
      Invalidated : Boolean := False;
      Events_Lost : Boolean := False;
   end record;

   type Raw_Event is record
      Subject : Handle := Invalid_Handle;
      Changes : Raw_Changes;
   end record;
   type Raw_Event_Array is array (Positive range <>) of Raw_Event;

   procedure Open (Source : in out C.int);
   function Add (Source : C.int; Path : String) return Handle;
   procedure Remove
     (Source  : C.int;
      Subject : Handle;
      Success : out Boolean);
   procedure Close (Source : in out C.int; Success : out Boolean);

   --  Drain one nonblocking kernel batch. Events for one native handle are
   --  coalesced when possible. A synthetic Invalid_Handle/Events_Lost result
   --  means callers must invalidate their complete watched set.
   procedure Read
     (Source : C.int;
      Events : out Raw_Event_Array;
      Count  : out Natural)
   with Post => Count <= Events'Length;
end Flyology.File_Watch_Native;
