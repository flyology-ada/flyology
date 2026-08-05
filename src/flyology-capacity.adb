with Flyology.Capacity_Policy;

package body Flyology.Capacity is

   use type Interfaces.C.int;
   package Policy renames Flyology.Capacity_Policy;

#if FLYOLOGY_CONNECTION_TEST_HOOKS then
   function Test_Fail_Next_Release_Wake return Interfaces.C.int
     with Import,
          Convention => C,
          External_Name =>
            "flyology_test_connection_fail_next_capacity_release_wake";
#end if;

   protected body Gate is
      entry Acquire
        (Accepted      : out Boolean;
         Cleanup_Armed : access Boolean := null)
        when Policy.Acquire_Entry_Open
          (Stopping, Active_Count, Capacity)
      is
      begin
         if Cleanup_Armed /= null and then Cleanup_Armed.all then
            raise Program_Error with "capacity cleanup is already armed";
         end if;
         case Policy.Classify_Acquire
           (Stopping, Active_Count, Capacity)
         is
            when Policy.Admit_Permit =>
               if Active_Count + 1 = Capacity and then Acquire_Signalled then
                  Wake_Sources.Consume (Acquire_Wake);
                  Acquire_Signalled := False;
               end if;
               Active_Count :=
                 Policy.Active_After_Acquire (Active_Count, Capacity);
               if Cleanup_Armed /= null then
                  Cleanup_Armed.all := True;
               end if;
               Accepted := True;
            when Policy.Reject_Closed =>
               Accepted := False;
            when Policy.Wait_For_Permit =>
               raise Program_Error with "capacity entry opened while full";
         end case;
      end Acquire;

      procedure Try_Acquire
        (Result        : out Acquire_Result;
         Cleanup_Armed : access Boolean := null)
      is
      begin
         if Cleanup_Armed /= null and then Cleanup_Armed.all then
            raise Program_Error with "capacity cleanup is already armed";
         end if;
         case Policy.Classify_Acquire
           (Stopping, Active_Count, Capacity)
         is
            when Policy.Admit_Permit =>
               if Active_Count + 1 = Capacity and then Acquire_Signalled then
                  Wake_Sources.Consume (Acquire_Wake);
                  Acquire_Signalled := False;
               end if;
               Active_Count :=
                 Policy.Active_After_Acquire (Active_Count, Capacity);
               if Cleanup_Armed /= null then
                  Cleanup_Armed.all := True;
               end if;
               Result := Permit_Acquired;
            when Policy.Wait_For_Permit =>
               Result := Gate_Full;
            when Policy.Reject_Closed =>
               Result := Gate_Closed;
         end case;
      end Try_Acquire;

      procedure Release (Cleanup_Armed : access Boolean := null) is
      begin
         if Cleanup_Armed /= null and then not Cleanup_Armed.all then
            raise Program_Error with "capacity cleanup is not armed";
         end if;
         if not Policy.Release_Allowed (Active_Count) then
            raise Program_Error with "capacity permit released twice";
         end if;
         Active_Count := Policy.Active_After_Release (Active_Count);
         if Cleanup_Armed /= null then
            --  Publish completion before a fallible wake. The permit is no
            --  longer active even when signalling reports an error.
            Cleanup_Armed.all := False;
         end if;
         if Wake_Sources.Descriptor (Acquire_Wake) >= 0
           and then not Acquire_Signalled
         then
#if FLYOLOGY_CONNECTION_TEST_HOOKS then
            if Test_Fail_Next_Release_Wake /= 0 then
               raise Program_Error with
                 "injected capacity release wake failure";
            end if;
#end if;
            Wake_Sources.Signal (Acquire_Wake);
            Acquire_Signalled := True;
         end if;
      end Release;

      procedure Request_Shutdown is
         Failed : Boolean := False;
      begin
         if not Stopping then
            --  Publish terminal state before either fallible wake so all
            --  protected-entry and state-query callers still observe shutdown.
            Stopping := True;
            if Wake_Sources.Descriptor (Shutdown_Wake) >= 0 then
               begin
                  Wake_Sources.Signal (Shutdown_Wake);
               exception
                  when others =>
                     Failed := True;
               end;
            end if;
            if Wake_Sources.Descriptor (Acquire_Wake) >= 0
              and then not Acquire_Signalled
            then
               begin
                  Wake_Sources.Signal (Acquire_Wake);
                  Acquire_Signalled := True;
               exception
                  when others =>
                     Failed := True;
               end;
            end if;
            if Failed then
               raise Program_Error with "cannot signal capacity shutdown";
            end if;
         end if;
      end Request_Shutdown;

      entry Await_Drained
        when Policy.Is_Drained (Stopping, Active_Count)
      is
      begin
         null;
      end Await_Drained;

      function Shutdown_Requested return Boolean is (Stopping);

      function Active return Natural is (Active_Count);

      function Waiting return Natural is (Acquire'Count);

      procedure Wait_Source
        (FD                : out Interfaces.C.int;
         Already_Requested : out Boolean)
      is
      begin
         Already_Requested := Stopping;
         if Stopping then
            FD := -1;
         else
            Wake_Sources.Ensure (Shutdown_Wake);
            FD := Wake_Sources.Descriptor (Shutdown_Wake);
         end if;
      end Wait_Source;

      procedure Acquire_Wait_Source
        (FD          : out Interfaces.C.int;
         Can_Acquire : out Boolean)
      is
      begin
         Can_Acquire :=
           Policy.Acquire_Entry_Open (Stopping, Active_Count, Capacity);
         if Can_Acquire then
            FD := -1;
         else
            Wake_Sources.Ensure (Acquire_Wake);
            FD := Wake_Sources.Descriptor (Acquire_Wake);
         end if;
      end Acquire_Wait_Source;
   end Gate;

   procedure Timed_Acquire
     (Item    : in out Gate;
      Timeout : Duration;
      Result  : out Acquire_Result)
   is
      Accepted : Boolean := False;
   begin
      if Timeout < 0.0 then
         Item.Acquire (Accepted);
      else
         select
            Item.Acquire (Accepted);
         or
            delay Timeout;
            Result := Acquire_Timed_Out;
            return;
         end select;
      end if;
      Result := (if Accepted then Permit_Acquired else Gate_Closed);
   end Timed_Acquire;

end Flyology.Capacity;
