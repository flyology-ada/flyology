with Ada.Finalization;
with Ada.Strings.Unbounded;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Regions;
with Interfaces;
with Interfaces.C;
with System;

--  Owns shareable backing objects and process-local shared mappings. Linking
--  this package performs no mapping, descriptor, scheduler, or poller work.
--  Create, open, close, unlink, map, unmap, and flush are synchronous metadata
--  or virtual-memory operations. They may occupy a lightweight task's event-
--  loop pthread; use a native-task boundary when that latency is unacceptable.

package Flyology.Shared_Memory is

   use type Interfaces.C.int;

   --  Raised when an operating-system backing or mapping operation fails.
   Operating_System_Error : exception;

   --  Raised when an exact size, object type, or namespace invariant fails.
   Validation_Error : exception;

   --  Raised when a requested descriptor security property is unavailable.
   Security_Error : exception;

   --  Fixed-width byte length shared with relocatable data structures.
   subtype Byte_Length is Flyology.Data_Structures.Byte_Count;

   --  POSIX permission bits accepted when creating named or file objects.
   subtype Permission_Bits is Interfaces.Unsigned_32 range 0 .. 8#777#;

   --  Kind of backing object represented by an owned descriptor.
   --  @enum Anonymous_Capability Anonymous memfd on Linux or immediately
   --     unlinked POSIX shared-memory object on Darwin
   --  @enum Named_POSIX Named POSIX shared-memory object
   --  @enum File_Backed Regular file opened without following symlinks where
   --     the host supports that flag
   --  @enum Received_Capability Descriptor received through SCM_RIGHTS
   type Backing_Kind is (Anonymous_Capability, Named_POSIX, File_Backed, Received_Capability);

   --  Security properties verified on the live descriptor.
   --  @field Close_On_Exec FD_CLOEXEC is set
   --  @field Size_Immutable Linux grow, shrink, and further-seal seals are set
   --  @field No_Execute_Seal Linux MFD_NOEXEC_SEAL was accepted by the kernel
   --  @field No_Execute_Seal_Supported The running Linux kernel recognized
   --     MFD_NOEXEC_SEAL
   --  @field No_Symlink_Follow File opening used O_NOFOLLOW
   --  @field Owner_Only_Permissions Group and other permission bits are clear;
   --     Linux memfd objects are capability-only but normally report this as
   --     False because their inode mode bits are not the access boundary
   type Security_Properties is record
      Close_On_Exec             : Boolean := False;
      Size_Immutable            : Boolean := False;
      No_Execute_Seal           : Boolean := False;
      No_Execute_Seal_Supported : Boolean := False;
      No_Symlink_Follow         : Boolean := False;
      Owner_Only_Permissions    : Boolean := False;
   end record;

   --  Result of opening a namespace object that another process may still be
   --  sizing. Initialization_In_Progress leaves the output object closed.
   --  @enum Created_New This caller created and exactly sized the object
   --  @enum Opened_Existing An existing object passed exact-size validation
   --  @enum Initialization_In_Progress The object exists but still has zero
   --     length; retry only at an application-selected scheduling point
   type Namespace_Open_Result is (Created_New, Opened_Existing, Initialization_In_Progress);

   --  Limited owner of one backing descriptor. Close is independent of any
   --  mappings already created from the descriptor. Finalization attempts a
   --  non-raising close but never unlinks a named object or file.
   type Backing_Object is limited private;

   --  Limited owner of one process-local shared read/write mapping. The
   --  mapping never requests execute permission. Every structure and region
   --  view borrowing its bytes must detach before Unmap or finalization.
   type Mapping is limited private;

   --  Create anonymous capability-backed storage at an exact positive size.
   --  Linux always requires immutable size seals and tries MFD_NOEXEC_SEAL,
   --  falling back only when the running kernel does not recognize it. Darwin
   --  uses an unpredictable exclusive mode-0600 POSIX shm name and unlinks it
   --  before returning. Contents remain writable through shared mappings.
   --  @param Item Closed owner that receives the new descriptor
   --  @param Length Exact positive byte length
   --  @param Require_No_Execute_Seal Reject hosts without an applied Linux
   --     no-execute seal
   --  @exception Constraint_Error Length is zero or not natively representable
   --  @exception Security_Error A required seal or descriptor property fails
   --  @exception Operating_System_Error Creation or exact sizing fails
   procedure Create_Anonymous
     (Item : in out Backing_Object; Length : Byte_Length; Require_No_Execute_Seal : Boolean := False);

   --  Exclusively create and exactly size a named POSIX shared-memory object.
   --  The name must begin with one slash and contain no other slash. Close
   --  does not unlink it; call Unlink explicitly.
   --  @param Item Closed owner that receives the new descriptor
   --  @param Name POSIX shared-memory name
   --  @param Length Exact positive byte length
   --  @param Permissions Requested creation permissions, normally 0600
   --  @exception Constraint_Error Name or length is invalid
   --  @exception Operating_System_Error Exclusive creation or sizing fails
   procedure Create_Named
     (Item        : in out Backing_Object;
      Name        : String;
      Length      : Byte_Length;
      Permissions : Permission_Bits := 8#600#);

   --  Open an existing named object only when its size exactly matches.
   --  A zero-sized object is reported as initialization in progress and Item
   --  remains closed. Any other size mismatch fails closed.
   --  @param Item Closed owner that receives a ready descriptor
   --  @param Name POSIX shared-memory name
   --  @param Expected_Length Required positive byte length
   --  @param Result Existing-ready or initialization-in-progress result
   --  @exception Constraint_Error Name or length is invalid
   --  @exception Validation_Error Type or nonzero size does not match
   --  @exception Operating_System_Error Opening or validation fails
   procedure Open_Named
     (Item            : in out Backing_Object;
      Name            : String;
      Expected_Length : Byte_Length;
      Result          : out Namespace_Open_Result);

   --  Exclusively create a named object or open the winner's object. An
   --  opener racing the creator before exact sizing receives
   --  Initialization_In_Progress with Item closed; bytes are never repaired
   --  or overwritten by an opener.
   --  @param Item Closed owner that receives a ready descriptor
   --  @param Name POSIX shared-memory name
   --  @param Length Exact required byte length
   --  @param Result Created, opened, or initialization-in-progress result
   --  @param Permissions Requested permissions when this caller creates
   --  @exception Constraint_Error Name or length is invalid
   --  @exception Validation_Error Existing type or nonzero size does not match
   --  @exception Operating_System_Error Namespace or sizing operation fails
   procedure Create_Or_Open_Named
     (Item        : in out Backing_Object;
      Name        : String;
      Length      : Byte_Length;
      Result      : out Namespace_Open_Result;
      Permissions : Permission_Bits := 8#600#);

   --  Exclusively create and exactly size a regular file without following a
   --  final symlink where supported. Close does not unlink the path.
   --  @param Item Closed owner that receives the new descriptor
   --  @param Path Nonempty file path without a NUL byte
   --  @param Length Exact positive byte length
   --  @param Permissions Requested creation permissions, normally 0600
   --  @exception Constraint_Error Path or length is invalid
   --  @exception Validation_Error The created object is not a regular file
   --  @exception Operating_System_Error Creation or sizing fails
   procedure Create_File
     (Item        : in out Backing_Object;
      Path        : String;
      Length      : Byte_Length;
      Permissions : Permission_Bits := 8#600#);

   --  Open an existing regular file without following a final symlink where
   --  supported and require its exact size.
   --  @param Item Closed owner that receives the descriptor
   --  @param Path Nonempty file path without a NUL byte
   --  @param Expected_Length Required positive byte length
   --  @exception Constraint_Error Path or length is invalid
   --  @exception Validation_Error Object type or size does not match
   --  @exception Operating_System_Error Opening or validation fails
   procedure Open_File (Item : in out Backing_Object; Path : String; Expected_Length : Byte_Length);

   --  Remove Item's named POSIX object or file namespace entry. Where the host
   --  exposes stable object identity, reject a name that no longer identifies
   --  Item's open descriptor. Callers must always exclude concurrent unlink-
   --  and-replacement until this call returns: identity comparison and unlink
   --  are separate operations, and Darwin POSIX shm descriptors expose no
   --  stable identity for this comparison. The call is explicit, idempotent
   --  after success, and independent of live mappings. Anonymous objects are
   --  already unlinked or unnamed.
   --  @param Item Owned backing object whose saved namespace entry is removed
   --  @exception Validation_Error Item is closed or the name was replaced
   --  @exception Operating_System_Error Unlinking fails
   procedure Unlink (Item : in out Backing_Object);

   --  Close Item's descriptor. The operation is idempotent and does not
   --  invalidate live mappings or unlink namespace entries.
   --  @param Item Descriptor owner to close
   --  @exception Operating_System_Error Closing reports an error
   procedure Close (Item : in out Backing_Object);

   --  Report whether Item owns an open descriptor.
   --  @param Item Owner to inspect
   --  @return True while Close has not consumed the descriptor
   function Is_Open (Item : Backing_Object) return Boolean;

   --  Return the exactly validated object length.
   --  @param Item Open owner to inspect
   --  @return Exact byte length, or zero while closed
   function Length (Item : Backing_Object) return Byte_Length;

   --  Return the recorded backing kind.
   --  @param Item Open owner to inspect
   --  @return Backing kind established at creation, open, or receive
   --  @exception Validation_Error Item is closed
   function Kind (Item : Backing_Object) return Backing_Kind;

   --  Return descriptor properties verified when Item was acquired.
   --  @param Item Open owner to inspect
   --  @return Verified security properties
   --  @exception Validation_Error Item is closed
   function Properties (Item : Backing_Object) return Security_Properties;

   --  Map the complete backing object shared, readable, and writable at an
   --  operating-system-selected address. No fixed address or execute
   --  permission is requested.
   --  @param Item Closed mapping owner that receives the mapping
   --  @param Source Open backing object borrowed only for this call
   --  @exception Validation_Error Item is mapped or Source is closed
   --  @exception Operating_System_Error Mapping fails
   procedure Map (Item : in out Mapping; Source : Backing_Object);

   --  Flush dirty mapping pages according to the selected synchronous or
   --  asynchronous msync policy. For file-backed durability, also call Flush
   --  on the backing object. Neither operation supplies crash-consistent
   --  application transactions.
   --  @param Item Live mapping to flush
   --  @param Synchronous Wait for page writeback when True
   --  @exception Validation_Error Item is not mapped
   --  @exception Operating_System_Error Flushing fails
   procedure Flush (Item : Mapping; Synchronous : Boolean := True);

   --  Request descriptor-level persistence with fsync. This is meaningful for
   --  file-backed objects and is not an application transaction protocol.
   --  @param Item Open backing object to flush
   --  @exception Validation_Error Item is closed
   --  @exception Operating_System_Error Flushing fails
   procedure Flush (Item : Backing_Object);

   --  Attach a process-local Data_Structures region view to the complete
   --  mapping without exposing its native address. Detach every nested
   --  structure view and Region before unmapping.
   --  @param Item Live mapping borrowed by Region
   --  @param Region Detached region view to attach
   --  @exception Validation_Error Item is not mapped
   procedure Attach_Region (Item : Mapping; Region : in out Flyology.Data_Structures.Regions.View);

   --  Unmap Item. The operation is idempotent and independent of the backing
   --  descriptor, but all borrowed views must already be detached.
   --  @param Item Mapping owner to release
   --  @exception Operating_System_Error Unmapping fails
   procedure Unmap (Item : in out Mapping);

   --  Report whether Item owns a live mapping.
   --  @param Item Mapping owner to inspect
   --  @return True after Map and before Unmap
   function Is_Mapped (Item : Mapping) return Boolean;

   --  Return the live mapping length, or zero while unmapped.
   --  @param Item Mapping owner to inspect
   --  @return Complete mapped byte length
   function Length (Item : Mapping) return Byte_Length;

private
   package C renames Interfaces.C;
   package Unbounded renames Ada.Strings.Unbounded;

   type Backing_Object is limited new Ada.Finalization.Limited_Controlled with record
      Descriptor         : C.int := -1;
      Length_Value       : Byte_Length := 0;
      Kind_Value         : Backing_Kind := Anonymous_Capability;
      Property_Value     : Security_Properties := (others => False);
      Namespace_Value    : Unbounded.Unbounded_String;
      Namespace_Is_POSIX : Boolean := False;
      May_Initialize     : Boolean := False;
   end record;

   --  @exclude Controlled finalization hook
   --  @param Item Descriptor owner finalized without raising
   overriding
   procedure Finalize (Item : in out Backing_Object);

   type Mapping_State is new Ada.Finalization.Limited_Controlled with record
      Base           : System.Address := System.Null_Address;
      Length_Value   : Byte_Length := 0;
      May_Initialize : Boolean := False;
   end record;

   --  @exclude Controlled finalization hook
   --  @param Item Mapping state finalized without raising
   overriding
   procedure Finalize (Item : in out Mapping_State);

   type Mapping is limited record
      State : Mapping_State;
   end record;

   --  Private child-package support for SCM_RIGHTS.
   --  @exclude Private child-package descriptor adoption
   --  @param Item Closed descriptor owner
   --  @param Descriptor Validated received descriptor
   --  @param Length Exact received length
   --  @param Properties Verified descriptor properties
   procedure Adopt_Received
     (Item       : in out Backing_Object;
      Descriptor : C.int;
      Length     : Byte_Length;
      Properties : Security_Properties);
   --  @exclude Private child-package received descriptor validation
   --  @param Descriptor Newly received descriptor to inspect
   --  @param Expected_Length Exact locally selected length
   --  @param Require_Immutable_Size Whether immutable size seals are required
   --  @param Properties Verified properties returned on success
   procedure Validate_Received
     (Descriptor             : C.int;
      Expected_Length        : Byte_Length;
      Require_Immutable_Size : Boolean;
      Properties             : out Security_Properties);
   --  @exclude Private child-package descriptor access
   --  @param Item Open descriptor owner
   --  @return Owned native descriptor
   function Owned_Descriptor (Item : Backing_Object) return C.int;
   --  @exclude Private child-package mapping access
   --  @param Item Mapping to inspect
   --  @return Process-local mapping base
   function Mapping_Base (Item : Mapping) return System.Address;
   --  @exclude Private child-package mapping access
   --  @param Item Mapping to inspect
   --  @return Exact mapping length
   function Mapping_Length (Item : Mapping) return Byte_Length;
   --  @exclude Private child-package initialization authority
   --  @param Item Mapping to inspect
   --  @return Whether exclusive backing creation authorizes zero claim
   function Mapping_May_Initialize (Item : Mapping) return Boolean;

end Flyology.Shared_Memory;
