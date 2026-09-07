with Ada.Real_Time;
with Flyology.Supervision.Children;
with Flyology.Supervision.Families;
with Flyology.Supervision.Input_Children;
with Flyology.Supervision.Static;
with Flyology.Task_Lifecycle_Testing;

procedure Flyology.Supervision.Restart_Window_Smoke is
   Spike_Failure : exception;

   protected type Generation_Counter is
      procedure Begin_Generation (Value : out Positive);
      function Current return Natural;
   private
      Value : Natural := 0;
   end Generation_Counter;

   protected body Generation_Counter is
      procedure Begin_Generation (Value : out Positive) is
      begin
         Generation_Counter.Value := Generation_Counter.Value + 1;
         Value := Generation_Counter.Value;
      end Begin_Generation;

      function Current return Natural
      is (Value);
   end Generation_Counter;

   type Static_Context is limited record
      Starts : Generation_Counter;
   end record;

   procedure Execute_Static (Context : in out Static_Context; Control : not null access Generation_Control) is
      Attempt : Positive;
   begin
      Context.Starts.Begin_Generation (Attempt);
      if Attempt = 1 then
         Mark_Ready (Control.all);
         delay 0.250;
      end if;
      raise Spike_Failure with "static generation fails";
   end Execute_Static;

   package Static_Child is new
     Children (Application_Context => Static_Context, Execute => Execute_Static, Task_Model => Native_Task);

   type Static_Child_Kind is (Service);

   Recovery : constant Recovery_Limits :=
     (Burst_Attempts    => 3,
      Window            => Ada.Real_Time.Seconds (5),
      Total_Attempts    => 10,
      Initial_Backoff   => Ada.Real_Time.Milliseconds (10),
      Maximum_Backoff   => Ada.Real_Time.Milliseconds (10),
      Stability_Reset   => Ada.Real_Time.Milliseconds (200),
      Recovery_Deadline => Ada.Real_Time.Seconds (2));

   Child_Recovery : constant Recovery_Limits :=
     (Burst_Attempts    => 10,
      Window            => Ada.Real_Time.Seconds (5),
      Total_Attempts    => 10,
      Initial_Backoff   => Ada.Real_Time.Milliseconds (10),
      Maximum_Backoff   => Ada.Real_Time.Milliseconds (10),
      Stability_Reset   => Ada.Real_Time.Milliseconds (200),
      Recovery_Deadline => Ada.Real_Time.Seconds (2));

   function Static_Id (Child : Static_Child_Kind) return Child_Id is
      pragma Unreferenced (Child);
   begin
      return 16_900_001;
   end Static_Id;

   function Static_Specification (Child : Static_Child_Kind) return Child_Specification is
      pragma Unreferenced (Child);
   begin
      return
        (Restart           => On_Failure,
         Impact            => Isolate_Child,
         Recovery          => Child_Recovery,
         Stopping          => Default_Stop_Policy,
         Readiness_Timeout => Ada.Real_Time.Seconds (1),
         Restart_Safe      => True,
         Task_Model        => Native_Task,
         Has_Group         => False,
         Group             => 0);
   end Static_Specification;

   function No_Static_Relationship (Left, Right : Static_Child_Kind) return Boolean is
      pragma Unreferenced (Left, Right);
   begin
      return False;
   end No_Static_Relationship;

   procedure Run_Static_Generation
     (Context : aliased in out Static_Context;
      Child   : Static_Child_Kind;
      Control : aliased in out Generation_Control;
      Result  : out Generation_Result)
   is
      pragma Unreferenced (Child);
   begin
      Static_Child.Run (Context, Control, Result);
   end Run_Static_Generation;

   package Static_Supervisor is new
     Static
       (Child_Kind          => Static_Child_Kind,
        Application_Context => Static_Context,
        Logical_Id          => Static_Id,
        Specification       => Static_Specification,
        Depends_On          => No_Static_Relationship,
        Cohort_Member       => No_Static_Relationship,
        Run_One_Generation  => Run_Static_Generation,
        Subtree_Recovery    => Recovery);

   type Family_Context is limited record
      Starts : Generation_Counter;
   end record;

   type Family_Request is (Only_Child);

   procedure Execute_Family
     (Context : in out Family_Context; Input : Family_Request; Control : not null access Generation_Control)
   is
      pragma Unreferenced (Input);
      Attempt : Positive;
   begin
      Context.Starts.Begin_Generation (Attempt);
      if Attempt = 1 then
         Mark_Ready (Control.all);
         delay 0.250;
      end if;
      raise Spike_Failure with "family generation fails";
   end Execute_Family;

   package Family_Child is new
     Input_Children
       (Input_Type          => Family_Request,
        Application_Context => Family_Context,
        Execute             => Execute_Family,
        Task_Model          => Native_Task);

   Family_Recovery : constant Recovery_Limits :=
     (Burst_Attempts    => 3,
      Window            => Ada.Real_Time.Seconds (5),
      Total_Attempts    => 10,
      Initial_Backoff   => Ada.Real_Time.Milliseconds (10),
      Maximum_Backoff   => Ada.Real_Time.Milliseconds (10),
      Stability_Reset   => Ada.Real_Time.Milliseconds (200),
      Recovery_Deadline => Ada.Real_Time.Seconds (2));

   Family_Specification : constant Child_Specification :=
     (Restart           => On_Failure,
      Impact            => Isolate_Child,
      Recovery          => Family_Recovery,
      Stopping          => Default_Stop_Policy,
      Readiness_Timeout => Ada.Real_Time.Seconds (1),
      Restart_Safe      => True,
      Task_Model        => Native_Task,
      Has_Group         => False,
      Group             => 0);

   package Family_Supervisor is new
     Families
       (Request             => Family_Request,
        Application_Context => Family_Context,
        Run_One_Generation  => Family_Child.Run,
        Policy              => Family_Specification,
        First_Child_Id      => 16_900_002,
        Maximum_Children    => 1);

begin
   Flyology.Task_Lifecycle_Testing.Reset;
   declare
      Context : aliased Static_Context;
      Item    : aliased Static_Supervisor.Supervisor;
      Result  : Supervisor_Result;
      Matched : Boolean := True;

      task Owner is
         entry Start;
         entry Join;
      end Owner;

      task body Owner is
      begin
         accept Start;
         Static_Supervisor.Run (Item, Context, Result);
         accept Join;
      end Owner;
   begin
      Flyology.Task_Lifecycle_Testing.Arm (Flyology.Task_Lifecycle_Testing.Static_Generation_Starting);
      Owner.Start;
      for Expected in 1 .. 4 loop
         Flyology.Task_Lifecycle_Testing.Wait_Reached
           (Flyology.Task_Lifecycle_Testing.Static_Generation_Starting);
         declare
            Snapshot : constant Child_Snapshot := Static_Supervisor.Current (Item, Service);
         begin
            Flyology.Task_Lifecycle_Testing.Arm
              (Flyology.Task_Lifecycle_Testing.Static_Generation_Terminated);
            Flyology.Task_Lifecycle_Testing.Release
              (Flyology.Task_Lifecycle_Testing.Static_Generation_Starting);
            Flyology.Task_Lifecycle_Testing.Wait_Reached
              (Flyology.Task_Lifecycle_Testing.Static_Generation_Terminated);
            if Expected < 4 then
               Flyology.Task_Lifecycle_Testing.Arm
                 (Flyology.Task_Lifecycle_Testing.Static_Generation_Starting);
            end if;
            Flyology.Task_Lifecycle_Testing.Release
              (Flyology.Task_Lifecycle_Testing.Static_Generation_Terminated);
            Matched :=
              Matched
              and then Natural (Snapshot.Attempts) = Expected - 1
              and then Snapshot.State = Starting
              and then not Snapshot.Ready;
         end;
      end loop;
      Owner.Join;
      pragma Assert (Matched);
      pragma Assert (Context.Starts.Current = 4);
      pragma Assert (Result.Outcome = Recovery_Exhausted);
      pragma Assert (Result.Termination.Kind = Policy_Exhaustion);
      pragma Assert (Natural (Static_Supervisor.Current (Item, Service).Attempts) = 3);
   end;

   Flyology.Task_Lifecycle_Testing.Reset;
   declare
      Context : aliased Family_Context;
      Item    : aliased Family_Supervisor.Family;
      Result  : Supervisor_Result;
      Matched : Boolean := True;

      task Owner is
         entry Start;
         entry Join;
      end Owner;

      task body Owner is
      begin
         accept Start;
         Family_Supervisor.Run (Item, Context, Result);
         accept Join;
      end Owner;

      Handle : Child_Handle;
   begin
      Flyology.Task_Lifecycle_Testing.Arm (Flyology.Task_Lifecycle_Testing.Family_Generation_Starting);
      Owner.Start;
      loop
         exit when Family_Supervisor.Accepting (Item);
         delay 0.001;
      end loop;
      Family_Supervisor.Start (Item, Only_Child, Handle);
      for Expected in 1 .. 4 loop
         Flyology.Task_Lifecycle_Testing.Wait_Reached
           (Flyology.Task_Lifecycle_Testing.Family_Generation_Starting);
         declare
            Snapshot : constant Child_Snapshot := Family_Supervisor.Current (Item, Child_Id (16_900_002));
         begin
            Flyology.Task_Lifecycle_Testing.Arm
              (Flyology.Task_Lifecycle_Testing.Family_Generation_Terminated);
            Flyology.Task_Lifecycle_Testing.Release
              (Flyology.Task_Lifecycle_Testing.Family_Generation_Starting);
            Flyology.Task_Lifecycle_Testing.Wait_Reached
              (Flyology.Task_Lifecycle_Testing.Family_Generation_Terminated);
            if Expected < 4 then
               Flyology.Task_Lifecycle_Testing.Arm
                 (Flyology.Task_Lifecycle_Testing.Family_Generation_Starting);
            end if;
            Flyology.Task_Lifecycle_Testing.Release
              (Flyology.Task_Lifecycle_Testing.Family_Generation_Terminated);
            Matched :=
              Matched
              and then Natural (Snapshot.Attempts) = Expected - 1
              and then Snapshot.State = Starting
              and then not Snapshot.Ready;
         end;
      end loop;
      Owner.Join;
      pragma Assert (Matched);
      pragma Assert (Context.Starts.Current = 4);
      pragma Assert (Result.Outcome = Recovery_Exhausted);
      pragma Assert (Result.Termination.Kind = Policy_Exhaustion);
      pragma Assert (Natural (Family_Supervisor.Current (Item, Child_Id (16_900_002)).Attempts) = 3);
   end;
end Flyology.Supervision.Restart_Window_Smoke;
