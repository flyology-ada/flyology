with Ada.Streams;
with Flyology.Buffers;
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

   --  Raised after a timed file operation's abort has reached a terminal state
   --  and the caller may safely reuse its buffer.
   Timeout_Error : exception renames Flyology.IO.Timeout_Error;

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

   --  Read positionally within one relative deadline. A lightweight timeout
   --  requests kernel cancellation and does not return until the kernel has
   --  relinquished Item. A native pread cannot be interrupted after entry, so
   --  timeout delivery may be delayed until that syscall returns. Negative
   --  Timeout waits without a deadline. Zero is one immediate attempt whose
   --  result wins, matching Flyology.IO.Wait and Flyology.Buffers.Acquire_For:
   --  a positional read has no readiness wait, so the attempt runs and returns
   --  transferred bytes, end of file, or a failure rather than Timeout_Error.
   --  Zero still bounds only readiness, not device latency, so a page-cache
   --  miss may occupy the caller for the duration of the disk read.
   --  @param File Open descriptor permitting reads
   --  @param Offset Starting byte position
   --  @param Item Destination buffer
   --  @param Last Last element written, or Item'First - 1 at end of file
   --  @param Timeout Maximum monotonic wait in seconds
   --  @param Token Optional one-shot cancellation token
   --  @exception Device_Error Submission, completion, or pread reports failure
   --  @exception Operation_Cancelled Token cancellation reaches a terminal
   --     state
   --  @exception Timeout_Error Deadline cancellation reaches a terminal state;
   --     never raised for a zero or negative Timeout
   procedure Read_At
     (File    : File_Descriptor;
      Offset  : File_Offset;
      Item    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration;
      Token   : access Cancellation_Token := null);

   --  Read directly into an acquired unique buffer and replace its readable
   --  length. Kernel ownership and cancellation semantics match the array
   --  overload.
   --  @param File Open descriptor permitting reads
   --  @param Offset Starting byte position
   --  @param Item Acquired destination buffer
   --  @param Read Number of bytes read; zero at end of file
   --  @param Token Optional one-shot cancellation token
   --  @exception Device_Error Submission, completion, or pread reports failure
   --  @exception Operation_Cancelled Cancellation reaches a terminal state
   procedure Read_At
     (File   : File_Descriptor;
      Offset : File_Offset;
      Item   : in out Flyology.Buffers.Unique_Buffer;
      Read   : out Natural;
      Token  : access Cancellation_Token := null)
     with Pre => Flyology.Buffers.Has_Buffer (Item),
          Post => Flyology.Buffers.Length (Item) = Read;

   --  Read positionally into a unique buffer within one relative deadline.
   --  Timeout, cancellation, and terminal buffer ownership match the array
   --  overload, including the zero-Timeout immediate attempt.
   --  @param File Open descriptor permitting reads
   --  @param Offset Starting byte position
   --  @param Item Acquired destination buffer
   --  @param Read Number of bytes read; zero at end of file
   --  @param Timeout Maximum monotonic wait in seconds
   --  @param Token Optional one-shot cancellation token
   --  @exception Device_Error Submission, completion, or pread reports failure
   --  @exception Operation_Cancelled Token cancellation reaches a terminal
   --     state
   --  @exception Timeout_Error Deadline cancellation reaches a terminal state;
   --     never raised for a zero or negative Timeout
   procedure Read_At
     (File    : File_Descriptor;
      Offset  : File_Offset;
      Item    : in out Flyology.Buffers.Unique_Buffer;
      Read    : out Natural;
      Timeout : Duration;
      Token   : access Cancellation_Token := null)
     with Pre => Flyology.Buffers.Has_Buffer (Item),
          Post => Flyology.Buffers.Length (Item) = Read;

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

   --  Write directly from a unique buffer's readable payload. Item remains
   --  owned until the synchronous call returns.
   --  @param File Open descriptor permitting writes
   --  @param Offset Starting byte position
   --  @param Item Acquired source buffer
   --  @param Written Number of bytes written on normal return
   --  @param Token Optional one-shot cancellation token
   --  @exception Device_Error Submission, completion, or pwrite reports
   --     failure
   --  @exception Operation_Cancelled Cancellation reaches a terminal state
   procedure Write_At
     (File    : File_Descriptor;
      Offset  : File_Offset;
      Item    : Flyology.Buffers.Unique_Buffer;
      Written : out Natural;
      Token   : access Cancellation_Token := null)
     with Pre => Flyology.Buffers.Has_Buffer (Item);

private
   type File_Descriptor is new Interfaces.C.int;
   Invalid_File : constant File_Descriptor := -1;
end Flyology.IO.Files;
