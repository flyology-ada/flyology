with Ada.Finalization;
with Interfaces;

--  Publishes bounded typed service availability without storing application
--  payloads or access-to-task values. A published lease identifies one exact
--  supervisor controller and child generation. Application service operations
--  must validate that lease inside the same protected object that owns the
--  corresponding endpoint state.
--  @formal Service_Kind Application enumeration of published services
--  @formal Logical_Id Stable child identity associated with each service
generic
   type Service_Kind is (<>);
   with function Logical_Id (Service : Service_Kind) return Child_Id;

package Flyology.Supervision.Service_Slots is

   --  Raised when two service kinds use the same logical child identity.
   Configuration_Error : exception;

   --  Fixed service directory. Storage is determined by Service_Kind and no
   --  publication, lookup, or revocation allocates memory.
   type Directory is limited private;

   --  Copyable authority to one exact published generation. A lease contains
   --  no application endpoint and cannot extend any task or resource lifetime.
   type Service_Lease is private;

   --  Availability returned by a service lookup.
   --  @enum Unavailable No generation is currently published for the service
   --  @enum Available Lease contains the exact published generation
   type Availability_Status is (Unavailable, Available);

   --  Atomic fixed service lookup.
   --  @field Status Whether a generation was published
   --  @field Lease Exact published generation when Status is Available
   type Service_Observation
     (Status : Availability_Status := Unavailable)
   is record
      case Status is
         when Unavailable =>
            null;
         when Available =>
            Lease : Service_Lease;
      end case;
   end record;

   --  Controlled ownership of one publication. Finalization revokes only the
   --  exact publication created through this object; it cannot withdraw a
   --  replacement generation or another publisher's entry.
   --  @field From Directory that must outlive the publication
   type Publication (From : not null access Directory) is limited private;

   --  Reserve Service for Control's exact generation, report readiness, then
   --  atomically make its lease available until Item is withdrawn or
   --  finalized. Duplicate and logical-child validation occurs before
   --  readiness changes. Item's access discriminant makes From's lifetime an
   --  Ada accessibility constraint. No application callback is invoked and no
   --  allocation is performed.
   --  @param Item Publication owner bound to its directory
   --  @param Service Typed service being published
   --  @param Control Exact generation providing the ready service
   --  @exception Program_Error Item is active, Control names another logical
   --     child, Service already has a live publication, or readiness was
   --     already reported or stopping began
   procedure Publish_Ready
     (Item    : in out Publication;
      Service : Service_Kind;
      Control : in out Generation_Control);

   --  Revoke Item's exact publication. This is idempotent and cannot revoke a
   --  later publication. Call it before releasing the service resources when
   --  performing an orderly stop; finalization supplies the failure path.
   --  @param Item Publication to withdraw
   procedure Withdraw (Item : in out Publication);

   --  Report whether Item currently owns a publication.
   --  @param Item Publication owner to inspect
   --  @return True after Publish_Ready and before Withdraw or finalization
   function Active (Item : Publication) return Boolean;

   --  Atomically copy the current lease for Service.
   --  @param From Directory to inspect
   --  @param Service Typed service to acquire
   --  @return Available with an exact lease, or Unavailable
   function Acquire
     (From    : Directory;
      Service : Service_Kind) return Service_Observation;

   --  Check whether Lease remains the exact publication for its service.
   --  This is useful for observation and routing. It is not a substitute for
   --  validating the lease within the protected operation that mutates the
   --  application endpoint.
   --  @param From Directory that issued Lease
   --  @param Lease Exact service lease to validate
   --  @return True only while the same publication remains current
   function Current
     (From  : Directory;
      Lease : Service_Lease) return Boolean;

   --  Return the typed service represented by Lease.
   --  @param Lease Published service lease
   --  @return Service key carried by Lease
   function Service (Lease : Service_Lease) return Service_Kind;

   --  Return the exact controller-qualified generation represented by Lease.
   --  @param Lease Published service lease
   --  @return Child handle carried by Lease
   function Handle (Lease : Service_Lease) return Child_Handle;

private
   subtype Publication_Token is Interfaces.Unsigned_64;

   type Service_Lease is record
      Kind  : Service_Kind := Service_Kind'First;
      Value : Child_Handle;
   end record;

   type Published_Array is array (Service_Kind) of Boolean;
   type Handle_Array is array (Service_Kind) of Child_Handle;
   type Token_Array is array (Service_Kind) of Publication_Token;

   protected type Directory_State is
      procedure Next_Token (Value : out Publication_Token);
      procedure Reserve
        (Kind     : Service_Kind;
         Value    : Child_Handle;
         Token    : Publication_Token;
         Accepted : out Boolean);
      procedure Activate
        (Kind  : Service_Kind;
         Value : Child_Handle;
         Token : Publication_Token);
      procedure Revoke
        (Kind  : Service_Kind;
         Value : Child_Handle;
         Token : Publication_Token);
      function Acquire (Kind : Service_Kind) return Service_Observation;
      function Current (Lease : Service_Lease) return Boolean;
   private
      Published : Published_Array := (others => False);
      Claimed   : Published_Array := (others => False);
      Handles   : Handle_Array;
      Tokens    : Token_Array := (others => 0);
      Last_Token : Publication_Token := 0;
   end Directory_State;

   type Directory is limited record
      State : aliased Directory_State;
   end record;

   type Publication (From : not null access Directory) is
     limited new Ada.Finalization.Limited_Controlled with record
      Kind   : Service_Kind := Service_Kind'First;
      Value  : Child_Handle;
      Token  : Publication_Token := 0;
      Owned  : Boolean := False;
   end record;

   --  @exclude
   --  @param Item Publication finalized during normal or exceptional cleanup
   overriding procedure Finalize (Item : in out Publication);

end Flyology.Supervision.Service_Slots;
