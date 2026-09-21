with Flyology.Capacity_Policy;
with Flyology.Connection_Test_Hooks;
with Flyology.Worker_Pool_Test_Hooks;

package body Flyology.Capacity is

   use type Interfaces.C.int;
   package Policy renames Flyology.Capacity_Policy;
   package Test_Hooks renames Flyology.Worker_Pool_Test_Hooks;

   procedure Flush (Guard : in out Action_Guard);

   overriding
   procedure Finalize (Guard : in out Action_Guard) is
   begin
      if Guard.Claim.Armed then
         --  An abort immediately after a protected state cut still leaves its
         --  wake or drain claim with this caller-owned guard.
         begin
            Flush (Guard);
         exception
            when others =>
               null;
         end;
         if Guard.Claim.Armed then
            Guard.State.Fail_Action (Guard.Claim.Kind'Access, Guard.Claim.Armed'Access);
         end if;
      end if;
   end Finalize;

   overriding
   procedure Finalize (Guard : in out Initialization_Guard) is
   begin
      if Guard.Armed then
         Guard.State.Cancel_Initialization (Guard.Kind);
         Guard.Armed := False;
      end if;
   end Finalize;

   protected body Gate_State is
      entry Take_Permit
        (Accepted : out Boolean;
         Cleanup_Armed : access Boolean;
         Guard : not null access Wake_Claim)
        when Policy.Acquire_Entry_Open (Stopping, Active_Count, Capacity)
      is
         Action : constant Policy.Acquire_Action :=
           Policy.Classify_Acquire (Stopping, Active_Count, Capacity);
      begin
         if Cleanup_Armed /= null and then Cleanup_Armed.all then
            raise Program_Error with "capacity cleanup is already armed";
         end if;
         case Action is
            when Policy.Admit_Permit =>
               Active_Count := Policy.Active_After_Acquire (Active_Count, Capacity);
               Accepted := True;
               if Active_Count = Capacity and then Acquire_Phase = Wake_Signalled then
                  Acquire_Phase := Wake_Draining;
                  Guard.Kind := Drain_Acquire;
                  Guard.Descriptor := Acquire_Read_FD;
                  Guard.Armed := True;
               end if;
            when Policy.Reject_Closed =>
               Accepted := False;
            when Policy.Wait_For_Permit =>
               raise Program_Error with "capacity entry opened while full";
         end case;
         --  The permit and cleanup obligation transfer in the same cut.
         if Cleanup_Armed /= null then
            Cleanup_Armed.all := Policy.Obligation_After_Acquire (Action);
         end if;
         if Accepted and then Test_Hooks.Enabled then
            Test_Hooks.Capacity_Acquire_Barrier;
         end if;
      end Take_Permit;

      procedure Try_Acquire
        (Result : out Acquire_Result;
         Cleanup_Armed : access Boolean;
         Guard : not null access Wake_Claim)
      is
         Action : constant Policy.Acquire_Action :=
           Policy.Classify_Acquire (Stopping, Active_Count, Capacity);
      begin
         if Cleanup_Armed /= null and then Cleanup_Armed.all then
            raise Program_Error with "capacity cleanup is already armed";
         end if;
         case Action is
            when Policy.Admit_Permit =>
               Active_Count := Policy.Active_After_Acquire (Active_Count, Capacity);
               Result := Permit_Acquired;
               if Active_Count = Capacity and then Acquire_Phase = Wake_Signalled then
                  Acquire_Phase := Wake_Draining;
                  Guard.Kind := Drain_Acquire;
                  Guard.Descriptor := Acquire_Read_FD;
                  Guard.Armed := True;
               end if;
            when Policy.Wait_For_Permit =>
               Result := Gate_Full;
            when Policy.Reject_Closed =>
               Result := Gate_Closed;
         end case;
         if Cleanup_Armed /= null then
            Cleanup_Armed.all := Policy.Obligation_After_Acquire (Action);
         end if;
      end Try_Acquire;

      procedure Release (Cleanup_Armed : access Boolean; Guard : not null access Wake_Claim) is
      begin
         if Cleanup_Armed /= null and then not Cleanup_Armed.all then
            raise Program_Error with "capacity cleanup is not armed";
         end if;
         if not Policy.Release_Allowed (Active_Count) then
            raise Program_Error with "capacity permit released twice";
         end if;
         Active_Count := Policy.Active_After_Release (Active_Count);
         if Cleanup_Armed /= null then
            Cleanup_Armed.all := False;
         end if;
         if Acquire_Write_FD >= 0 and then Acquire_Phase = Wake_Quiet then
            Acquire_Phase := Wake_Signalling;
            Guard.Kind := Signal_Acquire;
            Guard.Descriptor := Acquire_Write_FD;
            Guard.Armed := True;
         end if;
      end Release;

      procedure Request_Shutdown (Shutdown_Guard, Acquire_Guard : not null access Wake_Claim) is
      begin
         if not Stopping then
            Stopping := True;
            if Shutdown_Write_FD >= 0 then
               Shutdown_Guard.Kind := Signal_Shutdown;
               Shutdown_Guard.Descriptor := Shutdown_Write_FD;
               Shutdown_Guard.Armed := True;
            end if;
            if Acquire_Write_FD >= 0 and then Acquire_Phase = Wake_Quiet then
               Acquire_Phase := Wake_Signalling;
               Acquire_Guard.Kind := Signal_Acquire;
               Acquire_Guard.Descriptor := Acquire_Write_FD;
               Acquire_Guard.Armed := True;
            end if;
         end if;
      end Request_Shutdown;

      entry Await_Drained when Policy.Is_Drained (Stopping, Active_Count) is
      begin
         null;
      end Await_Drained;

      function Shutdown_Requested return Boolean is (Stopping);
      function Active return Natural is (Active_Count);
      function Waiting return Natural is (Take_Permit'Count);

      procedure Begin_Shutdown_Wait
        (Guard : not null access Initialization_Guard;
         FD : out Interfaces.C.int;
         Already_Requested : out Boolean)
      is
      begin
         Already_Requested := Stopping;
         FD := (if Stopping then -1 else Shutdown_Read_FD);
         if not Stopping and then FD < 0 and then not Shutdown_Initializing then
            Shutdown_Initializing := True;
            Guard.Armed := True;
         end if;
      end Begin_Shutdown_Wait;

      procedure Begin_Acquire_Wait
        (Guard : not null access Initialization_Guard;
         FD : out Interfaces.C.int;
         Can_Acquire, Stable : out Boolean)
      is
      begin
         Can_Acquire := Policy.Acquire_Entry_Open (Stopping, Active_Count, Capacity);
         Stable := Acquire_Phase = Wake_Quiet or else Acquire_Phase = Wake_Signalled;
         FD := (if Can_Acquire or else not Stable then -1 else Acquire_Read_FD);
         if not Can_Acquire and then Stable and then FD < 0 and then not Acquire_Initializing then
            Acquire_Initializing := True;
            Guard.Armed := True;
         end if;
      end Begin_Acquire_Wait;

      entry Wait_Shutdown_Ready when not Shutdown_Initializing is
      begin
         null;
      end Wait_Shutdown_Ready;

      entry Wait_Acquire_Ready
        when not Acquire_Initializing and then
          (Acquire_Phase = Wake_Quiet or else Acquire_Phase = Wake_Signalled)
      is
      begin
         null;
      end Wait_Acquire_Ready;

      procedure Publish_Source (Kind : Initialization_Kind; FD, Signal_FD : Interfaces.C.int) is
      begin
         if FD < 0 or else Signal_FD < 0 then
            raise Program_Error with "invalid capacity wake publication";
         end if;
         case Kind is
            when Shutdown_Source =>
               if not Shutdown_Initializing or else Shutdown_Read_FD >= 0 then
                  raise Program_Error with "invalid shutdown wake publication";
               end if;
               Shutdown_Read_FD := FD;
               Shutdown_Write_FD := Signal_FD;
               Shutdown_Initializing := False;
            when Acquire_Source =>
               if not Acquire_Initializing or else Acquire_Read_FD >= 0 then
                  raise Program_Error with "invalid acquire wake publication";
               end if;
               Acquire_Read_FD := FD;
               Acquire_Write_FD := Signal_FD;
               Acquire_Initializing := False;
         end case;
      end Publish_Source;

      procedure Cancel_Initialization (Kind : Initialization_Kind) is
      begin
         case Kind is
            when Shutdown_Source => Shutdown_Initializing := False;
            when Acquire_Source  => Acquire_Initializing := False;
         end case;
      end Cancel_Initialization;

      procedure Complete_Signal
        (Kind : not null access Wake_Action; Armed : not null access Boolean)
      is
      begin
         if Acquire_Phase /= Wake_Signalling then
            raise Program_Error with "invalid capacity signal completion";
         end if;
         if not Stopping and then Active_Count = Capacity then
            Acquire_Phase := Wake_Draining;
            Kind.all := Drain_Acquire;
         else
            Acquire_Phase := Wake_Signalled;
            Kind.all := No_Action;
            Armed.all := False;
         end if;
      end Complete_Signal;

      procedure Complete_Drain
        (Kind : not null access Wake_Action; Armed : not null access Boolean)
      is
      begin
         if Acquire_Phase /= Wake_Draining then
            raise Program_Error with "invalid capacity drain completion";
         end if;
         if Stopping or else Active_Count < Capacity then
            Acquire_Phase := Wake_Signalling;
            Kind.all := Signal_Acquire;
         else
            Acquire_Phase := Wake_Quiet;
            Kind.all := No_Action;
            Armed.all := False;
         end if;
      end Complete_Drain;

      procedure Fail_Action
        (Kind : not null access Wake_Action; Armed : not null access Boolean)
      is
      begin
         if Kind.all = Signal_Acquire or else Kind.all = Drain_Acquire then
            Acquire_Phase := Wake_Quiet;
         end if;
         Kind.all := No_Action;
         Armed.all := False;
      end Fail_Action;
   end Gate_State;

   procedure Flush (Guard : in out Action_Guard) is
   begin
      while Guard.Claim.Armed loop
         case Guard.Claim.Kind is
            when Signal_Shutdown =>
               Flyology.Wake_Sources.Signal_Borrowed (Guard.Claim.Descriptor);
               Guard.Claim.Kind := No_Action;
               Guard.Claim.Armed := False;
            when Signal_Acquire =>
               if Flyology.Connection_Test_Hooks.Enabled
                 and then Flyology.Connection_Test_Hooks.Fail_Next_Capacity_Wake
               then
                  raise Program_Error with "injected capacity release wake failure";
               end if;
               Flyology.Wake_Sources.Signal_Borrowed (Guard.Claim.Descriptor);
               Guard.State.Complete_Signal (Guard.Claim.Kind'Access, Guard.Claim.Armed'Access);
               Guard.Claim.Descriptor := Flyology.Wake_Sources.Descriptor (Guard.Source.all);
            when Drain_Acquire =>
               begin
                  if Flyology.Connection_Test_Hooks.Enabled
                    and then Flyology.Connection_Test_Hooks.Fail_Next_Capacity_Wake
                  then
                     raise Program_Error with "injected capacity drain failure";
                  end if;
                  Flyology.Wake_Sources.Drain (Guard.Source.all);
               exception
                  when others =>
                     --  The permit has already transferred. Do not raise
                     --  before the caller can observe that ownership. Leave
                     --  the claim armed for finalization to retry once.
                     return;
               end;
               Guard.State.Complete_Drain (Guard.Claim.Kind'Access, Guard.Claim.Armed'Access);
               Guard.Claim.Descriptor := Flyology.Wake_Sources.Signal_Descriptor (Guard.Source.all);
            when No_Action =>
               Guard.Claim.Armed := False;
         end case;
      end loop;
   end Flush;

   procedure Request_Shutdown (Item : in out Gate) is
      Shutdown_Guard : aliased Action_Guard;
      Acquire_Guard  : aliased Action_Guard;
   begin
      Shutdown_Guard.State := Item.State'Unchecked_Access;
      Shutdown_Guard.Source := Item.Shutdown_Wake'Unchecked_Access;
      Acquire_Guard.State := Item.State'Unchecked_Access;
      Acquire_Guard.Source := Item.Acquire_Wake'Unchecked_Access;
      Item.State.Request_Shutdown (Shutdown_Guard.Claim'Access, Acquire_Guard.Claim'Access);
      --  Keep both guards armed if the first signal raises. Finalization will
      --  still attempt the other descriptor.
      Flush (Shutdown_Guard);
      Flush (Acquire_Guard);
   end Request_Shutdown;

   procedure Acquire (Item : in out Gate; Accepted : out Boolean; Cleanup_Armed : access Boolean := null) is
      Guard : aliased Action_Guard;
   begin
      Guard.State := Item.State'Unchecked_Access;
      Guard.Source := Item.Acquire_Wake'Unchecked_Access;
      Item.State.Take_Permit (Accepted, Cleanup_Armed, Guard.Claim'Access);
      Flush (Guard);
   end Acquire;

   procedure Try_Acquire
     (Item : in out Gate; Result : out Acquire_Result; Cleanup_Armed : access Boolean := null)
   is
      Guard : aliased Action_Guard;
   begin
      Guard.State := Item.State'Unchecked_Access;
      Guard.Source := Item.Acquire_Wake'Unchecked_Access;
      Item.State.Try_Acquire (Result, Cleanup_Armed, Guard.Claim'Access);
      Flush (Guard);
   end Try_Acquire;

   procedure Release (Item : in out Gate; Cleanup_Armed : access Boolean := null) is
      Guard : aliased Action_Guard;
   begin
      Guard.State := Item.State'Unchecked_Access;
      Guard.Source := Item.Acquire_Wake'Unchecked_Access;
      Item.State.Release (Cleanup_Armed, Guard.Claim'Access);
      Flush (Guard);
   end Release;

   procedure Await_Drained (Item : in out Gate) is
   begin
      Item.State.Await_Drained;
   end Await_Drained;

   function Shutdown_Requested (Item : Gate) return Boolean is (Item.State.Shutdown_Requested);
   function Active (Item : Gate) return Natural is (Item.State.Active);
   function Waiting (Item : Gate) return Natural is (Item.State.Waiting);

   procedure Wait_Source (Item : in out Gate; FD : out Interfaces.C.int; Already_Requested : out Boolean) is
   begin
      loop
         declare
            Guard : aliased Initialization_Guard;
         begin
            Guard.State := Item.State'Unchecked_Access;
            Guard.Kind := Shutdown_Source;
            Item.State.Begin_Shutdown_Wait (Guard'Access, FD, Already_Requested);
            if Already_Requested or else FD >= 0 then
               return;
            elsif Guard.Armed then
               Flyology.Wake_Sources.Ensure (Item.Shutdown_Wake);
               Item.State.Publish_Source
                 (Shutdown_Source,
                  Flyology.Wake_Sources.Descriptor (Item.Shutdown_Wake),
                  Flyology.Wake_Sources.Signal_Descriptor (Item.Shutdown_Wake));
               Guard.Armed := False;
            else
               Item.State.Wait_Shutdown_Ready;
            end if;
         end;
      end loop;
   end Wait_Source;

   procedure Acquire_Wait_Source (Item : in out Gate; FD : out Interfaces.C.int; Can_Acquire : out Boolean) is
      Stable : Boolean;
   begin
      loop
         declare
            Guard : aliased Initialization_Guard;
         begin
            Guard.State := Item.State'Unchecked_Access;
            Guard.Kind := Acquire_Source;
            Item.State.Begin_Acquire_Wait (Guard'Access, FD, Can_Acquire, Stable);
            if Can_Acquire or else (Stable and then FD >= 0) then
               return;
            elsif Guard.Armed then
               Flyology.Wake_Sources.Ensure (Item.Acquire_Wake);
               Item.State.Publish_Source
                 (Acquire_Source,
                  Flyology.Wake_Sources.Descriptor (Item.Acquire_Wake),
                  Flyology.Wake_Sources.Signal_Descriptor (Item.Acquire_Wake));
               Guard.Armed := False;
            else
               Item.State.Wait_Acquire_Ready;
            end if;
         end;
      end loop;
   end Acquire_Wait_Source;

   procedure Timed_Acquire
     (Item          : in out Gate;
      Timeout       : Duration;
      Result        : out Acquire_Result;
      Cleanup_Armed : access Boolean := null)
   is
      Accepted : Boolean := False;
      Guard    : aliased Action_Guard;
   begin
      if Cleanup_Armed /= null and then Cleanup_Armed.all then
         raise Program_Error with "capacity cleanup is already armed";
      end if;
      Guard.State := Item.State'Unchecked_Access;
      Guard.Source := Item.Acquire_Wake'Unchecked_Access;
      if Timeout < 0.0 then
         Item.State.Take_Permit (Accepted, Cleanup_Armed, Guard.Claim'Access);
      else
         select
            Item.State.Take_Permit (Accepted, Cleanup_Armed, Guard.Claim'Access);
         or
            delay Timeout;
            Result := Acquire_Timed_Out;
            return;
         end select;
      end if;
      Flush (Guard);
      Result := (if Accepted then Permit_Acquired else Gate_Closed);
   end Timed_Acquire;

end Flyology.Capacity;
