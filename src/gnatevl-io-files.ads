with Ada.Streams;
with Interfaces.C;

package Gnatevl.IO.Files is

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

   procedure Read_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset);

   procedure Write_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset);

private
   type File_Descriptor is new Interfaces.C.int;
   Invalid_File : constant File_Descriptor := -1;
end Gnatevl.IO.Files;
