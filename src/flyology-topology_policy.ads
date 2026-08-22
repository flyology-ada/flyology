with Interfaces;

private package Flyology.Topology_Policy
  with Preelaborate, SPARK_Mode => On
is

   --  Map a hash to one zero-based member of a fixed shard set.
   function Shard_Index (Hash : Interfaces.Unsigned_64; Shard_Count : Positive) return Natural
   with Global => null, Pre => Shard_Count <= 128, Post => Shard_Index'Result < Shard_Count;

end Flyology.Topology_Policy;
