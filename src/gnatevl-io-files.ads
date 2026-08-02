with Ada.Streams;
with Gnatevl.Cancellation;
with Interfaces.C;

package Gnatevl.IO.Files is

   Operation_Cancelled : exception renames
     Gnatevl.Cancellation.Operation_Cancelled;

   subtype Cancellation_Token is Gnatevl.Cancellation.Token;

   type File_Descriptor is private;
   Invalid_File : constant File_Descriptor;

   type Open_Mode is (Read_Only, Write_Only, Read_Write);
   type File_Offset is range 0 .. Interfaces.C.long_long'Last;

   function Open
     (Path     : String;
      Mode     : Open_Mode := Read_Only;
      Create   : Boolean := False;
      Truncate : Boolean := False) return File_Descriptor;

   procedure Close (File : in out File_Descriptor);

   --  Evented tasks submit reads and writes to the execution group's kernel
   --  completion backend (Darwin AIO/kqueue or Linux io_uring/epoll). Native
   --  tasks use positional syscalls directly. Open and Close are metadata
   --  syscalls on both lanes; no hidden file-worker tasks are created.
   --
   --  Evented operations with a Token remain suspended after cancellation is
   --  requested until the kernel has relinquished the request and Item can be
   --  reused safely. Operation_Cancelled therefore reports a terminal state,
   --  not merely that cancellation was submitted. Native operations preserve
   --  their direct positional-syscall behavior and observe a token before
   --  entering that syscall; they cannot interrupt an in-progress syscall.

   procedure Read_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Token  : access Cancellation_Token := null);

   procedure Write_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Token  : access Cancellation_Token := null);

private
   type File_Descriptor is new Interfaces.C.int;
   Invalid_File : constant File_Descriptor := -1;
end Gnatevl.IO.Files;
