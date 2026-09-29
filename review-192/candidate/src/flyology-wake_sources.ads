with Ada.Finalization;
with Interfaces.C;

package Flyology.Wake_Sources is
   pragma Preelaborate;

   --  Provides a readable one-shot descriptor for protected cancellation
   --  state.
   --
   --  Example:
   --
   --     Flyology.Wake_Sources.Signal (Wake);

   --  Controlled owner of a lazily created descriptor pair. Operations on the
   --  Source object are intentionally unsynchronized: place Source inside a
   --  protected object or otherwise serialize every call. Concurrent
   --  Signal_Borrowed calls may use a previously borrowed descriptor only
   --  while that external lifetime claim excludes Ensure, Release, and
   --  finalization. Finalize releases both descriptors.
   type Source is new Ada.Finalization.Limited_Controlled with private;

   --  Lazily allocate a nonblocking close-on-exec descriptor pair. Repeated
   --  calls before Release are harmless.
   --  @param Item Serialized source to initialize
   --  @exception Program_Error Descriptor creation or configuration fails
   procedure Ensure (Item : in out Source);
   --  Make Item's read end ready. Repeated signals remain readable until
   --  Consume or Release; this operation does not consume or close the source.
   --  @param Item Serialized source to signal
   --  @exception Program_Error Descriptor creation or signaling fails
   procedure Signal (Item : in out Source);
   --  Signal through the borrowed write descriptor returned by
   --  Signal_Descriptor. The Source must outlive the call. EINTR is retried;
   --  the nonblocking EAGAIN case is a coalesced success. This operation
   --  retains and closes no descriptor and must not be called while holding a
   --  protected lock because an unbounded signal sequence may delay retry.
   --  @param Descriptor Borrowed live write descriptor; concurrent borrowed
   --     signals are permitted while the owning Source cannot be released
   --  @exception Program_Error Descriptor is invalid or signaling fails
   procedure Signal_Borrowed (Descriptor : Interfaces.C.int);
   --  Result of one borrowed-descriptor signal attempt.
   --  @enum Signal_Delivered One byte was written or readiness was already
   --     coalesced by a full nonblocking source
   --  @enum Signal_Interrupted The one syscall was interrupted before writing
   --  @enum Signal_Failed The descriptor or syscall result was invalid
   type Signal_Attempt_Result is (Signal_Delivered, Signal_Interrupted, Signal_Failed);
   --  Attempt exactly one nonblocking borrowed-descriptor signal. EAGAIN is a
   --  coalesced success, EINTR is reported for an outside-lock retry, and all
   --  other invalid or failed writes are reported without raising. Unlike
   --  Signal_Borrowed, this operation performs exactly one O_NONBLOCK
   --  one-byte syscall with no retry, allocation, callback, or retained state,
   --  so it may form one bounded protected cut. Retry Signal_Interrupted only
   --  after leaving that protected action.
   --  @param Descriptor Borrowed live write descriptor
   --  @return Result of the single syscall attempt
   function Try_Signal_Borrowed (Descriptor : Interfaces.C.int) return Signal_Attempt_Result;
   --  Consume one pending signal while retaining the descriptor generation.
   --  @param Item Serialized source with a pending signal
   --  @exception Program_Error No signal is pending or reading fails
   procedure Consume (Item : in out Source);
   --  Consume every signal currently pending while retaining the descriptor
   --  generation. This is intended for coalesced completion notifications;
   --  use Consume when each byte represents one independently counted event.
   --  @param Item Serialized source with at least one pending signal
   --  @exception Program_Error No signal is pending or reading fails
   procedure Consume_All (Item : in out Source);
   --  Close both owned descriptors. Repeated calls are harmless. A later
   --  Ensure creates a new descriptor generation.
   --  @param Item Serialized source whose descriptors are released
   procedure Release (Item : in out Source);
   --  Borrow the current readable descriptor without transferring ownership.
   --  @param Item Source to inspect
   --  @return Read descriptor, or -1 before Ensure or after Release
   function Descriptor (Item : Source) return Interfaces.C.int;

   --  Borrow the descriptor used to signal Item. This is an internal provider
   --  boundary; callers must not read, close, or retain it after Item leaves
   --  scope.
   --  @param Item Initialized source to inspect
   --  @return Signal descriptor, or -1 before Ensure or after Release
   function Signal_Descriptor (Item : Source) return Interfaces.C.int;

private
   type Source is new Ada.Finalization.Limited_Controlled with record
      Read_End  : Interfaces.C.int := Interfaces.C.int (-1);
      Write_End : Interfaces.C.int := Interfaces.C.int (-1);
   end record;

   --  Release Item without propagating close errors.
   --  @param Item Source being finalized
   overriding
   procedure Finalize (Item : in out Source);
end Flyology.Wake_Sources;
