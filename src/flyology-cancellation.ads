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

   --  Thread-safe one-shot source. Request is idempotent and cannot be reset.
   --  Finalization releases lazily created wake descriptors after all
   --  borrowing operations have left scope.
   protected type Token is
      --  Record cancellation and wake every operation waiting on this token.
      --  Raises Program_Error when wake descriptor creation or signaling
      --  fails.
      procedure Request;
      --  Inspect the one-shot state without allocating a wake descriptor.
      --  @return True after Request has completed
      function Requested return Boolean;
      --  Borrow the readable wake descriptor. Ownership remains with Token;
      --  callers must not close it, and Token must outlive the wait. No
      --  descriptor is allocated when cancellation was already requested.
      --  @param FD Borrowed descriptor, or -1 when already requested
      --  @param Already_Requested True when Request preceded this call
      --  @exception Program_Error Wake descriptor creation fails
      procedure Wait_Source
        (FD : out Interfaces.C.int; Already_Requested : out Boolean);
   private
      Is_Requested : Boolean := False;  --  One-shot state
      Wake         : Flyology.Wake_Sources.Source;  --  Owned readiness source
   end Token;
end Flyology.Cancellation;
