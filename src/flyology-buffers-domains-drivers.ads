with Ada.Finalization;
with Ada.Streams;

--  Definite access-free buffer ownership used by bounded provider storage.
--  Every operation that touches storage takes and validates the owning domain.
--  Application code should use Domains.Owned_Buffer instead.
--  @exclude

package Flyology.Buffers.Domains.Drivers is

   type Reservation_Result is
     (Reservation_Acquired, Reservation_In_Use, Reservation_Generation_Exhausted);

   type Release_Preparation_Result is
     (Release_Prepared, Live_Claims_Remain, Release_Already_Acknowledged);

   --  Controlled precommit ownership of one newly reserved pool generation.
   --  Finalization rolls an uncommitted exact reservation back to Available
   --  at the same generation.
   type Reservation_Claim (Domain : not null access Buffer_Domain)
   is limited new Ada.Finalization.Limited_Controlled with private;

   --  Try to reserve Pool without waiting. Claim must be vacant. A successful
   --  gate action writes authority directly into Claim, so abort before caller
   --  result copy-out still leaves the controlled Claim responsible for
   --  rollback. The base-pool snapshot is conservative; a stale nonzero
   --  snapshot may report Reservation_In_Use and callers may retry.
   --  Available with zero claims and a fresh empty base snapshot succeeds,
   --  including at the final generation. Claims, a nonempty snapshot,
   --  Reserved, or Released_Pending_Ack report Reservation_In_Use;
   --  Permanently_Exhausted reports Reservation_Generation_Exhausted.
   procedure Reserve
     (Claim  : in out Reservation_Claim;
      Pool   : Pool_Reference;
      Result : out Reservation_Result);

   function Has_Reservation (Claim : Reservation_Claim) return Boolean;

   --  Publish Claim into an unpublished context-record field. Target must be
   --  vacant and exclusively owned by an existing context transition claim:
   --  the record is Admitting/initializing, no lookup, close, or liveness path
   --  may observe Target, and an admission guard already owns rollback. Call
   --  with no context lock held. Only a later context protected action may
   --  publish the record Active.
   procedure Commit_Reservation
     (Claim : in out Reservation_Claim; Target : aliased in out Pool_Reservation);

   --  Roll back an unpublished reservation while the same context transition
   --  claim remains exclusive. The gate returns the pool to Available at the
   --  same generation and clears Target atomically before the context record
   --  is restored or retired. Repeating with a vacant Target is inert.
   procedure Rollback_Reservation
     (Domain : not null access Buffer_Domain; Target : aliased in out Pool_Reservation);

   --  Domain-bound resumable release token. Prepare writes one exact pending
   --  generation into a caller-declared vacant token. Unauthorized
   --  finalization leaves the domain pending so cleanup can prepare again;
   --  authorized finalization acknowledges as a nonraising fallback.
   type Reservation_Release (Domain : not null access Buffer_Domain)
   is limited new Ada.Finalization.Limited_Controlled with private;

   --  Prepare requires a vacant Token before domain mutation. An older
   --  generation or the exact exhausted generation reports
   --  Release_Already_Acknowledged. Exact Reserved with zero claims becomes
   --  pending and reports Release_Prepared; exact Pending reissues the token.
   --  A conservative nonempty base snapshot or exact live claims reports
   --  Live_Claims_Remain. Exact Available, future, invalid, or foreign input
   --  raises Program_Error. Unauthorized token finalization keeps Pending.
   procedure Prepare_Release
     (Token       : in out Reservation_Release;
      Reservation : Pool_Reservation;
      Result      : out Release_Preparation_Result);

   function Has_Release (Token : Reservation_Release) return Boolean;

   --  Pure value check used by the context before its final retirement cut.
   function Matches
     (Token : Reservation_Release; Reservation : Pool_Reservation) return Boolean;

   function Is_Authorized (Token : Reservation_Release) return Boolean;

   --  Validate exact nonvacant correspondence and perform only a no-fail
   --  scalar write. The caller must invoke this within the context protected
   --  action that simultaneously retires the matching session. This operation
   --  never enters the domain gate.
   procedure Authorize
     (Token : in out Reservation_Release; Reservation : Pool_Reservation);

   --  Acknowledge only an authorized nonvacant token outside the context lock.
   --  Vacant or unauthorized tokens raise Program_Error without entering or
   --  mutating the domain gate and remain unchanged.
   --  An older token or exact exhausted duplicate is cleared inertly. Exact
   --  Pending advances to Available or becomes permanently exhausted and then
   --  clears the token. Exact Available, Reserved, or future authority raises
   --  Program_Error without clearing it.
   procedure Acknowledge (Token : in out Reservation_Release);

   --  Return held and acquisition-in-progress claims for one exact pool.
   --  This diagnostic supports bounded coordination and does not grant
   --  reservation or storage authority.
   function Active_Claims
     (Domain : not null access Buffer_Domain; Pool : Pool_Reference) return Natural;

   --  One pool token without an Ada access component. A capability must be
   --  contained by a domain-bound controlled owner that releases it. A source
   --  used by Move_To, Move, or Release must be an aliased component or object
   --  as required by those formals; aliasing does not add a stored access.
   type Buffer_Capability is limited private;

   --  Move from a domain-bound public owner into provider storage.
   --  Validation failure raises Program_Error without changing either owner.
   --  Unwinding before the abort-deferred commit restores Item; unwinding
   --  after it leaves Target as the sole owner.
   --  @param Domain Exact owning domain
   --  @param Item Acquired source, vacant after commit
   --  @param Target Vacant definite capability receiving ownership
   procedure Move_From
     (Domain : not null access Buffer_Domain;
      Item   : in out Owned_Buffer;
      Target : in out Buffer_Capability);

   --  Move provider storage into a vacant public owner.
   --  Validation failure raises Program_Error without changing either owner.
   --  Unwinding before commit restores Source; unwinding after commit leaves
   --  Item as the sole owner.
   --  @param Domain Exact owning domain
   --  @param Source Acquired capability, vacant after commit
   --  @param Item Vacant domain-bound target
   procedure Move_To
     (Domain : not null access Buffer_Domain;
      Source : aliased in out Buffer_Capability;
      Item   : in out Owned_Buffer);

   --  Move between definite provider carriers.
   --  Validation failure raises Program_Error without changing either owner.
   --  Unwinding before commit restores Source; unwinding after commit leaves
   --  Target as the sole owner.
   --  @param Domain Exact owning domain
   --  @param Source Acquired capability, vacant after commit
   --  @param Target Vacant capability receiving ownership
   procedure Move
     (Domain : not null access Buffer_Domain;
      Source : aliased in out Buffer_Capability;
      Target : in out Buffer_Capability);

   --  Release provider storage to its exact pool.
   --  A foreign Domain raises Program_Error and leaves Item unchanged.
   --  Validation precedes the abort-deferred ownership commit. After commit,
   --  Item remains vacant while normal or unwinding cleanup returns the exact
   --  slot to its pool.
   --  @param Domain Exact owning domain
   --  @param Item Capability relinquishing ownership
   procedure Release
     (Domain : not null access Buffer_Domain; Item : aliased in out Buffer_Capability);

   --  @param Item Capability to inspect
   --  @return True only while Item owns a token
   function Has_Buffer (Item : Buffer_Capability) return Boolean;

   --  @param Domain Candidate owning domain
   --  @param Item Capability to inspect
   --  @return True only for an acquired capability from Domain
   function Belongs_To
     (Domain : not null access Buffer_Domain; Item : Buffer_Capability) return Boolean;

   --  Return Item's exact pool.
   --  @param Domain Exact owning domain
   --  @param Item Acquired capability
   --  @return Validated pool reference
   --  @exception Program_Error Item is vacant, foreign, or invalid
   function Buffer_Pool
     (Domain : not null access Buffer_Domain; Item : Buffer_Capability) return Pool_Reference;

   --  Return exact reserved provenance, or Invalid_Reservation for an ordinary
   --  acquired capability.
   function Buffer_Reservation
     (Domain : not null access Buffer_Domain; Item : Buffer_Capability)
      return Pool_Reservation;

   --  @param Domain Exact owning domain
   --  @param Item Acquired capability
   --  @return Initialized payload length
   --  @exception Program_Error Item is vacant, foreign, or invalid
   function Length
     (Domain : not null access Buffer_Domain; Item : Buffer_Capability) return Natural;

   --  @param Domain Exact owning domain
   --  @param Item Acquired capability
   --  @return Selected pool block size
   --  @exception Program_Error Item is vacant, foreign, or invalid
   function Capacity
     (Domain : not null access Buffer_Domain; Item : Buffer_Capability) return Positive;

   --  Borrow initialized bytes for Process's dynamic extent. Process may not
   --  retain an address into Data. Exceptions propagate without moving or
   --  releasing the capability.
   --  @param Domain Exact owning domain
   --  @param Item Acquired capability
   --  @param Process Synchronous payload observer
   --  @exception Program_Error Item is vacant, foreign, or invalid
   procedure With_Readable_Data
     (Domain  : not null access Buffer_Domain;
      Item    : Buffer_Capability;
      Process : not null access procedure (Data : Ada.Streams.Stream_Element_Array));

private
   type Reservation_Claim (Domain : not null access Buffer_Domain)
   is limited new Ada.Finalization.Limited_Controlled with record
      Reference : aliased Pool_Reservation := Invalid_Reservation;
   end record;

   overriding
   procedure Finalize (Claim : in out Reservation_Claim);

   type Reservation_Release (Domain : not null access Buffer_Domain)
   is limited new Ada.Finalization.Limited_Controlled with record
      Reference      : aliased Pool_Reservation := Invalid_Reservation;
      Ack_Authorized : Boolean := False;
   end record;

   overriding
   procedure Finalize (Token : in out Reservation_Release);

   type Buffer_Capability is limited record
      Reference   : aliased Pool_Reference := Invalid_Pool;
      Reservation : aliased Pool_Reservation := Invalid_Reservation;
      Token       : aliased Buffer_Token := No_Token;
   end record;

end Flyology.Buffers.Domains.Drivers;
