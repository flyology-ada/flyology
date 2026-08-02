with Ada.Dynamic_Priorities;
with Ada.Finalization;
with Ada.Synchronous_Task_Control;
with Ada.Task_Attributes;
with System;

package body Semantic_Scenarios is

   package Priorities renames Ada.Dynamic_Priorities;
   package STC renames Ada.Synchronous_Task_Control;

   package Attributes is new Ada.Task_Attributes
     (Attribute     => Natural,
      Initial_Value => 0);

   protected type Signal is
      procedure Set;
      entry Wait;
      function Is_Set return Boolean;
   private
      Raised : Boolean := False;
   end Signal;

   protected body Signal is
      procedure Set is
      begin
         Raised := True;
      end Set;

      entry Wait when Raised is
      begin
         null;
      end Wait;

      function Is_Set return Boolean is (Raised);
   end Signal;

   function Run return Results is
      Outcome                    : Results := (others => False);
      Select_Delay_Fired         : Boolean := False;
      Reached_Terminate_Select   : Boolean := False;
      Requeue_Value_Seen         : Natural := 0;
      ATC_Triggered              : Boolean := False;
      ATC_Continued              : Boolean := False;
      Suspension_Continued       : Boolean := False;
      First_Attribute_Value      : Natural := 0;
      Second_Attribute_Value     : Natural := 0;
      Dynamic_Priority_OK        : Boolean := False;
      Nested_Master_Completed    : Boolean := False;
      Activation_Body_Started   : Boolean := False;
      Delay_Abort_Continued      : Boolean := False;
      Entry_Abort_Continued      : Boolean := False;
      Finalization_Done          : Signal;
      Rendezvous_Returned        : Natural := 0;
   begin
      --  Conditional and timed calls are made while the server is
      --  deterministically held before its accept statement.  The test does
      --  not depend on either lane winning a scheduling race.
      declare
         Open_Server : STC.Suspension_Object;

         task Server is
            pragma Task_Info (Model);
            entry Probe;
            entry Stop;
         end Server;

         task body Server is
         begin
            STC.Suspend_Until_True (Open_Server);
            select
               accept Probe;
            or
               accept Stop;
            end select;
         end Server;

         Conditional_Fell_Through : Boolean := False;
         Timed_Out                : Boolean := False;
      begin
         select
            Server.Probe;
         else
            Conditional_Fell_Through := True;
         end select;

         select
            Server.Probe;
         or
            delay 0.005;
            Timed_Out := True;
         end select;

         Outcome (Conditional_Entry) := Conditional_Fell_Through;
         Outcome (Timed_Entry) := Timed_Out;
         STC.Set_True (Open_Server);
         Server.Stop;
      end;

      --  The first select has no callable entry, so its delay alternative is
      --  the only possible completion.  The second select reaches terminate
      --  when this block's master waits for the dependent task.
      declare
         task Selector is
            pragma Task_Info (Model);
            entry Finish;
            entry Never;
         end Selector;

         task body Selector is
         begin
            select
               accept Never;
            or
               delay 0.005;
               Select_Delay_Fired := True;
            end select;

            accept Finish;
            Reached_Terminate_Select := True;
            select
               accept Never;
            or
               terminate;
            end select;
         end Selector;
      begin
         Selector.Finish;
      end;
      Outcome (Select_Delay) := Select_Delay_Fired;
      Outcome (Select_Terminate) := Reached_Terminate_Select;

      declare
         task Requeue_Server is
            pragma Task_Info (Model);
            entry First (Value : Natural);
            entry Second (Value : Natural);
         end Requeue_Server;

         task body Requeue_Server is
         begin
            accept First (Value : Natural) do
               requeue Second;
            end First;
            accept Second (Value : Natural) do
               Requeue_Value_Seen := Value;
            end Second;
         end Requeue_Server;
      begin
         Requeue_Server.First (37);
      end;
      Outcome (Requeued_Entry) := Requeue_Value_Seen = 37;

      declare
         Never_Open : STC.Suspension_Object;

         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
         begin
            select
               delay 0.005;
               ATC_Triggered := True;
            then abort
               STC.Suspend_Until_True (Never_Open);
               ATC_Continued := True;
            end select;
         end Worker;
      begin
         null;
      end;
      Outcome (Abortable_Select) := ATC_Triggered and not ATC_Continued;

      declare
         Gate      : STC.Suspension_Object;
         Started   : Signal;

         task Waiter is
            pragma Task_Info (Model);
         end Waiter;

         task body Waiter is
         begin
            Started.Set;
            STC.Suspend_Until_True (Gate);
            Suspension_Continued := True;
         end Waiter;
      begin
         Started.Wait;
         STC.Set_True (Gate);
      end;
      Outcome (Suspension_Object) := Suspension_Continued;

      declare
         task First is
            pragma Task_Info (Model);
         end First;

         task Second is
            pragma Task_Info (Model);
         end Second;

         task body First is
         begin
            Attributes.Set_Value (101);
            delay 0.0;
            First_Attribute_Value := Attributes.Value;
         end First;

         task body Second is
         begin
            Attributes.Set_Value (202);
            delay 0.0;
            Second_Attribute_Value := Attributes.Value;
         end Second;
      begin
         null;
      end;
      Outcome (Task_Attribute) :=
        First_Attribute_Value = 101 and Second_Attribute_Value = 202;

      --  A maximum-ceiling protected operation remains legal after a real
      --  base-priority change, and the changed priority remains observable.
      --  This does not attempt to prescribe an OS dispatch trace.
      declare
         protected Ceiling_Object with Priority => System.Priority'Last is
            procedure Touch;
            function Was_Touched return Boolean;
         private
            Touched : Boolean := False;
         end Ceiling_Object;

         protected body Ceiling_Object is
            procedure Touch is
            begin
               Touched := True;
            end Touch;

            function Was_Touched return Boolean is (Touched);
         end Ceiling_Object;

         task Priority_Worker is
            pragma Task_Info (Model);
         end Priority_Worker;

         task body Priority_Worker is
            Original : constant System.Any_Priority := Priorities.Get_Priority;
            Changed  : constant System.Any_Priority :=
              (if Original < System.Any_Priority'Last
               then Original + 1
               else Original - 1);
         begin
            Priorities.Set_Priority (Changed);
            Ceiling_Object.Touch;
            Dynamic_Priority_OK :=
              Priorities.Get_Priority = Changed
              and then Ceiling_Object.Was_Touched;
            Priorities.Set_Priority (Original);
         end Priority_Worker;
      begin
         null;
      end;
      Outcome (Dynamic_Priority) := Dynamic_Priority_OK;

      --  Both an object-declared task and a task allocated from an access
      --  type must finish before their respective task master can leave.
      declare
         task Nested_Child is
            pragma Task_Info (Model);
         end Nested_Child;

         task body Nested_Child is
         begin
            delay 0.0;
            Nested_Master_Completed := True;
         end Nested_Child;
      begin
         null;
      end;
      Outcome (Nested_Master) := Nested_Master_Completed;

      declare
         Heap_Task_Completed : Boolean := False;
      begin
         declare
            task type Heap_Task is
               pragma Task_Info (Model);
            end Heap_Task;

            task body Heap_Task is
            begin
               delay 0.005;
               Heap_Task_Completed := True;
            end Heap_Task;

            type Heap_Task_Access is access Heap_Task;
            Item : constant Heap_Task_Access := new Heap_Task;
            pragma Unreferenced (Item);
         begin
            null;
         end;
         Outcome (Access_Task_Master) := Heap_Task_Completed;
      end;

      --  Exercise abort at four distinct GNARL suspension/lifecycle points.
      --  Each enclosing block provides the completion synchronization, so no
      --  fixed timeout is used to guess when abort delivery has completed.
      declare
         Activation_Entered : Signal;
         Activation_Release : STC.Suspension_Object;

         function Wait_During_Activation return Boolean is
         begin
            Activation_Entered.Set;
            STC.Suspend_Until_True (Activation_Release);
            return True;
         end Wait_During_Activation;

         task Owner is
            pragma Task_Info (Model);
         end Owner;

         task body Owner is
            task Child is
               pragma Task_Info (Model);
            end Child;

            task body Child is
               Activated : constant Boolean := Wait_During_Activation;
               pragma Unreferenced (Activated);
            begin
               Activation_Body_Started := True;
            end Child;
         begin
            null;
         end Owner;
      begin
         Activation_Entered.Wait;
         abort Owner;
         STC.Set_True (Activation_Release);
      end;
      Outcome (Abort_Activation) := not Activation_Body_Started;

      declare
         Started   : Signal;

         task Sleeper is
            pragma Task_Info (Model);
         end Sleeper;

         task body Sleeper is
         begin
            Started.Set;
            delay 60.0;
            Delay_Abort_Continued := True;
         end Sleeper;
      begin
         Started.Wait;
         abort Sleeper;
      end;
      Outcome (Abort_Delay) := not Delay_Abort_Continued;

      declare
         Started   : Signal;

         protected Closed_Gate is
            entry Wait;
         end Closed_Gate;

         protected body Closed_Gate is
            entry Wait when False is
            begin
               null;
            end Wait;
         end Closed_Gate;

         task Blocked_Caller is
            pragma Task_Info (Model);
         end Blocked_Caller;

         task body Blocked_Caller is
         begin
            Started.Set;
            Closed_Gate.Wait;
            Entry_Abort_Continued := True;
         end Blocked_Caller;
      begin
         Started.Wait;
         abort Blocked_Caller;
      end;
      Outcome (Abort_Entry_Wait) := not Entry_Abort_Continued;

      declare
         Finalize_Entered : Signal;
         Finalize_Release : STC.Suspension_Object;

         type Probe is new Ada.Finalization.Controlled with null record;
         overriding procedure Finalize (Object : in out Probe);

         procedure Finalize (Object : in out Probe) is
            pragma Unreferenced (Object);
         begin
            Finalize_Entered.Set;
            STC.Suspend_Until_True (Finalize_Release);
            Finalization_Done.Set;
         end Finalize;

         task Victim is
            pragma Task_Info (Model);
         end Victim;

         task body Victim is
            Object : Probe;
            pragma Unreferenced (Object);
         begin
            null;
         end Victim;
      begin
         Finalize_Entered.Wait;
         abort Victim;
         STC.Set_True (Finalize_Release);
      end;
      Outcome (Abort_Finalization) := Finalization_Done.Is_Set;

      declare
         task Peer is
            pragma Task_Info (Peer_Model);
            entry Exchange (Input : Natural; Output : out Natural);
         end Peer;

         task body Peer is
         begin
            accept Exchange (Input : Natural; Output : out Natural) do
               Output := Input + 1;
            end Exchange;
         end Peer;

         task Caller is
            pragma Task_Info (Model);
         end Caller;

         task body Caller is
         begin
            Peer.Exchange (41, Rendezvous_Returned);
         end Caller;
      begin
         null;
      end;
      Outcome (Cross_Lane_Rendezvous) := Rendezvous_Returned = 42;

      return Outcome;
   end Run;

end Semantic_Scenarios;
