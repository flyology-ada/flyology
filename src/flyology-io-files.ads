with Ada.Streams;
with Flyology.Buffers;
with Flyology.Cancellation;
with Flyology.Operations;
with Interfaces.C;
private with System;

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

   --  Common limited base for completion-driven positional file operations.
   --  Concrete operations borrow an aliased array until Finish consumes the
   --  terminal result. Scoped file operations currently require a lightweight
   --  owner; the existing synchronous overloads remain available in both
   --  lanes.
   type File_Operation is
     abstract new Flyology.Operations.Operation with private;
   --  Scoped completion-driven positional read.
   type Read_Operation is new File_Operation with private;
   --  Scoped completion-driven positional write.
   type Write_Operation is new File_Operation with private;

   --  Start one completion-driven positional read without parking the owner.
   --  Set, File, and Item must outlive the returned operation. Item is
   --  exclusively borrowed until Finish or finalization drains cancellation.
   --  @param Set Completion set that owns the operation slot
   --  @param File Open descriptor permitting reads
   --  @param Offset Starting byte position
   --  @param Item Aliased destination buffer
   --  @param Timeout Relative operation deadline; zero makes one immediate
   --     completion attempt and negative means none
   --  @return Started limited read operation
   function Read_At
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      File    : File_Descriptor;
      Offset  : File_Offset;
      Item    : not null access Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Flyology.IO.Infinite) return Read_Operation;

   --  Start or restart a positional read in an established operation object.
   --  @param File Open descriptor permitting reads
   --  @param Offset Starting byte position
   --  @param Item Aliased destination buffer
   --  @param Timeout Relative operation deadline
   --  @param Operation Fresh, released, or consumed read operation
   procedure Read_At
     (File      : File_Descriptor;
      Offset    : File_Offset;
      Item      : not null access Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Flyology.IO.Infinite;
      Operation : in out Read_Operation)
     with Pre =>
       not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation);

   --  Start one completion-driven positional write without parking the owner.
   --  A terminal cancellation does not roll back bytes already written.
   --  Set, File, and Item must outlive the returned operation, and Item must
   --  not be changed until Finish or finalization drains cancellation.
   --  @param Set Completion set that owns the operation slot
   --  @param File Open descriptor permitting writes
   --  @param Offset Starting byte position
   --  @param Item Aliased source buffer
   --  @param Timeout Relative operation deadline; zero makes one immediate
   --     completion attempt and negative means none
   --  @return Started limited write operation
   function Write_At
     (Set     : not null access Flyology.Operations.Completion_Set'Class;
      File    : File_Descriptor;
      Offset  : File_Offset;
      Item    : not null access constant Ada.Streams.Stream_Element_Array;
      Timeout : Duration := Flyology.IO.Infinite) return Write_Operation;

   --  Start or restart a positional write in an established operation object.
   --  @param File Open descriptor permitting writes
   --  @param Offset Starting byte position
   --  @param Item Aliased source buffer
   --  @param Timeout Relative operation deadline
   --  @param Operation Fresh, released, or consumed write operation
   procedure Write_At
     (File      : File_Descriptor;
      Offset    : File_Offset;
      Item      : not null access constant Ada.Streams.Stream_Element_Array;
      Timeout   : Duration := Flyology.IO.Infinite;
      Operation : in out Write_Operation)
     with Pre =>
       not Flyology.Operations.Is_Active (Operation)
       and then not Flyology.Operations.Is_Terminal (Operation);

   --  Consume a terminal positional read and publish its Last value.
   --  @param Operation Terminal read operation
   --  @param Last Last element read, or Item'First - 1 at end of file
   --  @exception Device_Error Submission or completion failed
   --  @exception Operation_Cancelled Cancellation reached terminal state
   --  @exception Timeout_Error Deadline cancellation reached terminal state
   procedure Finish
     (Operation : in out Read_Operation;
      Last      : out Ada.Streams.Stream_Element_Offset);

   --  Consume a terminal positional write and publish its Last value.
   --  @param Operation Terminal write operation
   --  @param Last Last element written, or Item'First - 1 when none
   --  @exception Device_Error Submission or completion failed
   --  @exception Operation_Cancelled Cancellation reached terminal state
   --  @exception Timeout_Error Deadline cancellation reached terminal state
   procedure Finish
     (Operation : in out Write_Operation;
      Last      : out Ada.Streams.Stream_Element_Offset);

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

   Async_File_Node_Version : constant Interfaces.C.unsigned := 2;
   Async_File_Unused       : constant Interfaces.C.int := 0;
   Async_File_Submitted    : constant Interfaces.C.int := 1;
   Async_File_Cancelling   : constant Interfaces.C.int := 2;
   Async_File_Terminal     : constant Interfaces.C.int := 3;
   Async_File_Queued       : constant Interfaces.C.int := 4;

   type Async_File_Node is record
      Version          : Interfaces.C.unsigned := Async_File_Node_Version;
      State            : Interfaces.C.int := Async_File_Unused with Atomic;
      Owner            : System.Address := System.Null_Address;
      Descriptor       : Interfaces.C.int := Interfaces.C.int (-1);
      Buffer           : System.Address := System.Null_Address;
      Length           : Interfaces.C.size_t := 0;
      Offset           : Interfaces.C.long_long := 0;
      For_Write        : Interfaces.C.int := 0;
      Signal_FD        : Interfaces.C.int := Interfaces.C.int (-1);
      Result           : Interfaces.C.long_long := 0;
      Error_Code       : Interfaces.C.int := 0;
      Cancelled        : Interfaces.C.int := 0;
      Cancel_Requested : Interfaces.C.int := 0;
      Next             : System.Address := System.Null_Address;
   end record with Convention => C;

   type Scoped_File_Failure is
     (No_Failure,
      Submission_Failure,
      Completion_Failure,
      Deadline_Failure,
      Wrong_Lane_Failure);

   type File_Operation is
     abstract new Flyology.Operations.Operation with record
      Node        : aliased Async_File_Node;
      Buffer_First : Ada.Streams.Stream_Element_Offset := 1;
      Buffer_Length : Natural := 0;
      Failure     : Scoped_File_Failure := No_Failure;
      Timed_Out   : Boolean := False;
   end record;

   --  @exclude
   --  @param Item File operation to advance
   --  @param Event Driver event to process
   overriding procedure Drive
     (Item  : in out File_Operation;
      Event : Flyology.Operations.Driver_Event);

   --  @exclude
   --  @param Item File operation to cancel and drain
   overriding procedure Request_Cancellation
     (Item : in out File_Operation);

   type Read_Operation is new File_Operation with null record;
   type Write_Operation is new File_Operation with null record;
end Flyology.IO.Files;
