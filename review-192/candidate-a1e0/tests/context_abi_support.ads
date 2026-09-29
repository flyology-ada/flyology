with Flyology.IO.Sockets;
with Interfaces.C;

--  Test-only dispatcher called through the machine-state conformance probe.

package Context_ABI_Support is
   subtype Action_Code is Interfaces.C.unsigned range 0 .. 4;

   No_Switch            : constant Action_Code := 0;
   Cooperative_Yield    : constant Action_Code := 1;
   Timer_Suspension     : constant Action_Code := 2;
   Descriptor_Readiness : constant Action_Code := 3;
   Cross_Group_Move     : constant Action_Code := 4;

   procedure Configure (Reader : aliased in out Flyology.IO.Sockets.Socket_Type);

   procedure Wait_For_Descriptor_Request;

   function Probe (Action : Action_Code) return Interfaces.C.unsigned;

private
   function Callback (Action : Action_Code) return Interfaces.C.unsigned;
   pragma Export (C, Callback, "flyology_test_context_callback");
end Context_ABI_Support;
