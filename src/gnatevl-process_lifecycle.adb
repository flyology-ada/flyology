with Interfaces.C;

package body Gnatevl.Process_Lifecycle is
   package C renames Interfaces.C;
   use type C.int;

   function Runtime_State return C.int;
   pragma Import
     (C, Runtime_State, "gnatevl_runtime_observe_lifecycle");

   function Runtime_Created_Groups return C.int;
   pragma Import
     (C,
      Runtime_Created_Groups,
      "gnatevl_runtime_observe_created_groups");

   function State return Event_Runtime_State is
   begin
      case Runtime_State is
         when 0 =>
            return Dormant;
         when 1 =>
            return Running;
         when 2 =>
            return Finalizing;
         when 3 =>
            return Stopped;
         when 4 =>
            return Cleanup_Deferred;
         when 5 =>
            return Fork_Child;
         when others =>
            raise Program_Error with "unknown GNATEVL lifecycle state";
      end case;
   end State;

   function Created_Groups return Group_Count is
      Result : constant C.int := Runtime_Created_Groups;
   begin
      if Result < 0 or else Result > C.int (Group_Count'Last) then
         raise Program_Error with "invalid GNATEVL event-group count";
      end if;
      return Group_Count (Result);
   end Created_Groups;

end Gnatevl.Process_Lifecycle;
