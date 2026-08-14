with Ada.Real_Time;
with Flyology.Cancellation;
with Flyology.Supervision.Children;
with Flyology.Supervision.Families;
with Flyology.Supervision.Input_Children;
with Flyology.Supervision.Static;
with Interfaces;

procedure Flyology.Supervision.Nested_Family_Restart_Smoke is
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_64;

   Test_Failure : exception;

   subtype Link_Request is Positive range 1 .. 2;
   type Link_Count_Array is array (Link_Request) of Natural;
   type Link_Flag_Array is array (Link_Request) of Boolean;

   protected type Test_State is
      procedure Request_Prerequisite_Failure;
      procedure Take_Prerequisite_Failure (Requested : out Boolean);
      procedure Begin_Owner (Value : Generation);
      procedure Reconcile (Input : Link_Request);
      procedure Begin_Link (Input : Link_Request);
      procedure End_Link (Input : Link_Request);
      procedure Remember_First_Handle (Value : Child_Handle);
      function First_Handle return Child_Handle;
      procedure Note_Old_Handle_Rejected;
      procedure Note_Stop_Forwarding_Failure;
      function Owner_Count return Natural;
      function Reconciliation_Count (Input : Link_Request) return Natural;
      function Persistent_Creation_Count
        (Input : Link_Request) return Natural;
      function Link_Start_Count (Input : Link_Request) return Natural;
      function Link_Is_Active (Input : Link_Request) return Boolean;
      function Old_Handle_Was_Rejected return Boolean;
      function Stop_Forwarding_Failed return Boolean;
   private
      Failure_Pending : Boolean := False;
      Owners : Natural := 0;
      Last_Owner : Generation := Generation'First;
      Desired : Link_Flag_Array := (others => True);
      Reconciliations : Link_Count_Array := (others => 0);
      Persisted : Link_Flag_Array := (others => False);
      Persistent_Creations : Link_Count_Array := (others => 0);
      Active_Links : Link_Flag_Array := (others => False);
      Link_Starts : Link_Count_Array := (others => 0);
      Saved_Handle : Child_Handle;
      Has_Saved_Handle : Boolean := False;
      Old_Handle_Rejected : Boolean := False;
      Forwarding_Failed : Boolean := False;
   end Test_State;

   protected body Test_State is
      procedure Request_Prerequisite_Failure is
      begin
         Failure_Pending := True;
      end Request_Prerequisite_Failure;

      procedure Take_Prerequisite_Failure (Requested : out Boolean) is
      begin
         Requested := Failure_Pending;
         Failure_Pending := False;
      end Take_Prerequisite_Failure;

      procedure Begin_Owner (Value : Generation) is
      begin
         if Owners > 0 and then Value <= Last_Owner then
            raise Program_Error with
              "nested family owner generation did not advance";
         end if;
         Owners := Owners + 1;
         Last_Owner := Value;
      end Begin_Owner;

      procedure Reconcile (Input : Link_Request) is
      begin
         if not Desired (Input) then
            raise Program_Error with "an undesired link was reconciled";
         end if;
         Reconciliations (Input) := Reconciliations (Input) + 1;
         if not Persisted (Input) then
            Persisted (Input) := True;
            Persistent_Creations (Input) :=
              Persistent_Creations (Input) + 1;
         end if;
      end Reconcile;

      procedure Begin_Link (Input : Link_Request) is
      begin
         if Active_Links (Input) then
            raise Program_Error with
              "replacement link overlapped the prior family incarnation";
         end if;
         Active_Links (Input) := True;
         Link_Starts (Input) := Link_Starts (Input) + 1;
      end Begin_Link;

      procedure End_Link (Input : Link_Request) is
      begin
         if not Active_Links (Input) then
            raise Program_Error with "link generation ended twice";
         end if;
         Active_Links (Input) := False;
      end End_Link;

      procedure Remember_First_Handle (Value : Child_Handle) is
      begin
         if Has_Saved_Handle then
            raise Program_Error with "first family handle was overwritten";
         end if;
         Saved_Handle := Value;
         Has_Saved_Handle := True;
      end Remember_First_Handle;

      function First_Handle return Child_Handle is
      begin
         if not Has_Saved_Handle then
            raise Program_Error with "first family handle is unavailable";
         end if;
         return Saved_Handle;
      end First_Handle;

      procedure Note_Old_Handle_Rejected is
      begin
         Old_Handle_Rejected := True;
      end Note_Old_Handle_Rejected;

      procedure Note_Stop_Forwarding_Failure is
      begin
         Forwarding_Failed := True;
      end Note_Stop_Forwarding_Failure;

      function Owner_Count return Natural is (Owners);

      function Reconciliation_Count (Input : Link_Request) return Natural is
        (Reconciliations (Input));

      function Persistent_Creation_Count
        (Input : Link_Request) return Natural is
        (Persistent_Creations (Input));

      function Link_Start_Count (Input : Link_Request) return Natural is
        (Link_Starts (Input));

      function Link_Is_Active (Input : Link_Request) return Boolean is
        (Active_Links (Input));

      function Old_Handle_Was_Rejected return Boolean is
        (Old_Handle_Rejected);

      function Stop_Forwarding_Failed return Boolean is
        (Forwarding_Failed);
   end Test_State;

   type Family_Context is limited record
      State : Test_State;
   end record;

   type Context is limited record
      Family_State : aliased Family_Context;
   end record;

   procedure Execute_Link
     (State   : in out Family_Context;
      Input   : Link_Request;
      Control : not null access Generation_Control)
   is
      Released : Boolean := False;

      procedure Release is
      begin
         if not Released then
            State.State.End_Link (Input);
            Released := True;
         end if;
      end Release;
   begin
      State.State.Begin_Link (Input);
      Mark_Ready (Control.all);
      loop
         if Stop_Requested (Control.all) then
            Release;
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         delay 0.001;
      end loop;
   exception
      when others =>
         Release;
         raise;
   end Execute_Link;

   package Link_Child is new Flyology.Supervision.Input_Children
     (Input_Type          => Link_Request,
      Application_Context => Family_Context,
      Execute             => Execute_Link,
      Task_Model          => Flyology.Native_Task);

   procedure Run_Link_Generation
     (State   : aliased in out Family_Context;
      Input   : Link_Request;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result) is
   begin
      Link_Child.Run (State, Input, Control, Result);
   end Run_Link_Generation;

   Link_Policy : constant Child_Specification :=
     (Restart           => Never,
      Impact            => Escalate,
      Recovery          => Default_Recovery_Limits,
      Stopping          => Default_Stop_Policy,
      Readiness_Timeout => Ada.Real_Time.Seconds (1),
      Restart_Safe      => True,
      Task_Model        => Flyology.Native_Task,
      Has_Group         => False,
      Group             => 0);

   package Link_Families is new Flyology.Supervision.Families
     (Request             => Link_Request,
      Application_Context => Family_Context,
      Run_One_Generation  => Run_Link_Generation,
      Policy              => Link_Policy,
      First_Child_Id      => 12_000_000_000,
      Maximum_Children   => Link_Request'Last);

   protected type Nested_Completion is
      procedure Finish (Value : Supervisor_Result);
      procedure Fail;
      function Done return Boolean;
      function Succeeded return Boolean;
      function Outcome return Supervisor_Outcome;
   private
      Is_Done : Boolean := False;
      Was_Successful : Boolean := False;
      Stored_Outcome : Supervisor_Outcome := Shutdown_Completed;
   end Nested_Completion;

   protected body Nested_Completion is
      procedure Finish (Value : Supervisor_Result) is
      begin
         Is_Done := True;
         Was_Successful := True;
         Stored_Outcome := Value.Outcome;
      end Finish;

      procedure Fail is
      begin
         Is_Done := True;
         Was_Successful := False;
      end Fail;

      function Done return Boolean is (Is_Done);
      function Succeeded return Boolean is (Was_Successful);
      function Outcome return Supervisor_Outcome is (Stored_Outcome);
   end Nested_Completion;

   procedure Execute_Prerequisite
     (State   : in out Context;
      Control : not null access Generation_Control)
   is
      Requested : Boolean;
      Value : constant Generation := Current_Generation (Handle (Control.all));
   begin
      Mark_Ready (Control.all);
      loop
         if Value = Generation'First then
            State.Family_State.State.Take_Prerequisite_Failure (Requested);
            if Requested then
               raise Test_Failure with "restart-dependents trigger failed";
            end if;
         end if;
         if Stop_Requested (Control.all) then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         delay 0.001;
      end loop;
   end Execute_Prerequisite;

   procedure Execute_Family_Owner
     (State   : in out Context;
      Control : not null access Generation_Control)
   is
      Owner_Generation : constant Generation :=
        Current_Generation (Handle (Control.all));
      Item : aliased Link_Families.Family;
      Completion : Nested_Completion;

      task Runner;

      task body Runner is
         Result : Supervisor_Result;
      begin
         Link_Families.Run_Nested
           (Item, State.Family_State, Control.all, Result);
         Completion.Finish (Result);
      exception
         when others =>
            Completion.Fail;
      end Runner;

      Handles : array (Link_Request) of Child_Handle;
      Deadline : Ada.Real_Time.Time;
      Forwarding_Timed_Out : Boolean := False;
   begin
      State.Family_State.State.Begin_Owner (Owner_Generation);
      Deadline := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      while not Link_Families.Accepting (Item) loop
         if Completion.Done then
            raise Program_Error with
              "nested family returned before admission opened";
         elsif Ada.Real_Time.Clock >= Deadline then
            raise Program_Error with "nested family admission did not open";
         end if;
         delay 0.001;
      end loop;

      for Input in Link_Request loop
         State.Family_State.State.Reconcile (Input);
         Link_Families.Start (Item, Input, Handles (Input));
      end loop;

      if Owner_Generation = Generation'First then
         State.Family_State.State.Remember_First_Handle
           (Handles (Link_Request'First));
      else
         declare
            Old : constant Child_Handle :=
              State.Family_State.State.First_Handle;
         begin
            if Same_Controller (Old, Handles (Link_Request'First)) then
               raise Program_Error with
                 "reconstructed family reused its controller identity";
            end if;
            begin
               declare
                  Ignored : constant Child_Snapshot :=
                    Link_Families.Current (Item, Old);
               begin
                  pragma Unreferenced (Ignored);
                  raise Program_Error with
                    "old family handle controlled the new incarnation";
               end;
            exception
               when Link_Families.Stale_Handle =>
                  State.Family_State.State.Note_Old_Handle_Rejected;
            end;
         end;
      end if;

      Deadline := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (2);
      for Input in Link_Request loop
         while not Link_Families.Current (Item, Handles (Input)).Ready loop
            if Completion.Done then
               raise Program_Error with
                 "nested family returned before desired links were ready";
            elsif Ada.Real_Time.Clock >= Deadline then
               raise Program_Error with "desired link did not become ready";
            end if;
            delay 0.001;
         end loop;
      end loop;
      Mark_Ready (Control.all);

      while not Stop_Requested (Control.all) loop
         if Completion.Done then
            raise Program_Error with
              "nested family returned while its owner remained live";
         end if;
         delay 0.001;
      end loop;

      Deadline := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (1);
      while not Completion.Done loop
         if Ada.Real_Time.Clock >= Deadline then
            Forwarding_Timed_Out := True;
            State.Family_State.State.Note_Stop_Forwarding_Failure;
            Link_Families.Request_Shutdown (Item);
            exit;
         end if;
         delay 0.001;
      end loop;
      while not Completion.Done loop
         delay 0.001;
      end loop;

      if Forwarding_Timed_Out then
         raise Program_Error with
           "Run_Nested did not forward its parent stop";
      elsif not Completion.Succeeded
        or else Completion.Outcome /= Shutdown_Completed
      then
         raise Program_Error with "nested family shutdown failed";
      end if;
   exception
      when others =>
         Link_Families.Request_Shutdown (Item);
         while not Completion.Done loop
            delay 0.001;
         end loop;
         raise;
   end Execute_Family_Owner;

   package Prerequisite_Child is new Flyology.Supervision.Children
     (Application_Context => Context,
      Execute             => Execute_Prerequisite,
      Task_Model          => Flyology.Native_Task);

   package Family_Owner_Child is new Flyology.Supervision.Children
     (Application_Context => Context,
      Execute             => Execute_Family_Owner,
      Task_Model          => Flyology.Native_Task);

   type Outer_Child is (Prerequisite, Family_Owner);

   function Outer_Id (Child : Outer_Child) return Child_Id is
     (Child_Id (13_000_000_000 + Outer_Child'Pos (Child)));

   function Outer_Specification
     (Child : Outer_Child) return Child_Specification is
     ((Restart           =>
         (if Child = Prerequisite then On_Failure else Never),
       Impact            =>
         (if Child = Prerequisite then Restart_Dependents else Escalate),
       Recovery          =>
         (Burst_Attempts    => 2,
          Window            => Ada.Real_Time.Seconds (1),
          Total_Attempts    => 2,
          Initial_Backoff   => Ada.Real_Time.Milliseconds (1),
          Maximum_Backoff   => Ada.Real_Time.Milliseconds (1),
          Stability_Reset   => Ada.Real_Time.Seconds (1),
          Recovery_Deadline => Ada.Real_Time.Seconds (3)),
       Stopping          =>
         (Grace             => Ada.Real_Time.Seconds (2),
          Request_Abort     => False,
          Abort_Observation => Ada.Real_Time.Seconds (1)),
       Readiness_Timeout => Ada.Real_Time.Seconds (2),
       Restart_Safe      => True,
       Task_Model        => Flyology.Native_Task,
       Has_Group         => False,
       Group             => 0));

   function Depends_On
     (Child, Required : Outer_Child) return Boolean is
     (Child = Family_Owner and then Required = Prerequisite);

   function Same_Cohort
     (Trigger, Member : Outer_Child) return Boolean is
     (Trigger = Member);

   procedure Run_Outer_Generation
     (State   : aliased in out Context;
      Child   : Outer_Child;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result) is
   begin
      case Child is
         when Prerequisite =>
            Prerequisite_Child.Run (State, Control, Result);
         when Family_Owner =>
            Family_Owner_Child.Run (State, Control, Result);
      end case;
   end Run_Outer_Generation;

   package Outer_Supervisors is new Flyology.Supervision.Static
     (Child_Kind          => Outer_Child,
      Application_Context => Context,
      Logical_Id          => Outer_Id,
      Specification       => Outer_Specification,
      Depends_On          => Depends_On,
      Cohort_Member       => Same_Cohort,
      Run_One_Generation  => Run_Outer_Generation);

   State : aliased Context;
   Item : aliased Outer_Supervisors.Supervisor;
   Result : Supervisor_Result;

   task Owner is
      entry Start;
      entry Join;
   end Owner;

   task body Owner is
   begin
      accept Start;
      Outer_Supervisors.Run (Item, State, Result);
      accept Join;
   end Owner;

   Deadline : Ada.Real_Time.Time;
begin
   Owner.Start;
   Deadline := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
   loop
      exit when
        Outer_Supervisors.Current (Item, Prerequisite).Ready
        and then Outer_Supervisors.Current (Item, Family_Owner).Ready;
      if Ada.Real_Time.Clock >= Deadline then
         raise Program_Error with "outer topology did not become ready";
      end if;
      delay 0.001;
   end loop;

   State.Family_State.State.Request_Prerequisite_Failure;
   Deadline := Ada.Real_Time.Clock + Ada.Real_Time.Seconds (5);
   loop
      exit when
        Outer_Supervisors.Current (Item, Prerequisite).Ready
        and then Outer_Supervisors.Current (Item, Family_Owner).Ready
        and then
          Outer_Supervisors.Current (Item, Prerequisite).Generation = 2
        and then
          Outer_Supervisors.Current (Item, Family_Owner).Generation = 2;
      if Ada.Real_Time.Clock >= Deadline then
         raise Program_Error with
           "nested family owner was not reconstructed";
      end if;
      delay 0.001;
   end loop;

   pragma Assert (State.Family_State.State.Owner_Count = 2);
   pragma Assert (State.Family_State.State.Old_Handle_Was_Rejected);
   pragma Assert (not State.Family_State.State.Stop_Forwarding_Failed);
   for Input in Link_Request loop
      pragma Assert
        (State.Family_State.State.Reconciliation_Count (Input) = 2);
      pragma Assert
        (State.Family_State.State.Persistent_Creation_Count (Input) = 1);
      pragma Assert (State.Family_State.State.Link_Start_Count (Input) = 2);
      pragma Assert (State.Family_State.State.Link_Is_Active (Input));
   end loop;

   Outer_Supervisors.Request_Shutdown (Item);
   Owner.Join;
   pragma Assert (Result.Outcome = Shutdown_Completed);
   pragma Assert (not State.Family_State.State.Stop_Forwarding_Failed);
   for Input in Link_Request loop
      pragma Assert (not State.Family_State.State.Link_Is_Active (Input));
   end loop;
exception
   when others =>
      Outer_Supervisors.Request_Shutdown (Item);
      select
         Owner.Join;
      or
         delay 3.0;
      end select;
      raise;
end Flyology.Supervision.Nested_Family_Restart_Smoke;
