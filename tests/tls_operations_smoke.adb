with Ada.Exceptions;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.Cancellation;
with Flyology.IO.Sockets;
with Flyology.IO.Timers;
with Flyology.IO.TLS;
with Flyology.IO.TLS.Drivers;
with Flyology.Operations;
with Flyology.Operations.Drivers;
with TLS_Test_Provider;

procedure TLS_Operations_Smoke is
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;
   package TLS_Drivers renames Flyology.IO.TLS.Drivers;
   package Provider renames TLS_Test_Provider;

   use Ada.Streams;
   use type TLS_Drivers.Acquisition_Result;
   use type TLS_Drivers.Step_Result;
   use type Flyology.Operations.Driver_Event;
   use type Flyology.Operations.Terminal_Outcome;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   function Ref (Item : Flyology.Operations.Operation'Class) return Flyology.Operations.Operation_Reference
   renames Flyology.Operations.Reference;

   procedure Close_If_Open (Socket : in out Sockets.Socket_Type) is
   begin
      if Sockets.Is_Open (Socket) then
         Sockets.Close_Socket (Socket);
      end if;
   exception
      when others =>
         null;
   end Close_If_Open;

   type Stream_Array_Access is access all Stream_Element_Array;
   type Synthetic_Phase is (Handshake_Phase, Receive_Phase, Send_Phase, Shutdown_Phase);

   type Synthetic_Receive_Operation
     (Set  : not null access Flyology.Operations.Completion_Set'Class;
      Item : not null access TLS.Connection'Class)
   is new Flyology.Operations.Operation (Set) with record
      IO        : TLS_Drivers.Capability;
      Data      : Stream_Array_Access := null;
      Last      : Stream_Element_Offset := 0;
      Acquiring : Boolean := True;
      Phase     : Synthetic_Phase := Handshake_Phase;
   end record;

   overriding
   procedure Drive (Item : in out Synthetic_Receive_Operation; Event : Flyology.Operations.Driver_Event);
   overriding
   procedure Request_Cancellation (Item : in out Synthetic_Receive_Operation);

   overriding
   procedure Drive (Item : in out Synthetic_Receive_Operation; Event : Flyology.Operations.Driver_Event) is
      Acquired : TLS_Drivers.Acquisition_Result;
      Step     : TLS_Drivers.Step_Result;
   begin
      if Event = Flyology.Operations.Deadline_Reached then
         TLS_Drivers.Release (Item.IO);
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
         return;
      elsif Event = Flyology.Operations.Start_Operation then
         TLS_Drivers.Start (Item.IO, Item.Item, Acquired, Timeout => 1.0);
         TLS_Drivers.Arm_Deadline (Item.IO, Item);
      elsif Item.Acquiring then
         TLS_Drivers.Poll_Acquisition (Item.IO, Acquired);
      else
         Acquired := TLS_Drivers.Acquired;
      end if;

      if Acquired = TLS_Drivers.Need_Acquire_Readiness then
         TLS_Drivers.Arm_Acquisition (Item.IO, Item);
         return;
      end if;
      Item.Acquiring := False;
      case Item.Phase is
         when Handshake_Phase =>
            TLS_Drivers.Handshake (Item.IO, Step);

         when Receive_Phase   =>
            TLS_Drivers.Receive (Item.IO, Item.Data.all, Item.Last, Step);

         when Send_Phase      =>
            TLS_Drivers.Send (Item.IO, Item.Data.all, Item.Last, Step);

         when Shutdown_Phase  =>
            TLS_Drivers.Shutdown (Item.IO, Step);
      end case;
      case Step is
         when TLS_Drivers.Made_Progress                      =>
            if Item.Phase = Synthetic_Phase'Last then
               TLS_Drivers.Release (Item.IO);
               Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Succeeded);
            else
               Item.Phase := Synthetic_Phase'Succ (Item.Phase);
               Flyology.Operations.Drivers.Reschedule (Item);
            end if;

         when TLS_Drivers.Peer_Closed                        =>
            TLS_Drivers.Release (Item.IO);
            Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);

         when TLS_Drivers.Need_Read | TLS_Drivers.Need_Write =>
            TLS_Drivers.Arm_Transport (Item.IO, Item, Step);
      end case;
   exception
      when others =>
         begin
            TLS_Drivers.Release (Item.IO);
         exception
            when others =>
               null;
         end;
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
   end Drive;

   overriding
   procedure Request_Cancellation (Item : in out Synthetic_Receive_Operation) is
   begin
      TLS_Drivers.Cancel (Item.IO);
      Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Cancelled);
   exception
      when others =>
         Flyology.Operations.Drivers.Complete (Item, Flyology.Operations.Failed);
   end Request_Cancellation;

   protected Results is
      procedure Publish (Passed : Boolean);
      entry Await_All (Passed : out Boolean);
   private
      Count : Natural range 0 .. 2 := 0;
      Value : Boolean := True;
   end Results;

   protected body Results is
      procedure Publish (Passed : Boolean) is
      begin
         Value := Value and Passed;
         Count := Count + 1;
      end Publish;

      entry Await_All (Passed : out Boolean) when Count = 2 is
      begin
         Passed := Value;
      end Await_All;
   end Results;

   task type Runner (Model : Flyology.Execution_Model) is
      pragma Task_Info (Model);
   end Runner;

   task body Runner is
      Passed : constant Boolean := True;
   begin
      --  Every familiar standalone TLS primitive has an eager operation
      --  overload. Five operations queue on one connection lease while two
      --  gates and a timer share the same bounded set.
      declare
         Backend : Provider.Provider;
         Socket  : Sockets.Socket_Type;
         Peer    : Sockets.Socket_Type;
         Item    : aliased TLS.Connection;
         One     : aliased Stream_Element_Array := [1 => 0];
         Exact   : aliased Stream_Element_Array := [1 => 0, 2 => 0];
         Output  : aliased constant Stream_Element_Array := [1 => 7, 2 => 8];
      begin
         Sockets.Create_Socket_Pair (Socket, Peer);
         TLS.Take (Backend, Socket, TLS.Server, "", Item);
         --  The test provider reports WANT_READ without consuming transport
         --  bytes, so one byte keeps the descriptor deterministically ready.
         Sockets.Send_All (Peer, [1 => 91]);
         declare
            Set         : aliased Flyology.Operations.Completion_Set (8);
            Handshake   : aliased TLS.Handshake_Operation :=
              TLS.Handshake (Set'Access, Item'Access, Timeout => 1.0);
            Receive     : aliased TLS.Receive_Operation :=
              TLS.Receive (Set'Access, Item'Access, One'Access, Timeout => 1.0);
            Receive_All : aliased TLS.Receive_Exactly_Operation :=
              TLS.Receive_Exactly (Set'Access, Item'Access, Exact'Access, Timeout => 1.0);
            Send        : aliased TLS.Send_All_Operation :=
              TLS.Send_All (Set'Access, Item'Access, Output'Access, Timeout => 1.0);
            Shutdown    : aliased TLS.Shutdown_Operation :=
              TLS.Shutdown (Set'Access, Item'Access, Timeout => 1.0);
            Alarm       : aliased Flyology.IO.Timers.Timer_Operation :=
              Flyology.IO.Timers.Sleep_For (Set'Access, 1.0);
            First       : Flyology.Operations.Gate_Operation :=
              Flyology.Operations.Wait_For_Success (Set'Access, [Ref (Handshake), Ref (Alarm)]);
            All_Success : Flyology.Operations.Gate_Operation :=
              Flyology.Operations.Wait_For_Successes
                (Set'Access,
                 [Ref (Handshake), Ref (Receive), Ref (Receive_All), Ref (Send), Ref (Shutdown)],
                 Required => 5);
            Batch       : Flyology.Operations.Completion_Batch (Set.Capacity);
            Matches     : Flyology.Operations.Completion_Batch (Set.Capacity);
            Last        : Stream_Element_Offset;
            All_Outcome : Flyology.Operations.Terminal_Outcome := Flyology.Operations.Succeeded;
         begin
            while not Flyology.Operations.Is_Terminal (All_Success) loop
               Flyology.Operations.Wait_Some (Set, Required => 2, Completed => Batch);
            end loop;
            Check
              (Flyology.Operations.Is_Terminal (First)
               and then Flyology.Operations.Outcome (First) = Flyology.Operations.Succeeded,
               "standalone TLS success race did not complete");
            Flyology.Operations.Finish (First, Matches);
            Check (Matches.Count >= 1, "success gate returned no member");
            All_Outcome := Flyology.Operations.Outcome (All_Success);
            Flyology.Operations.Finish (All_Success, Matches);
            Check
              (All_Outcome = Flyology.Operations.Succeeded and then Matches.Count = 5,
               "all-success gate lost a successful TLS member");

            if Flyology.Operations.Is_Active (Alarm) then
               Flyology.Operations.Cancel (Alarm);
            end if;
            begin
               Flyology.IO.Timers.Finish (Alarm);
            exception
               when Flyology.Operations.Operation_Cancelled =>
                  null;
            end;

            TLS.Finish (Handshake);
            TLS.Finish (Receive, Last);
            TLS.Finish (Receive_All);
            begin
               TLS.Finish (Send);
            exception
               when Error : others =>
                  raise Program_Error
                    with "scoped TLS send failed: " & Ada.Exceptions.Exception_Information (Error);
            end;
            TLS.Finish (Shutdown);
            Check
              (Last = One'Last and then One = [42] and then Exact = [42, 42],
               "standalone TLS operation data mismatch");

            --  Reusable overloads retain their operation slots and restart
            --  the same provider state without allocating new wait objects.
            TLS.Handshake (Item'Access, Timeout => 1.0, Operation => Handshake);
            TLS.Receive (Item'Access, One'Access, Timeout => 1.0, Operation => Receive);
            TLS.Receive_Exactly (Item'Access, Exact'Access, Timeout => 1.0, Operation => Receive_All);
            TLS.Send_All (Item'Access, Output'Access, Timeout => 1.0, Operation => Send);
            TLS.Shutdown (Item'Access, Timeout => 1.0, Operation => Shutdown);
            Flyology.Operations.Wait_All (Set);
            TLS.Finish (Handshake);
            TLS.Finish (Receive, Last);
            TLS.Finish (Receive_All);
            TLS.Finish (Send);
            TLS.Finish (Shutdown);
         end;
         TLS.Close (Item);
         Close_If_Open (Peer);
      end;

      --  Timeout zero is an immediate poll, not an automatic failure. Empty
      --  data operations still validate and acquire the open connection.
      declare
         Backend   : Provider.Provider;
         Socket    : Sockets.Socket_Type;
         Peer      : Sockets.Socket_Type;
         Item      : aliased TLS.Connection;
         Empty_In  : aliased Stream_Element_Array := Stream_Element_Array'(1 .. 0 => 0);
         Empty_Out : aliased constant Stream_Element_Array := Stream_Element_Array'(1 .. 0 => 0);
      begin
         Provider.Set_Script
           (Backend, Provider.Handshake_Operation, [1 => (TLS.Complete, Provider.Preserve_Output, 0)]);
         Provider.Set_Script
           (Backend, Provider.Shutdown_Operation, [1 => (TLS.Complete, Provider.Preserve_Output, 0)]);
         Sockets.Create_Socket_Pair (Socket, Peer);
         TLS.Take (Backend, Socket, TLS.Server, "", Item);
         declare
            Set         : aliased Flyology.Operations.Completion_Set (5);
            Handshake   : TLS.Handshake_Operation := TLS.Handshake (Set'Access, Item'Access, Timeout => 0.0);
            Receive     : TLS.Receive_Operation :=
              TLS.Receive (Set'Access, Item'Access, Empty_In'Access, Timeout => 0.0);
            Receive_All : TLS.Receive_Exactly_Operation :=
              TLS.Receive_Exactly (Set'Access, Item'Access, Empty_In'Access, Timeout => 0.0);
            Send        : TLS.Send_All_Operation :=
              TLS.Send_All (Set'Access, Item'Access, Empty_Out'Access, Timeout => 0.0);
            Shutdown    : TLS.Shutdown_Operation := TLS.Shutdown (Set'Access, Item'Access, Timeout => 0.0);
            Last        : Stream_Element_Offset;
         begin
            Flyology.Operations.Wait_All (Set);
            Check
              (Flyology.Operations.Terminal_Count (Set) = 5,
               "zero-time TLS operations did not poll immediately");
            TLS.Finish (Handshake);
            TLS.Finish (Receive, Last);
            TLS.Finish (Receive_All);
            TLS.Finish (Send);
            TLS.Finish (Shutdown);
            Check (Last = Empty_In'First - 1, "empty TLS receive returned the wrong bound");
         end;
         TLS.Close (Item);
         Close_If_Open (Peer);
      end;

      --  A zero deadline still performs the familiar immediate readiness
      --  poll after WANT. A writable socket must permit the next provider
      --  step instead of losing to deadline bookkeeping.
      declare
         Backend : Provider.Provider;
         Socket  : Sockets.Socket_Type;
         Peer    : Sockets.Socket_Type;
         Item    : aliased TLS.Connection;
      begin
         Provider.Set_Script
           (Backend,
            Provider.Handshake_Operation,
            [1 => (TLS.Want_Write, Provider.Preserve_Output, 0),
             2 => (TLS.Complete, Provider.Preserve_Output, 0)]);
         Sockets.Create_Socket_Pair (Socket, Peer);
         TLS.Take (Backend, Socket, TLS.Server, "", Item);
         declare
            Set       : aliased Flyology.Operations.Completion_Set (1);
            Handshake : TLS.Handshake_Operation := TLS.Handshake (Set'Access, Item'Access, Timeout => 0.0);
         begin
            Flyology.Operations.Wait_All (Set);
            Check
              (Flyology.Operations.Outcome (Handshake) = Flyology.Operations.Succeeded,
               "zero-time TLS readiness poll lost to its deadline");
            TLS.Finish (Handshake);
         end;
         TLS.Close (Item);
         Close_If_Open (Peer);
      end;

      --  Readiness receives only one concession at an expired deadline. A
      --  provider that reports WANT again on a level-ready descriptor must
      --  time out instead of spinning through another readiness probe.
      declare
         Backend : Provider.Provider;
         Socket  : Sockets.Socket_Type;
         Peer    : Sockets.Socket_Type;
         Item    : aliased TLS.Connection;
      begin
         Provider.Set_Script
           (Backend,
            Provider.Handshake_Operation,
            [1 => (TLS.Want_Write, Provider.Preserve_Output, 0),
             2 => (TLS.Want_Write, Provider.Preserve_Output, 0),
             3 => (TLS.Complete, Provider.Preserve_Output, 0)]);
         Sockets.Create_Socket_Pair (Socket, Peer);
         TLS.Take (Backend, Socket, TLS.Server, "", Item);
         declare
            Set       : aliased Flyology.Operations.Completion_Set (1);
            Handshake : TLS.Handshake_Operation := TLS.Handshake (Set'Access, Item'Access, Timeout => 0.0);
            Timed_Out : Boolean := False;
         begin
            Flyology.Operations.Wait_All (Set);
            Check
              (Flyology.Operations.Outcome (Handshake) = Flyology.Operations.Failed,
               "repeated ready TLS WANT escaped its expired deadline");
            begin
               TLS.Finish (Handshake);
            exception
               when Flyology.IO.Timeout_Error =>
                  Timed_Out := True;
            end;
            Check (Timed_Out, "repeated ready TLS WANT did not retain its timeout");
         end;
         TLS.Close (Item);
         Close_If_Open (Peer);
      end;

      --  Timeout is retained as the member outcome and raised only by its
      --  typed Finish. The completion-set wait itself remains composable.
      declare
         Backend : Provider.Provider;
         Socket  : Sockets.Socket_Type;
         Peer    : Sockets.Socket_Type;
         Item    : aliased TLS.Connection;
         Data    : aliased Stream_Element_Array := [1 => 99];
         Raised  : Boolean := False;
      begin
         Sockets.Create_Socket_Pair (Socket, Peer);
         TLS.Take (Backend, Socket, TLS.Server, "", Item);
         declare
            Set  : aliased Flyology.Operations.Completion_Set (1);
            Get  : TLS.Receive_Operation :=
              TLS.Receive (Set'Access, Item'Access, Data'Access, Timeout => 0.010);
            Last : Stream_Element_Offset;
         begin
            Flyology.Operations.Wait_All (Set);
            Check
              (Flyology.Operations.Outcome (Get) = Flyology.Operations.Failed,
               "TLS timeout did not become a failed member");
            begin
               TLS.Finish (Get, Last);
            exception
               when Flyology.IO.Timeout_Error =>
                  Raised := True;
            end;
         end;
         Check (Raised, "TLS timeout was not retained for Finish");
         TLS.Close (Item);
         Close_If_Open (Peer);
      end;

      --  Explicit cancellation terminalizes without changing a pending
      --  receive buffer, and implicit finalization releases an active borrow.
      declare
         Backend : Provider.Provider;
         Socket  : Sockets.Socket_Type;
         Peer    : Sockets.Socket_Type;
         Item    : aliased TLS.Connection;
         Data    : aliased Stream_Element_Array := [1 => 77];
         Token   : aliased Flyology.Cancellation.Token;
         Raised  : Boolean := False;
      begin
         Sockets.Create_Socket_Pair (Socket, Peer);
         TLS.Take (Backend, Socket, TLS.Server, "", Item);
         Token.Request;
         declare
            Set  : aliased Flyology.Operations.Completion_Set (1);
            Get  : TLS.Receive_Operation :=
              TLS.Receive (Set'Access, Item'Access, Data'Access, Token => Token'Access);
            Last : Stream_Element_Offset;
         begin
            Flyology.Operations.Wait_All (Set);
            begin
               TLS.Finish (Get, Last);
            exception
               when Flyology.Operations.Operation_Cancelled =>
                  Raised := True;
            end;
            TLS.Receive (Item'Access, Data'Access, Operation => Get);
            Flyology.Operations.Cancel (Get);
            Flyology.Operations.Wait_All (Set);
            begin
               TLS.Finish (Get, Last);
            exception
               when Flyology.Operations.Operation_Cancelled =>
                  null;
            end;
         end;
         Check (Raised and then Data = [77], "TLS cancellation did not preserve the pending buffer");
         declare
            Set       : aliased Flyology.Operations.Completion_Set (1);
            Abandoned : TLS.Receive_Operation := TLS.Receive (Set'Access, Item'Access, Data'Access);
            pragma Unreferenced (Abandoned);
         begin
            null;
         end;
         TLS.Close (Item);
         Close_If_Open (Peer);
      end;

      --  Provider errors are visible to success waits as failed members and
      --  preserve the original TLS exception until typed Finish.
      declare
         Backend : Provider.Provider;
         Socket  : Sockets.Socket_Type;
         Peer    : Sockets.Socket_Type;
         Item    : aliased TLS.Connection;
         Raised  : Boolean := False;
      begin
         Provider.Set_Script
           (Backend, Provider.Handshake_Operation, [1 => (TLS.Failed, Provider.Preserve_Output, 0)]);
         Sockets.Create_Socket_Pair (Socket, Peer);
         TLS.Take (Backend, Socket, TLS.Server, "", Item);
         declare
            Set    : aliased Flyology.Operations.Completion_Set (1);
            Failed : TLS.Handshake_Operation := TLS.Handshake (Set'Access, Item'Access, Timeout => 1.0);
            Batch  : Flyology.Operations.Completion_Batch (Set.Capacity);
         begin
            Flyology.Operations.Wait_For_Success (Set, Batch);
            Check
              (Batch.Count = 1 and then Flyology.Operations.Outcome (Failed) = Flyology.Operations.Failed,
               "TLS provider failure did not make success impossible");
            begin
               TLS.Finish (Failed);
            exception
               when TLS.TLS_Error =>
                  Raised := True;
            end;
         end;
         Check (Raised, "TLS provider exception was not retained for Finish");
         TLS.Close (Item);
         Close_If_Open (Peer);
      end;

      --  Concurrent Close wakes an acquired operation, then waits for its
      --  cancellation to discharge the provider lease before destroying the
      --  session and descriptor.
      declare
         Backend : Provider.Provider;
         Socket  : Sockets.Socket_Type;
         Peer    : Sockets.Socket_Type;
         Item    : aliased TLS.Connection;
         Data    : aliased Stream_Element_Array := [1 => 0];

         protected Close_Status is
            procedure Publish (Passed : Boolean);
            entry Await (Passed : out Boolean);
         private
            Done  : Boolean := False;
            Value : Boolean := False;
         end Close_Status;

         protected body Close_Status is
            procedure Publish (Passed : Boolean) is
            begin
               Value := Passed;
               Done := True;
            end Publish;

            entry Await (Passed : out Boolean) when Done is
            begin
               Passed := Value;
            end Await;
         end Close_Status;
      begin
         Provider.Set_Script
           (Backend, Provider.Receive_Operation, [1 => (TLS.Want_Read, Provider.Preserve_Output, 0)]);
         Sockets.Create_Socket_Pair (Socket, Peer);
         TLS.Take (Backend, Socket, TLS.Server, "", Item);
         declare
            Set       : aliased Flyology.Operations.Completion_Set (1);
            Get       : TLS.Receive_Operation := TLS.Receive (Set'Access, Item'Access, Data'Access);
            Last      : Stream_Element_Offset;
            Cancelled : Boolean := False;

            task Closer is
               pragma Task_Info (Model);
            end Closer;

            task body Closer is
            begin
               delay 0.010;
               TLS.Close (Item);
               Close_Status.Publish (not TLS.Is_Open (Item));
            exception
               when others =>
                  Close_Status.Publish (False);
            end Closer;
         begin
            Flyology.Operations.Wait_All (Set);
            begin
               TLS.Finish (Get, Last);
            exception
               when Flyology.Operations.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Check (Cancelled, "concurrent TLS close was not retained");
         end;
         declare
            Closed : Boolean;
         begin
            Close_Status.Await (Closed);
            Check (Closed, "concurrent TLS close did not drain operation");
         end;
         Close_If_Open (Peer);
      end;

      --  Finalizing an operation queued behind a set-independent holder must
      --  withdraw its registration; otherwise Close would wait forever.
      declare
         Backend  : Provider.Provider;
         Socket   : Sockets.Socket_Type;
         Peer     : Sockets.Socket_Type;
         Item     : aliased TLS.Connection;
         Holder   : TLS_Drivers.Capability;
         Held     : TLS_Drivers.Acquisition_Result;
         Data     : aliased Stream_Element_Array := [1 => 0];
         Rejected : Boolean := False;
      begin
         Sockets.Create_Socket_Pair (Socket, Peer);
         TLS.Take (Backend, Socket, TLS.Server, "", Item);
         TLS_Drivers.Start (Holder, Item'Access, Held, Timeout => 1.0);
         Check (Held = TLS_Drivers.Acquired, "TLS holder lease unavailable");
         begin
            TLS_Drivers.Start (Holder, Item'Access, Held, Timeout => 1.0);
         exception
            when Program_Error =>
               Rejected := True;
         end;
         Check
           (Rejected and then TLS_Drivers.Is_Engaged (Holder) and then TLS_Drivers.Is_Acquired (Holder),
            "rejected TLS driver Start destroyed its existing lease");
         declare
            Set    : aliased Flyology.Operations.Completion_Set (1);
            Queued : TLS.Receive_Operation := TLS.Receive (Set'Access, Item'Access, Data'Access);
            pragma Unreferenced (Queued);
         begin
            null;
         end;
         TLS_Drivers.Release (Holder);
         TLS.Close (Item);
         Check (not TLS.Is_Open (Item), "finalized queued TLS operation leaked its registration");
         Close_If_Open (Peer);
      end;

      --  A set-independent capability queued behind another lease must clear
      --  its retained connection borrow when concurrent Close cancels its
      --  registration. The acquired holder then releases the final lease so
      --  Close can finish.
      declare
         Backend   : Provider.Provider;
         Socket    : Sockets.Socket_Type;
         Peer      : Sockets.Socket_Type;
         Item      : aliased TLS.Connection;
         Holder    : TLS_Drivers.Capability;
         Waiter    : TLS_Drivers.Capability;
         Result    : TLS_Drivers.Acquisition_Result;
         Cancelled : Boolean := False;
      begin
         Sockets.Create_Socket_Pair (Socket, Peer);
         TLS.Take (Backend, Socket, TLS.Server, "", Item);
         TLS_Drivers.Start (Holder, Item'Access, Result, Timeout => 1.0);
         Check (Result = TLS_Drivers.Acquired, "TLS holder lease unavailable");
         TLS_Drivers.Start (Waiter, Item'Access, Result, Timeout => 1.0);
         Check (Result = TLS_Drivers.Need_Acquire_Readiness, "second TLS capability did not queue");
         declare
            task Closer is
               pragma Task_Info (Model);
            end Closer;

            task body Closer is
            begin
               TLS.Close (Item);
            end Closer;
         begin
            delay 0.010;
            begin
               TLS_Drivers.Poll_Acquisition (Waiter, Result);
            exception
               when Flyology.Operations.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Check
              (Cancelled and then not TLS_Drivers.Is_Engaged (Waiter),
               "cancelled TLS capability retained its connection borrow");
            TLS_Drivers.Release (Holder);
         end;
         Check (not TLS.Is_Open (Item), "TLS capability close did not drain");
         Close_If_Open (Peer);
      end;

      --  The set-independent capability lets a higher-level provider own the
      --  only operation slot and follow cross-direction TLS WANT results.
      declare
         Backend : Provider.Provider;
         Socket  : Sockets.Socket_Type;
         Peer    : Sockets.Socket_Type;
         Item    : aliased TLS.Connection;
         Data    : aliased Stream_Element_Array := [1 => 0];
         Holder  : TLS_Drivers.Capability;
         Held    : TLS_Drivers.Acquisition_Result;
      begin
         Provider.Set_Script
           (Backend,
            Provider.Handshake_Operation,
            [1 => (TLS.Want_Write, Provider.Preserve_Output, 0),
             2 => (TLS.Complete, Provider.Preserve_Output, 0)]);
         Provider.Set_Script
           (Backend,
            Provider.Receive_Operation,
            [1 => (TLS.Want_Read, Provider.Preserve_Output, 0),
             2 => (TLS.Complete, Provider.Advance_Output, 1)]);
         Provider.Set_Script
           (Backend,
            Provider.Send_Operation,
            [1 => (TLS.Want_Read, Provider.Preserve_Output, 0),
             2 => (TLS.Complete, Provider.Advance_Output, 1)]);
         Provider.Set_Script
           (Backend,
            Provider.Shutdown_Operation,
            [1 => (TLS.Want_Write, Provider.Preserve_Output, 0),
             2 => (TLS.Complete, Provider.Preserve_Output, 0)]);
         Sockets.Create_Socket_Pair (Socket, Peer);
         TLS.Take (Backend, Socket, TLS.Server, "", Item);
         Sockets.Send_All (Peer, [1 => 66]);
         TLS_Drivers.Start (Holder, Item'Access, Held, Timeout => 1.0);
         Check (Held = TLS_Drivers.Acquired, "TLS holder lease unavailable");
         declare
            Set : aliased Flyology.Operations.Completion_Set (1);
            Get : Synthetic_Receive_Operation (Set'Access, Item'Access);
         begin
            Get.Data := Data'Unchecked_Access;
            Flyology.Operations.Drivers.Start (Get);
            Flyology.Operations.Drive
              (Flyology.Operations.Operation'Class (Get), Flyology.Operations.Start_Operation);
            Check
              (TLS_Drivers.Is_Engaged (Get.IO) and then not TLS_Drivers.Is_Acquired (Get.IO),
               "outer TLS capability did not arm queued acquisition");
            TLS_Drivers.Release (Holder);
            Flyology.Operations.Wait_All (Set);
            Check
              (Flyology.Operations.Outcome (Get) = Flyology.Operations.Succeeded
               and then Data = [42]
               and then not TLS_Drivers.Is_Engaged (Get.IO),
               "set-independent TLS capability did not compose");
            Flyology.Operations.Consume (Get);
         end;
         TLS.Close (Item);
         Close_If_Open (Peer);
      end;

      Results.Publish (Passed);
   exception
      when Error : others =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "tls operations runner failed: " & Ada.Exceptions.Exception_Information (Error));
         Results.Publish (False);
   end Runner;

   Native      : Runner (Flyology.Native_Task);
   Lightweight : Runner (Flyology.Lightweight_Task);
   Passed      : Boolean;
begin
   Results.Await_All (Passed);
   Check (Passed, "standalone TLS runner failed");
   Ada.Text_IO.Put_Line ("tls operations smoke: ok");
end TLS_Operations_Smoke;
