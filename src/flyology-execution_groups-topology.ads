with Interfaces;

--  Names execution groups as stable application ownership shards.
--
--  Example:
--
--     Target := Shard_For_Hash (Request_Id);
--     Cross_To_Shard (Target);
package Flyology.Execution_Groups.Topology with Preelaborate is

   --  Shared execution-group identifier eligible for application sharding.
   --  A value belongs to the configured pool only when In_Configured_Pool is
   --  true.
   subtype Shard_Id is Shared_Group_Id;

   --  Map Hash deterministically across the process's configured shared
   --  groups. The pool size is frozen during application startup, so a given
   --  hash remains on the same shard within one process. Launching with a
   --  different FLYOLOGY_LOOP_POOL_SIZE may remap keys; persist an independent
   --  partition count when storage compatibility requires it.
   --  @param Hash Application key or hash to partition
   --  @return Group in 0 .. Configured_Pool_Size - 1
   --  @exception Group_Error The runtime reports an invalid pool size
   function Shard_For_Hash
     (Hash : Interfaces.Unsigned_64) return Shard_Id;

   --  Map Hash across an explicit fixed number of shards without consulting
   --  or starting the runtime. Use this overload when a stored partitioning
   --  scheme must remain independent of the startup loop-pool size.
   --  @param Hash Application key or hash to partition
   --  @param Shard_Count Number of zero-based shards in the mapping
   --  @return Group in 0 .. Shard_Count - 1
   function Shard_For_Hash
     (Hash        : Interfaces.Unsigned_64;
      Shard_Count : Loop_Pool_Size) return Shard_Id
   with
     Global => null,
     Post   =>
       Group_Id (Shard_For_Hash'Result) < Group_Id (Shard_Count);

   --  Cross an application ownership boundary at an explicit cooperative safe
   --  point. This is Migrate restricted to the configured shared pool. The
   --  caller returns on Target's loop pthread with unchanged Ada task identity
   --  and locals. Native tasks cannot cross because their stacks remain owned
   --  by their GNARL pthreads.
   --  @param Target Configured ownership shard to enter
   --  @exception Group_Error The runtime reports an invalid pool size
   --  @exception Migration_Error Target is outside the configured pool, or
   --     the caller is native, pinned, or otherwise cannot migrate
   procedure Cross_To_Shard (Target : Shard_Id);

end Flyology.Execution_Groups.Topology;
