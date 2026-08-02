with Ada.Streams;
with Flyology.Cancellation;
with Interfaces.C;

--  Provides positional file I/O with lane-specific blocking behavior.
--
--  Example:
--
--     File := Flyology.IO.Files.Open ("state.bin");
package Flyology.IO.Files is

   --  Raised only after a cancellation request reaches a terminal state and
   --  the caller may safely reuse its I/O buffer.
   Operation_Cancelled : exception renames
     Flyology.Cancellation.Operation_Cancelled;

   --  Shared one-shot token. The token must outlive every operation using it.
   subtype Cancellation_Token is Flyology.Cancellation.Token;

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

   --  Read at Offset without changing the descriptor's file position. A
   --  lightweight task suspends until kernel completion; a native task blocks
   --  its thread in pread. A requested token is observed before native pread
   --  starts, but cannot interrupt a native syscall already in progress. A
   --  lightweight cancellation stays suspended until the kernel relinquishes
   --  Item, so Operation_Cancelled is a terminal buffer-ownership handoff.
   --  @param File Open descriptor permitting reads
   --  @param Offset Starting byte position
   --  @param Item Destination buffer
   --  @param Last Last element written, or Item'First - 1 at end of file
   --  @param Token Optional one-shot cancellation token
   --  @exception Device_Error Submission, completion, or pread reports failure
   --  @exception Operation_Cancelled Token cancellation reaches a terminal
   --     state
   procedure Read_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Token  : access Cancellation_Token := null);

   --  Write at Offset without changing the descriptor's file position. A
   --  single call may transfer fewer than Item'Length elements. Lightweight
   --  tasks suspend for kernel completion; native tasks block in pwrite. Token
   --  and buffer-lifetime semantics match Read_At. Cancellation does not roll
   --  back bytes already written. When Operation_Cancelled is raised, Last has
   --  no defined application meaning and a blind retry may duplicate or
   --  overwrite data; callers needing retry safety must provide an idempotent
   --  protocol or track committed offsets independently.
   --  @param File Open descriptor permitting writes
   --  @param Offset Starting byte position
   --  @param Item Source buffer
   --  @param Last Last element written, or Item'First - 1 if none, meaningful
   --     only on normal return
   --  @param Token Optional one-shot cancellation token
   --  @exception Device_Error Submission, completion, or pwrite reports
   --     failure
   --  @exception Operation_Cancelled Token cancellation reaches a terminal
   --     state
   procedure Write_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Token  : access Cancellation_Token := null);

private
   type File_Descriptor is new Interfaces.C.int;
   Invalid_File : constant File_Descriptor := -1;
end Flyology.IO.Files;
