--  Controls whether the calling task permits best-effort stack reclamation.
package Flyology.Dormancy with Preelaborate is

   --  Wake-latency contract for the calling task.
   --  @enum Prompt Do not proactively mark the task stack cold
   --  @enum Reclaimable Permit cold advice during sufficiently long waits
   type Policy is (Prompt, Reclaimable);

   --  Raised when a dormancy request is invalid for the calling task.
   Dormancy_Error : exception;

   --  Set the calling task's dormancy policy. Reclaimable applies only to a
   --  lightweight task waiting solely on a timer whose remaining delay is at
   --  least Minimum_Wait. Prompt is the default and is accepted as a no-op by
   --  native tasks. This policy is independent of Ada scheduling priority and
   --  does not prevent the operating system from paging memory normally.
   --  @param Value New wake-latency policy
   --  @param Minimum_Wait Minimum remaining timer delay before cold advice
   --  @exception Dormancy_Error Value is Reclaimable in a native task or the
   --     interval is negative or too large for the runtime ABI
   procedure Set_Policy
     (Value        : Policy;
      Minimum_Wait : Duration := 1.0);

   --  Return the calling task's policy. Native tasks report Prompt.
   --  @return Current dormancy policy
   function Current_Policy return Policy;

   --  Report whether the host exposes nondestructive cold-page advice. This
   --  query starts no event loop. A supported call remains best effort and
   --  can be rejected for an individual mapping.
   --  @return True when cold-page advice is available in the host build
   function Cold_Advice_Supported return Boolean;

end Flyology.Dormancy;
