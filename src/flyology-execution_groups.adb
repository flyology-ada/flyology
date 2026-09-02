with Interfaces.C;
with Flyology.Placement_Policy;

package body Flyology.Execution_Groups is
   package C renames Interfaces.C;

   use type C.int;
   use type C.unsigned_long_long;

   type Runtime_Placement_Status is record
      Mode       : C.int;
      Value      : C.int;
      State      : C.int;
      Error_Code : C.int;
   end record;
   pragma Convention (C, Runtime_Placement_Status);

   type Runtime_Pool_Reduction_Status is record
      Phase                   : C.int;
      Target_Size             : C.int;
      Automatic_Tasks         : C.unsigned_long_long;
      Pinned_Automatic_Tasks  : C.unsigned_long_long;
      Waiting_Automatic_Tasks : C.unsigned_long_long;
      Explicit_Tasks          : C.unsigned_long_long;
      Placement_Claims        : C.unsigned_long_long;
   end record
   with Convention => C;

   function Runtime_Current_Group return C.int;
   pragma Import (C, Runtime_Current_Group, "flyology_runtime_current_group");

   function Runtime_Configured_Pool_Size return C.int;
   pragma Import (C, Runtime_Configured_Pool_Size, "flyology_runtime_configured_pool_size");

   function Runtime_Grow_Configured_Pool (Minimum_Size : C.int) return C.int;
   pragma Import (C, Runtime_Grow_Configured_Pool, "flyology_runtime_grow_configured_pool");

   function Runtime_Request_Pool_Reduction (Maximum_Size : C.int) return C.int;
   pragma Import (C, Runtime_Request_Pool_Reduction, "flyology_runtime_request_pool_reduction");

   function Runtime_Query_Pool_Reduction (Status : System.Address; Status_Size : C.size_t) return C.int;
   pragma Import (C, Runtime_Query_Pool_Reduction, "flyology_runtime_query_pool_reduction");

   function Runtime_Configured_Placement return C.int;
   pragma Import (C, Runtime_Configured_Placement, "flyology_runtime_configured_placement");

   function Runtime_Placement_Supported (Mode : C.int) return C.int;
   pragma Import (C, Runtime_Placement_Supported, "flyology_runtime_placement_supported");

   function Runtime_Placement_Value_Available (Mode : C.int; Value : C.int) return C.int;
   pragma Import (C, Runtime_Placement_Value_Available, "flyology_runtime_placement_value_available");

   function Runtime_Configure_Loop_Thread (Group : C.int; Mode : C.int; Value : C.int) return C.int;
   pragma Import (C, Runtime_Configure_Loop_Thread, "flyology_runtime_configure_group_placement");

   function Runtime_Loop_Thread_Status
     (Group : C.int; Status : System.Address; Status_Size : C.size_t) return C.int;
   pragma Import (C, Runtime_Loop_Thread_Status, "flyology_runtime_query_group_placement");

   function Runtime_Current_Processor return C.int;
   pragma Import (C, Runtime_Current_Processor, "flyology_runtime_current_processor");

   function Runtime_Create_Dedicated_Group return C.int;
   pragma Import (C, Runtime_Create_Dedicated_Group, "flyology_runtime_create_dedicated_group");

   function Runtime_Is_Dedicated_Group (Group : C.int) return C.int;
   pragma Import (C, Runtime_Is_Dedicated_Group, "flyology_runtime_is_dedicated_group");

   function Runtime_Migrate (Group : C.int) return C.int;
   pragma Import (C, Runtime_Migrate, "flyology_runtime_migrate");
   --  Result of Runtime_Migrate when the calling lightweight task is inside
   --  a protected action. The value is fixed by the documented result of
   --  System.Flyology.Scheduler.Migrate.
   Runtime_Blocked_In_Protected_Action : constant C.int := -2;

   function Runtime_Pin_Current_Thread (Owner : access System.Address) return C.int;
   pragma Import (C, Runtime_Pin_Current_Thread, "flyology_runtime_pin_current_thread");

   function Runtime_Unpin_Current_Thread (Owner : System.Address) return C.int;
   pragma Import (C, Runtime_Unpin_Current_Thread, "flyology_runtime_unpin_current_thread");

   function Runtime_Current_Thread_Is_Pinned return C.int;
   pragma Import (C, Runtime_Current_Thread_Is_Pinned, "flyology_runtime_current_thread_is_pinned");

   function For_CPU (CPU : Group_Selecting_CPU) return Shared_Group_Id
   is (Shared_Group_Id (Flyology.Placement_Policy.Group_For_CPU (Natural (CPU))));

   function Pin_To_Current_Thread return Thread_Pin is
      Owner : aliased System.Address := System.Null_Address;
   begin
      if Runtime_Pin_Current_Thread (Owner'Access) /= 0 then
         raise Group_Error with "cannot pin calling task to its current thread";
      end if;
      return Result : Thread_Pin do
         Result.Active := True;
         Result.Owner := Owner;
      end return;
   end Pin_To_Current_Thread;

   function Is_Thread_Pinned return Boolean
   is (Runtime_Current_Thread_Is_Pinned /= 0);

   overriding
   procedure Finalize (Object : in out Thread_Pin) is
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
      if Result < C.int (Group_Id'First) or else Result > C.int (Group_Id'Last) then
         raise Group_Error with "calling task is not lightweight";
      end if;
      return Group_Id (Result);
   end Current;

   function Configured_Pool_Size return Loop_Pool_Size is
      Result : constant C.int := Runtime_Configured_Pool_Size;
   begin
      if Result < C.int (Loop_Pool_Size'First) or else Result > C.int (Loop_Pool_Size'Last) then
         raise Group_Error with "invalid event-loop pool configuration";
      end if;
      return Loop_Pool_Size (Result);
   end Configured_Pool_Size;

   procedure Grow_Configured_Pool (Minimum_Size : Loop_Pool_Size) is
   begin
      if Runtime_Grow_Configured_Pool (C.int (Minimum_Size)) /= 0 then
         raise Group_Error with "cannot grow configured event-loop pool";
      end if;
   end Grow_Configured_Pool;

   function Request_Pool_Reduction (Maximum_Size : Loop_Pool_Size) return Pool_Reduction_Request_Result is
   begin
      case Runtime_Request_Pool_Reduction (C.int (Maximum_Size)) is
         when 0      =>
            return Reduction_Started;

         when 1      =>
            return Already_At_Or_Below;

         when 2      =>
            return Reduction_In_Progress;

         when others =>
            raise Group_Error with "cannot reduce configured event-loop pool";
      end case;
   end Request_Pool_Reduction;

   function Pool_Reduction return Pool_Reduction_Status is
      Raw : aliased Runtime_Pool_Reduction_Status;

      function Count (Value : C.unsigned_long_long) return Natural;

      function Count (Value : C.unsigned_long_long) return Natural is
      begin
         if Value > C.unsigned_long_long (Natural'Last) then
            raise Group_Error with "invalid event-loop reduction count";
         end if;
         return Natural (Value);
      end Count;
   begin
      if Runtime_Query_Pool_Reduction (Raw'Address, C.size_t (Raw'Size / 8)) /= 0
        or else Raw.Target_Size < C.int (Loop_Pool_Size'First)
        or else Raw.Target_Size > C.int (Loop_Pool_Size'Last)
      then
         raise Group_Error with "cannot query event-loop pool reduction";
      end if;
      return
        (Phase                   =>
           (case Raw.Phase is
              when 0      => No_Reduction,
              when 1      => Draining,
              when 2      => Drained,
              when others => raise Group_Error with "invalid event-loop pool reduction phase"),
         Target_Size             => Loop_Pool_Size (Raw.Target_Size),
         Automatic_Tasks         => Count (Raw.Automatic_Tasks),
         Pinned_Automatic_Tasks  => Count (Raw.Pinned_Automatic_Tasks),
         Waiting_Automatic_Tasks => Count (Raw.Waiting_Automatic_Tasks),
         Explicit_Tasks          => Count (Raw.Explicit_Tasks),
         Placement_Claims        => Count (Raw.Placement_Claims));
   end Pool_Reduction;

   function Configured_Placement return Automatic_Placement_Policy is
   begin
      case Runtime_Configured_Placement is
         when 0      =>
            return Round_Robin;

         when others =>
            raise Group_Error with "unknown event-loop placement policy";
      end case;
   end Configured_Placement;

   function In_Configured_Pool (Group : Group_Id) return Boolean
   is (Group < Group_Id (Configured_Pool_Size));

   function Mode_Of (Kind : Loop_Thread_Placement) return C.int
   is (case Kind is
         when No_Placement => 0,
         when Strict_CPU   => 1,
         when Advisory_Tag => 2);

   function Placement_Supported (Kind : Loop_Thread_Placement) return Boolean
   is (Runtime_Placement_Supported (Mode_Of (Kind)) /= 0);

   function Placement_Value_Available (Kind : Loop_Thread_Placement; Value : Placement_Value) return Boolean
   is (Runtime_Placement_Value_Available (Mode_Of (Kind), C.int (Value)) /= 0);

   function Configure_Loop_Thread
     (Group : Group_Id; Kind : Loop_Thread_Placement; Value : Placement_Value := 0)
      return Placement_Configuration_Result
   is
      Result : constant C.int := Runtime_Configure_Loop_Thread (C.int (Group), Mode_Of (Kind), C.int (Value));
   begin
      case Result is
         when 0      =>
            return Configured;

         when 1      =>
            return Unchanged;

         when 2      =>
            return Unsupported;

         when 3      =>
            return Invalid_Value;

         when 4      =>
            return Group_Already_Started;

         when 5      =>
            return Runtime_Unavailable;

         when others =>
            raise Group_Error with "unknown loop-thread configuration result";
      end case;
   end Configure_Loop_Thread;

   function Loop_Thread_Status (Group : Group_Id) return Placement_Status is
      Raw    : aliased Runtime_Placement_Status;
      Result : C.int;
      Kind   : Loop_Thread_Placement;
      State  : Placement_State;
   begin
      Result := Runtime_Loop_Thread_Status (C.int (Group), Raw'Address, C.size_t (Raw'Size / 8));
      if Result /= 0 or else Raw.Value < 0 then
         raise Group_Error with "cannot query loop-thread placement";
      end if;
      case Raw.Mode is
         when 0      =>
            Kind := No_Placement;

         when 1      =>
            Kind := Strict_CPU;

         when 2      =>
            Kind := Advisory_Tag;

         when others =>
            raise Group_Error with "unknown loop-thread placement mode";
      end case;
      case Raw.State is
         when 0      =>
            State := Not_Requested;

         when 1      =>
            State := Pending_Startup;

         when 2      =>
            State := Applied;

         when 3      =>
            State := Failed;

         when 4      =>
            State := Unavailable;

         when others =>
            raise Group_Error with "unknown loop-thread placement state";
      end case;
      return
        (Kind       => Kind,
         Value      => Placement_Value (Raw.Value),
         State      => State,
         Error_Code => Integer (Raw.Error_Code));
   end Loop_Thread_Status;

   function Current_Processor return Integer
   is (Integer (Runtime_Current_Processor));

   function Create_Dedicated return Dedicated_Group_Id is
      Result : constant C.int := Runtime_Create_Dedicated_Group;
   begin
      if Result < C.int (Dedicated_Group_Id'First) or else Result > C.int (Dedicated_Group_Id'Last) then
         raise Group_Error with "cannot create a dedicated execution group";
      end if;
      return Dedicated_Group_Id (Result);
   end Create_Dedicated;

   function Is_Dedicated (Group : Group_Id) return Boolean
   is (Runtime_Is_Dedicated_Group (C.int (Group)) /= 0);

   procedure Migrate (Group : Group_Id) is
      Result : constant C.int := Runtime_Migrate (C.int (Group));
   begin
      if Result = Runtime_Blocked_In_Protected_Action then
         --  GNARL's wording at every RM 9.5.1 detection site, so each
         --  lightweight suspension point inside a protected action reports
         --  one outcome. The normal unwinding releases the protected
         --  object's lock on the thread that holds it.
         raise Program_Error with "potentially blocking operation";
      elsif Result /= 0 then
         raise Migration_Error with "task cannot migrate to execution group" & Group'Image;
      end if;
   end Migrate;

end Flyology.Execution_Groups;
