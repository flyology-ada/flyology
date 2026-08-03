with Ada.Finalization;
with Interfaces.C;

package Flyology.Wake_Sources is
   pragma Preelaborate;

   --  Provides a readable one-shot descriptor for protected cancellation
   --  state.
   --
   --  Example:
   --
   --     Flyology.Wake_Sources.Signal (Wake);

   --  Controlled owner of a lazily created descriptor pair. Operations are
   --  intentionally unsynchronized: place Source inside a protected object or
   --  otherwise serialize every call. Finalize releases both descriptors.
   type Source is new Ada.Finalization.Limited_Controlled with private;

   --  Lazily allocate a nonblocking close-on-exec descriptor pair. Repeated
   --  calls before Release are harmless.
   --  @param Item Serialized source to initialize
   --  @exception Program_Error Descriptor creation or configuration fails
   procedure Ensure (Item : in out Source);
   --  Make Item's read end ready. Repeated signals remain readable until
   --  Consume or Release; this operation does not consume or close the source.
   --  @param Item Serialized source to signal
   --  @exception Program_Error Descriptor creation or signaling fails
   procedure Signal (Item : in out Source);
   --  Consume one pending signal while retaining the descriptor generation.
   --  @param Item Serialized source with a pending signal
   --  @exception Program_Error No signal is pending or reading fails
   procedure Consume (Item : in out Source);
   --  Close both owned descriptors. Repeated calls are harmless. A later
   --  Ensure creates a new descriptor generation.
   --  @param Item Serialized source whose descriptors are released
   procedure Release (Item : in out Source);
   --  Borrow the current readable descriptor without transferring ownership.
   --  @param Item Source to inspect
   --  @return Read descriptor, or -1 before Ensure or after Release
   function Descriptor (Item : Source) return Interfaces.C.int;

private
   type Source is new Ada.Finalization.Limited_Controlled with record
      Read_End  : Interfaces.C.int := Interfaces.C.int (-1);
      Write_End : Interfaces.C.int := Interfaces.C.int (-1);
   end record;

   --  Release Item without propagating close errors.
   --  @param Item Source being finalized
   overriding procedure Finalize (Item : in out Source);
end Flyology.Wake_Sources;
