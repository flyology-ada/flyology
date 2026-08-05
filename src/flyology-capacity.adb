with Flyology.Capacity_Policy;

package body Flyology.Capacity is

   use type Interfaces.C.int;
   package Policy renames Flyology.Capacity_Policy;

   protected body Gate is
      entry Acquire (Accepted : out Boolean)
        when Policy.Acquire_Entry_Open
          (Stopping, Active_Count, Capacity)
      is
      begin
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
               Accepted := True;
            when Policy.Reject_Closed =>
               Accepted := False;
            when Policy.Wait_For_Permit =>
               raise Program_Error with "capacity entry opened while full";
         end case;
      end Acquire;

      procedure Try_Acquire (Result : out Acquire_Result) is
      begin
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
               Result := Permit_Acquired;
            when Policy.Wait_For_Permit =>
               Result := Gate_Full;
            when Policy.Reject_Closed =>
               Result := Gate_Closed;
         end case;
      end Try_Acquire;

      procedure Release is
      begin
         if not Policy.Release_Allowed (Active_Count) then
            raise Program_Error with "capacity permit released twice";
         end if;
         Active_Count := Policy.Active_After_Release (Active_Count);
         if Wake_Sources.Descriptor (Acquire_Wake) >= 0
           and then not Acquire_Signalled
         then
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
