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
   type Pool_Configuration is record
      Block_Size : Positive;
      Capacity   : Positive;
   end record;

   type Pool_Configuration_Array is array (Positive range <>) of Pool_Configuration;

   --  Fixed heterogeneous pool catalogue. Create is the only constructor.
   type Buffer_Domain (<>) is limited private;

   --  Construct a domain and all configured pool storage transactionally.
   --  Configuration must contain at least one pool. Any failed construction
   --  releases every pool that was already created.
   --  @param Configuration Complete pool catalogue in logical index order
   --  @return Domain owning the configured pools and their storage
   function Create (Configuration : Pool_Configuration_Array) return Buffer_Domain
   with Pre => Configuration'Length > 0;

   --  Opaque, process-local reference to one immutable domain catalogue slot.
   type Pool_Reference is private;

   Invalid_Pool : constant Pool_Reference;

   --  Report whether Reference contains a complete nonzero identity.
   --  @param Reference Opaque pool reference to inspect
   --  @return True only for a structurally complete reference
   function Is_Valid (Reference : Pool_Reference) return Boolean;

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
   type Owned_Buffer (Domain : not null access Buffer_Domain)
   is limited new Ada.Finalization.Limited_Controlled with private;

   --  Acquire from Source, waiting until a slot is available.
   --  @param Item Vacant domain-bound owner receiving a slot
   --  @param Source Exact pool selected for acquisition
   --  @exception Program_Error Source is foreign or Item is occupied
   --  Unwinding before the abort-deferred ownership commit leaves Item vacant
   --  and restores the acquired slot. After commit, Item is the sole owner.
   procedure Acquire (Item : in out Owned_Buffer; Source : Pool_Reference)
   with Pre => not Has_Buffer (Item), Post => Has_Buffer (Item) and then Length (Item) = 0;

   --  Attempt acquisition without waiting.
   --  @param Item Vacant domain-bound owner receiving a slot
   --  @param Source Exact pool selected for acquisition
   --  @param Acquired True only when Item received ownership
   --  @exception Program_Error Source is foreign or Item is occupied
   --  Unwinding before the abort-deferred ownership commit leaves Item vacant
   --  and restores the acquired slot. After commit, Item is the sole owner.
   procedure Try_Acquire
     (Item : in out Owned_Buffer; Source : Pool_Reference; Acquired : out Boolean)
   with Pre => not Has_Buffer (Item), Post => Acquired = Has_Buffer (Item);

   --  Acquire within one relative deadline. Negative Timeout waits without a
   --  deadline; zero performs an immediate attempt.
   --  @param Item Vacant domain-bound owner receiving a slot
   --  @param Source Exact pool selected for acquisition
   --  @param Timeout Maximum monotonic wait in seconds
   --  @exception Timeout_Error No slot becomes available before the deadline
   --  @exception Program_Error Source is foreign or Item is occupied
   --  Unwinding before the abort-deferred ownership commit leaves Item vacant
   --  and restores the acquired slot. After commit, Item is the sole owner.
   procedure Acquire_For (Item : in out Owned_Buffer; Source : Pool_Reference; Timeout : Duration)
   with Pre => not Has_Buffer (Item), Post => Has_Buffer (Item) and then Length (Item) = 0;

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
   No_Catalogue_Generation : constant Catalogue_Generation := 0;
   Initial_Catalogue_Generation : constant Catalogue_Generation := 1;

   type Pool_Reference is record
      Domain     : Domain_Identity := No_Domain;
      Slot       : Natural := 0;
      Generation : Catalogue_Generation := No_Catalogue_Generation;
   end record;

   Invalid_Pool : constant Pool_Reference := (others => <>);

   type Pool_Holder (Block_Size : Positive; Capacity : Positive) is limited record
      Storage : aliased Pool (Block_Size, Capacity);
   end record;

   type Pool_Holder_Access is access Pool_Holder;
   type Pool_Holder_Access_Array is array (Positive range <>) of Pool_Holder_Access;

   type Buffer_Domain (Number_Of_Pools : Positive)
   is limited new Ada.Finalization.Limited_Controlled with record
      Identity : Domain_Identity := No_Domain;
      Pools    : Pool_Holder_Access_Array (1 .. Number_Of_Pools) := (others => null);
   end record;

   overriding
   procedure Initialize (Domain : in out Buffer_Domain);

   overriding
   procedure Finalize (Domain : in out Buffer_Domain);

   type Owned_Buffer (Domain : not null access Buffer_Domain)
   is limited new Ada.Finalization.Limited_Controlled with record
      Reference : aliased Pool_Reference := Invalid_Pool;
      Token     : aliased Buffer_Token := No_Token;
   end record;

   overriding
   procedure Finalize (Item : in out Owned_Buffer);

   function Resolve
     (Domain : Buffer_Domain; Reference : Pool_Reference) return Pool_Holder_Access;

   procedure Release_Token
     (Domain : in out Buffer_Domain; Reference : Pool_Reference; Token : in out Buffer_Token);

   procedure Commit_Transfer
     (Source_Reference : not null access Pool_Reference;
      Source_Token     : not null access Buffer_Token;
      Target_Reference : not null access Pool_Reference;
      Target_Token     : not null access Buffer_Token);

   procedure Observe
     (Domain    : Buffer_Domain;
      Reference : Pool_Reference;
      Token     : Buffer_Token;
      Process   : not null access procedure (Data : Ada.Streams.Stream_Element_Array));

end Flyology.Buffers.Domains;
