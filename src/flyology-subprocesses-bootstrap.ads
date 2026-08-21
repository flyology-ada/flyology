with Flyology.IO.Socket_Handoffs;
with Flyology.IO.Sockets;

--  Launches a child image with two private AF_UNIX stream channels at stable
--  descriptors. The control channel carries framed upgrade commands. The
--  capability channel is dedicated exclusively to typed SCM_RIGHTS handoff.
package Flyology.Subprocesses.Bootstrap is
   package Sockets renames Flyology.IO.Sockets;
   package Socket_Handoffs renames Flyology.IO.Socket_Handoffs;

   --  Bootstrap channels could not be created, validated, or adopted.
   Bootstrap_Error : exception;

   --  Stable child descriptor for the framed control stream.
   Child_Control_Descriptor : constant Flyology.IO.Descriptor := 3;
   --  Stable child descriptor for the capability-handoff stream.
   Child_Capability_Descriptor : constant Flyology.IO.Descriptor := 4;

   --  Spawn Item and return the coordinator endpoints. The child sees the
   --  matching endpoints as fd 3 and fd 4. All four original socket-pair
   --  descriptors are closed in the child during posix_spawn file actions.
   --  The child inherits the coordinator's standard output and error; its
   --  standard input immediately observes end-of-file.
   --  @exception Spawn_Error Channel creation, posix_spawn, or reaper setup
   --     fails
   --  @exception Bootstrap_Error A spawned channel cannot be validated or
   --     adopted; the child is terminated and reaped before this is raised
   --  @exception Program_Error An output already owns a resource
   --  @exception Storage_Error Launch-description allocation fails
   --  @param Item Child executable, arguments, environment, and launch context
   --  @param Child Closed destination process handle
   --  @param Control Closed destination for the coordinator control endpoint
   --  @param Capabilities Closed destination for the capability endpoint
   procedure Spawn
     (Item         : Command;
      Child        : in out Process;
      Control      : in out Sockets.Socket_Type;
      Capabilities : in out Socket_Handoffs.Handoff_Channel)
   with Pre =>
     not Is_Open (Child)
       and then not Sockets.Is_Open (Control)
       and then not Socket_Handoffs.Is_Open (Capabilities),
     Post =>
       Is_Open (Child)
         and then Sockets.Is_Open (Control)
         and then Socket_Handoffs.Is_Open (Capabilities);

   --  Adopt and validate the inherited child endpoints. Call this once near
   --  image startup, before creating application tasks. fd 3 becomes Control;
   --  fd 4 becomes the dedicated capability channel. Failure closes every
   --  endpoint that this call managed to acquire.
   --  @exception Bootstrap_Error The inherited descriptors are missing,
   --     malformed, unsupported for Trust, or cannot be adopted
   --  @exception Program_Error An output already owns a resource
   --  @param Control Closed destination for inherited fd 3
   --  @param Capabilities Closed destination for inherited fd 4
   --  @param Trust Peer trust used for capability-channel validation
   procedure Adopt_Inherited
     (Control      : in out Sockets.Socket_Type;
      Capabilities : in out Socket_Handoffs.Handoff_Channel;
      Trust        : Socket_Handoffs.Peer_Trust :=
        Socket_Handoffs.Trusted_Peer)
   with Pre =>
     not Sockets.Is_Open (Control)
       and then not Socket_Handoffs.Is_Open (Capabilities),
     Post =>
       Sockets.Is_Open (Control)
         and then Socket_Handoffs.Is_Open (Capabilities);
end Flyology.Subprocesses.Bootstrap;
