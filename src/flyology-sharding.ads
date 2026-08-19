with Flyology.Execution_Groups.Topology;
with Flyology.Task_Results;
with Interfaces;

--  Names the vocabulary shared by sharded ownership services. A sharded
--  service keeps one application instance per configured shared execution
--  group and reaches a non-owning instance only through an explicit
--  operation, never through a reference.
--
--  Example:
--
--     Target := Flyology.Sharding.Shard_For_Hash (Key, Shards => 4);
package Flyology.Sharding with Preelaborate is

   --  Configured shared group that owns one service instance.
   subtype Shard_Id is Flyology.Execution_Groups.Topology.Shard_Id;

   --  Number of shards a service owns. This is the automatic loop-pool
   --  range; a service never places an instance on a dedicated group.
   subtype Shard_Count is Flyology.Execution_Groups.Loop_Pool_Size;

   --  Raised when a shard count, service state, or reuse of a one-shot
   --  service object is invalid.
   Configuration_Error : exception;

   --  Raised when an operation is submitted to a service that has not
   --  published readiness or has begun shutdown.
   Not_Running : exception;

   --  Raised when the caller asked for its own shard's instance and is not
   --  a lightweight task running on a shard of that service.
   Not_Owner : exception;

   --  Raised when a shard operation submits work back to its own shard.
   --  The unchecked call would deadlock the shard against itself.
   Reentrant_Operation : exception;

   --  Terminal classification of one Serve call.
   --  @enum Shutdown_Completed Request_Shutdown drained every in-flight
   --     operation and joined every shard agent
   --  @enum Startup_Failed A shard instance could not be constructed; no
   --     operation was ever admitted
   --  @enum Shard_Failed A shard agent terminated while the service was
   --     running and the remaining shards were stopped
   type Service_Outcome is
     (Shutdown_Completed,
      Startup_Failed,
      Shard_Failed);

   --  Bounded terminal result of a Serve call. The exception fields are
   --  empty unless Outcome is Startup_Failed or Shard_Failed, and reuse the
   --  fixed capacities already defined by Flyology.Task_Results.
   --  @field Outcome Terminal classification
   --  @field Shard Shard that caused a non-shutdown outcome. It is
   --     meaningful only in a result Serve returned normally; when Serve
   --     propagates an exception it records a Startup_Failed result whose
   --     shard names no particular shard
   --  @field Exception_Name Bounded fully qualified exception identity
   --  @field Exception_Message Bounded copied exception message
   type Service_Result is record
      Outcome           : Service_Outcome := Shutdown_Completed;
      Shard             : Shard_Id := Shard_Id'First;
      Exception_Name    : Flyology.Task_Results.Bounded_Exception_Name;
      Exception_Message : Flyology.Task_Results.Bounded_Exception_Message;
   end record;

   --  Map Hash across an explicit shard count without consulting the
   --  runtime. This is Execution_Groups.Topology.Shard_For_Hash with the
   --  service's own count, so routing stays stable when the automatic pool
   --  grows later.
   --  @param Hash Application key or hash to partition
   --  @param Shards Number of zero-based shards in the mapping
   --  @return Shard in 0 .. Shards - 1
   function Shard_For_Hash
     (Hash   : Interfaces.Unsigned_64;
      Shards : Shard_Count) return Shard_Id
   is (Flyology.Execution_Groups.Topology.Shard_For_Hash (Hash, Shards))
   with Global => null;

end Flyology.Sharding;
