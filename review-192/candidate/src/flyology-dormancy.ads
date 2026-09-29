--  Controls whether the calling task permits best-effort stack reclamation.

package Flyology.Dormancy
  with Preelaborate
is

   --  Wake-latency contract for the calling task.
   --  @enum Prompt Do not proactively mark the task stack cold
   --  @enum Reclaimable Permit cold advice during sufficiently long waits
   --  @enum Page_Out Ask the kernel to reclaim applicable stack pages now
   type Policy is (Prompt, Reclaimable, Page_Out);

   --  Raised when a dormancy request is invalid for the calling task.
   Dormancy_Error : exception;

   --  Set the calling task's dormancy policy. Reclaimable marks applicable
   --  pages cold; Page_Out requests immediate kernel reclamation. Both apply
   --  only to a lightweight task waiting solely on a timer whose remaining
   --  delay is at least Minimum_Wait. Prompt is the default and is accepted as
   --  a no-op by native tasks. The policy is independent of Ada priority.
   --  @param Value New wake-latency policy
   --  @param Minimum_Wait Minimum remaining timer delay before cold advice
   --  @exception Dormancy_Error Value is not Prompt in a native task or the
   --     interval is negative or too large for the runtime ABI
   procedure Set_Policy (Value : Policy; Minimum_Wait : Duration := 1.0);

   --  Return the calling task's policy. Native tasks report Prompt.
   --  @return Current dormancy policy
   function Current_Policy return Policy;

   --  Report whether the host exposes nondestructive cold-page advice. This
   --  query starts no event loop. A supported call remains best effort and
   --  can be rejected for an individual mapping.
   --  @return True when cold-page advice is available in the host build
   function Cold_Advice_Supported return Boolean;

   --  Report whether the host exposes nondestructive page-out advice. The
   --  query starts no event loop. The kernel may ignore individual pages, and
   --  backing is determined by host swap, zswap, or zram configuration.
   --  @return True when page-out advice is available in the running kernel
   function Pageout_Advice_Supported return Boolean;

end Flyology.Dormancy;
