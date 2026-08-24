with Ada.Finalization;
with Ada.Streams;
with Interfaces;

--  Owns an immutable catalogue of heterogeneous fixed-block buffer pools.
--  Domain-bound public owners and access-free internal capabilities can move
--  one pool token without copying its payload.

package Flyology.Buffers.Domains is

   --  Complete construction parameters for one owned pool.
   --  @field Block_Size Payload capacity of each buffer
   --  @field Capacity Number of independently ownable buffers
   --  @field Maximum_Claims Bound on held and acquisition-in-progress claims;
   --     must be at least Capacity
   type Pool_Configuration is record
      Block_Size     : Positive;
      Capacity       : Positive;
      Maximum_Claims : Positive;
   end record;

   --  Ordered, nonempty catalogue used to construct a domain.
   type Pool_Configuration_Array is array (Positive range <>) of Pool_Configuration;

   --  Fixed heterogeneous pool catalogue. Create is the only constructor.
   type Buffer_Domain (<>) is limited private;

   --  Construct a domain and all configured pool storage transactionally.
   --  Configuration must contain at least one pool. Any failed construction
   --  releases every pool that was already created.
   --  @param Configuration Complete pool catalogue in logical index order
   --  @return Domain owning the configured pools and their storage
   --  @exception Constraint_Error A pool has Maximum_Claims below Capacity
   function Create (Configuration : Pool_Configuration_Array) return Buffer_Domain
   with Pre => Configuration'Length > 0;

   --  Opaque, process-local reference to one immutable domain catalogue slot.
   type Pool_Reference is private;

   --  Sentinel that names no pool.
   Invalid_Pool : constant Pool_Reference;

   --  Opaque authority for one exact reservation generation of one pool.
   --  The value is definite and contains no Ada access component.
   type Pool_Reservation is private;

   --  Sentinel that carries no reservation authority.
   Invalid_Reservation : constant Pool_Reservation;

   --  Total outcome of an ordinary or reservation-qualified acquisition.
   --  Buffer_Acquired is the only outcome that publishes ownership. Pool_Empty
   --  is reachable only from Try_Acquire, while Acquisition_Timed_Out is
   --  reachable only from Acquire_For.
   --  @enum Buffer_Acquired Ownership was published to the destination
   --  @enum Pool_Empty No unowned buffer was immediately available
   --  @enum Acquisition_Timed_Out The admitted timed wait reached its deadline
   --  @enum Pool_Reserved Ordinary acquisition was excluded by a reservation
   --  @enum Reservation_Stale The reservation names an older generation
   --  @enum Reservation_Not_Active The exact reservation has not been published
   --  @enum Reservation_Releasing Release was prepared but not acknowledged
   --  @enum Claim_Limit_Reached The reservation's bounded claim capacity is full
   --  @enum Pool_Permanently_Exhausted The reservation generation cannot advance
   type Acquisition_Result is
     (Buffer_Acquired,
      Pool_Empty,
      Acquisition_Timed_Out,
      Pool_Reserved,
      Reservation_Stale,
      Reservation_Not_Active,
      Reservation_Releasing,
      Claim_Limit_Reached,
      Pool_Permanently_Exhausted);

   --  Report whether Reference contains a complete nonzero identity.
   --  @param Reference Opaque pool reference to inspect
   --  @return True only for a structurally complete reference
   function Is_Valid (Reference : Pool_Reference) return Boolean;

   --  Report whether Reservation contains a complete pool reference and a
   --  nonzero reservation generation.
   --  @param Reservation Opaque reservation reference to inspect
   --  @return True only for a structurally complete reservation
   function Is_Valid (Reservation : Pool_Reservation) return Boolean;

   --  Return the pool named by Reservation, or Invalid_Pool when invalid.
   --  @param Reservation Reservation to inspect
   --  @return Embedded exact pool reference or Invalid_Pool
   function Reserved_Pool (Reservation : Pool_Reservation) return Pool_Reference;

   --  Return the number of pools owned by Domain.
   --  @param Domain Domain to inspect
   --  @return Fixed catalogue size
   function Pool_Count (Domain : Buffer_Domain) return Positive;

   --  Return the reference at one-based logical Index.
   --  @param Domain Domain whose catalogue is selected
   --  @param Index One-based logical catalogue index
   --  @return Exact immutable pool reference
   --  @exception Constraint_Error Index is outside Domain
   function Pool_At (Domain : Buffer_Domain; Index : Positive) return Pool_Reference;

   --  Report whether Reference names an exact pool in Domain.
   --  @param Domain Candidate owning domain
   --  @param Reference Pool reference to validate
   --  @return True only for an exact current catalogue member
   function Belongs_To (Domain : Buffer_Domain; Reference : Pool_Reference) return Boolean;

   --  Return the configured block size of Reference.
   --  @param Domain Owning domain
   --  @param Reference Exact pool reference
   --  @return Payload bytes in each pool slot
   --  @exception Program_Error Reference does not belong to Domain
   function Block_Size (Domain : Buffer_Domain; Reference : Pool_Reference) return Positive;

   --  Return the configured slot capacity of Reference.
   --  @param Domain Owning domain
   --  @param Reference Exact pool reference
   --  @return Number of pool slots
   --  @exception Program_Error Reference does not belong to Domain
   function Capacity (Domain : Buffer_Domain; Reference : Pool_Reference) return Positive;

   --  Return coherent ownership accounting for Reference.
   --  @param Domain Owning domain
   --  @param Reference Exact pool reference
   --  @return Current available and outstanding counts
   --  @exception Program_Error Reference does not belong to Domain
   function Current (Domain : Buffer_Domain; Reference : Pool_Reference) return Pool_Snapshot;

   --  Public single-owner handle tied by accessibility to one domain. A
   --  vacant handle does not select a pool until acquisition or movement.
   type Owned_Buffer (Domain : not null access Buffer_Domain) is limited
     new Ada.Finalization.Limited_Controlled with private;

   --  Acquire from Source, waiting until a slot is available.
   --  @param Item Vacant domain-bound owner receiving a slot
   --  @param Source Exact pool selected for acquisition
   --  @param Result Buffer_Acquired, Pool_Reserved,
   --     Reservation_Releasing, Claim_Limit_Reached, or
   --     Pool_Permanently_Exhausted
   --  @exception Program_Error Source is foreign or Item is occupied
   --  Unwinding before the abort-deferred ownership commit leaves Item vacant
   --  and restores the acquired slot. After commit, Item is the sole owner.
   procedure Acquire (Item : in out Owned_Buffer; Source : Pool_Reference; Result : out Acquisition_Result)
   with Pre => not Has_Buffer (Item), Post => (Result = Buffer_Acquired) = Has_Buffer (Item);

   --  Wait for a slot under one exact active reservation. An older reservation
   --  reports Reservation_Stale; an exact reservation reports
   --  Reservation_Not_Active, Reservation_Releasing, or
   --  Pool_Permanently_Exhausted according to the pool lifecycle. A future,
   --  invalid, or foreign reservation raises Program_Error. Claim exhaustion
   --  rejects immediately even though this is the blocking overload.
   --  @param Item Vacant domain-bound owner receiving a slot
   --  @param Reservation Exact reservation authority
   --  @param Result Total acquisition outcome
   procedure Acquire
     (Item : in out Owned_Buffer; Reservation : Pool_Reservation; Result : out Acquisition_Result)
   with Pre => not Has_Buffer (Item), Post => (Result = Buffer_Acquired) = Has_Buffer (Item);

   --  Attempt acquisition without waiting.
   --  @param Item Vacant domain-bound owner receiving a slot
   --  @param Source Exact pool selected for acquisition
   --  @param Result Buffer_Acquired, Pool_Empty, Pool_Reserved,
   --     Reservation_Releasing, Claim_Limit_Reached, or
   --     Pool_Permanently_Exhausted
   --  @exception Program_Error Source is foreign or Item is occupied
   --  Unwinding before the abort-deferred ownership commit leaves Item vacant
   --  and restores the acquired slot. After commit, Item is the sole owner.
   procedure Try_Acquire
     (Item : in out Owned_Buffer; Source : Pool_Reference; Result : out Acquisition_Result)
   with Pre => not Has_Buffer (Item), Post => (Result = Buffer_Acquired) = Has_Buffer (Item);

   --  Attempt acquisition under one exact active reservation without waiting.
   --  State classification precedes Pool_Empty; claim exhaustion precedes the
   --  base-pool attempt. Invalid, foreign, or future authority raises
   --  Program_Error before the gate is mutated.
   --  @param Item Vacant domain-bound owner receiving a slot
   --  @param Reservation Exact reservation authority
   --  @param Result Total acquisition outcome
   procedure Try_Acquire
     (Item : in out Owned_Buffer; Reservation : Pool_Reservation; Result : out Acquisition_Result)
   with Pre => not Has_Buffer (Item), Post => (Result = Buffer_Acquired) = Has_Buffer (Item);

   --  Acquire within one relative deadline. Negative Timeout waits without a
   --  deadline; zero performs an immediate attempt.
   --  @param Item Vacant domain-bound owner receiving a slot
   --  @param Source Exact pool selected for acquisition
   --  @param Timeout Maximum monotonic wait in seconds
   --  @param Result Buffer_Acquired, Acquisition_Timed_Out, Pool_Reserved,
   --     Reservation_Releasing, Claim_Limit_Reached, or
   --     Pool_Permanently_Exhausted
   --  @exception Program_Error Source is foreign or Item is occupied
   --  Unwinding before the abort-deferred ownership commit leaves Item vacant
   --  and restores the acquired slot. After commit, Item is the sole owner.
   procedure Acquire_For
     (Item    : in out Owned_Buffer;
      Source  : Pool_Reference;
      Timeout : Duration;
      Result  : out Acquisition_Result)
   with Pre => not Has_Buffer (Item), Post => (Result = Buffer_Acquired) = Has_Buffer (Item);

   --  Timed acquisition under one exact active reservation. Claim exhaustion
   --  and reservation-state outcomes reject before waiting; only an admitted
   --  base-pool wait may report Acquisition_Timed_Out.
   --  @param Item Vacant domain-bound owner receiving a slot
   --  @param Reservation Exact reservation authority
   --  @param Timeout Maximum monotonic wait in seconds
   --  @param Result Total acquisition outcome
   procedure Acquire_For
     (Item        : in out Owned_Buffer;
      Reservation : Pool_Reservation;
      Timeout     : Duration;
      Result      : out Acquisition_Result)
   with Pre => not Has_Buffer (Item), Post => (Result = Buffer_Acquired) = Has_Buffer (Item);

   --  Release Item to its selected pool and leave it vacant.
   --  @param Item Owner relinquishing its slot
   --  Validation precedes the abort-deferred ownership commit. After commit,
   --  Item remains vacant while normal or unwinding cleanup returns the exact
   --  slot to its pool.
   procedure Release (Item : in out Owned_Buffer)
   with Post => not Has_Buffer (Item);

   --  Move ownership between vacant/occupied handles of the same domain.
   --  @param Source Acquired owner, vacant after success
   --  @param Target Vacant same-domain owner receiving the slot
   --  @exception Program_Error Owners have different domains or invalid states
   --  Validation precedes mutation. Unwinding before the abort-deferred commit
   --  restores Source; unwinding after it leaves Target as the sole owner.
   procedure Move (Source : in out Owned_Buffer; Target : in out Owned_Buffer)
   with
     Pre  => Has_Buffer (Source) and then not Has_Buffer (Target),
     Post => not Has_Buffer (Source) and then Has_Buffer (Target);

   --  Report whether Item owns a slot.
   --  @param Item Domain-bound owner to inspect
   --  @return True only while Item owns a pool token
   function Has_Buffer (Item : Owned_Buffer) return Boolean;

   --  Return Item's exact pool, or Invalid_Pool when vacant.
   --  @param Item Domain-bound owner to inspect
   --  @return Selected exact pool or Invalid_Pool
   function Buffer_Pool (Item : Owned_Buffer) return Pool_Reference;

   --  Return Item's exact reservation provenance, or Invalid_Reservation for
   --  a vacant or ordinary buffer.
   --  @param Item Domain-bound owner to inspect
   --  @return Exact reservation or Invalid_Reservation
   function Buffer_Reservation (Item : Owned_Buffer) return Pool_Reservation;

   --  Return initialized payload length, or zero while vacant.
   --  @param Item Domain-bound owner to inspect
   --  @return Initialized byte count
   function Length (Item : Owned_Buffer) return Natural;

   --  Return Item's selected pool block size.
   --  @param Item Acquired domain-bound owner
   --  @return Writable payload capacity
   function Buffer_Capacity (Item : Owned_Buffer) return Positive
   with Pre => Has_Buffer (Item);

   --  Set Item's application-defined scalar tag.
   --  @param Item Acquired domain-bound owner
   --  @param Value Application-defined scalar
   procedure Set_Tag (Item : in out Owned_Buffer; Value : Interfaces.Unsigned_64)
   with Pre => Has_Buffer (Item);

   --  Return Item's application tag, or zero while vacant.
   --  @param Item Domain-bound owner to inspect
   --  @return Application-defined scalar
   function Tag (Item : Owned_Buffer) return Interfaces.Unsigned_64;

   --  Borrow initialized payload bytes only for Process's dynamic extent.
   --  @param Item Acquired owner to observe
   --  @param Process Synchronous payload observer
   procedure With_Readable_Data
     (Item : Owned_Buffer; Process : not null access procedure (Data : Ada.Streams.Stream_Element_Array))
   with Pre => Has_Buffer (Item);

   --  Borrow the full writable block. Length commits only after Process
   --  returns normally with a value no greater than the pool block size.
   --  @param Item Acquired owner to modify
   --  @param Process Synchronous payload producer
   --  @exception Constraint_Error Process returns an excessive length
   procedure With_Writable_Data
     (Item    : in out Owned_Buffer;
      Process :
        not null access procedure (Data : in out Ada.Streams.Stream_Element_Array; Length : in out Natural))
   with Pre => Has_Buffer (Item);

   --  Copy Data into Item and set its initialized length.
   --  @param Item Acquired destination owner
   --  @param Data Source payload bytes
   --  @exception Constraint_Error Data exceeds Item's capacity
   procedure Copy_From (Item : in out Owned_Buffer; Data : Ada.Streams.Stream_Element_Array)
   with
     Pre  => Has_Buffer (Item) and then Data'Length <= Buffer_Capacity (Item),
     Post => Length (Item) = Data'Length;

private
   type Domain_Identity is mod 2**64;
   No_Domain : constant Domain_Identity := 0;

   type Catalogue_Generation is mod 2**64;
   No_Catalogue_Generation      : constant Catalogue_Generation := 0;
   Initial_Catalogue_Generation : constant Catalogue_Generation := 1;

   type Pool_Reference is record
      Domain     : Domain_Identity := No_Domain;
      Slot       : Natural := 0;
      Generation : Catalogue_Generation := No_Catalogue_Generation;
   end record;

   Invalid_Pool : constant Pool_Reference := (others => <>);

   subtype Reservation_Generation is Interfaces.Unsigned_64;
   No_Reservation_Generation      : constant Reservation_Generation := 0;
   Initial_Reservation_Generation : constant Reservation_Generation := 1;

   type Pool_Reservation is record
      Pool       : Pool_Reference := Invalid_Pool;
      Generation : Reservation_Generation := No_Reservation_Generation;
   end record;

   Invalid_Reservation : constant Pool_Reservation := (others => <>);

   type Reservation_State is (Available, Reserved, Released_Pending_Ack, Permanently_Exhausted);

   protected type Reservation_Gate (Maximum_Claims : Positive) is
      procedure Begin_Claim
        (Requested         : Pool_Reservation;
         Source            : Pool_Reference;
         Claim_Reference   : not null access Pool_Reference;
         Claim_Reservation : not null access Pool_Reservation;
         Result            : out Acquisition_Result);
      procedure End_Claim
        (Reference : not null access Pool_Reference; Reservation : not null access Pool_Reservation);
      procedure Try_Reserve
        (Reference              : Pool_Reference;
         Base_Empty             : Boolean;
         Force_Final_Generation : Boolean;
         Target                 : not null access Pool_Reservation;
         Reserved_Result        : out Boolean;
         In_Use                 : out Boolean);
      procedure Commit_Reservation
        (Source : not null access Pool_Reservation; Target : not null access Pool_Reservation);
      procedure Rollback_Reservation (Target : not null access Pool_Reservation);
      procedure Prepare_Release
        (Source               : Pool_Reservation;
         Base_Empty           : Boolean;
         Target               : not null access Pool_Reservation;
         Prepared             : out Boolean;
         Live_Claims          : out Boolean;
         Already_Acknowledged : out Boolean);
      procedure Acknowledge (Target : not null access Pool_Reservation; Authorized : Boolean);
      function Valid_Claim (Reservation : Pool_Reservation) return Boolean;
      function State return Reservation_State;
      function Claim_Count return Natural;
   private
      Lifecycle  : Reservation_State := Available;
      Generation : Reservation_Generation := Initial_Reservation_Generation;
      Claims     : Natural := 0;
   end Reservation_Gate;

   type Pool_Holder
     (Block_Size     : Positive;
      Capacity       : Positive;
      Maximum_Claims : Positive)
   is limited record
      Storage : aliased Pool (Block_Size, Capacity);
      Gate    : Reservation_Gate (Maximum_Claims);
   end record;

   type Pool_Holder_Access is access Pool_Holder;
   type Pool_Holder_Access_Array is array (Positive range <>) of Pool_Holder_Access;

   type Buffer_Domain (Number_Of_Pools : Positive) is limited new Ada.Finalization.Limited_Controlled
   with record
      Identity : Domain_Identity := No_Domain;
      Pools    : Pool_Holder_Access_Array (1 .. Number_Of_Pools) := (others => null);
   end record;

   --  @exclude
   --  @param Domain Domain being initialized
   overriding
   procedure Initialize (Domain : in out Buffer_Domain);

   --  @exclude
   --  @param Domain Domain being finalized
   overriding
   procedure Finalize (Domain : in out Buffer_Domain);

   type Owned_Buffer (Domain : not null access Buffer_Domain) is limited
     new Ada.Finalization.Limited_Controlled
   with record
      Reference   : aliased Pool_Reference := Invalid_Pool;
      Reservation : aliased Pool_Reservation := Invalid_Reservation;
      Token       : aliased Buffer_Token := No_Token;
   end record;

   --  @exclude
   --  @param Item Domain-bound owner being finalized
   overriding
   procedure Finalize (Item : in out Owned_Buffer);

   --  @exclude
   --  @param Domain Domain whose catalogue is searched
   --  @param Reference Exact pool reference to resolve
   --  @return Process-local pool holder
   function Resolve (Domain : Buffer_Domain; Reference : Pool_Reference) return Pool_Holder_Access;

   --  @exclude
   --  @param Domain Domain receiving the released slot
   --  @param Reference Exact pool reference, cleared on success
   --  @param Reservation Reservation provenance, cleared on success
   --  @param Token Detached storage token, cleared on success
   procedure Release_Token
     (Domain      : in out Buffer_Domain;
      Reference   : not null access Pool_Reference;
      Reservation : not null access Pool_Reservation;
      Token       : not null access Buffer_Token);

   --  @exclude
   --  @param Source_Reference Source pool reference, cleared on success
   --  @param Source_Reservation Source reservation, cleared on success
   --  @param Source_Token Source storage token, cleared on success
   --  @param Target_Reference Vacant target pool reference
   --  @param Target_Reservation Vacant target reservation
   --  @param Target_Token Vacant target storage token
   procedure Commit_Transfer
     (Source_Reference   : not null access Pool_Reference;
      Source_Reservation : not null access Pool_Reservation;
      Source_Token       : not null access Buffer_Token;
      Target_Reference   : not null access Pool_Reference;
      Target_Reservation : not null access Pool_Reservation;
      Target_Token       : not null access Buffer_Token);

   --  @exclude
   --  @param Domain Domain whose ownership is validated
   --  @param Reference Exact candidate pool reference
   --  @param Reservation Candidate reservation provenance
   --  @return Process-local pool holder
   function Resolve_Ownership
     (Domain : Buffer_Domain; Reference : Pool_Reference; Reservation : Pool_Reservation)
      return Pool_Holder_Access;

   --  @exclude
   --  @param Domain Domain whose storage is observed
   --  @param Reference Exact pool reference
   --  @param Reservation Exact reservation provenance
   --  @param Token Exact storage token
   --  @param Process Synchronous payload observer
   procedure Observe
     (Domain      : Buffer_Domain;
      Reference   : Pool_Reference;
      Reservation : Pool_Reservation;
      Token       : Buffer_Token;
      Process     : not null access procedure (Data : Ada.Streams.Stream_Element_Array));

end Flyology.Buffers.Domains;
