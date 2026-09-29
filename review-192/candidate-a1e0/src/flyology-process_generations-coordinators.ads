with Ada.Finalization;
with Flyology.Cancellation;
with Flyology.IO.Sockets;
with Flyology.Process_Generations.Messages;
with Flyology.Subprocesses;
private with Flyology.IO.Socket_Handoffs;
private with Flyology.Process_Generations.Transport;

--  Stable owner for one listener escrow, one active image, and at most one
--  candidate. Operations are synchronous and must be externally serialized;
--  each returns only after its protocol boundary is acknowledged.

package Flyology.Process_Generations.Coordinators is
   --  Launch, protocol, application, or image-lifecycle operation failed.
   Upgrade_Error      : exception;
   --  Supplied transaction authority does not match the active upgrade.
   Stale_Authority    : exception;
   --  Requested operation is not valid in the current lifecycle phase.
   Invalid_Phase      : exception;
   --  A nonwrapping upgrade or generation identifier is exhausted.
   Identity_Exhausted : exception;

   --  Maximum retained failure-message size.
   Maximum_Failure_Length : constant Positive := 256;
   --  Significant retained failure-message length.
   subtype Failure_Length is Natural range 0 .. Maximum_Failure_Length;
   --  Fixed storage for a bounded failure message.
   type Failure_Buffer is array (Positive range 1 .. Maximum_Failure_Length) of Character;

   --  Point-in-time observation of coordinator state.
   --  @field Initialized Listener escrow and identity are initialized
   --  @field Phase Current transaction phase
   --  @field Authority Current or most recently completed authority
   --  @field Has_Active An active image slot is occupied
   --  @field Active_Generation Active image generation when present
   --  @field Has_Candidate A candidate image slot is occupied
   --  @field Candidate_Generation Candidate generation when present
   --  @field Candidate_Ready Candidate supplied matching readiness evidence
   --  @field Candidate_Admitted Candidate can accept new connections
   --  @field Rollback_Available A previous artifact can be restarted fresh
   --  @field Desired_Topology_Epoch Desired topology epoch
   --  @field Desired_Topology_Digest Desired topology digest
   --  @field Compensation Latest cancellation compensation observation
   --  @field Failure_Size Significant bytes in Failure
   --  @field Failure Fixed storage for the latest bounded failure message
   type Coordinator_Snapshot is record
      Initialized             : Boolean := False;
      Phase                   : Upgrade_Phase := Stable;
      Authority               : Upgrade_Handle := (Coordinator => 1, Upgrade => 1, Candidate => 1);
      Has_Active              : Boolean := False;
      Active_Generation       : Image_Generation := 1;
      Has_Candidate           : Boolean := False;
      Candidate_Generation    : Image_Generation := 1;
      Candidate_Ready         : Boolean := False;
      Candidate_Admitted      : Boolean := False;
      Rollback_Available      : Boolean := False;
      Desired_Topology_Epoch  : Messages.Nonzero_U64 := 1;
      Desired_Topology_Digest : Messages.Topology_Digest := (others => 0);
      Compensation            : Compensation_Result := Not_Required;
      Failure_Size            : Failure_Length := 0;
      Failure                 : Failure_Buffer := (others => ' ');
   end record;

   --  Extract the significant retained failure text.
   --  @param Item Coordinator snapshot
   --  @return Failure text, or an empty string when no failure is retained
   function Failure_Message (Item : Coordinator_Snapshot) return String;

   --  Stable owner of listener escrow and managed image slots.
   type Coordinator is new Ada.Finalization.Limited_Controlled with private;

   --  Transfer a bound listening socket into stable coordinator escrow.
   --  @param Item Uninitialized coordinator
   --  @param Identity Stable nonzero coordinator identity
   --  @param Listener Bound listener whose ownership is transferred
   --  @param First_Upgrade First nonwrapping transaction identity
   --  @param First_Generation First nonwrapping process-generation identity
   procedure Initialize
     (Item             : in out Coordinator;
      Identity         : Coordinator_Id;
      Listener         : in out Flyology.IO.Sockets.Socket_Type;
      First_Upgrade    : Upgrade_Id := 1;
      First_Generation : Image_Generation := 1)
   with Post => not Flyology.IO.Sockets.Is_Open (Listener);

   --  Capture current coordinator state. The observation reconciles and reaps
   --  any managed image whose terminal process state is already available.
   --  @param Item Initialized coordinator
   --  @return Point-in-time state observation
   function Snapshot (Item : in out Coordinator) return Coordinator_Snapshot;

   --  Spawn, authenticate, provision, and hand a borrowed listener duplicate
   --  to a candidate. The server is not started and cannot accept on return.
   --  @param Item Initialized coordinator with no candidate
   --  @param Executable Candidate executable and launch context
   --  @param Provision Desired topology and candidate role
   --  @param Authority Newly allocated transaction authority
   --  @param Timeout Total startup and provisioning timeout
   --  @param Token Optional one-shot cancellation source
   procedure Start_Upgrade
     (Item       : in out Coordinator;
      Executable : Flyology.Subprocesses.Command;
      Provision  : Messages.Provisioning_Data;
      Authority  : out Upgrade_Handle;
      Timeout    : Duration := 30.0;
      Token      : access Flyology.Cancellation.Token := null);

   --  Start candidate admission and wait for exact accepting/topology proof.
   --  @param Item Coordinator holding the prepared candidate
   --  @param Authority Exact current transaction authority
   --  @param Timeout Total activation and readiness timeout
   --  @param Token Optional one-shot cancellation source
   procedure Begin_Canary
     (Item      : in out Coordinator;
      Authority : Upgrade_Handle;
      Timeout   : Duration := 30.0;
      Token     : access Flyology.Cancellation.Token := null);

   --  Revoke and drain a prepared or canary candidate. During a canary the
   --  compensation hook runs after quiescence. The active image is untouched.
   --  @param Item Coordinator holding the candidate
   --  @param Authority Exact current transaction authority
   --  @param Compensation Observed application compensation outcome
   --  @param Timeout Total cancellation timeout
   procedure Cancel
     (Item         : in out Coordinator;
      Authority    : Upgrade_Handle;
      Compensation : out Compensation_Result;
      Timeout      : Duration := 30.0);

   --  Commit the candidate, then drain and reap the previous active image.
   --  Any failure after this call begins is classified Rollback_Required.
   --  @param Item Coordinator holding the ready candidate
   --  @param Authority Exact current transaction authority
   --  @param Timeout Total promotion and previous-image drain timeout
   procedure Promote (Item : in out Coordinator; Authority : Upgrade_Handle; Timeout : Duration := 30.0);

   --  Convenience for bootstrapping the first managed active image.
   --  @param Item Initialized coordinator with no active image
   --  @param Executable Initial executable and launch context
   --  @param Provision Desired topology and active role
   --  @param Authority Newly allocated initial transaction authority
   --  @param Timeout Total startup, readiness, and promotion timeout
   --  @param Token Optional one-shot cancellation source
   procedure Start_Initial
     (Item       : in out Coordinator;
      Executable : Flyology.Subprocesses.Command;
      Provision  : Messages.Provisioning_Data;
      Authority  : out Upgrade_Handle;
      Timeout    : Duration := 30.0;
      Token      : access Flyology.Cancellation.Token := null);

   --  Retire every image implicated in a completed or uncertain promotion,
   --  then start a fresh process from the retained previous artifact and
   --  topology. No old Ada runtime, task, or connection is resurrected.
   --  @param Item Coordinator with a retained previous artifact
   --  @param Authority Newly allocated rollback transaction authority
   --  @param Timeout Total fencing and fresh-image startup timeout
   procedure Rollback_To_Previous
     (Item : in out Coordinator; Authority : out Upgrade_Handle; Timeout : Duration := 30.0);

   --  Cleanly drain every managed image when possible, then release listener
   --  escrow. Cleanup failures are reported after all slots are attempted.
   --  @param Item Coordinator to shut down
   --  @param Timeout Total drain timeout for each managed image
   procedure Shutdown (Item : in out Coordinator; Timeout : Duration := 30.0);

private
   package Sockets renames Flyology.IO.Sockets;
   package Handoffs renames Flyology.IO.Socket_Handoffs;
   package Transport renames Flyology.Process_Generations.Transport;

   type Slot_Index is range 0 .. 1;
   type Image_Slot is limited record
      Occupied     : Boolean := False;
      Generation   : Image_Generation := 1;
      Child        : Flyology.Subprocesses.Process;
      Control      : Transport.Control_Channel;
      Capabilities : Handoffs.Handoff_Channel;
      Artifact     : Flyology.Subprocesses.Command;
      Provision    : Messages.Provisioning_Data :=
        (Application_Signature => 1,
         Topology_Schema       => 1,
         Topology_Epoch        => 1,
         Digest                => (others => 0),
         Role                  => Canary_Safe);
   end record;
   type Slot_Array is array (Slot_Index) of Image_Slot;

   type Coordinator is new Ada.Finalization.Limited_Controlled with record
      State                : Coordinator_Snapshot;
      Identity             : Coordinator_Id := 1;
      Next_Upgrade         : Upgrade_Id := 1;
      Next_Generation      : Image_Generation := 1;
      Upgrade_Exhausted    : Boolean := False;
      Generation_Exhausted : Boolean := False;
      Listener             : Sockets.Socket_Type;
      Slots                : Slot_Array;
      Active_Slot          : Slot_Index := 0;
      Candidate_Slot       : Slot_Index := 0;
      Rollback_Artifact    : Flyology.Subprocesses.Command;
      Rollback_Provision   : Messages.Provisioning_Data :=
        (Application_Signature => 1,
         Topology_Schema       => 1,
         Topology_Epoch        => 1,
         Digest                => (others => 0),
         Role                  => Canary_Safe);
   end record;

   --  Release managed resources without propagating cleanup failures.
   --  @param Item Coordinator owner being finalized
   overriding
   procedure Finalize (Item : in out Coordinator);
end Flyology.Process_Generations.Coordinators;
