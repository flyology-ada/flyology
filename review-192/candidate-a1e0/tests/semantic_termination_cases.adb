with Ada.Exceptions;
with Ada.Finalization;
with Ada.Real_Time;
with Ada.Synchronous_Task_Control;
with Ada.Task_Identification;
with Ada.Task_Termination;
with Ada.Text_IO;

package body Semantic_Termination_Cases is
   package Exceptions renames Ada.Exceptions;
   package RT renames Ada.Real_Time;
   package STC renames Ada.Synchronous_Task_Control;
   package Task_Ids renames Ada.Task_Identification;
   package Termination renames Ada.Task_Termination;

   use type Exceptions.Exception_Id;
   use type RT.Time;
   use type Task_Ids.Task_Id;
   use type Termination.Cause_Of_Termination;
   use type Termination.Termination_Handler;

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

      function Is_Set return Boolean
      is (Raised);
   end Signal;

   protected type Termination_Record is
      procedure Handle
        (Cause : Termination.Cause_Of_Termination; T : Task_Ids.Task_Id; X : Exceptions.Exception_Occurrence);
      entry Wait;
      function Matches
        (Cause        : Termination.Cause_Of_Termination;
         T            : Task_Ids.Task_Id;
         Exception_Id : Exceptions.Exception_Id) return Boolean;
   private
      Seen           : Boolean := False;
      Seen_Cause     : Termination.Cause_Of_Termination := Termination.Normal;
      Seen_Task      : Task_Ids.Task_Id := Task_Ids.Null_Task_Id;
      Seen_Exception : Exceptions.Exception_Id := Exceptions.Null_Id;
   end Termination_Record;

   protected body Termination_Record is
      procedure Handle
        (Cause : Termination.Cause_Of_Termination; T : Task_Ids.Task_Id; X : Exceptions.Exception_Occurrence)
      is
      begin
         Seen := True;
         Seen_Cause := Cause;
         Seen_Task := T;
         Seen_Exception := Exceptions.Exception_Identity (X);
      end Handle;

      entry Wait when Seen is
      begin
         null;
      end Wait;

      function Matches
        (Cause        : Termination.Cause_Of_Termination;
         T            : Task_Ids.Task_Id;
         Exception_Id : Exceptions.Exception_Id) return Boolean
      is (Seen and then Seen_Cause = Cause and then Seen_Task = T and then Seen_Exception = Exception_Id);
   end Termination_Record;

   --  Ada.Task_Termination.Termination_Handler is declared at library level,
   --  so its protected callback objects must have matching accessibility.
   Normal_Termination   : Termination_Record;
   Failure_Termination  : Termination_Record;
   Abnormal_Termination : Termination_Record;

   procedure Await_Terminated (T : Task_Ids.Task_Id; Context : String) is
      Deadline : constant RT.Time := RT.Clock + RT.Seconds (2);
   begin
      loop
         exit when Task_Ids.Is_Terminated (T);
         if RT.Clock >= Deadline then
            raise Program_Error with Context & " did not terminate";
         end if;
         delay 0.001;
      end loop;
   end Await_Terminated;

   function Invalid_Family_Index return Natural is
   begin
      return 4;
   end Invalid_Family_Index;
   pragma No_Inline (Invalid_Family_Index);

   function Run return Results is
      Outcome : Results := (others => False);

      procedure Begin_Case (Item : Check_Id) is
      begin
         Ada.Text_IO.Put_Line ("semantic termination: " & Label & "/" & Check_Id'Image (Item));
      end Begin_Case;
   begin
      --  The server accepts two distinct family members in a fixed order.
      --  Each caller can complete only through the member it selected; no
      --  scheduler ordering is inferred from when the callers happen to run.
      Begin_Case (Entry_Family);
      declare
         Server_Open : STC.Suspension_Object;
         Call_Two    : STC.Suspension_Object;
         Call_One    : STC.Suspension_Object;
         Two_Result  : Natural := 0;
         One_Result  : Natural := 0;
         Two_Done    : Signal;
         One_Done    : Signal;

         task Server is
            pragma Task_Info (Subject_Model);
            entry Visit (Positive range 1 .. 3) (Input : Natural; Output : out Natural);
         end Server;

         task body Server is
         begin
            STC.Suspend_Until_True (Server_Open);
            accept Visit (2) (Input : Natural; Output : out Natural) do
               Output := Input + 20;
            end Visit;
            accept Visit (1) (Input : Natural; Output : out Natural) do
               Output := Input + 10;
            end Visit;
         end Server;

         task Caller_Two is
            pragma Task_Info (Peer_Model);
         end Caller_Two;

         task body Caller_Two is
         begin
            STC.Suspend_Until_True (Call_Two);
            Server.Visit (2) (2, Two_Result);
            Two_Done.Set;
         end Caller_Two;

         task Caller_One is
            pragma Task_Info (Peer_Model);
         end Caller_One;

         task body Caller_One is
         begin
            STC.Suspend_Until_True (Call_One);
            Server.Visit (1) (1, One_Result);
            One_Done.Set;
         end Caller_One;

         Range_Raised : Boolean := False;
      begin
         STC.Set_True (Call_Two);
         STC.Set_True (Call_One);
         STC.Set_True (Server_Open);

         declare
            Index  : constant Natural := Invalid_Family_Index;
            Result : Natural;
         begin
            Server.Visit (Index) (0, Result);
         exception
            when Constraint_Error =>
               Range_Raised := True;
         end;

         Two_Done.Wait;
         One_Done.Wait;
         Outcome (Entry_Family) := Range_Raised and then Two_Result = 22 and then One_Result = 11;
      end;

      --  The Is_Terminated observation establishes the state before the call;
      --  Tasking_Error is therefore an entry-call semantic, not a race.
      Begin_Case (Terminated_Entry_Call);
      declare
         Leaving : Signal;
         Raised  : Boolean := False;

         task Finished is
            pragma Task_Info (Subject_Model);
            entry Never;
         end Finished;

         pragma Warnings (Off, "no accept for entry ""Never""");
         task body Finished is
         begin
            Leaving.Set;
         end Finished;
         pragma Warnings (On, "no accept for entry ""Never""");

         Id : constant Task_Ids.Task_Id := Finished'Identity;
      begin
         Leaving.Wait;
         Await_Terminated (Id, "normal task");
         begin
            Finished.Never;
         exception
            when Tasking_Error =>
               Raised := True;
         end;
         Outcome (Terminated_Entry_Call) := Raised;
      end;

      Begin_Case (Failed_Entry_Call);
      declare
         Failing : Signal;
         Raised  : Boolean := False;

         task Failed is
            pragma Task_Info (Subject_Model);
            entry Never;
         end Failed;

         pragma Warnings (Off, "no accept for entry ""Never""");
         task body Failed is
         begin
            Failing.Set;
            raise Constraint_Error with "intentional task-body failure";
         end Failed;
         pragma Warnings (On, "no accept for entry ""Never""");

         Id : constant Task_Ids.Task_Id := Failed'Identity;
      begin
         Failing.Wait;
         Await_Terminated (Id, "failed task");
         begin
            Failed.Never;
         exception
            when Tasking_Error =>
               Raised := True;
         end;
         --  Reaching this statement also records that the unhandled body
         --  exception stayed within Failed instead of escaping its master.
         Outcome (Failed_Entry_Call) := Raised;
      end;

      --  Broken fails only after Sibling has entered its body.  A third sibling
      --  causally aborts that live task after the failure.  The activation
      --  point cannot propagate Tasking_Error out of the master until the
      --  explicitly aborted sibling is joined and both probes are finalized.
      Begin_Case (Partial_Activation_Failure);
      declare
         Sibling_Body      : Signal;
         Broken_Failed     : Signal;
         Sibling_Finalized : Signal;
         Broken_Finalized  : Signal;

         protected Closed_Gate is
            entry Wait;
         end Closed_Gate;

         protected body Closed_Gate is
            entry Wait when False is
            begin
               null;
            end Wait;
         end Closed_Gate;

         type Probe_Kind is (Sibling_Probe, Broken_Probe);
         type Probe (Kind : Probe_Kind) is new Ada.Finalization.Limited_Controlled with null record;
         overriding
         procedure Finalize (Object : in out Probe);

         procedure Finalize (Object : in out Probe) is
         begin
            case Object.Kind is
               when Sibling_Probe =>
                  Sibling_Finalized.Set;

               when Broken_Probe  =>
                  Broken_Finalized.Set;
            end case;
         end Finalize;

         function Fail_After_Sibling_Start return Boolean is
         begin
            Sibling_Body.Wait;
            Broken_Failed.Set;
            raise Constraint_Error with "intentional activation failure";
            return False;
         end Fail_After_Sibling_Start;

         Activation_Raised : Boolean := False;
         Statements_Ran    : Boolean := False;
      begin
         begin
            declare
               task Sibling is
                  pragma Task_Info (Subject_Model);
               end Sibling;

               task body Sibling is
                  Object : Probe (Sibling_Probe);
                  pragma Unreferenced (Object);
               begin
                  Sibling_Body.Set;
                  Closed_Gate.Wait;
               end Sibling;

               task Broken is
                  pragma Task_Info (Peer_Model);
               end Broken;

               task body Broken is
                  Object : Probe (Broken_Probe);
                  Failed : constant Boolean := Fail_After_Sibling_Start;
                  pragma Unreferenced (Object, Failed);
               begin
                  null;
               end Broken;

               task Aborter is
                  pragma Task_Info (Subject_Model);
               end Aborter;

               task body Aborter is
               begin
                  Broken_Failed.Wait;
                  abort Sibling;
               end Aborter;
            begin
               Statements_Ran := True;
            end;
         exception
            when Tasking_Error =>
               Activation_Raised := True;
         end;
         Outcome (Partial_Activation_Failure) :=
           Activation_Raised
           and then not Statements_Ran
           and then Sibling_Finalized.Is_Set
           and then Broken_Finalized.Is_Set;
      end;

      --  Once accepted, a call is an active rendezvous.  Aborting its caller
      --  cannot cut the accept body short; abort takes effect after the
      --  rendezvous, before the caller executes its following statement.
      Begin_Case (Abort_Active_Rendezvous);
      declare
         In_Accept        : Signal;
         Accept_Completed : Signal;
         Release_Accept   : STC.Suspension_Object;
         Caller_Continued : Boolean := False;

         task Server is
            pragma Task_Info (Subject_Model);
            entry Exchange;
         end Server;

         task body Server is
         begin
            accept Exchange do
               In_Accept.Set;
               STC.Suspend_Until_True (Release_Accept);
               Accept_Completed.Set;
            end Exchange;
         end Server;

         task Caller is
            pragma Task_Info (Peer_Model);
         end Caller;

         task body Caller is
         begin
            Server.Exchange;
            Caller_Continued := True;
         end Caller;
      begin
         In_Accept.Wait;
         abort Caller;
         STC.Set_True (Release_Accept);
         Accept_Completed.Wait;
         Await_Terminated (Caller'Identity, "aborted rendezvous caller");
         Outcome (Abort_Active_Rendezvous) := Accept_Completed.Is_Set and not Caller_Continued;
      end;

      --  The trigger task accepts Inner first, then waits for the inner ATC
      --  to resume before accepting Outer.  This causally distinguishes the
      --  nested abort scopes without assigning meaning to dispatch timing.
      Begin_Case (Nested_Asynchronous_Transfer);
      declare
         Inner_Trigger_Ran : Signal;
         Inner_Resumed     : Signal;
         Outer_Trigger_Ran : Signal;
         Outer_Resumed     : Signal;
         Allow_Outer       : STC.Suspension_Object;

         protected Inner_Closed is
            entry Wait;
         end Inner_Closed;

         protected body Inner_Closed is
            entry Wait when False is
            begin
               null;
            end Wait;
         end Inner_Closed;

         protected Outer_Closed is
            entry Wait;
         end Outer_Closed;

         protected body Outer_Closed is
            entry Wait when False is
            begin
               null;
            end Wait;
         end Outer_Closed;

         Inner_Continued : Boolean := False;
         Outer_Continued : Boolean := False;

         task Triggers is
            pragma Task_Info (Subject_Model);
            entry Inner;
            entry Outer;
         end Triggers;

         task body Triggers is
         begin
            accept Inner;
            STC.Suspend_Until_True (Allow_Outer);
            accept Outer;
         end Triggers;

         task Worker is
            pragma Task_Info (Peer_Model);
         end Worker;

         task body Worker is
         begin
            select
               Triggers.Outer;
               Outer_Trigger_Ran.Set;
            then abort
               select
                  Triggers.Inner;
                  Inner_Trigger_Ran.Set;
               then abort
                  Inner_Closed.Wait;
                  Inner_Continued := True;
               end select;
               Inner_Resumed.Set;
               STC.Set_True (Allow_Outer);
               Outer_Closed.Wait;
               Outer_Continued := True;
            end select;
            Outer_Resumed.Set;
         end Worker;
      begin
         Outer_Resumed.Wait;
         Outcome (Nested_Asynchronous_Transfer) :=
           Inner_Trigger_Ran.Is_Set
           and then Inner_Resumed.Is_Set
           and then Outer_Trigger_Ran.Is_Set
           and then Outer_Resumed.Is_Set
           and then not Inner_Continued
           and then not Outer_Continued;
      end;

      Begin_Case (Termination_Handlers);
      declare
         Normal_Gate    : STC.Suspension_Object;
         Failure_Gate   : STC.Suspension_Object;
         Abnormal_Start : Signal;

         protected Abort_Gate is
            entry Wait;
         end Abort_Gate;

         protected body Abort_Gate is
            entry Wait when False is
            begin
               null;
            end Wait;
         end Abort_Gate;

         Normal_OK   : Boolean := False;
         Failure_OK  : Boolean := False;
         Abnormal_OK : Boolean := False;
      begin
         declare
            task Normal_Task is
               pragma Task_Info (Subject_Model);
            end Normal_Task;

            task body Normal_Task is
            begin
               STC.Suspend_Until_True (Normal_Gate);
            end Normal_Task;

            Id : constant Task_Ids.Task_Id := Normal_Task'Identity;
         begin
            Termination.Set_Specific_Handler (Id, Normal_Termination.Handle'Access);
            Normal_OK := Termination.Specific_Handler (Id) = Normal_Termination.Handle'Access;
            STC.Set_True (Normal_Gate);
            Normal_Termination.Wait;
            Normal_OK :=
              Normal_OK and then Normal_Termination.Matches (Termination.Normal, Id, Exceptions.Null_Id);
         end;

         declare
            task Failure_Task is
               pragma Task_Info (Subject_Model);
            end Failure_Task;

            task body Failure_Task is
            begin
               STC.Suspend_Until_True (Failure_Gate);
               raise Constraint_Error with "termination handler failure";
            end Failure_Task;

            Id : constant Task_Ids.Task_Id := Failure_Task'Identity;
         begin
            Termination.Set_Specific_Handler (Id, Failure_Termination.Handle'Access);
            STC.Set_True (Failure_Gate);
            Failure_Termination.Wait;
            Failure_OK :=
              Failure_Termination.Matches (Termination.Unhandled_Exception, Id, Constraint_Error'Identity);
         end;

         declare
            task Abnormal_Task is
               pragma Task_Info (Subject_Model);
            end Abnormal_Task;

            task body Abnormal_Task is
            begin
               Abnormal_Start.Set;
               Abort_Gate.Wait;
            end Abnormal_Task;

            Id : constant Task_Ids.Task_Id := Abnormal_Task'Identity;
         begin
            Termination.Set_Specific_Handler (Id, Abnormal_Termination.Handle'Access);
            Abnormal_Start.Wait;
            abort Abnormal_Task;
            Abnormal_Termination.Wait;
            Abnormal_OK := Abnormal_Termination.Matches (Termination.Abnormal, Id, Exceptions.Null_Id);
         end;

         Outcome (Termination_Handlers) := Normal_OK and Failure_OK and Abnormal_OK;
      end;

      return Outcome;
   end Run;

end Semantic_Termination_Cases;
