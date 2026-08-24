--  Disabled buffer test seams selected by the owning project. The
--  imported-only declaration makes a missed static guard visible to symbol
--  inspection without supplying any production implementation.
private package Flyology.Buffer_Test_Hooks is

   --  Keep this a literal compile-time constant. GNAT removes code guarded by
   --  a literal False even at -O0; a function returning False can retain both
   --  its call and references inside the guarded branch.
   Enabled : constant Boolean := False;

   procedure Arm_Next_Acquisition_Near_Exhaustion
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_arm";

   function Consume_Next_Acquisition_Near_Exhaustion return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_consume";

   procedure Arm_Domain_Allocation_Failure (After_Successful_Allocations : Natural)
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_allocation_arm";

   function Consume_Domain_Allocation_Failure return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_allocation_consume";

   procedure Note_Domain_Pool_Allocated
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_pool_allocated";

   procedure Note_Domain_Pool_Freed
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_pool_freed";

   function Live_Domain_Pools return Natural
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_pools_live";

   procedure Arm_Next_Domain_Transfer_Failure
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_transfer_arm";

   function Consume_Next_Domain_Transfer_Failure return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_transfer_consume";

   procedure Arm_Next_Domain_Transfer_Post_Commit_Failure
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_post_commit_arm";

   function Consume_Next_Domain_Transfer_Post_Commit_Failure return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_post_commit_consume";

   procedure Arm_Next_Domain_Release_Failure
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_release_arm";

   function Consume_Next_Domain_Release_Failure return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_release_consume";

   procedure Arm_Next_Domain_Release_Post_Commit_Failure
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_release_post_arm";

   function Consume_Next_Domain_Release_Post_Commit_Failure return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_release_post_consume";

   procedure Arm_Next_Domain_Acquisition_Pre_Commit_Failure
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_acquire_pre_arm";

   function Consume_Next_Domain_Acquisition_Pre_Commit_Failure return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_acquire_pre_consume";

   procedure Arm_Next_Domain_Acquisition_Post_Commit_Failure
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_acquire_post_arm";

   function Consume_Next_Domain_Acquisition_Post_Commit_Failure return Boolean
   with Import, External_Name => "flyology_disabled_hook_must_be_elided_buffer_domain_acquire_post_consume";

end Flyology.Buffer_Test_Hooks;
