with Ada.Streams;
with GNAT.Sockets;

--  Provides nonblocking socket operations with one API for both task lanes.
--  Lightweight callers suspend on readiness; native callers block their
--  thread in poll(2). Callers must synchronize concurrent use and close of the
--  same socket.
--
--  Interrupt sets are the raw composition hook for independent lifecycle
--  sources such as connection close, server shutdown, and per-operation
--  cancellation. Readability interrupts the socket operation; this package
--  does not consume or close a member, and every owner must outlive the call.
--
--  Example:
--
--     Flyology.IO.Sockets.Receive (Socket, Buffer, Last, Timeout => 1.0);
package Flyology.IO.Sockets is

   --  Raised when a member of the operation's interrupt set becomes readable.
   Operation_Interrupted : exception;

   --  Return Socket's operating-system descriptor without transferring
   --  ownership.
   --  @param Socket Socket to inspect
   --  @return Borrowed descriptor; the socket remains its owner
   function Native_Descriptor
     (Socket : GNAT.Sockets.Socket_Type) return Descriptor;

   --  Enable nonblocking mode. All other operations call Prepare themselves.
   --  @param Socket Open socket to configure
   --  @exception GNAT.Sockets.Socket_Error Socket configuration fails
   procedure Prepare (Socket : GNAT.Sockets.Socket_Type);

   --  Receive one available chunk. Negative Timeout means no limit; zero is an
   --  immediate poll, and one deadline spans EINTR/readiness retries. Optional
   --  interrupt descriptors are observed for readability but not consumed.
   --  @param Socket Open connected socket
   --  @param Item Destination buffer
   --  @param Last Last element received, or Item'First - 1 on orderly closure
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The deadline expires before readiness
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Readiness polling fails
   --  @exception GNAT.Sockets.Socket_Error Socket receive or setup fails
   procedure Receive
     (Socket  : GNAT.Sockets.Socket_Type;
      Item    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Fill Item or raise. One Timeout deadline spans every partial receive and
   --  retry. Lane and interrupt behavior match Receive.
   --  @param Socket Open connected socket
   --  @param Item Destination buffer to fill
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Polling fails or peer closes before completion
   --  @exception GNAT.Sockets.Socket_Error Socket receive or setup fails
   procedure Receive_Exactly
     (Socket  : GNAT.Sockets.Socket_Type;
      Item    : out Ada.Streams.Stream_Element_Array;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Send one available chunk. Timeout and interrupt behavior match Receive;
   --  one deadline spans EINTR/readiness retries.
   --  @param Socket Open connected socket
   --  @param Item Source buffer
   --  @param Last Last element sent, or Item'First - 1 if none
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The deadline expires before readiness
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Readiness polling fails
   --  @exception GNAT.Sockets.Socket_Error Socket send or setup fails
   procedure Send
     (Socket  : GNAT.Sockets.Socket_Type;
      Item    : Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Send all of Item or raise. One Timeout deadline spans every partial send
   --  and retry. Lane and interrupt behavior match Send.
   --  @param Socket Open connected socket
   --  @param Item Source buffer to send completely
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The shared deadline expires
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Polling fails or no forward progress is made
   --  @exception GNAT.Sockets.Socket_Error Socket send or setup fails
   procedure Send_All
     (Socket  : GNAT.Sockets.Socket_Type;
      Item    : Ada.Streams.Stream_Element_Array;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Accept one connection and configure it for Flyology I/O. Aborted
   --  backlog entries and protocol-level admission errors are retried.
   --  Process or system descriptor exhaustion is retried with exponential
   --  backoff capped at 50 milliseconds; interrupt descriptors remain part of
   --  that wait. Other listener errors fail. Timeout and interrupt behavior
   --  match Receive, with one deadline across all retries and backoff.
   --  @param Server Open listening socket; ownership is retained
   --  @param Socket Newly accepted socket owned by the caller on return
   --  @param Address Accepted peer address
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The deadline expires before an accept
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Readiness polling fails
   --  @exception GNAT.Sockets.Socket_Error Accept or socket setup fails
   procedure Accept_Connection
     (Server  : GNAT.Sockets.Socket_Type;
      Socket  : out GNAT.Sockets.Socket_Type;
      Address : out GNAT.Sockets.Sock_Addr_Type;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre => Interrupts'Length < Max_Wait_Requests;

   --  Connect Socket to Server. A nonblocking connect waits for write
   --  readiness and checks the socket error. One deadline spans retries.
   --  @param Socket Open unconnected socket; ownership is retained
   --  @param Server Destination address
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Independent readable lifecycle wake descriptors
   --  @exception Timeout_Error The deadline expires before connection
   --  @exception Operation_Interrupted An interrupt descriptor is readable
   --  @exception Device_Error Readiness polling fails
   --  @exception GNAT.Sockets.Socket_Error Connect or socket setup fails
   procedure Connect
     (Socket  : GNAT.Sockets.Socket_Type;
      Server  : GNAT.Sockets.Sock_Addr_Type;
      Timeout    : Duration := Infinite;
      Interrupts : Interrupt_Set := No_Interrupts)
     with Pre => Interrupts'Length < Max_Wait_Requests;

end Flyology.IO.Sockets;
