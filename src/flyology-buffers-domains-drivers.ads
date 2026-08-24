with Ada.Streams;

--  Definite access-free buffer ownership used by bounded provider storage.
--  Every operation that touches storage takes and validates the owning domain.
--  Application code should use Domains.Owned_Buffer instead.
--  @exclude

package Flyology.Buffers.Domains.Drivers is

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
   type Buffer_Capability is limited record
      Reference : aliased Pool_Reference := Invalid_Pool;
      Token     : aliased Buffer_Token := No_Token;
   end record;

end Flyology.Buffers.Domains.Drivers;
