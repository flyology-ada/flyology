with Ada.Unchecked_Deallocation;
with System.Address_To_Access_Conversions;
with Flyology.IO;
with Flyology.Task_Scope_Policy;
with Flyology.Worker_Pool_Test_Hooks;

package body Flyology.Task_Scopes is
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_64;

   package Test_Hooks renames Flyology.Worker_Pool_Test_Hooks;

   protected Identity_Source is
      procedure Next (Value : out Interfaces.Unsigned_64);
   private
      Last : Interfaces.Unsigned_64 := 0;
   end Identity_Source;

   protected body Identity_Source is
      procedure Next (Value : out Interfaces.Unsigned_64) is
      begin
         if Last = Interfaces.Unsigned_64'Last then
            raise Program_Error with "task-scope identity space exhausted";
         end if;
         Last := Last + 1;
         Value := Last;
      end Next;
   end Identity_Source;

   protected body Shared_State is
      procedure Configure
        (Token : Cancellation_Access; Deadline : Ada.Real_Time.Time; Cancel_On_Failure : Boolean) is
      begin
         if Configured then
            raise Program_Error with "task scope is already configured";
         end if;
         Parent_Stop := Token;
         End_Time := Deadline;
         Cancel_On_Failure_Value := Cancel_On_Failure;
         Configured := True;
      end Configure;

      procedure Submit (Input : Input_Type; Index : out Positive) is
      begin
         if not Configured then
            raise Program_Error with "task scope is not configured";
         elsif Closed then
            raise Program_Error with "task scope admission is closed";
         elsif Submitted = Capacity then
            raise Constraint_Error with "task scope capacity is exhausted";
         end if;
         --  Publish only after the user-defined copy has completed.  A
         --  controlled Input_Type may raise from Adjust; in that case no
         --  worker may observe a phantom operation.
         Inputs (Submitted + 1) := Input;
         Submitted := Submitted + 1;
         Index := Submitted;
      end Submit;

      entry Next (Index : out Positive; Stop : out Boolean) when Next_Index <= Submitted or else Stopping is
      begin
         if Stopping and then Next_Index > Submitted then
            Stop := True;
            Index := 1;
            return;
         end if;
         Stop := False;
         Index := Next_Index;
         Next_Index := Next_Index + 1;
      end Next;

      procedure Operation_Context
        (Index             : Positive;
         Token             : out Cancellation_Access;
         Deadline          : out Ada.Real_Time.Time;
         Cancel_On_Failure : out Boolean) is
      begin
         pragma Unreferenced (Index);
         Token := Parent_Stop;
         Deadline := End_Time;
         Cancel_On_Failure := Cancel_On_Failure_Value;
      end Operation_Context;

      procedure Operation_Input (Index : Positive; Input : out Input_Type) is
      begin
         Input := Inputs (Index);
      end Operation_Input;

      procedure Complete (Index : Positive; Value : Result_Type) is
      begin
         Results (Index) := Value;
         Successes (Index) := True;
         Completed := Completed + 1;
      end Complete;

      procedure Fail (Index : Positive; Occurrence : Ada.Exceptions.Exception_Occurrence) is
      begin
         Failure_Ids (Index) := Ada.Exceptions.Exception_Identity (Occurrence);
         Successes (Index) := False;
         Completed := Completed + 1;
         --  Terminalize before copying diagnostic text so allocation failure
         --  cannot leave Join waiting forever.
         Failure_Messages (Index) :=
           Ada.Strings.Unbounded.To_Unbounded_String (Ada.Exceptions.Exception_Message (Occurrence));
      end Fail;

      procedure Close_Admission is
      begin
         Closed := True;
      end Close_Admission;

      entry Await_All when Closed and then Completed = Submitted is
      begin
         null;
      end Await_All;

      procedure Shutdown is
      begin
         Stopping := True;
      end Shutdown;

      procedure Set_Expected_Workers (Count : Natural) is
      begin
         Expected_Workers := Count;
         Expected_Workers_Set := True;
      end Set_Expected_Workers;

      procedure Worker_Stopped is
      begin
         Stopped_Workers := Stopped_Workers + 1;
      end Worker_Stopped;

      entry Await_Workers when Expected_Workers_Set and then Stopped_Workers = Expected_Workers is
      begin
         null;
      end Await_Workers;

      function Submitted_Count return Natural
      is (Submitted);

      function Was_Successful (Index : Positive) return Boolean is
      begin
         if Index > Submitted or else Completed < Submitted then
            raise Invalid_Handle;
         end if;
         return Successes (Index);
      end Was_Successful;

      function Result_Value (Index : Positive) return Result_Type is
      begin
         if Index > Submitted or else Completed < Submitted then
            raise Invalid_Handle;
         end if;
         return Results (Index);
      end Result_Value;

      function Failure_Id (Index : Positive) return Ada.Exceptions.Exception_Id is
      begin
         if Index > Submitted or else Completed < Submitted then
            raise Invalid_Handle;
         end if;
         return Failure_Ids (Index);
      end Failure_Id;

      function Failure_Message (Index : Positive) return Ada.Strings.Unbounded.Unbounded_String is
      begin
         if Index > Submitted or else Completed < Submitted then
            raise Invalid_Handle;
         end if;
         return Failure_Messages (Index);
      end Failure_Message;
   end Shared_State;

   task body Worker is
      --  Activation-phase fault injection. Enabled is a literal False in the
      --  production-selected specification, so the hook call disappears even
      --  at -O0.
      Activation_Checked : constant Boolean :=
        (if Test_Hooks.Enabled then Test_Hooks.Check_Activation else True);
      pragma Unreferenced (Activation_Checked);
      package Conversions is new System.Address_To_Access_Conversions (Shared_State);
      State              : Conversions.Object_Pointer;
      Stopped            : Boolean := False;
   begin
      select
         accept Start (State_Address : System.Address) do
            State := Conversions.To_Pointer (State_Address);
         end Start;
      or
         accept Stop;
         Stopped := True;
      end select;

      begin
         while not Stopped loop
            declare
               Index             : Positive;
               Input             : Input_Type;
               Stop              : Boolean;
               Token             : Cancellation_Access;
               Deadline          : Ada.Real_Time.Time;
               Cancel_On_Failure : Boolean;
               Value             : Result_Type;
            begin
               State.Next (Index, Stop);
               exit when Stop;
               begin
                  State.Operation_Context (Index, Token, Deadline, Cancel_On_Failure);
                  State.Operation_Input (Index, Input);
                  if Token.Requested then
                     raise Flyology.Cancellation.Operation_Cancelled;
                  elsif Deadline /= Ada.Real_Time.Time_Last and then Ada.Real_Time.Clock >= Deadline then
                     raise Flyology.IO.Timeout_Error with "task scope operation deadline expired";
                  end if;
                  Execute (Input, Token, Deadline, Value);
                  State.Complete (Index, Value);
               exception
                  when Error : others =>
                     begin
                        State.Fail (Index, Error);
                     exception
                        when others =>
                           null;
                     end;
                     if Cancel_On_Failure and then not Token.Requested then
                        Token.Request;
                     end if;
               end;
            end;
         end loop;
      exception
         when others =>
            null;
      end;
      if not Stopped then
         State.Worker_Stopped;
      end if;
   end Worker;

   task body Cancellation_Monitor is
      Parent_Source  : Cancellation_Access;
      Child_Source   : Cancellation_Access;
      Release_Source : Cancellation_Access;
      Stopped        : Boolean := False;
   begin
      select
         accept Start
           (Parent : Cancellation_Access; Child : Cancellation_Access; Release : Cancellation_Access)
         do
            Parent_Source := Parent;
            Child_Source := Child;
            Release_Source := Release;
         end Start;
      or
         accept Stop;
         Stopped := True;
      end select;

      --  Wait on the parent token itself rather than polling it. The scope's
      --  release signal is the abortable part, so whichever event happens
      --  first ends the wait with no periodic wakeup: parent cancellation
      --  reaches the scope token at protected-entry latency, and an idle
      --  scope costs no timer wakeups while it lives.
      if not Stopped and then Parent_Source /= null then
         select
            Parent_Source.Await_Request;
            begin
               if not Child_Source.Requested then
                  Child_Source.Request;
               end if;
            exception
               --  Cancellation stays recorded when its wake descriptor cannot
               --  be signalled, and the monitor must survive to answer the
               --  Stop rendezvous: a terminated monitor turns Join into
               --  Tasking_Error and strands every completed result.
               when others =>
                  null;
            end;
         then abort
            Release_Source.Await_Request;
         end select;
      end if;

      --  Cancellation is one-shot, so nothing is left to observe. The Stop
      --  rendezvous remains the handshake that tells Join and finalization
      --  the monitor will not touch the scope-owned token again.
      if not Stopped then
         accept Stop;
      end if;
   end Cancellation_Monitor;

   procedure Configure
     (Item : in out Scope; Deadline : Ada.Real_Time.Time; Cancel_Siblings_On_Failure : Boolean := True) is
   begin
      if Item.Is_Configured then
         raise Program_Error with "task scope is already configured";
      end if;
      Item.Token := Item.Local_Stop'Unchecked_Access;
      Item.State.Configure (Item.Token, Deadline, Cancel_Siblings_On_Failure);
      --  From here Finalize owns rollback if allocation or activation raises.
      Item.Cleanup_Required := True;
      Identity_Source.Next (Item.Identity);
      Item.Workers := new Worker_Array (1 .. Item.Capacity);
      --  Create one worker per allocator. RM 9.2 completes activation inside
      --  the allocator, so an array allocator that fails to activate worker K
      --  would raise with the array value never assigned, leaving workers
      --  1 .. K-1 running and unreachable. A lone task whose activation fails
      --  is completed instead, and every earlier worker is already recorded
      --  in Item.Workers where Finalize can stop and release it.
      for Index in 1 .. Item.Capacity loop
         Item.Workers (Index) := new Worker;
         Item.Created_Workers := Index;
      end loop;
      for Index in 1 .. Item.Capacity loop
         Item.Workers (Index).Start (Item.State'Address);
         Item.Activated_Workers := Item.Activated_Workers + 1;
      end loop;
      if Item.Parent = null then
         Item.Monitor_Stopped := True;
      else
         Item.Monitor := new Cancellation_Monitor;
         Item.Monitor_Stopped := False;
         Item.Monitor.Start
           (Item.Parent.all'Unchecked_Access, Item.Token, Item.Monitor_Release'Unchecked_Access);
      end if;
      Item.Is_Configured := True;
   end Configure;

   procedure Spawn (Item : in out Scope; Input : Input_Type; Handle : out Operation_Handle) is
      Index : Positive;
   begin
      if Item.Is_Joined then
         raise Program_Error with "task scope is already joined";
      end if;
      Item.State.Submit (Input, Index);
      Handle := (Owner => Item.Identity, Index => Index);
   end Spawn;

   --  Release the cancellation monitor and take its acknowledgement. The
   --  release token never lends a wake descriptor, so requesting it cannot
   --  fail. A monitor that terminated early can no longer be handshaken, and
   --  it can no longer reach the scope either, so Tasking_Error from that
   --  rendezvous is a completed stop rather than a failure to report.
   procedure Stop_Monitor (Item : in out Scope) is
   begin
      if Item.Monitor /= null and then not Item.Monitor_Stopped then
         Item.Monitor_Release.Request;
         begin
            Item.Monitor.Stop;
         exception
            when Tasking_Error =>
               null;
         end;
      end if;
      Item.Monitor_Stopped := True;
   end Stop_Monitor;

   procedure Join (Item : in out Scope) is
   begin
      if not Item.Is_Configured then
         raise Program_Error with "task scope is not configured";
      elsif Item.Is_Joined then
         return;
      end if;
      Item.State.Close_Admission;
      Item.State.Await_All;
      Item.State.Shutdown;
      Item.State.Set_Expected_Workers
        (Task_Scope_Policy.Awaited_Workers (Item.Created_Workers, Item.Activated_Workers));
      Item.State.Await_Workers;
      Stop_Monitor (Item);
      Item.Is_Joined := True;
      Item.Cleanup_Required := False;
   end Join;

   function Succeeded (Item : Scope; Handle : Operation_Handle) return Boolean is
   begin
      if not Item.Is_Joined then
         raise Program_Error with "task scope is not joined";
      end if;
      if Handle.Owner /= Item.Identity then
         raise Invalid_Handle;
      end if;
      return Item.State.Was_Successful (Handle.Index);
   end Succeeded;

   function Result (Item : Scope; Handle : Operation_Handle) return Result_Type is
      Index : constant Positive := Handle.Index;
   begin
      if not Item.Is_Joined then
         raise Program_Error with "task scope is not joined";
      elsif Handle.Owner /= Item.Identity then
         raise Invalid_Handle;
      end if;
      declare
         Successful : constant Boolean := Item.State.Was_Successful (Index);
      begin
         if not Successful then
            Ada.Exceptions.Raise_Exception
              (Item.State.Failure_Id (Index),
               Ada.Strings.Unbounded.To_String (Item.State.Failure_Message (Index)));
         end if;
         return Item.State.Result_Value (Index);
      end;
   end Result;

   overriding
   procedure Finalize (Item : in out Scope) is
      procedure Free_Worker is new Ada.Unchecked_Deallocation (Worker, Worker_Access);
      procedure Free_Workers is new Ada.Unchecked_Deallocation (Worker_Array, Worker_Array_Access);
      procedure Free_Monitor is new
        Ada.Unchecked_Deallocation (Cancellation_Monitor, Cancellation_Monitor_Access);
      Cancel_Failed  : Boolean := False;
      Cancel_Failure : Ada.Exceptions.Exception_Occurrence;
      --  Worker bookkeeping is settled once Configure has returned or
      --  raised, so this census is stable for the whole cleanup.
      Created        : constant Natural := Item.Created_Workers;
      Activated      : constant Natural := Item.Activated_Workers;
   begin
      pragma Assert (Task_Scope_Policy.Accounts_For_Every_Worker (Created, Activated));
      if Item.Cleanup_Required and then not Item.Is_Joined then
         begin
            if not Item.Local_Stop.Requested then
               Item.Local_Stop.Request;
            end if;
         exception
            when Failure : others =>
               --  Cancellation stays recorded when its wake descriptor cannot
               --  be signalled, so the workers still finish. Joining them
               --  cannot be skipped: they hold pointers into Item.State and
               --  Item.Local_Stop, and the token releases the descriptors a
               --  blocked operation borrowed as soon as this Finalize returns.
               --  The failure is reported once the scope is quiet.
               Cancel_Failed := True;
               Ada.Exceptions.Save_Occurrence (Cancel_Failure, Failure);
         end;
         Item.State.Close_Admission;
         Item.State.Await_All;
         Item.State.Shutdown;
         if Item.Workers /= null then
            --  Workers created but never started, including the ones a failed
            --  Configure left behind, have no Shared_State pointer and can
            --  only leave their initial select through this rendezvous.
            for Index in
              Task_Scope_Policy.First_Unstarted (Created, Activated)
              .. Task_Scope_Policy.Last_Unstarted (Created, Activated)
            loop
               begin
                  Item.Workers (Index).Stop;
               exception
                  when Tasking_Error =>
                     null;
               end;
            end loop;
         end if;
         Item.State.Set_Expected_Workers (Task_Scope_Policy.Awaited_Workers (Created, Activated));
         Item.State.Await_Workers;
         Stop_Monitor (Item);
         Item.Is_Joined := True;
         Item.Cleanup_Required := False;
      end if;
      if Item.Monitor /= null then
         Free_Monitor (Item.Monitor);
      end if;
      if Item.Workers /= null then
         for Index in Item.Workers'Range loop
            Free_Worker (Item.Workers (Index));
         end loop;
         Free_Workers (Item.Workers);
      end if;
      if Cancel_Failed then
         Ada.Exceptions.Reraise_Occurrence (Cancel_Failure);
      end if;
   end Finalize;

end Flyology.Task_Scopes;
