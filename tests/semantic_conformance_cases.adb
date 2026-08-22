with Ada.Finalization;

package body Semantic_Conformance_Cases is

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

   function Run return Results is
      Outcome : Results := (others => False);
   begin
      --  An exception raised by an accept body is propagated to both sides
      --  of the rendezvous.  Both tasks catch it locally so their master can
      --  make an exact observation instead of inferring task termination.
      declare
         Acceptor_Caught : Boolean := False;
         Caller_Caught   : Boolean := False;
      begin
         declare
            task Server is
               pragma Task_Info (Server_Model);
               entry Fail;
            end Server;

            task body Server is
            begin
               begin
                  accept Fail do
                     raise Constraint_Error with "conformance rendezvous";
                  end Fail;
               exception
                  when Constraint_Error =>
                     Acceptor_Caught := True;
               end;
            end Server;

            task Caller is
               pragma Task_Info (Caller_Model);
            end Caller;

            task body Caller is
            begin
               begin
                  Server.Fail;
               exception
                  when Constraint_Error =>
                     Caller_Caught := True;
               end;
            end Caller;
         begin
            null;
         end;
         Outcome (Rendezvous_Exception) := Acceptor_Caught and Caller_Caught;
      end;

      --  A task whose declarative part raises has failed activation.  The
      --  activating scope sees Tasking_Error, its statements do not start,
      --  and controlled objects elaborated before the failure are finalized.
      declare
         Finalized : Signal;
         Body_Ran  : Boolean := False;
         Activated : Boolean := False;

         type Probe is new Ada.Finalization.Controlled with null record;
         overriding
         procedure Finalize (Object : in out Probe);

         procedure Finalize (Object : in out Probe) is
            pragma Unreferenced (Object);
         begin
            Finalized.Set;
         end Finalize;

         function Fail_Activation return Boolean is
         begin
            raise Constraint_Error with "conformance activation";
            return False;
         end Fail_Activation;
      begin
         begin
            declare
               task Broken is
                  pragma Task_Info (Server_Model);
               end Broken;

               task body Broken is
                  Object : Probe;
                  Failed : constant Boolean := Fail_Activation;
                  pragma Unreferenced (Object, Failed);
               begin
                  Body_Ran := True;
               end Broken;
            begin
               Activated := True;
            end;
         exception
            when Tasking_Error =>
               null;
         end;
         Outcome (Activation_Failure_Cleanup) := not Activated and not Body_Ran and Finalized.Is_Set;
      end;

      --  WITH ABORT preserves the timed caller's ability to cancel after the
      --  initial rendezvous has requeued it to a closed entry.
      declare
         Ready      : Signal;
         Requeued   : Signal;
         Timed_Out  : Boolean := False;
         Ghost_Call : Boolean := False;

         task Server is
            pragma Task_Info (Server_Model);
            entry Start;
            entry Pending;
            entry Stop;
         end Server;

         task body Server is
         begin
            Ready.Set;
            accept Start do
               Requeued.Set;
               requeue Pending with abort;
            end Start;
            accept Stop;
            select
               accept Pending do
                  Ghost_Call := True;
               end Pending;
            else
               null;
            end select;
         end Server;
      begin
         Ready.Wait;
         declare
            task Caller is
               pragma Task_Info (Caller_Model);
            end Caller;

            task body Caller is
            begin
               select
                  Server.Start;
               or
                  delay 0.050;
                  Timed_Out := True;
               end select;
            end Caller;
         begin
            null;
         end;
         Server.Stop;
         Outcome (Requeue_With_Abort) := Timed_Out and Requeued.Is_Set and not Ghost_Call;
      end;

      --  Without WITH ABORT, accepting the original entry makes a timed call
      --  irrevocable.  The delay expires while the call is requeued, but the
      --  caller completes through the second rendezvous instead.
      declare
         Ready     : Signal;
         Requeued  : Signal;
         Returned  : Boolean := False;
         Timed_Out : Boolean := False;

         task Server is
            pragma Task_Info (Server_Model);
            entry Start;
            entry Pending;
         end Server;

         task body Server is
         begin
            Ready.Set;
            accept Start do
               Requeued.Set;
               requeue Pending;
            end Start;
            delay 0.050;
            accept Pending;
         end Server;
      begin
         Ready.Wait;
         declare
            task Caller is
               pragma Task_Info (Caller_Model);
            end Caller;

            task body Caller is
            begin
               select
                  Server.Start;
                  Returned := True;
               or
                  delay 0.010;
                  Timed_Out := True;
               end select;
            end Caller;
         begin
            null;
         end;
         Outcome (Requeue_Without_Abort) := Returned and not Timed_Out and Requeued.Is_Set;
      end;

      return Outcome;
   end Run;

end Semantic_Conformance_Cases;
