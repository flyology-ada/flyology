with Flyology.Buffers;
with Flyology.IO.Sockets;
with Interfaces.C;

--  Transfers positional regular-file regions to connected stream sockets.
package Flyology.IO.Files.Transfers is

   --  Nonnegative number of file bytes requested or transferred.
   type Byte_Count is range 0 .. Interfaces.C.long_long'Last;

   --  Send one available chunk from File starting at Offset. The operation
   --  returns after one positive socket send, Count bytes, or end of file;
   --  callers advance Offset by Sent only after normal return. One deadline
   --  spans file access, socket readiness, and buffer-release completion.
   --  Native tasks
   --  use the host sendfile operation. Lightweight tasks use completion-driven
   --  file input and a platform reduced-copy socket path when available,
   --  otherwise they send from Scratch normally. Scratch remains exclusively
   --  owned by the caller and may be reused when the call returns or raises.
   --  Cancellation or timeout can race with socket progress that the API
   --  cannot report through the out parameter on an exceptional return. Do
   --  not retry the same region blindly after either exception when duplicate
   --  bytes would be unsafe.
   --  The caller must serialize File and Socket lifetime and must not modify
   --  the transferred file region concurrently.
   --  @param File Open regular-file descriptor permitting reads
   --  @param Socket Open connected stream socket
   --  @param Offset Starting byte position; the descriptor position is not
   --     changed
   --  @param Count Maximum bytes to send in this call
   --  @param Scratch Acquired fallback and lightweight transfer buffer
   --  @param Sent Bytes sent on normal return; zero for zero Count or EOF
   --  @param Timeout Shared monotonic deadline in seconds
   --  @param Token Optional one-shot cancellation token
   --  @exception Operation_Cancelled Token cancellation reaches a terminal
   --     buffer-ownership state
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Device_Error File completion, polling, or progress fails
   --  @exception Socket_Error Flyology.IO.Sockets.Socket_Error is raised when
   --     the socket transfer fails
   procedure Send_Chunk
     (File    : File_Descriptor;
      Socket  : Flyology.IO.Sockets.Socket_Type;
      Offset  : File_Offset;
      Count   : Byte_Count;
      Scratch : in out Flyology.Buffers.Unique_Buffer;
      Sent    : out Byte_Count;
      Timeout : Duration := Infinite;
      Token   : access Cancellation_Token := null)
     with Pre => Flyology.Buffers.Has_Buffer (Scratch),
          Post => Sent <= Count and then (if Count = 0 then Sent = 0);

end Flyology.IO.Files.Transfers;
