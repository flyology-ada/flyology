with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Flyology.Supervision.Children;
with Flyology.Supervision.Families;
with Flyology.Supervision.Input_Children;
with Flyology.Supervision.Static;
with Flyology.Task_Lifecycle_Testing;
with Flyology_TLA.Command_Line;
with Flyology_TLA.Replay;
with Flyology_TLA.Traces;
with Supervision_Restart_Window_Model;

procedure Flyology.Supervision.Restart_Window_Conformance is

   package Model renames Supervision_Restart_Window_Model;
   package Hooks renames Flyology.Task_Lifecycle_Testing;
   use Ada.Strings.Unbounded;
   use type Model.Input_Step_Type;
   use type Model.State_Phase_Type;

   Limits : constant Flyology_TLA.Traces.Load_Limits :=
     (Maximum_File_Bytes   => 1_000_000,
      Maximum_Steps        => 16,
      Maximum_JSON_Depth   => 24,
      Maximum_Object_Names => 1_000,
      Maximum_Name_Bytes   => 4_096,
      Maximum_String_Bytes => 100_000,
      Maximum_Value_Bytes  => 500_000);

   Replay_Failure : exception;

   protected type Gate is
      procedure Arrive;
      entry Wait_Reached;
      entry Hold;
      procedure Release;
   private
      At_Gate : Boolean := False;
      Open    : Boolean := False;
   end Gate;

   protected body Gate is
      procedure Arrive is
      begin
         At_Gate := True;
      end Arrive;

      entry Wait_Reached when At_Gate is
      begin
         null;
      end Wait_Reached;

      entry Hold when Open is
      begin
         Open := False;
         At_Gate := False;
      end Hold;

      procedure Release is
      begin
         Open := True;
      end Release;
   end Gate;

   protected type Generation_Counter is
      procedure Begin_Generation;
      function Current return Natural;
   private
      Value : Natural := 0;
   end Generation_Counter;

   protected body Generation_Counter is
      procedure Begin_Generation is
      begin
         Value := Value + 1;
      end Begin_Generation;

      function Current return Natural
      is (Value);
   end Generation_Counter;

   type Static_Context is limited record
      Starts : Generation_Counter;
      Ready  : Gate;
      Stable : Gate;
   end record;

   procedure Execute_Static (Context : in out Static_Context; Control : not null access Generation_Control) is
   begin
      Context.Starts.Begin_Generation;
      if Context.Starts.Current = 1 then
         Mark_Ready (Control.all);
         Context.Ready.Arrive;
         Context.Ready.Hold;
         delay 0.250;
         Context.Stable.Arrive;
         Context.Stable.Hold;
      end if;
      raise Replay_Failure with "modeled static generation failure";
   end Execute_Static;

   package Static_Child is new
     Supervision.Children
       (Application_Context => Static_Context,
        Execute             => Execute_Static,
        Task_Model          => Native_Task);

   type Static_Child_Kind is (Service);

   Subtree_Recovery : constant Recovery_Limits :=
     (Burst_Attempts    => 3,
      Window            => Ada.Real_Time.Seconds (5),
      Total_Attempts    => 3,
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
      return 16_900_011;
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

   function No_Relationship (Left, Right : Static_Child_Kind) return Boolean is
      pragma Unreferenced (Left, Right);
   begin
      return False;
   end No_Relationship;

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

   package Static_Controller is new
     Supervision.Static
       (Child_Kind          => Static_Child_Kind,
        Application_Context => Static_Context,
        Logical_Id          => Static_Id,
        Specification       => Static_Specification,
        Depends_On          => No_Relationship,
        Cohort_Member       => No_Relationship,
        Run_One_Generation  => Run_Static_Generation,
        Subtree_Recovery    => Subtree_Recovery);

   type Family_Context is limited record
      Starts : Generation_Counter;
      Ready  : Gate;
      Stable : Gate;
   end record;

   type Family_Request is (Only_Child);

   procedure Execute_Family
     (Context : in out Family_Context; Input : Family_Request; Control : not null access Generation_Control)
   is
      pragma Unreferenced (Input);
   begin
      Context.Starts.Begin_Generation;
      if Context.Starts.Current = 1 then
         Mark_Ready (Control.all);
         Context.Ready.Arrive;
         Context.Ready.Hold;
         delay 0.250;
         Context.Stable.Arrive;
         Context.Stable.Hold;
      end if;
      raise Replay_Failure with "modeled family generation failure";
   end Execute_Family;

   package Family_Child is new
     Supervision.Input_Children
       (Input_Type          => Family_Request,
        Application_Context => Family_Context,
        Execute             => Execute_Family,
        Task_Model          => Native_Task);

   Family_Specification : constant Child_Specification :=
     (Restart           => On_Failure,
      Impact            => Isolate_Child,
      Recovery          => Subtree_Recovery,
      Stopping          => Default_Stop_Policy,
      Readiness_Timeout => Ada.Real_Time.Seconds (1),
      Restart_Safe      => True,
      Task_Model        => Native_Task,
      Has_Group         => False,
      Group             => 0);

   package Family_Controller is new
     Supervision.Families
       (Request             => Family_Request,
        Application_Context => Family_Context,
        Run_One_Generation  => Family_Child.Run,
        Policy              => Family_Specification,
        First_Child_Id      => 16_900_012,
        Maximum_Children    => 1);

   type Static_Context_Access is access all Static_Context;
   type Static_Controller_Access is access all Static_Controller.Supervisor;
   type Family_Context_Access is access all Family_Context;
   type Family_Controller_Access is access all Family_Controller.Family;
   type Result_Access is access all Supervisor_Result;

   task type Static_Worker
     (Context : not null Static_Context_Access;
      Item    : not null Static_Controller_Access;
      Result  : not null Result_Access)
   is
      entry Join;
   end Static_Worker;

   task body Static_Worker is
   begin
      Static_Controller.Run (Item.all, Context.all, Result.all);
      accept Join;
   end Static_Worker;

   task type Family_Worker
     (Context : not null Family_Context_Access;
      Item    : not null Family_Controller_Access;
      Result  : not null Result_Access)
   is
      entry Join;
   end Family_Worker;

   task body Family_Worker is
   begin
      Family_Controller.Run (Item.all, Context.all, Result.all);
      accept Join;
   end Family_Worker;

   type Static_Worker_Access is access Static_Worker;
   type Family_Worker_Access is access Family_Worker;

   procedure Free_Static is new Ada.Unchecked_Deallocation (Static_Worker, Static_Worker_Access);
   procedure Free_Family is new Ada.Unchecked_Deallocation (Family_Worker, Family_Worker_Access);

   Initial_State : constant Model.State_Type :=
     (Phase               => Model.State_Phase_Starting,
      Now                 => 0,
      Static_Ready_Since  => 2,
      Subtree_Ready_Since => 2,
      Family_Ready_Since  => 2,
      Static_Used         => 0,
      Subtree_Used        => 0,
      Family_Used         => 0,
      Static_Starts       => 1,
      Family_Starts       => 1,
      Exhausted           => False,
      Last_Action         => Model.State_Last_Action_Init);

   type Restart_Adapter is new Model.Adapter with record
      Static_Context : aliased Flyology.Supervision.Restart_Window_Conformance.Static_Context;
      Static_Item    : aliased Static_Controller.Supervisor;
      Static_Result  : aliased Supervisor_Result;
      Family_Context : aliased Flyology.Supervision.Restart_Window_Conformance.Family_Context;
      Family_Item    : aliased Family_Controller.Family;
      Family_Result  : aliased Supervisor_Result;
      Family_Handle  : Child_Handle;
      Static_Task    : Static_Worker_Access := null;
      Family_Task    : Family_Worker_Access := null;
      Current        : Model.State_Type := Initial_State;
      Ready          : Boolean := False;
   end record;

   overriding
   procedure Reset
     (Self     : in out Restart_Adapter;
      Observed : out Model.State_Type;
      Status   : out Flyology_TLA.Replay.Adapter_Outcome);

   overriding
   procedure Apply
     (Self         : in out Restart_Adapter;
      Index        : Positive;
      Action       : String;
      Role         : String;
      Input        : Model.Input_Type;
      Model_Source : String;
      Observed     : out Model.Outcome_Type;
      State        : out Model.State_Type;
      Status       : out Flyology_TLA.Replay.Adapter_Outcome);

   procedure Fail (Status : out Flyology_TLA.Replay.Adapter_Outcome; Detail : String) is
   begin
      Status := (Succeeded => False, Detail => To_Unbounded_String (Detail));
   end Fail;

   procedure Wait_Hook (Point : Hooks.Barrier_Point) is
   begin
      Hooks.Wait_Reached (Point);
   end Wait_Hook;

   function Static_Snapshot (Self : Restart_Adapter) return Child_Snapshot
   is (Static_Controller.Current (Self.Static_Item, Service));

   function Family_Snapshot (Self : Restart_Adapter) return Child_Snapshot
   is (Family_Controller.Current (Self.Family_Item, Child_Id (16_900_012)));

   procedure Set_Observed (Self : Restart_Adapter; Observed : out Model.Outcome_Type) is
   begin
      Observed :=
        (Static_Starts => Model.Outcome_Static_Starts_Type (Self.Current.Static_Starts),
         Family_Starts => Model.Outcome_Family_Starts_Type (Self.Current.Family_Starts),
         Static_Used   => Model.Outcome_Static_Used_Type (Self.Current.Static_Used),
         Subtree_Used  => Model.Outcome_Subtree_Used_Type (Self.Current.Subtree_Used),
         Family_Used   => Model.Outcome_Family_Used_Type (Self.Current.Family_Used),
         Exhausted     => Self.Current.Exhausted);
   end Set_Observed;

   procedure Reset
     (Self     : in out Restart_Adapter;
      Observed : out Model.State_Type;
      Status   : out Flyology_TLA.Replay.Adapter_Outcome) is
   begin
      Hooks.Reset;
      Hooks.Arm (Hooks.Static_Generation_Starting);
      Hooks.Arm (Hooks.Family_Generation_Starting);
      Self.Static_Task :=
        new Static_Worker
              (Self.Static_Context'Unchecked_Access,
               Self.Static_Item'Unchecked_Access,
               Self.Static_Result'Unchecked_Access);
      Self.Family_Task :=
        new Family_Worker
              (Self.Family_Context'Unchecked_Access,
               Self.Family_Item'Unchecked_Access,
               Self.Family_Result'Unchecked_Access);
      while not Family_Controller.Accepting (Self.Family_Item) loop
         delay 0.001;
      end loop;
      Family_Controller.Start (Self.Family_Item, Only_Child, Self.Family_Handle);
      Wait_Hook (Hooks.Static_Generation_Starting);
      Wait_Hook (Hooks.Family_Generation_Starting);
      Self.Current := Initial_State;
      Self.Ready := True;
      Observed := Self.Current;
      Status := (Succeeded => True, Detail => Null_Unbounded_String);
   exception
      when Error : others =>
         Observed := Self.Current;
         Fail (Status, "fixture reset failed: " & Ada.Exceptions.Exception_Message (Error));
   end Reset;

   procedure Apply
     (Self         : in out Restart_Adapter;
      Index        : Positive;
      Action       : String;
      Role         : String;
      Input        : Model.Input_Type;
      Model_Source : String;
      Observed     : out Model.Outcome_Type;
      State        : out Model.State_Type;
      Status       : out Flyology_TLA.Replay.Adapter_Outcome)
   is
      pragma Unreferenced (Index);
      Static_Value : Child_Snapshot;
      Family_Value : Child_Snapshot;
   begin
      Set_Observed (Self, Observed);
      State := Self.Current;
      if not Self.Ready then
         Fail (Status, "supervision fixture is not ready");
         return;
      elsif Action /= Model_Source then
         Fail (Status, "modeled action and source differ");
         return;
      end if;

      if Role = "mark-ready" and then Input.Step = Model.Input_Step_Mark_Restart_Ready then
         Hooks.Release (Hooks.Static_Generation_Starting);
         Hooks.Release (Hooks.Family_Generation_Starting);
         Self.Static_Context.Ready.Wait_Reached;
         Self.Family_Context.Ready.Wait_Reached;
         loop
            Static_Value := Static_Snapshot (Self);
            Family_Value := Family_Snapshot (Self);
            exit when Static_Value.Ready and then Family_Value.Ready;
            delay 0.001;
         end loop;
         Self.Current.Phase := Model.State_Phase_Ready_Await_Stability;
         Self.Current.Static_Ready_Since := 0;
         Self.Current.Subtree_Ready_Since := 0;
         Self.Current.Family_Ready_Since := 0;
         Self.Current.Last_Action := Model.State_Last_Action_Mark_Restart_Ready;

      elsif Role = "advance-time" and then Input.Step = Model.Input_Step_Advance_Restart_Time then
         Self.Static_Context.Ready.Release;
         Self.Family_Context.Ready.Release;
         Self.Static_Context.Stable.Wait_Reached;
         Self.Family_Context.Stable.Wait_Reached;
         Self.Current.Phase := Model.State_Phase_Ready;
         Self.Current.Now := 1;
         Self.Current.Last_Action := Model.State_Last_Action_Advance_Restart_Time;

      elsif Role = "fail"
        and then Input.Step in Model.Input_Step_Restart_Failure | Model.Input_Step_Restart_Exhausted
      then
         Hooks.Arm (Hooks.Static_Generation_Terminated);
         Hooks.Arm (Hooks.Family_Generation_Terminated);
         if Self.Current.Phase = Model.State_Phase_Ready then
            Self.Static_Context.Stable.Release;
            Self.Family_Context.Stable.Release;
         else
            Hooks.Release (Hooks.Static_Generation_Starting);
            Hooks.Release (Hooks.Family_Generation_Starting);
         end if;
         Wait_Hook (Hooks.Static_Generation_Terminated);
         Wait_Hook (Hooks.Family_Generation_Terminated);
         Static_Value := Static_Snapshot (Self);
         Family_Value := Family_Snapshot (Self);
         Self.Current.Static_Starts := Model.State_Static_Starts_Type (Self.Static_Context.Starts.Current);
         Self.Current.Family_Starts := Model.State_Family_Starts_Type (Self.Family_Context.Starts.Current);
         Self.Current.Static_Used := Model.State_Static_Used_Type (Static_Value.Attempts);
         Self.Current.Subtree_Used := Model.State_Subtree_Used_Type (Static_Value.Attempts);
         Self.Current.Family_Used := Model.State_Family_Used_Type (Family_Value.Attempts);
         if Input.Step = Model.Input_Step_Restart_Exhausted then
            Self.Current.Phase := Model.State_Phase_Exhausted;
            Self.Current.Exhausted := True;
            Self.Current.Last_Action := Model.State_Last_Action_Restart_Exhausted;
            Hooks.Release (Hooks.Static_Generation_Terminated);
            Hooks.Release (Hooks.Family_Generation_Terminated);
            Self.Static_Task.Join;
            Self.Family_Task.Join;
            Free_Static (Self.Static_Task);
            Free_Family (Self.Family_Task);
         else
            Self.Current.Phase := Model.State_Phase_Replacement_Start;
            Self.Current.Subtree_Ready_Since := 2;
            Self.Current.Last_Action := Model.State_Last_Action_Restart_Failure;
         end if;

      elsif Role = "start-generation" and then Input.Step = Model.Input_Step_Start_Restart_Generation then
         Hooks.Arm (Hooks.Static_Generation_Starting);
         Hooks.Arm (Hooks.Family_Generation_Starting);
         Hooks.Release (Hooks.Static_Generation_Terminated);
         Hooks.Release (Hooks.Family_Generation_Terminated);
         Wait_Hook (Hooks.Static_Generation_Starting);
         Wait_Hook (Hooks.Family_Generation_Starting);
         Static_Value := Static_Snapshot (Self);
         Family_Value := Family_Snapshot (Self);
         Self.Current.Phase := Model.State_Phase_Starting_Unready;
         Self.Current.Static_Ready_Since := 2;
         Self.Current.Family_Ready_Since := 2;
         Self.Current.Static_Starts :=
           Model.State_Static_Starts_Type (Self.Static_Context.Starts.Current + 1);
         Self.Current.Family_Starts :=
           Model.State_Family_Starts_Type (Self.Family_Context.Starts.Current + 1);
         Self.Current.Static_Used := Model.State_Static_Used_Type (Static_Value.Attempts);
         Self.Current.Subtree_Used := Model.State_Subtree_Used_Type (Static_Value.Attempts);
         Self.Current.Family_Used := Model.State_Family_Used_Type (Family_Value.Attempts);
         Self.Current.Last_Action := Model.State_Last_Action_Start_Restart_Generation;

      else
         Fail (Status, "unsupported modeled supervision action or input");
         return;
      end if;

      Set_Observed (Self, Observed);
      State := Self.Current;
      Status := (Succeeded => True, Detail => Null_Unbounded_String);
   exception
      when Error : others =>
         Set_Observed (Self, Observed);
         State := Self.Current;
         Fail (Status, "implementation action failed: " & Ada.Exceptions.Exception_Message (Error));
   end Apply;

   procedure Cleanup (Self : in out Restart_Adapter) is
   begin
      if Self.Static_Task /= null then
         Hooks.Release (Hooks.Static_Generation_Starting);
         Hooks.Release (Hooks.Static_Generation_Terminated);
         Self.Static_Context.Ready.Release;
         Self.Static_Context.Stable.Release;
         Static_Controller.Request_Shutdown (Self.Static_Item);
         Self.Static_Task.Join;
         Free_Static (Self.Static_Task);
      end if;
      if Self.Family_Task /= null then
         Hooks.Release (Hooks.Family_Generation_Starting);
         Hooks.Release (Hooks.Family_Generation_Terminated);
         Self.Family_Context.Ready.Release;
         Self.Family_Context.Stable.Release;
         Family_Controller.Request_Shutdown (Self.Family_Item);
         Self.Family_Task.Join;
         Free_Family (Self.Family_Task);
      end if;
      Self.Ready := False;
   end Cleanup;

begin
   declare
      Config : Flyology_TLA.Command_Line.Configuration := Flyology_TLA.Command_Line.Parse (Limits);
   begin
      if Flyology_TLA.Command_Line.Help_Requested (Config) then
         Flyology_TLA.Command_Line.Put_Help;
         return;
      end if;

      declare
         Trace   : constant Flyology_TLA.Traces.Trace := Flyology_TLA.Command_Line.Load (Config);
         Adapter : Restart_Adapter;
         Result  : Flyology_TLA.Replay.Replay_Result;
      begin
         Model.Run (Adapter, Trace, Flyology_TLA.Command_Line.Limits (Config), Result);
         Cleanup (Adapter);
         Flyology_TLA.Command_Line.Report (Config, Result);
         Flyology_TLA.Command_Line.Set_Exit_Status (Result);
      end;
   end;
exception
   when Error : Flyology_TLA.Command_Line.Usage_Error =>
      Flyology_TLA.Command_Line.Fail (Ada.Exceptions.Exception_Message (Error), Show_Help => True);
   when Error : Flyology_TLA.Traces.Trace_Error =>
      Flyology_TLA.Command_Line.Fail ("cannot load trace: " & Ada.Exceptions.Exception_Message (Error));
end Flyology.Supervision.Restart_Window_Conformance;
