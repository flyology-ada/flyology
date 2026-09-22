--  Internal reuse boundary for an exclusively owned, quiescent token.
--  The caller must exclude all descriptor, request, and entry borrowers;
--  Reset releases the previous descriptor generation before clearing the
--  one-shot request state. Native executors enforce this with slot ownership
--  and cancellation-claim drainage. This unit is not a general cancellation
--  restart facility.
package Flyology.Cancellation.Reuse is
   procedure Reset (Item : in out Token);
end Flyology.Cancellation.Reuse;
