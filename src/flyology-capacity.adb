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
      end Release;

      procedure Request_Shutdown is
      begin
         if not Stopping then
            --  Avoid allocating an OS descriptor merely to record shutdown.
            --  Wait_Source observes Stopping under this same protected lock.
            if Wake_Sources.Descriptor (Wake) >= 0 then
               Wake_Sources.Signal (Wake);
            end if;
            Stopping := True;
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
            Wake_Sources.Ensure (Wake);
            FD := Wake_Sources.Descriptor (Wake);
         end if;
      end Wait_Source;
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
