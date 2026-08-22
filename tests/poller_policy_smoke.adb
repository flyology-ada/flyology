with System.Flyology.Poller_Policy;

procedure Poller_Policy_Smoke is
   package Policy renames System.Flyology.Poller_Policy;

   use type Policy.Cancel_Outcome;

   Capacity : constant Policy.Batch_Capacity := Policy.Max_Batch_Capacity;
   State    : Policy.Drain_State;
   Plan     : Policy.Batch_Plan;
   Budget   : Policy.Drain_Budget;

   --  Keep the test linked through libgnarl, where the production runtime
   --  policy unit lives. An undesignated Ada task remains native by default.
   task Runtime_Link;

   task body Runtime_Link is
   begin
      null;
   end Runtime_Link;
begin
   if Policy.Remaining_Budget (Capacity, 0) /= Capacity
     or else Policy.Remaining_Budget (Capacity, Capacity) /= 0
   then
      raise Program_Error with "poller policy capacity boundary failed";
   end if;

   --  Model the historical failure boundary: the file wake is consumed, then
   --  64 socket events fill the following epoll batch. With no trailing room,
   --  the obligation must remain latched and reserve the next batch's first
   --  file-drain turn.
   State := Policy.After_Wake (State);
   Budget := Policy.Remaining_Budget (Capacity, Capacity);
   State := Policy.After_Batch (State, Capacity, Delivered => Capacity, Only_File_Events => False);
   Plan := Policy.Plan_Batch (State, Capacity);
   if Budget /= 0
     or else not State.Pending
     or else Plan.Initial_Drain_Budget /= 1
     or else Policy.Remaining_Budget (Capacity, Plan.Initial_Drain_Budget) /= Capacity - 1
   then
      raise Program_Error with "full epoll batch discarded the file-drain obligation";
   end if;

   State := Policy.After_Drain (Plan.State, May_Remain => False);
   if State.Pending then
      raise Program_Error with "completed file drain remained pending";
   end if;

   State := Policy.After_Wake (State);
   Plan := Policy.Plan_Batch (State, Capacity);
   State := Policy.After_Drain (Plan.State, May_Remain => True);
   Plan := Policy.Plan_Batch (State, Capacity);
   if not State.Pending or else Plan.Initial_Drain_Budget /= 1 then
      raise Program_Error with "conservative file-drain report was not retained";
   end if;

   --  A one-result caller alternates after a file-only batch. Skipping one
   --  initial drain for epoll fairness preserves the obligation, and the
   --  following batch must restore the file-drain turn.
   State := (Pending => False, File_Only_Last_Batch => False);
   State := Policy.After_Wake (State);
   Plan := Policy.Plan_Batch (State, Capacity => 1);
   State := Policy.After_Drain (Plan.State, May_Remain => True);
   State := Policy.After_Batch (State, Capacity => 1, Delivered => 1, Only_File_Events => True);
   Plan := Policy.Plan_Batch (State, Capacity => 1);
   if Plan.Initial_Drain_Budget /= 0 or else not Plan.State.Pending or else Plan.State.File_Only_Last_Batch
   then
      raise Program_Error with "one-result epoll turn was not selected";
   end if;

   State := Policy.After_Batch (Plan.State, Capacity => 1, Delivered => 1, Only_File_Events => False);
   Plan := Policy.Plan_Batch (State, Capacity => 1);
   if Plan.Initial_Drain_Budget /= 1 then
      raise Program_Error with "one-result alternation skipped the retained file drain";
   end if;

   --  Cancellation is idempotent for an interest the kernel no longer holds.
   --  A consumed one-shot interest answers ENOENT, and a descriptor closed
   --  under an armed interest answers EBADF; neither may reach the scheduler
   --  as a poller failure, because that turns an ordinary close race into a
   --  process abort.
   if Policy.Classify_Cancel (Succeeded => True, Error => 0) /= Policy.Interest_Cleared
     or else Policy.Classify_Cancel (Succeeded => False, Error => Policy.Interest_Absent_Error)
             /= Policy.Registration_Gone
     or else Policy.Classify_Cancel (Succeeded => False, Error => Policy.Descriptor_Closed_Error)
             /= Policy.Registration_Gone
   then
      raise Program_Error with "poller cancellation is not idempotent for an absent registration";
   end if;

   if Policy.Classify_Cancel (Succeeded => False, Error => 22) /= Policy.Cancel_Failed then
      raise Program_Error with "poller cancellation accepted an unexpected platform error";
   end if;
end Poller_Policy_Smoke;
