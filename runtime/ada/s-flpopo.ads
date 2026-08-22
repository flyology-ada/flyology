package System.Flyology.Poller_Policy
  with Preelaborate, SPARK_Mode
is
   Max_Batch_Capacity : constant := 64;

   subtype Batch_Capacity is Positive range 1 .. Max_Batch_Capacity;
   subtype Batch_Count is Natural range 0 .. Max_Batch_Capacity;
   subtype Drain_Budget is Batch_Count;

   type Drain_State is record
      Pending              : Boolean := False;
      File_Only_Last_Batch : Boolean := False;
   end record;

   type Batch_Plan is record
      State                : Drain_State;
      Initial_Drain_Budget : Drain_Budget;
   end record;

   --  Result of asking the platform to drop one armed readiness interest.
   type Cancel_Outcome is (Interest_Cleared, Registration_Gone, Cancel_Failed);

   --  POSIX error numbers that report an interest the kernel no longer holds.
   --  Darwin and Linux agree on both values, so the classification below is
   --  platform-neutral.
   Interest_Absent_Error   : constant := 2;  --  ENOENT
   Descriptor_Closed_Error : constant := 9;  --  EBADF

   --  Classify one epoll or kqueue cancellation request. Cancellation is
   --  idempotent for a one-shot interest the kernel already consumed, which
   --  reports ENOENT, and for a descriptor whose owner closed it while the
   --  interest was armed, which reports EBADF because the registration went
   --  with the descriptor. Only a poller that can no longer manage its own
   --  registrations is a failure.
   function Classify_Cancel (Succeeded : Boolean; Error : Integer) return Cancel_Outcome
   with
     Post =>
       Classify_Cancel'Result
       = (if Succeeded
          then Interest_Cleared
          elsif Error = Interest_Absent_Error or else Error = Descriptor_Closed_Error
          then Registration_Gone
          else Cancel_Failed);
   pragma Inline_Always (Classify_Cancel);

   --  Plan the bounded file-drain turn that precedes the epoll probe. A
   --  retained obligation receives one slot unless a one-result caller must
   --  first take its alternating epoll turn.
   function Plan_Batch (State : Drain_State; Capacity : Batch_Capacity) return Batch_Plan
   with
     Post =>
       Plan_Batch'Result.Initial_Drain_Budget <= Capacity
       and then Plan_Batch'Result.State.Pending = State.Pending
       and then Plan_Batch'Result.Initial_Drain_Budget
                = (if State.Pending and then (Capacity > 1 or else not State.File_Only_Last_Batch)
                   then 1
                   else 0)
       and then Plan_Batch'Result.State.File_Only_Last_Batch
                = (if Capacity = 1
                     and then State.File_Only_Last_Batch
                     and then Plan_Batch'Result.Initial_Drain_Budget = 0
                   then False
                   else State.File_Only_Last_Batch);
   pragma Inline_Always (Plan_Batch);

   --  Return the output room left after an epoll batch. A saturated batch has
   --  no trailing drain budget; any retained obligation remains state, not a
   --  readiness edge.
   function Remaining_Budget (Capacity : Batch_Capacity; Delivered : Batch_Count) return Drain_Budget
   with
     Pre  => Delivered <= Capacity,
     Post =>
       Remaining_Budget'Result + Delivered = Capacity
       and then (Remaining_Budget'Result = 0) = (Delivered = Capacity);
   pragma Inline_Always (Remaining_Budget);

   --  Consuming the shared eventfd latches a file-drain obligation. This
   --  transition does not assert that a kernel completion exists.
   function After_Wake (State : Drain_State) return Drain_State
   with
     Post =>
       After_Wake'Result.Pending and then After_Wake'Result.File_Only_Last_Batch = State.File_Only_Last_Batch;
   pragma Inline_Always (After_Wake);

   --  Replace the obligation with the file engine's conservative report
   --  after a drain attempt.
   function After_Drain (State : Drain_State; May_Remain : Boolean) return Drain_State
   with
     Post =>
       After_Drain'Result.Pending = May_Remain
       and then After_Drain'Result.File_Only_Last_Batch = State.File_Only_Last_Batch;
   pragma Inline_Always (After_Drain);

   --  Record whether a completed batch contained only file completions. The
   --  one-result case controls source alternation. Pending is intentionally
   --  preserved across a full epoll batch that had no trailing drain room.
   function After_Batch
     (State : Drain_State; Capacity : Batch_Capacity; Delivered : Batch_Count; Only_File_Events : Boolean)
      return Drain_State
   with
     Pre  => Delivered <= Capacity and then (if Only_File_Events then Delivered > 0),
     Post =>
       After_Batch'Result.Pending = State.Pending
       and then After_Batch'Result.File_Only_Last_Batch
                = (Capacity = 1 and then Delivered = 1 and then Only_File_Events);
   pragma Inline_Always (After_Batch);

end System.Flyology.Poller_Policy;
