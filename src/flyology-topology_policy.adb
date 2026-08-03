package body Flyology.Topology_Policy
  with SPARK_Mode => On
is
   use type Interfaces.Unsigned_64;

   function Shard_Index
     (Hash        : Interfaces.Unsigned_64;
      Shard_Count : Positive) return Natural
   is
     (Natural (Hash mod Interfaces.Unsigned_64 (Shard_Count)));

end Flyology.Topology_Policy;
