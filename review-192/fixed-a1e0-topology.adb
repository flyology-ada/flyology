with Interfaces.C;
with Flyology.Topology_Policy;

package body Flyology.Execution_Groups.Topology is

   package C renames Interfaces.C;

   use type C.int;

   function Runtime_Migrate_Configured (Group : C.int) return C.int;
   pragma Import (C, Runtime_Migrate_Configured, "flyology_runtime_migrate_configured");

   Runtime_Blocked_In_Protected_Action : constant C.int := -2;
   Runtime_Target_Not_Configured       : constant C.int := -3;

   function Shard_For_Hash (Hash : Interfaces.Unsigned_64; Shard_Count : Loop_Pool_Size) return Shard_Id
   is (Shard_Id (Flyology.Topology_Policy.Shard_Index (Hash, Positive (Shard_Count))));

   function Shard_For_Hash (Hash : Interfaces.Unsigned_64) return Shard_Id
   is (Shard_For_Hash (Hash, Configured_Pool_Size));

   procedure Cross_To_Shard (Target : Shard_Id) is
      Result : constant C.int := Runtime_Migrate_Configured (C.int (Target));
   begin
      if Result = Runtime_Blocked_In_Protected_Action then
         raise Program_Error with "potentially blocking operation";
      elsif Result = Runtime_Target_Not_Configured then
         raise Migration_Error with "ownership shard is outside the configured event-loop pool";
      elsif Result /= 0 then
         raise Migration_Error with "task cannot migrate to ownership shard" & Target'Image;
      end if;
   end Cross_To_Shard;

end Flyology.Execution_Groups.Topology;
