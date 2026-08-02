with Gnatevl.Wake_Sources;
with Interfaces.C;

package Gnatevl.Cancellation is
   pragma Preelaborate;

   Operation_Cancelled : exception;

   --  A one-shot cancellation source shared by every task-aware I/O domain.
   --  The object must outlive operations using it. Request is idempotent;
   --  finalization releases the underlying wake descriptors.
   protected type Token is
      procedure Request;
      function Requested return Boolean;
      procedure Wait_Source
        (FD : out Interfaces.C.int; Already_Requested : out Boolean);
   private
      Is_Requested : Boolean := False;
      Wake         : Gnatevl.Wake_Sources.Source;
   end Token;
end Gnatevl.Cancellation;
