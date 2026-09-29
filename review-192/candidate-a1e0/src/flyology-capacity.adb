with Flyology.Capacity_Policy;
with Flyology.Connection_Test_Hooks;
with Flyology.Worker_Pool_Test_Hooks;

package body Flyology.Capacity is

   use type Interfaces.C.int;
   package Policy renames Flyology.Capacity_Policy;
   package Test_Hooks renames Flyology.Worker_Pool_Test_Hooks;

   protected body Gate is
      entry Acquire (Accepted : out Boolean; Cleanup_Armed : access Boolean := null)
        when Policy.Acquire_Entry_Open (Stopping, Active_Count, Capacity)
      is
         Action : constant Policy.Acquire_Action :=
           Policy.Classify_Acquire (Stopping, Active_Count, Capacity);
      begin
         if Cleanup_Armed /= null and then Cleanup_Armed.all then
            raise Program_Error with "capacity cleanup is already armed";
         end if;
         case Action is
            when Policy.Admit_Permit    =>
               if Active_Count + 1 = Capacity and then Acquire_Signalled then
                  Wake_Sources.Consume (Acquire_Wake);
                  Acquire_Signalled := False;
               end if;
               Active_Count := Policy.Active_After_Acquire (Active_Count, Capacity);
               Accepted := True;

            when Policy.Reject_Closed   =>
               Accepted := False;

            when Policy.Wait_For_Permit =>
               raise Program_Error with "capacity entry opened while full";
         end case;
         --  Permit ownership and the caller's cleanup obligation change in
         --  the same protected action, so a pending abort cannot separate
         --  them.
         if Cleanup_Armed /= null then
            Cleanup_Armed.all := Policy.Obligation_After_Acquire (Action);
         end if;
         if Accepted then
            --  This barrier is inside the protected action: abort stays
            --  deferred after the permit is counted until the caller's
            --  cleanup obligation is already authoritative.
            if Test_Hooks.Enabled then
               Test_Hooks.Capacity_Acquire_Barrier;
            end if;
         end if;
      end Acquire;

      procedure Try_Acquire (Result : out Acquire_Result; Cleanup_Armed : access Boolean := null) is
         Action : constant Policy.Acquire_Action :=
           Policy.Classify_Acquire (Stopping, Active_Count, Capacity);
      begin
         if Cleanup_Armed /= null and then Cleanup_Armed.all then
            raise Program_Error with "capacity cleanup is already armed";
         end if;
         case Action is
            when Policy.Admit_Permit    =>
               if Active_Count + 1 = Capacity and then Acquire_Signalled then
                  Wake_Sources.Consume (Acquire_Wake);
                  Acquire_Signalled := False;
               end if;
               Active_Count := Policy.Active_After_Acquire (Active_Count, Capacity);
               Result := Permit_Acquired;

            when Policy.Wait_For_Permit =>
               Result := Gate_Full;

            when Policy.Reject_Closed   =>
               Result := Gate_Closed;
         end case;
         --  Permit ownership and the caller's cleanup obligation change in
         --  the same protected action, so a pending abort cannot separate
         --  them.
         if Cleanup_Armed /= null then
            Cleanup_Armed.all := Policy.Obligation_After_Acquire (Action);
         end if;
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
         if Wake_Sources.Descriptor (Acquire_Wake) >= 0 and then not Acquire_Signalled then
            if Flyology.Connection_Test_Hooks.Enabled
              and then Flyology.Connection_Test_Hooks.Fail_Next_Capacity_Release_Wake
            then
               raise Program_Error with "injected capacity release wake failure";
            end if;
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
            if Wake_Sources.Descriptor (Acquire_Wake) >= 0 and then not Acquire_Signalled then
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

      entry Await_Drained when Policy.Is_Drained (Stopping, Active_Count) is
      begin
         null;
      end Await_Drained;

      function Shutdown_Requested return Boolean
      is (Stopping);

      function Active return Natural
      is (Active_Count);

      function Waiting return Natural
      is (Acquire'Count);

      procedure Wait_Source (FD : out Interfaces.C.int; Already_Requested : out Boolean) is
      begin
         Already_Requested := Stopping;
         if Stopping then
            FD := -1;
         else
            Wake_Sources.Ensure (Shutdown_Wake);
            FD := Wake_Sources.Descriptor (Shutdown_Wake);
         end if;
      end Wait_Source;

      procedure Acquire_Wait_Source (FD : out Interfaces.C.int; Can_Acquire : out Boolean) is
      begin
         Can_Acquire := Policy.Acquire_Entry_Open (Stopping, Active_Count, Capacity);
         if Can_Acquire then
            FD := -1;
         else
            Wake_Sources.Ensure (Acquire_Wake);
            FD := Wake_Sources.Descriptor (Acquire_Wake);
         end if;
      end Acquire_Wait_Source;
   end Gate;

   procedure Timed_Acquire
     (Item          : in out Gate;
      Timeout       : Duration;
      Result        : out Acquire_Result;
      Cleanup_Armed : access Boolean := null)
   is
      Accepted : Boolean := False;
   begin
      --  Reject an already-armed obligation even when the deadline expires
      --  before the entry is accepted, so the contract does not depend on
      --  which alternative of the timed call is selected.
      if Cleanup_Armed /= null and then Cleanup_Armed.all then
         raise Program_Error with "capacity cleanup is already armed";
      end if;
      --  The obligation is published inside the entry's protected action.
      --  Abort is deferred there, so a caller aborted after acquisition still
      --  owns a released obligation even though Result is never copied back.
      if Timeout < 0.0 then
         Item.Acquire (Accepted, Cleanup_Armed);
      else
         select
            Item.Acquire (Accepted, Cleanup_Armed);
         or
            delay Timeout;
            Result := Acquire_Timed_Out;
            return;
         end select;
      end if;
      Result := (if Accepted then Permit_Acquired else Gate_Closed);
   end Timed_Acquire;

end Flyology.Capacity;
