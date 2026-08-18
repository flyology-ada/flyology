with Interfaces.C;

--  Supplies readiness primitives shared by lightweight and native tasks.
--
--  Example:
--
--     if Flyology.IO.Wait (FD, Flyology.IO.For_Read, 0.0) then
--        null;
--     end if;
package Flyology.IO with Preelaborate is

   --  Conventional negative timeout denoting no time limit. All negative
   --  Duration values have the same meaning in this API.
   Infinite : constant Duration := -1.0;

   --  Raised by higher-level I/O operations when one deadline expires.
   Timeout_Error : exception;
   --  Raised when descriptor validation, polling, or a device operation fails.
   Device_Error  : exception;

   --  Native operating-system descriptor number.
   subtype Descriptor is Interfaces.C.int;
   --  Sentinel denoting no descriptor.
   Invalid_Descriptor : constant Descriptor := Interfaces.C.int (-1);
   --  Maximum number of descriptors in one allocation-free Wait_Any call.
   Max_Wait_Requests : constant := 32;
   --  Caller index positions in one Wait_Any request set. The subtype bounds
   --  each element position rather than the element count, so every array
   --  and slice must lie inside 1 .. Max_Wait_Requests.
   subtype Wait_Index is Positive range 1 .. Max_Wait_Requests;
   --  Caller index positions in one interrupt set. An interruptible wait
   --  spends request position 1 on its primary descriptor, so an interrupt
   --  set admits one position fewer than a complete request set.
   subtype Interrupt_Index is Positive range 1 .. Max_Wait_Requests - 1;
   --  Readable wake descriptors composed into an interruptible wait. The
   --  wait observes but never reads or closes them; their owners must outlive
   --  the call. Interrupt_Index constrains the position of every member.
   type Interrupt_Set is array (Interrupt_Index range <>) of Descriptor;
   --  Empty interrupt set used when no wake source is present.
   No_Interrupts : constant Interrupt_Set (1 .. 0) :=
     (others => Invalid_Descriptor);
   --  Readiness condition requested from the poller.
   --  @enum For_Read The descriptor can be read without blocking
   --  @enum For_Write The descriptor can be written without blocking
   type Wait_Kind is (For_Read, For_Write);
   --  Result from an interruptible wait.
   --  @enum Ready The primary descriptor became ready
   --  @enum Timed_Out The deadline expired
   --  @enum Interrupted A member of the interrupt set became readable
   type Wait_Outcome is (Ready, Timed_Out, Interrupted);

   --  One descriptor readiness request.
   --  @field FD Descriptor to observe
   --  @field Condition Read or write readiness to observe
   type Wait_Request is record
      FD        : Descriptor;
      Condition : Wait_Kind;
   end record;
   --  Caller-indexed set passed to Wait_Any. Wait_Index constrains the
   --  position of every member.
   type Wait_Request_Array is array (Wait_Index range <>) of Wait_Request;

   --  Report whether the calling Ada task uses a Flyology event loop.
   --  @return True for a lightweight task; False for a native task
   function Is_Lightweight_Task return Boolean;

   --  Wait until FD is ready or Timeout seconds expire. Negative means no
   --  limit; zero performs an immediate poll. A lightweight task suspends on
   --  its event loop; a native task blocks its thread in poll(2). Retries
   --  after
   --  EINTR share the original deadline.
   --  @param FD Valid descriptor to observe
   --  @param Condition Requested readiness condition
   --  @param Timeout Deadline interval in seconds
   --  @return True when ready; False on timeout
   --  @exception Device_Error FD is invalid or the poller fails
   function Wait
     (FD        : Descriptor;
      Condition : Wait_Kind;
      Timeout   : Duration := Infinite) return Boolean;

   --  Wait until one request is ready. Negative Timeout means no limit and
   --  zero is an immediate poll. One deadline spans EINTR retries. Duplicate
   --  descriptors and read/write pairs are supported; the lowest caller index
   --  wins simultaneous readiness. No descriptor is consumed. Lightweight
   --  tasks suspend; native tasks block their thread.
   --  @param Requests Readiness requests positioned within Wait_Index
   --  @param Timeout Deadline interval in seconds
   --  @return Exact Requests index ready, or 0 on timeout or empty input
   --  @exception Device_Error A descriptor is invalid or polling fails
   function Wait_Any
     (Requests : Wait_Request_Array;
      Timeout  : Duration := Infinite) return Natural;

   --  Wait for FD or any readable interrupt source. Interrupt
   --  descriptors are neither read nor closed. Timeout and lane behavior
   --  match Wait; one deadline spans native EINTR retries.
   --  @param FD Primary valid descriptor
   --  @param Condition Primary readiness condition
   --  @param Timeout Deadline interval in seconds
   --  @param Interrupts Readable wake descriptors positioned within
   --     Interrupt_Index
   --  @return Ready, Timed_Out, or Interrupted
   --  @exception Device_Error FD is invalid or the poller fails
   function Wait_Interruptibly
     (FD          : Descriptor;
      Condition   : Wait_Kind;
      Timeout     : Duration := Infinite;
      Interrupts  : Interrupt_Set := No_Interrupts) return Wait_Outcome;

end Flyology.IO;
