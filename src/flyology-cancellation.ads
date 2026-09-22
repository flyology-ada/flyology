private with Ada.Finalization;
with Flyology.Wake_Sources;
with Interfaces.C;

--  Supplies the shared one-shot cancellation identity used by task-aware I/O.
--  Tokens are safe to call from multiple Ada tasks and must outlive every
--  operation that borrows their wake source.
--
--  Example:
--
--     Stop : aliased Flyology.Cancellation.Token;
--     Stop.Request;

package Flyology.Cancellation is
   pragma Preelaborate;

   --  Reports terminal cancellation. File I/O raises this only after the
   --  kernel has relinquished the caller's buffer.
   Operation_Cancelled : exception;

   --  Entry-bearing view for an abortable select. The Token must outlive the
   --  selected call. Use Stop.Wait_Event.Await_Request as the trigger.
   type Request_Waiter is synchronized interface;
   --  Wait until the one-shot request state becomes terminal.
   --  @param Item Entry-bearing cancellation state to wait on
   procedure Await_Request (Item : in out Request_Waiter) is abstract;
   pragma Implemented (Await_Request, By_Entry);

   --  Thread-safe one-shot source. Request is idempotent and cannot be reset.
   --  Finalization releases lazily created wake descriptors after all
   --  borrowing operations have left scope.
   type Token is tagged limited private;

   --  Record cancellation and wake every operation waiting on this token.
   --  Program_Error is raised when an existing borrowed wake descriptor
   --  cannot be signalled. Cancellation remains recorded when signalling
   --  fails. The signal and any EINTR retry occur after the state lock exits.
   --  @param Item Token on which to record cancellation
   procedure Request (Item : in out Token);

   --  Wait until Request records terminal cancellation. Task-only waiting
   --  does not allocate a descriptor.
   --  @param Item Token on which to wait
   procedure Await_Request (Item : in out Token);

   --  Borrow the protected entry for an abortable select.
   --  @param Item Token that must outlive the select
   --  @return Entry-bearing view of Item's one-shot state
   function Wait_Event (Item : aliased in out Token) return not null access Request_Waiter'Class;

   --  Inspect the one-shot state without allocating a wake descriptor.
   --  @param Item Token to inspect
   --  @return True once Request records cancellation, including when wake
   --     signaling subsequently fails
   function Requested (Item : Token) return Boolean;

   --  Borrow the readable wake descriptor. Ownership remains with Token;
   --  callers must not close it, and Token must outlive the wait. No
   --  descriptor is allocated when cancellation was already requested.
   --  Descriptor creation occurs outside the protected state lock.
   --  @param Item Token that owns the borrowed descriptor
   --  @param FD Borrowed descriptor, or -1 when already requested
   --  @param Already_Requested True when Request preceded this call
   --  @exception Program_Error Wake descriptor creation fails
   procedure Wait_Source (Item : in out Token; FD : out Interfaces.C.int; Already_Requested : out Boolean);

private
   type Signal_Guard is new Ada.Finalization.Limited_Controlled with record
      Descriptor : Interfaces.C.int := Interfaces.C.int (-1);
      Armed      : Boolean := False;
   end record;

   --  @exclude Controlled signal-claim finalization hook
   --  @param Guard Signal claim to complete without raising
   overriding
   procedure Finalize (Guard : in out Signal_Guard);

   type Initialization_Guard;
   protected type Token_State is new Request_Waiter with
      procedure Record_Request (Guard : not null access Signal_Guard);
      overriding entry Await_Request;
      function Requested return Boolean;
      procedure Begin_Wait
        (Guard : not null access Initialization_Guard;
         FD : out Interfaces.C.int;
         Already_Requested : out Boolean);
      entry Wait_Ready (FD : out Interfaces.C.int; Already_Requested : out Boolean);
      procedure Publish_Wake (FD, Signal_FD : Interfaces.C.int);
      procedure Cancel_Initialization;
      procedure Reset_For_Reuse;
   private
      Is_Requested : Boolean := False;
      Initializing : Boolean := False;
      Read_FD      : Interfaces.C.int := Interfaces.C.int (-1);
      Write_FD     : Interfaces.C.int := Interfaces.C.int (-1);
   end Token_State;

   type State_Access is access all Token_State;
   type Initialization_Guard is new Ada.Finalization.Limited_Controlled with record
      State : State_Access := null;
      Armed : Boolean := False;
   end record;

   --  @exclude Controlled initialization-claim finalization hook
   --  @param Guard Initialization claim to cancel without raising
   overriding
   procedure Finalize (Guard : in out Initialization_Guard);

   type Token is tagged limited record
      State : aliased Token_State;
      Wake  : Flyology.Wake_Sources.Source;
   end record;
end Flyology.Cancellation;
