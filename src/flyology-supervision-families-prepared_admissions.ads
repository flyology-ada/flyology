with Ada.Finalization;
with Flyology.Operations;

--  Adds an explicitly prepared, non-runnable admission boundary to one
--  Families instance.  The parent Family retains its existing fixed slot
--  capacity; no manager is queued until Release_To_Run commits that cut.

generic
   --  Must be True. The instance raises Program_Error during elaboration when
   --  request assignment or cleanup may raise after provider publication.
   Request_Assignment_And_Cleanup_Are_Nonraising : Boolean;
package Flyology.Supervision.Families.Prepared_Admissions is

   Operation_Cancelled : exception renames Flyology.Operations.Operation_Cancelled;

   type Prepare_Result is
     (Start_Prepared, Start_Admission_Closed, Start_Capacity_Exhausted, Start_Generation_Exhausted);
   type Commit_Result is (Start_Committed, Start_Admission_Closed);
   type Release_Result is private;
   Admission_Released  : constant Release_Result;
   Admission_Cancelled : constant Release_Result;

   type Start_Claim (Owner : not null access Family) is limited private;
   type Started_Admission (Owner : not null access Family) is limited private;

   --  Each claim or admission object has one externally serialized owner.
   --  Calls that read or mutate the same object must not overlap. Operations
   --  on distinct objects may proceed concurrently; Family protects their
   --  shared bounded provider state.

   --  Construct a vacant controlled reservation target.
   --  @param Owner Family whose storage must outlive the target
   --  @return Vacant claim bound to Owner
   function Vacant_Start_Claim (Owner : not null access Family) return Start_Claim;
   --  Construct a vacant controlled committed-admission target.
   --  @param Owner Family whose storage must outlive the target
   --  @return Vacant admission bound to Owner
   function Vacant_Started_Admission (Owner : not null access Family) return Started_Admission;

   --  Report whether the externally serialized claim structurally owns its
   --  exact prepared slot.
   --  @param Item Claim inspected without changing ownership
   --  @return True only while Item owns one prepared slot
   function Is_Active (Item : Start_Claim) return Boolean;
   --  Report whether the externally serialized admission structurally owns
   --  its exact admission epoch.
   --  @param Item Admission inspected without changing ownership
   --  @return True until exact cancellation/join clears the owner
   function Is_Active (Item : Started_Admission) return Boolean;
   --  Report whether release has committed execution ownership for this exact
   --  active admission. The caller externally serializes Item with release or
   --  cancellation.
   --  @param Item Admission inspected without changing ownership
   --  @return True only after its successful Release_To_Run cut
   function Is_Released (Item : Started_Admission) return Boolean;
   --  Return the exact first-generation handle reserved by this prepared
   --  claim. Commit_Start preserves the identity value when it transfers
   --  admission ownership to a Started_Admission.
   --  @param Item Active prepared claim whose first generation is requested
   --  @return Exact first-generation child handle for Item
   function First_Handle (Item : Start_Claim) return Child_Handle
   with Pre => Is_Active (Item);
   --  Return the exact first-generation handle reserved for this admission
   --  epoch. Later replacements retain the same logical child identity but
   --  advance its generation.
   --  @param Item Active admission whose first generation is requested
   --  @return Exact first-generation child handle for Item
   function First_Handle (Item : Started_Admission) return Child_Handle
   with Pre => Is_Active (Item);

   --  Reserve one exact non-runnable slot and copy Input into it. Result is
   --  total after Item/Claim provenance and vacancy validation. Only
   --  Start_Prepared occupies Claim; every other result leaves it vacant.
   --  @param Item Accepting family
   --  @param Input Request copied into unpublished fixed storage
   --  @param Claim Vacant same-family ownership target
   --  @param Result Prepared, closed, capacity, or generation outcome
   --  @exception Program_Error Claim is occupied or belongs to another family
   procedure Prepare_Start
     (Item   : not null access Family;
      Input  : Request;
      Claim  : in out Start_Claim;
      Result : out Prepare_Result);

   --  Move an exact prepared reservation into a blocked admission. A closed
   --  result retains Claim so rollback/finalization remains authoritative.
   --  @param Claim Active prepared owner, cleared only on Start_Committed
   --  @param Admission Vacant same-family target
   --  @param Result Commit or closed outcome
   --  @exception Program_Error Targets are vacant/occupied inconsistently or
   --     belong to different families
   procedure Commit_Start
     (Claim : in out Start_Claim; Admission : in out Started_Admission; Result : out Commit_Result);

   --  Queue an exact blocked admission. Repeated release after success is
   --  idempotent. Admission_Cancelled retains the active admission owner.
   --  @param Admission Active committed owner
   --  @param Result Caller-aliased result published in the release cut
   --  @exception Program_Error Admission is vacant or stale
   procedure Release_To_Run (Admission : in out Started_Admission; Result : not null access Release_Result);

   --  Nonraising idempotent cleanup of an exact prepared claim.
   --  @param Claim Claim to clear, if active
   procedure Rollback (Claim : in out Start_Claim);
   --  Nonraising idempotent cancellation and join of one exact admission
   --  epoch. This may wait for a released manager, but never joins slot reuse.
   --  @param Admission Admission owner cleared after its exact epoch joins
   procedure Cancel_And_Join (Admission : in out Started_Admission);

   --  First-class wait for one exact generation within Admission's exact
   --  admission epoch. Set and Owner storage must outlive Operation. Admission
   --  must be active, released, and owned by Owner only during initiation; the
   --  bounded monitor ticket retains the epoch afterward.
   --  @exclude
   type Observation_State (Owner : not null access Family) is limited private;

   type Observation_Operation
     (Set   : not null access Flyology.Operations.Completion_Set'Class;
      Owner : not null access Family)
   is new Flyology.Operations.Operation (Set) with record
      Provider : Observation_State (Owner);
   end record;

   --  Eagerly start one exact-admission observation. A negative Timeout waits
   --  indefinitely; zero attempts once; a positive value is a relative
   --  deadline. The operation retains one family monitor ticket while pending.
   --  @param Set Completion set that must outlive the result
   --  @param Owner Exact same Family as Admission
   --  @param Admission Active released admission, borrowed only for initiation
   --  @param Observed Exact generation within Admission's epoch
   --  @param Timeout Relative wait policy in seconds
   --  @return Active or immediately terminal scoped observation
   --  @exception Program_Error Invalid admission or owner
   --  @exception Stale_Handle Observed is outside the exact admission epoch
   --  @exception Constraint_Error Completion-set or monitor capacity exhausted
   function Observe_Exact
     (Set       : not null access Flyology.Operations.Completion_Set'Class;
      Owner     : not null access Family;
      Admission : Started_Admission;
      Observed  : Child_Handle;
      Timeout   : Duration := -1.0) return Observation_Operation;

   --  Rearm a vacant operation with the same semantics as the function form.
   --  @param Admission Active released admission
   --  @param Observed Exact generation within Admission's epoch
   --  @param Timeout Relative wait policy in seconds
   --  @param Operation Vacant operation bound to the same Family
   --  @exception Program_Error Invalid admission or owner
   --  @exception Stale_Handle Observed is outside the exact admission epoch
   --  @exception Constraint_Error Completion-set or monitor capacity exhausted
   procedure Observe_Exact
     (Admission : Started_Admission;
      Observed  : Child_Handle;
      Timeout   : Duration := -1.0;
      Operation : in out Observation_Operation)
   with
     Pre =>
       not Flyology.Operations.Is_Active (Operation) and then not Flyology.Operations.Is_Terminal (Operation);

   --  Consume one terminal operation and publish its copied observation.
   --  @param Operation Terminal observation to release
   --  @param Observation Exact terminal/replacement fact or timeout
   --  @exception Operation_Cancelled Operation was explicitly cancelled
   --  @exception Program_Error Provider failure was retained
   procedure Finish (Operation : in out Observation_Operation; Observation : out Generation_Observation);

private
   type Release_Result is record
      Succeeded : aliased Boolean := False;
   end record;

   Admission_Released  : constant Release_Result := (Succeeded => True);
   Admission_Cancelled : constant Release_Result := (Succeeded => False);

   type Claim_Owner (Owner : not null access Family) is limited new Ada.Finalization.Limited_Controlled
   with record
      Slot   : aliased Slot_Index := Slot_Index'First;
      Handle : aliased Child_Handle;
      Active : aliased Boolean := False;
   end record;

   overriding
   procedure Finalize (Item : in out Claim_Owner);

   type Start_Claim (Owner : not null access Family) is limited record
      State : Claim_Owner (Owner);
   end record;

   type Admission_Owner (Owner : not null access Family) is limited new Ada.Finalization.Limited_Controlled
   with record
      Slot     : aliased Slot_Index := Slot_Index'First;
      Handle   : aliased Child_Handle;
      Active   : aliased Boolean := False;
      Released : aliased Boolean := False;
   end record;

   overriding
   procedure Finalize (Item : in out Admission_Owner);

   type Started_Admission (Owner : not null access Family) is limited record
      State : Admission_Owner (Owner);
   end record;

   type Observation_Failure is (No_Failure, Invalid_Admission, Monitor_Failure);

   type Observation_State (Owner : not null access Family) is limited record
      Admission            : Child_Handle;
      Observed             : Child_Handle;
      Ticket               : aliased Monitor_Index := Monitor_Index'First;
      Token                : aliased Monitor_Token := 0;
      Active               : aliased Boolean := False;
      Status               : Generation_Observation_Status := Observation_Timed_Out;
      Snapshot             : Child_Snapshot;
      Failure              : Observation_Failure := No_Failure;
      Cancellation_Pending : Boolean := False;
   end record;

   overriding
   procedure Drive (Item : in out Observation_Operation; Event : Flyology.Operations.Driver_Event);
   overriding
   procedure Request_Cancellation (Item : in out Observation_Operation);

end Flyology.Supervision.Families.Prepared_Admissions;
