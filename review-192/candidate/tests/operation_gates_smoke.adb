with Ada.Exceptions;
with Ada.Streams;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.IO.Timers;
with Flyology.Operations;
with Flyology.Operations.Drivers;
with Flyology.Wake_Sources;

procedure Operation_Gates_Smoke is
   use type Flyology.Execution_Model;
   use type Flyology.Operations.Driver_Event;
   use type Flyology.Operations.Terminal_Outcome;

   type Multi_Source_Operation (Set : not null access Flyology.Operations.Completion_Set'Class) is
     new Flyology.Operations.Operation (Set)
   with null record;

   overriding
   procedure Drive (Item : in out Multi_Source_Operation; Event : Flyology.Operations.Driver_Event);

   overriding
   procedure Request_Cancellation (Item : in out Multi_Source_Operation);

   type Rescheduling_Operation (Set : not null access Flyology.Operations.Completion_Set'Class) is
     new Flyology.Operations.Operation (Set)
   with null record;

   overriding
   procedure Drive (Item : in out Rescheduling_Operation; Event : Flyology.Operations.Driver_Event);

   overriding
   procedure Request_Cancellation (Item : in out Rescheduling_Operation);

   type Deadline_Readiness_Operation (Set : not null access Flyology.Operations.Completion_Set'Class) is
     new Flyology.Operations.Operation (Set)
   with null record;

   overriding
   procedure Drive (Item : in out Deadline_Readiness_Operation; Event : Flyology.Operations.Driver_Event);

   overriding
   procedure Request_Cancellation (Item : in out Deadline_Readiness_Operation);

   overriding
   procedure Drive (Item : in out Multi_Source_Operation; Event : Flyology.Operations.Driver_Event) is
   begin
      if Event /= Flyology.Operations.Source_Ready then
         raise Program_Error with "unexpected multi-source driver event";
      end if;
      Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out Multi_Source_Operation) is
   begin
      Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
   end Request_Cancellation;

   overriding
   procedure Drive (Item : in out Rescheduling_Operation; Event : Flyology.Operations.Driver_Event) is
   begin
      if Event /= Flyology.Operations.Continue_Operation then
         raise Program_Error with "unexpected rescheduling driver event";
      end if;
      Flyology.Operations.Drivers.Reschedule (Item);
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out Rescheduling_Operation) is
   begin
      Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
   end Request_Cancellation;

   overriding
   procedure Drive (Item : in out Deadline_Readiness_Operation; Event : Flyology.Operations.Driver_Event) is
   begin
      case Event is
         when Flyology.Operations.Source_Ready     =>
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);

         when Flyology.Operations.Deadline_Reached =>
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);

         when others                               =>
            raise Program_Error with "unexpected deadline-readiness driver event";
      end case;
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out Deadline_Readiness_Operation) is
   begin
      Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
   end Request_Cancellation;

   protected Result is
      procedure Set (Passed : Boolean);
      entry Wait (Passed : out Boolean);
   private
      Done : Boolean := False;
      OK   : Boolean := False;
   end Result;

   protected body Result is
      procedure Set (Passed : Boolean) is
      begin
         OK := Passed;
         Done := True;
      end Set;

      entry Wait (Passed : out Boolean) when Done is
      begin
         Passed := OK;
         Done := False;
      end Wait;
   end Result;

   function Ref (Item : Flyology.Operations.Operation'Class) return Flyology.Operations.Operation_Reference
   renames Flyology.Operations.Reference;

   function Contains (Batch : Flyology.Operations.Completion_Batch; Id : Natural) return Boolean is
   begin
      for Position in 1 .. Batch.Count loop
         if Natural (Batch.Ids (Position)) = Id then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

   procedure Finish_Cancelled (Item : in out Flyology.IO.Timers.Timer_Operation) is
   begin
      Flyology.IO.Timers.Finish (Item);
      raise Program_Error with "cancelled timer finished successfully";
   exception
      when Flyology.Operations.Operation_Cancelled =>
         null;
   end Finish_Cancelled;

   task type Runner (Model : Flyology.Execution_Model) is
      pragma Task_Info (Model);
   end Runner;

   task body Runner is
      Passed : Boolean := True;
   begin
      --  One operation can wait on several heterogeneous lifecycle/readiness
      --  descriptors while retaining one completion-set slot. Readiness of
      --  either descriptor resumes the same driver exactly once.
      declare
         package Sockets renames Flyology.IO.Sockets;
         Left_1, Right_1, Left_2, Right_2 : Sockets.Socket_Type;
         Set                              : aliased Flyology.Operations.Completion_Set (1);
         Item                             : Multi_Source_Operation (Set'Access);
         Data                             : constant Ada.Streams.Stream_Element_Array := [1 => 42];
         Last                             : Ada.Streams.Stream_Element_Offset;
      begin
         Sockets.Create_Socket_Pair (Left_1, Right_1);
         Sockets.Create_Socket_Pair (Left_2, Right_2);
         Sockets.Prepare (Left_1);
         Sockets.Prepare (Left_2);
         Flyology.Operations.Drivers.Start (Item);
         Flyology.Operations.Drivers.Arm_Readiness
           (Item, [(Sockets.Native_Descriptor (Left_1), False), (Sockets.Native_Descriptor (Left_2), False)]);
         Sockets.Send_Socket (Right_2, Data, Last);
         Flyology.Operations.Wait_All (Set);
         Passed := Passed and then Flyology.Operations.Outcome (Item) = Flyology.Operations.Succeeded;
         Flyology.Operations.Consume (Item);
      end;

      --  The documented maximum is a real one-operation capability: six
      --  latched descriptors coexist with an independently armed deadline.
      --  Exercise a signal present at arm, a signal published after arm, the
      --  caller's consume-before-reuse protocol, and cancellation after the
      --  complete set has been armed.
      declare
         type Wake_Source_Array is
           array (Positive range <>) of Flyology.Wake_Sources.Source;
         Wake    :
           Wake_Source_Array
             (1 .. Flyology.Operations.Max_Readiness_Sources_Per_Operation);
         Sources :
           Flyology.Operations.Drivers.Readiness_Source_Array (Wake'Range);
         Set     : aliased Flyology.Operations.Completion_Set (1);
         Item    : Deadline_Readiness_Operation (Set'Access);
      begin
         for Index in Wake'Range loop
            Flyology.Wake_Sources.Ensure (Wake (Index));
            Sources (Index) :=
              (Flyology.Wake_Sources.Descriptor (Wake (Index)), False);
         end loop;

         Flyology.Operations.Drivers.Start (Item);
         Flyology.Operations.Drivers.Arm_Deadline (Item, 1.0);
         Flyology.Wake_Sources.Signal (Wake (2));
         Flyology.Operations.Drivers.Arm_Readiness (Item, Sources);
         Flyology.Operations.Wait_All (Set);
         Passed :=
           Passed
           and then Flyology.Operations.Outcome (Item)
                    = Flyology.Operations.Succeeded;
         Flyology.Operations.Consume (Item);
         Flyology.Wake_Sources.Consume (Wake (2));

         Flyology.Operations.Drivers.Start (Item);
         Flyology.Operations.Drivers.Arm_Deadline (Item, 1.0);
         Flyology.Operations.Drivers.Arm_Readiness (Item, Sources);
         Flyology.Wake_Sources.Signal (Wake (5));
         Flyology.Operations.Wait_All (Set);
         Passed :=
           Passed
           and then Flyology.Operations.Outcome (Item)
                    = Flyology.Operations.Succeeded;
         Flyology.Operations.Consume (Item);
         Flyology.Wake_Sources.Consume (Wake (5));

         --  Consuming the latched source after the operation disarms its
         --  combined wait prevents the prior generation from waking reuse.
         Flyology.Operations.Drivers.Start (Item);
         Flyology.Operations.Drivers.Arm_Deadline (Item, 0.01);
         Flyology.Operations.Drivers.Arm_Readiness (Item, Sources);
         Flyology.Operations.Wait_All (Set);
         Passed :=
           Passed
           and then Flyology.Operations.Outcome (Item)
                    = Flyology.Operations.Failed;
         Flyology.Operations.Consume (Item);

         Flyology.Operations.Drivers.Start (Item);
         Flyology.Operations.Drivers.Arm_Deadline (Item, 1.0);
         Flyology.Operations.Drivers.Arm_Readiness (Item, Sources);
         Flyology.Operations.Cancel (Item);
         Flyology.Wake_Sources.Signal (Wake (4));
         Passed :=
           Passed
           and then Flyology.Operations.Outcome (Item)
                    = Flyology.Operations.Cancelled;
         Flyology.Operations.Consume (Item);
         Flyology.Wake_Sources.Consume (Wake (4));
      end;
      --  A provider may request another immediate owner-stack step after
      --  partial progress. Such a member must not hide an already-completed
      --  sibling from Wait_Some, even when it keeps rescheduling itself.
      declare
         Set   : aliased Flyology.Operations.Completion_Set (2);
         Fast  : Flyology.IO.Timers.Timer_Operation := Flyology.IO.Timers.Sleep_For (Set'Access, 0.0);
         Busy  : Rescheduling_Operation (Set'Access);
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         Flyology.Operations.Drivers.Start (Busy);
         Flyology.Operations.Drivers.Reschedule (Busy);
         Flyology.Operations.Wait_Some (Set, Batch);
         Passed :=
           Passed
           and then Contains (Batch, Flyology.Operations.Id (Fast))
           and then Flyology.Operations.Is_Active (Busy);
         Flyology.IO.Timers.Finish (Fast);
         Flyology.Operations.Cancel (Busy);
         Passed := Passed and then Flyology.Operations.Outcome (Busy) = Flyology.Operations.Cancelled;
         Flyology.Operations.Consume (Busy);
      end;

      --  A provider that continually requests immediate progress must not
      --  starve a different descriptor operation's zero-time readiness poll
      --  or expired deadline.
      declare
         package Sockets renames Flyology.IO.Sockets;
         Left, Right : Sockets.Socket_Type;
         Set         : aliased Flyology.Operations.Completion_Set (2);
         Busy        : Rescheduling_Operation (Set'Access);
         Expiring    : Deadline_Readiness_Operation (Set'Access);
         Batch       : Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         Sockets.Create_Socket_Pair (Left, Right);
         Sockets.Prepare (Left);
         Flyology.Operations.Drivers.Start (Busy);
         Flyology.Operations.Drivers.Reschedule (Busy);
         Flyology.Operations.Drivers.Start (Expiring);
         Flyology.Operations.Drivers.Arm_Readiness (Expiring, Sockets.Native_Descriptor (Left), False);
         Flyology.Operations.Drivers.Arm_Deadline (Expiring, 0.0);
         Flyology.Operations.Wait_Some (Set, Batch);
         Passed :=
           Passed
           and then Contains (Batch, Flyology.Operations.Id (Expiring))
           and then Flyology.Operations.Outcome (Expiring) = Flyology.Operations.Failed
           and then Flyology.Operations.Is_Active (Busy);
         Flyology.Operations.Consume (Expiring);
         Flyology.Operations.Cancel (Busy);
         Flyology.Operations.Consume (Busy);
      end;

      --  Wait_All counts every terminal member outcome, including
      --  cancellation, and retains the complete matching snapshot.
      declare
         Set     : aliased Flyology.Operations.Completion_Set (3);
         Left    : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Right   : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Joined  : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_All (Set'Access, [Ref (Left), Ref (Right)]);
         Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         Flyology.Operations.Cancel (Left);
         Passed := Passed and then Flyology.Operations.Is_Active (Joined);
         Flyology.Operations.Cancel (Right);
         Passed :=
           Passed
           and then Flyology.Operations.Is_Terminal (Joined)
           and then Flyology.Operations.Outcome (Joined) = Flyology.Operations.Succeeded;
         Flyology.Operations.Finish (Joined, Matches);
         Passed :=
           Passed
           and then Matches.Count = 2
           and then Contains (Matches, Flyology.Operations.Id (Left))
           and then Contains (Matches, Flyology.Operations.Id (Right));
         Finish_Cancelled (Left);
         Finish_Cancelled (Right);
      end;

      --  Cancelling an observer gate does not cancel its child. A downstream
      --  success gate sees that cancellation and becomes impossible.
      declare
         Set        : aliased Flyology.Operations.Completion_Set (3);
         Child      : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Observer   : aliased Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_All (Set'Access, [Ref (Child)]);
         Downstream : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_For_Success (Set'Access, [Ref (Observer)]);
         Matches    : Flyology.Operations.Completion_Batch (Set.Capacity);
         Cancelled  : Boolean := False;
      begin
         Flyology.Operations.Cancel (Observer);
         Passed :=
           Passed
           and then Flyology.Operations.Is_Active (Child)
           and then Flyology.Operations.Is_Terminal (Downstream)
           and then Flyology.Operations.Outcome (Downstream) = Flyology.Operations.Failed;
         begin
            Flyology.Operations.Finish (Observer, Matches);
         exception
            when Flyology.Operations.Operation_Cancelled =>
               Cancelled := True;
         end;
         --  Matched is an out parameter and is undefined when Finish raises.
         Passed := Passed and then Cancelled;
         Flyology.Operations.Finish (Downstream, Matches);
         Passed := Passed and then Matches.Count = 1;
         Flyology.Operations.Cancel (Child);
         Finish_Cancelled (Child);
      end;

      --  Threshold validation fails before reserving a gate slot or changing
      --  the member's lifecycle.
      declare
         Set      : aliased Flyology.Operations.Completion_Set (2);
         Child    : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Rejected : Boolean := False;
      begin
         begin
            declare
               Invalid : Flyology.Operations.Gate_Operation :=
                 Flyology.Operations.Wait_Some (Set'Access, [Ref (Child)], Required => 2);
               pragma Unreferenced (Invalid);
            begin
               null;
            end;
         exception
            when Flyology.Operations.Operation_Error =>
               Rejected := True;
         end;
         Passed := Passed and then Rejected and then Flyology.Operations.Is_Active (Child);
         Flyology.Operations.Cancel (Child);
         Finish_Cancelled (Child);
      end;

      --  Duplicate membership is rejected before a gate reserves a slot.
      declare
         Set      : aliased Flyology.Operations.Completion_Set (2);
         Child    : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Rejected : Boolean := False;
      begin
         begin
            declare
               Invalid : Flyology.Operations.Gate_Operation :=
                 Flyology.Operations.Wait_All (Set'Access, [Ref (Child), Ref (Child)]);
               pragma Unreferenced (Invalid);
            begin
               null;
            end;
         exception
            when Flyology.Operations.Operation_Error =>
               Rejected := True;
         end;
         Passed := Passed and then Rejected;
         Flyology.Operations.Cancel (Child);
         Finish_Cancelled (Child);
      end;

      --  A reference carries set identity and cannot cross completion sets.
      declare
         Source_Set : aliased Flyology.Operations.Completion_Set (1);
         Target_Set : aliased Flyology.Operations.Completion_Set (1);
         Child      : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Source_Set'Access, 1.0);
         Rejected   : Boolean := False;
      begin
         begin
            declare
               Invalid : Flyology.Operations.Gate_Operation :=
                 Flyology.Operations.Wait_All (Target_Set'Access, [Ref (Child)]);
               pragma Unreferenced (Invalid);
            begin
               null;
            end;
         exception
            when Flyology.Operations.Operation_Error =>
               Rejected := True;
         end;
         Passed := Passed and then Rejected;
         Flyology.Operations.Cancel (Child);
         Finish_Cancelled (Child);
      end;

      --  Slot reuse advances the generation and invalidates old references.
      declare
         Set      : aliased Flyology.Operations.Completion_Set (2);
         Child    : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Old      : constant Flyology.Operations.Operation_Reference := Ref (Child);
         Rejected : Boolean := False;
      begin
         Flyology.Operations.Cancel (Child);
         Finish_Cancelled (Child);
         Flyology.IO.Timers.Rearm (1.0, Child);
         begin
            declare
               Invalid : Flyology.Operations.Gate_Operation :=
                 Flyology.Operations.Wait_All (Set'Access, [Old]);
               pragma Unreferenced (Invalid);
            begin
               null;
            end;
         exception
            when Flyology.Operations.Operation_Error =>
               Rejected := True;
         end;
         Passed := Passed and then Rejected;
         Flyology.Operations.Cancel (Child);
         Finish_Cancelled (Child);
      end;

      --  Finalization also preserves the slot generation. A reference to an
      --  abandoned object cannot alias a different object that later reuses
      --  its vacant slot.
      declare
         Set      : aliased Flyology.Operations.Completion_Set (2);
         Old      : Flyology.Operations.Operation_Reference;
         Rejected : Boolean := False;
      begin
         declare
            Abandoned : constant Flyology.IO.Timers.Timer_Operation :=
              Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         begin
            Old := Ref (Abandoned);
         end;
         declare
            Replacement : Flyology.IO.Timers.Timer_Operation :=
              Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         begin
            begin
               declare
                  Invalid : Flyology.Operations.Gate_Operation :=
                    Flyology.Operations.Wait_All (Set'Access, [Old]);
                  pragma Unreferenced (Invalid);
               begin
                  null;
               end;
            exception
               when Flyology.Operations.Operation_Error =>
                  Rejected := True;
            end;
            Passed := Passed and then Rejected;
            Flyology.Operations.Cancel (Replacement);
            Finish_Cancelled (Replacement);
         end;
      end;

      --  Gates participate in the same bounded capacity as provider
      --  operations; exhaustion is reported without disturbing the member.
      declare
         Set      : aliased Flyology.Operations.Completion_Set (1);
         Child    : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Rejected : Boolean := False;
      begin
         begin
            declare
               Invalid : Flyology.Operations.Gate_Operation :=
                 Flyology.Operations.Wait_All (Set'Access, [Ref (Child)]);
               pragma Unreferenced (Invalid);
            begin
               null;
            end;
         exception
            when Flyology.Operations.Capacity_Error =>
               Rejected := True;
         end;
         Passed := Passed and then Rejected and then Flyology.Operations.Is_Active (Child);
         Flyology.Operations.Cancel (Child);
         Finish_Cancelled (Child);
      end;

      --  Exercise the exact high bit of the 32-slot dependency masks. Test
      --  storage uses access values only to avoid spelling 31 limited local
      --  declarations; operation initiation itself remains allocation-free.
      declare
         Set     : aliased Flyology.Operations.Completion_Set (Flyology.Operations.Max_Operations);
         type Timer_Access is access Flyology.IO.Timers.Timer_Operation;
         type Timer_Access_Array is array (Positive range <>) of Timer_Access;
         procedure Free is new Ada.Unchecked_Deallocation (Flyology.IO.Timers.Timer_Operation, Timer_Access);
         Items   : Timer_Access_Array (1 .. 31) := (others => null);
         Members : Flyology.Operations.Operation_Reference_Array (1 .. 31);
      begin
         for Position in Items'Range loop
            Items (Position) :=
              new Flyology.IO.Timers.Timer_Operation'(Flyology.IO.Timers.Sleep_For (Set'Access, 1.0));
            Members (Position) := Ref (Items (Position).all);
         end loop;
         declare
            Joined  : Flyology.Operations.Gate_Operation :=
              Flyology.Operations.Wait_All (Set'Access, Members);
            Matches : Flyology.Operations.Completion_Batch (Set.Capacity);
         begin
            Passed := Passed and then Flyology.Operations.Id (Joined) = Flyology.Operations.Max_Operations;
            for Item of Items loop
               Flyology.Operations.Cancel (Item.all);
            end loop;
            Flyology.Operations.Finish (Joined, Matches);
            Passed := Passed and then Matches.Count = Items'Length;
         end;
         for Item of Items loop
            Finish_Cancelled (Item.all);
            Free (Item);
         end loop;
      end;

      --  A member that was already terminal when the gate was constructed is
      --  retained by the same rule as a member terminalized afterward.
      declare
         Set   : aliased Flyology.Operations.Completion_Set (3);
         Fast  : aliased Flyology.IO.Timers.Timer_Operation := Flyology.IO.Timers.Sleep_For (Set'Access, 0.0);
         Slow  : aliased Flyology.IO.Timers.Timer_Operation := Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         Flyology.Operations.Wait_Some (Set, Batch);
         declare
            Joined   : Flyology.Operations.Gate_Operation :=
              Flyology.Operations.Wait_All (Set'Access, [Ref (Fast), Ref (Slow)]);
            Matches  : Flyology.Operations.Completion_Batch (Set.Capacity);
            Rejected : Boolean := False;
         begin
            begin
               Flyology.IO.Timers.Finish (Fast);
            exception
               when Flyology.Operations.Operation_Error =>
                  Rejected := True;
            end;
            Passed := Passed and then Rejected and then Flyology.Operations.Is_Active (Joined);
            Flyology.Operations.Cancel (Slow);
            Flyology.Operations.Finish (Joined, Matches);
            Passed := Passed and then Matches.Count = 2;
         end;
         Flyology.IO.Timers.Finish (Fast);
         Finish_Cancelled (Slow);
      end;

      --  If a member object leaves scope first, finalization retains a bounded
      --  terminal tombstone until the gate detaches. A replacement operation
      --  cannot reuse or be confused with that observed slot.
      declare
         Set     : aliased Flyology.Operations.Completion_Set (4);
         Slow    : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Fast_Id : Natural := 0;

         function Observe_Local return Flyology.Operations.Gate_Operation is
            Fast  : constant Flyology.IO.Timers.Timer_Operation :=
              Flyology.IO.Timers.Sleep_For (Set'Access, 0.0);
            Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
         begin
            Flyology.Operations.Wait_Some (Set, Batch);
            Fast_Id := Flyology.Operations.Id (Fast);
            return Flyology.Operations.Wait_All (Set'Access, [Ref (Fast), Ref (Slow)]);
         end Observe_Local;

         Joined      : Flyology.Operations.Gate_Operation := Observe_Local;
         Replacement : Flyology.IO.Timers.Timer_Operation := Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Matches     : Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         Passed := Passed and then Flyology.Operations.Id (Replacement) /= Fast_Id;
         Flyology.Operations.Cancel (Slow);
         Flyology.Operations.Finish (Joined, Matches);
         Passed :=
           Passed
           and then Matches.Count = 2
           and then Contains (Matches, Fast_Id)
           and then Contains (Matches, Flyology.Operations.Id (Slow));
         Flyology.Operations.Cancel (Replacement);
         Finish_Cancelled (Replacement);
         Finish_Cancelled (Slow);
      end;

      --  Gate finalization is observer-only cleanup. It detaches dependencies,
      --  releases its slot, and leaves a pending provider operation active.
      declare
         Set   : aliased Flyology.Operations.Completion_Set (2);
         Child : aliased Flyology.IO.Timers.Timer_Operation := Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
      begin
         declare
            Abandoned : Flyology.Operations.Gate_Operation :=
              Flyology.Operations.Wait_All (Set'Access, [Ref (Child)]);
            pragma Unreferenced (Abandoned);
         begin
            null;
         end;
         declare
            Replacement : Flyology.IO.Timers.Timer_Operation :=
              Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         begin
            Passed :=
              Passed
              and then Flyology.Operations.Is_Active (Child)
              and then Flyology.Operations.Is_Active (Replacement);
            Flyology.Operations.Cancel (Replacement);
            Finish_Cancelled (Replacement);
         end;
         Flyology.Operations.Cancel (Child);
         Finish_Cancelled (Child);
      end;

      --  One scheduler batch closes the complete dependency graph. Multiple
      --  observers of one member and their downstream join are each reported
      --  exactly once in ascending slot order.
      declare
         Set        : aliased Flyology.Operations.Completion_Set (4);
         Child      : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 0.0);
         Observer_1 : aliased Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_All (Set'Access, [Ref (Child)]);
         Observer_2 : aliased Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_For_Success (Set'Access, [Ref (Child)]);
         Joined     : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_All (Set'Access, [Ref (Observer_1), Ref (Observer_2)]);
         Batch      : Flyology.Operations.Completion_Batch (Set.Capacity);
         Matches    : Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         Flyology.Operations.Wait_Some (Set, Batch);
         Passed := Passed and then Batch.Count = 4;
         for Position in 1 .. Batch.Count loop
            Passed := Passed and then Natural (Batch.Ids (Position)) = Position;
         end loop;
         Flyology.Operations.Finish (Joined, Matches);
         Flyology.Operations.Finish (Observer_2, Matches);
         Flyology.Operations.Finish (Observer_1, Matches);
         Flyology.IO.Timers.Finish (Child);
      end;

      --  The direct counted waits return a stable, ascending batch. If the
      --  set becomes quiescent first, they return the smaller remaining batch
      --  instead of waiting forever for an impossible terminal count.
      declare
         Set    : aliased Flyology.Operations.Completion_Set (3);
         First  : Flyology.IO.Timers.Timer_Operation := Flyology.IO.Timers.Sleep_For (Set'Access, 0.0);
         Second : Flyology.IO.Timers.Timer_Operation := Flyology.IO.Timers.Sleep_For (Set'Access, 0.0);
         Batch  : Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         Flyology.Operations.Wait_At_Least (Set, 2, Batch);
         Passed :=
           Passed
           and then Batch.Count = 2
           and then Batch.Ids (1) = Flyology.Operations.Id (First)
           and then Batch.Ids (2) = Flyology.Operations.Id (Second);
         Flyology.IO.Timers.Finish (First);
         Flyology.IO.Timers.Finish (Second);
      end;

      declare
         Set   : aliased Flyology.Operations.Completion_Set (3);
         Only  : Flyology.IO.Timers.Timer_Operation := Flyology.IO.Timers.Sleep_For (Set'Access, 0.0);
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         Flyology.Operations.Wait_Some (Set, Required => 3, Completed => Batch);
         Passed := Passed and then Batch.Count = 1 and then Contains (Batch, Flyology.Operations.Id (Only));
         Flyology.IO.Timers.Finish (Only);
      end;

      --  Direct success waits use the same outcome accounting as first-class
      --  gates. Cancellation is reported but cannot satisfy the threshold.
      declare
         Set       : aliased Flyology.Operations.Completion_Set (2);
         Success   : Flyology.IO.Timers.Timer_Operation := Flyology.IO.Timers.Sleep_For (Set'Access, 0.0);
         Cancelled : Flyology.IO.Timers.Timer_Operation := Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Batch     : Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         Flyology.Operations.Cancel (Cancelled);
         Flyology.Operations.Wait_For_Success (Set, Batch);
         Passed :=
           Passed
           and then Batch.Count = 2
           and then Contains (Batch, Flyology.Operations.Id (Success))
           and then Contains (Batch, Flyology.Operations.Id (Cancelled));
         Flyology.IO.Timers.Finish (Success);
         Finish_Cancelled (Cancelled);
      end;

      declare
         Set   : aliased Flyology.Operations.Completion_Set (2);
         Left  : Flyology.IO.Timers.Timer_Operation := Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Right : Flyology.IO.Timers.Timer_Operation := Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Batch : Flyology.Operations.Completion_Batch (Set.Capacity);
      begin
         Flyology.Operations.Cancel (Left);
         Flyology.Operations.Cancel (Right);
         Flyology.Operations.Wait_For_Successes (Set, 1, Batch);
         Passed := Passed and then Batch.Count = 2;
         Finish_Cancelled (Left);
         Finish_Cancelled (Right);
      end;

      --  A terminal member remains retained while a pending gate depends on
      --  it. Finish is rejected until the gate detaches at its own terminal
      --  transition, then both results can be consumed normally.
      declare
         Set      : aliased Flyology.Operations.Completion_Set (3);
         Fast     : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 0.0);
         Slow     : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Joined   : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_All (Set'Access, [Ref (Fast), Ref (Slow)]);
         Batch    : Flyology.Operations.Completion_Batch (Set.Capacity);
         Matches  : Flyology.Operations.Completion_Batch (Set.Capacity);
         Rejected : Boolean := False;
      begin
         Flyology.Operations.Wait_Some (Set, Batch);
         begin
            Flyology.IO.Timers.Finish (Fast);
         exception
            when Flyology.Operations.Operation_Error =>
               Rejected := True;
         end;
         Passed := Passed and then Rejected and then Flyology.Operations.Is_Active (Joined);
         Flyology.Operations.Cancel (Slow);
         Flyology.Operations.Finish (Joined, Matches);
         Passed := Passed and then Matches.Count = 2;
         Flyology.IO.Timers.Finish (Fast);
         Finish_Cancelled (Slow);
      end;

      --  Finish is the explicit one-shot result-consumption boundary. It
      --  rejects a pending gate and a second Finish of a consumed gate.
      declare
         Set              : aliased Flyology.Operations.Completion_Set (2);
         Child            : aliased Flyology.IO.Timers.Timer_Operation :=
           Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
         Gate             : Flyology.Operations.Gate_Operation :=
           Flyology.Operations.Wait_All (Set'Access, [Ref (Child)]);
         Matches          : Flyology.Operations.Completion_Batch (Set.Capacity);
         Pending_Rejected : Boolean := False;
         Double_Rejected  : Boolean := False;
      begin
         begin
            Flyology.Operations.Finish (Gate, Matches);
         exception
            when Flyology.Operations.Operation_Error =>
               Pending_Rejected := True;
         end;
         Flyology.Operations.Cancel (Child);
         Flyology.Operations.Finish (Gate, Matches);
         begin
            Flyology.Operations.Finish (Gate, Matches);
         exception
            when Flyology.Operations.Operation_Error =>
               Double_Rejected := True;
         end;
         Passed := Passed and then Pending_Rejected and then Double_Rejected;
         Finish_Cancelled (Child);
      end;

      Result.Set (Passed);
   exception
      when Error : others =>
         Ada.Text_IO.Put_Line (Ada.Exceptions.Exception_Information (Error));
         Result.Set (False);
   end Runner;

   type Runner_Access is access Runner;
   Native      : Runner_Access;
   Lightweight : Runner_Access;
   pragma Unreferenced (Native, Lightweight);
   Passed      : Boolean;
begin
   Native := new Runner (Flyology.Native_Task);
   Result.Wait (Passed);
   pragma Assert (Passed);

   Lightweight := new Runner (Flyology.Lightweight_Task);
   Result.Wait (Passed);
   pragma Assert (Passed);
end Operation_Gates_Smoke;
