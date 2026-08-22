with Flyology.Topology_Policy;

package body Flyology.Execution_Groups.Topology is

   function Shard_For_Hash (Hash : Interfaces.Unsigned_64; Shard_Count : Loop_Pool_Size) return Shard_Id
   is (Shard_Id (Flyology.Topology_Policy.Shard_Index (Hash, Positive (Shard_Count))));

   function Shard_For_Hash (Hash : Interfaces.Unsigned_64) return Shard_Id
   is (Shard_For_Hash (Hash, Configured_Pool_Size));

   procedure Cross_To_Shard (Target : Shard_Id) is
   begin
      if not In_Configured_Pool (Target) then
         raise Migration_Error with "ownership shard is outside the configured event-loop pool";
      end if;
      Migrate (Target);
   end Cross_To_Shard;

end Flyology.Execution_Groups.Topology;
