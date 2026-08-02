with Interfaces.C;

package body Gnatevl.Execution_Groups is
   package C renames Interfaces.C;

   use type C.int;

   function Runtime_Current_Group return C.int;
   pragma Import
     (C, Runtime_Current_Group, "gnatevl_runtime_current_group");

   function Runtime_Configured_Pool_Size return C.int;
   pragma Import
     (C,
      Runtime_Configured_Pool_Size,
      "gnatevl_runtime_configured_pool_size");

   function Runtime_Configured_Placement return C.int;
   pragma Import
     (C,
      Runtime_Configured_Placement,
      "gnatevl_runtime_configured_placement");

   function Runtime_Create_Dedicated_Group return C.int;
   pragma Import
     (C,
      Runtime_Create_Dedicated_Group,
      "gnatevl_runtime_create_dedicated_group");

   function Runtime_Is_Dedicated_Group (Group : C.int) return C.int;
   pragma Import
     (C, Runtime_Is_Dedicated_Group, "gnatevl_runtime_is_dedicated_group");

   function Runtime_Migrate (Group : C.int) return C.int;
   pragma Import (C, Runtime_Migrate, "gnatevl_runtime_migrate");

   function Runtime_Pin_Current_Thread
     (Owner : access System.Address) return C.int;
   pragma Import
     (C, Runtime_Pin_Current_Thread, "gnatevl_runtime_pin_current_thread");

   function Runtime_Unpin_Current_Thread
     (Owner : System.Address) return C.int;
   pragma Import
     (C, Runtime_Unpin_Current_Thread, "gnatevl_runtime_unpin_current_thread");

   function Runtime_Current_Thread_Is_Pinned return C.int;
   pragma Import
     (C,
      Runtime_Current_Thread_Is_Pinned,
      "gnatevl_runtime_current_thread_is_pinned");

   function For_CPU
     (CPU : System.Multiprocessors.CPU_Range) return Shared_Group_Id
   is
     (Shared_Group_Id (CPU));

   function Pin_To_Current_Thread return Thread_Pin is
      Owner : aliased System.Address := System.Null_Address;
   begin
      if Runtime_Pin_Current_Thread (Owner'Access) /= 0 then
         raise Group_Error with
           "cannot pin calling task to its current thread";
      end if;
      return Result : Thread_Pin do
         Result.Active := True;
         Result.Owner := Owner;
      end return;
   end Pin_To_Current_Thread;

   function Is_Thread_Pinned return Boolean is
     (Runtime_Current_Thread_Is_Pinned /= 0);

   overriding procedure Finalize (Object : in out Thread_Pin) is
      Result : C.int;
   begin
      if Object.Active then
         Result := Runtime_Unpin_Current_Thread (Object.Owner);
         Object.Active := False;
         Object.Owner := System.Null_Address;
         --  Finalization cannot report an error safely. A nonzero result
         --  indicates a runtime invariant violation; normal nesting and task
         --  finalization always release the pin on the acquiring task.
         pragma Assert (Result = 0);
      end if;
   end Finalize;

   function Current return Group_Id is
      Result : constant C.int := Runtime_Current_Group;
   begin
      if Result < C.int (Group_Id'First)
        or else Result > C.int (Group_Id'Last)
      then
         raise Group_Error with "calling task is not evented";
      end if;
      return Group_Id (Result);
   end Current;

   function Configured_Pool_Size return Loop_Pool_Size is
      Result : constant C.int := Runtime_Configured_Pool_Size;
   begin
      if Result < C.int (Loop_Pool_Size'First)
        or else Result > C.int (Loop_Pool_Size'Last)
      then
         raise Group_Error with "invalid event-loop pool configuration";
      end if;
      return Loop_Pool_Size (Result);
   end Configured_Pool_Size;

   function Configured_Placement return Automatic_Placement_Policy is
   begin
      case Runtime_Configured_Placement is
         when 0 =>
            return Round_Robin;
         when others =>
            raise Group_Error with "unknown event-loop placement policy";
      end case;
   end Configured_Placement;

   function In_Configured_Pool (Group : Group_Id) return Boolean is
     (Group < Group_Id (Configured_Pool_Size));

   function Create_Dedicated return Dedicated_Group_Id is
      Result : constant C.int := Runtime_Create_Dedicated_Group;
   begin
      if Result < C.int (Dedicated_Group_Id'First)
        or else Result > C.int (Dedicated_Group_Id'Last)
      then
         raise Group_Error with "cannot create a dedicated execution group";
      end if;
      return Dedicated_Group_Id (Result);
   end Create_Dedicated;

   function Is_Dedicated (Group : Group_Id) return Boolean is
     (Runtime_Is_Dedicated_Group (C.int (Group)) /= 0);

   procedure Migrate (Group : Group_Id) is
   begin
      if Runtime_Migrate (C.int (Group)) /= 0 then
         raise Migration_Error with
           "task cannot migrate to execution group" & Group'Image;
      end if;
   end Migrate;

end Gnatevl.Execution_Groups;
