with Ada.Streams;
with Interfaces.C;

--  Provides positional file I/O with lane-specific blocking behavior.
--
--  Example:
--
--     File := Flyology.IO.Files.Open ("state.bin");
package Flyology.IO.Files is

   --  Owned operating-system file handle. This type is not controlled: the
   --  owning task must call Close. Concurrent operations require external
   --  synchronization, especially if Close may run at the same time.
   type File_Descriptor is private;
   --  Sentinel denoting no open file.
   Invalid_File : constant File_Descriptor;

   --  Access requested from Open.
   --  @enum Read_Only Permit reads only
   --  @enum Write_Only Permit writes only
   --  @enum Read_Write Permit both reads and writes
   type Open_Mode is (Read_Only, Write_Only, Read_Write);
   --  Nonnegative byte position used by positional reads and writes.
   type File_Offset is range 0 .. Interfaces.C.long_long'Last;

   --  Open Path directly on the calling lane. Create adds the platform create
   --  flag and Truncate truncates an existing file. Truncate is invalid with
   --  Read_Only. Open and Close are metadata syscalls and may block either
   --  lane's underlying thread.
   --  @param Path Filesystem path
   --  @param Mode Requested access mode
   --  @param Create Create the file when it does not exist
   --  @param Truncate Truncate the file before returning
   --  @return Newly owned file descriptor; the caller must Close it
   --  @exception Device_Error The mode combination is invalid or open(2) fails
   function Open
     (Path     : String;
      Mode     : Open_Mode := Read_Only;
      Create   : Boolean := False;
      Truncate : Boolean := False) return File_Descriptor;

   --  Close File and set it to Invalid_File. Closing Invalid_File is harmless.
   --  @param File Descriptor whose ownership is released
   --  @exception Device_Error close(2) reports an error; File is invalidated
   procedure Close (File : in out File_Descriptor);

   --  Read at Offset without changing the descriptor's file position.
   --  Lightweight tasks suspend until the execution group's kernel completion
   --  backend finishes the request. Native tasks block their thread in pread.
   --  @param File Open descriptor permitting reads
   --  @param Offset Starting byte position
   --  @param Item Destination buffer
   --  @param Last Last element written, or Item'First - 1 at end of file
   --  @exception Device_Error Submission, completion, or pread reports failure
   procedure Read_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset);

   --  Write at Offset without changing the descriptor's file position. A
   --  single call may transfer fewer than Item'Length elements. Lightweight
   --  tasks suspend for kernel completion; native tasks block in pwrite.
   --  @param File Open descriptor permitting writes
   --  @param Offset Starting byte position
   --  @param Item Source buffer
   --  @param Last Last element written, or Item'First - 1 if none
   --  @exception Device_Error Submission, completion, or pwrite reports
   --     failure
   procedure Write_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset);

private
   type File_Descriptor is new Interfaces.C.int;
   Invalid_File : constant File_Descriptor := -1;
end Flyology.IO.Files;
