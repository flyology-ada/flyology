with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Completion_Set_Finalize_Model;
with Flyology;
with Flyology.IO.Sockets;
with Flyology.Operations;
with Flyology.Operations.Drivers;
with Flyology_TLA.Command_Line;
with Flyology_TLA.Replay;
with Flyology_TLA.Traces;

procedure Operations_Finalize_Conformance is
   package Model renames Completion_Set_Finalize_Model;
   package Operations renames Flyology.Operations;
   package Drivers renames Flyology.Operations.Drivers;
   package Sockets renames Flyology.IO.Sockets;

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;
   use type Operations.Driver_Event;

   Limits : constant Flyology_TLA.Traces.Load_Limits :=
     (Maximum_File_Bytes   => 1_000_000,
      Maximum_Steps        => 16,
      Maximum_JSON_Depth   => 32,
      Maximum_Object_Names => 256,
      Maximum_Name_Bytes   => 256,
      Maximum_String_Bytes => 4_096,
      Maximum_Value_Bytes  => 32_768);

   protected type Cancellation_Barrier is
      procedure Note_Cancellation;
      procedure Note_Source_Ready;
      entry Wait_For_Cancellation;
      function Cancellation_Was_Requested return Boolean;
      function Source_Ready_Count return Natural;
   private
      Reached             : Boolean := False;
      Source_Ready_Drives : Natural := 0;
   end Cancellation_Barrier;

   protected body Cancellation_Barrier is
      procedure Note_Cancellation is
      begin
         Reached := True;
      end Note_Cancellation;

      procedure Note_Source_Ready is
      begin
         Source_Ready_Drives := Source_Ready_Drives + 1;
      end Note_Source_Ready;

      entry Wait_For_Cancellation when Reached is
      begin
         null;
      end Wait_For_Cancellation;

      function Cancellation_Was_Requested return Boolean is
      begin
         return Reached;
      end Cancellation_Was_Requested;

      function Source_Ready_Count return Natural is
      begin
         return Source_Ready_Drives;
      end Source_Ready_Count;
   end Cancellation_Barrier;

   type Immediate_Operation
     (Owner : not null access Operations.Completion_Set'Class)
   is new Operations.Operation (Owner) with null record;

   overriding
   procedure Drive
     (Item : in out Immediate_Operation; Event : Operations.Driver_Event);

   overriding
   procedure Request_Cancellation (Item : in out Immediate_Operation);

   type Delayed_Operation
     (Owner   : not null access Operations.Completion_Set'Class;
      Barrier : not null access Cancellation_Barrier)
   is new Operations.Operation (Owner) with null record;

   overriding
   procedure Drive
     (Item : in out Delayed_Operation; Event : Operations.Driver_Event);

   overriding
   procedure Request_Cancellation (Item : in out Delayed_Operation);

   procedure Drive
     (Item : in out Immediate_Operation; Event : Operations.Driver_Event)
   is
      pragma Unreferenced (Event);
   begin
      Drivers.Complete (Item, Operations.Succeeded);
   end Drive;

   procedure Request_Cancellation (Item : in out Immediate_Operation) is
   begin
      Drivers.Complete (Item, Operations.Cancelled);
   exception
      when others =>
         null;
   end Request_Cancellation;

   procedure Drive
     (Item : in out Delayed_Operation; Event : Operations.Driver_Event) is
   begin
      if Event = Operations.Source_Ready then
         Item.Barrier.Note_Source_Ready;
         Drivers.Complete (Item, Operations.Cancelled);
      else
         Drivers.Complete (Item, Operations.Failed);
      end if;
   end Drive;

   procedure Request_Cancellation (Item : in out Delayed_Operation) is
   begin
      Item.Barrier.Note_Cancellation;
   exception
      when others =>
         null;
   end Request_Cancellation;

   function Start_Immediate
     (Set : not null access Operations.Completion_Set'Class)
      return Immediate_Operation is
   begin
      return Result : Immediate_Operation (Set) do
         Drivers.Start (Result);
         Drive (Result, Operations.Start_Operation);
      end return;
   end Start_Immediate;

   function Start_Delayed
     (Set        : not null access Operations.Completion_Set'Class;
      Barrier    : not null access Cancellation_Barrier;
      Descriptor : Flyology.IO.Descriptor) return Delayed_Operation is
   begin
      return Result : Delayed_Operation (Set, Barrier) do
         Drivers.Start (Result);
         Drivers.Arm_Readiness (Result, Descriptor, For_Write => False);
      end return;
   end Start_Delayed;

   type Finalize_Observation is record
      Returned               : Boolean;
      Cancellation_Requested : Boolean;
      Target_Driven          : Boolean;
      Other_Preserved        : Boolean;
      Other_Replayable       : Boolean;
   end record;

   function Failure_Detail
     (Actual : Finalize_Observation) return Unbounded_String
   is
      Result : Unbounded_String :=
        To_Unbounded_String ("failed observations:");

      procedure Note (Name : String) is
      begin
         Append (Result, " " & Name);
      end Note;
   begin
      if not Actual.Returned then
         Note ("Returned");
      end if;
      if not Actual.Cancellation_Requested then
         Note ("Cancellation_Requested");
      end if;
      if not Actual.Target_Driven then
         Note ("Target_Driven");
      end if;
      if not Actual.Other_Preserved then
         Note ("Other_Preserved");
      end if;
      if not Actual.Other_Replayable then
         Note ("Other_Replayable");
      end if;
      return Result;
   end Failure_Detail;

   function Execute_Finalize return Finalize_Observation is
      Returned               : Boolean := False
      with Atomic;
      Cancellation_Requested : Boolean := False
      with Atomic;
      Target_Driven          : Boolean := False
      with Atomic;
      Other_Preserved        : Boolean := False
      with Atomic;
      Other_Replayable       : Boolean := False
      with Atomic;
   begin
      declare
         task Worker is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Worker;

         task body Worker is
            Left, Right : aliased Sockets.Socket_Type;
            Barrier     : aliased Cancellation_Barrier;
         begin
            Sockets.Create_Socket_Pair (Left, Right);
            declare
               task Signaler;

               task body Signaler is
                  Byte : constant Ada.Streams.Stream_Element_Array := [1 => 1];
                  Last : Ada.Streams.Stream_Element_Offset;
               begin
                  Barrier.Wait_For_Cancellation;
                  Sockets.Send_Socket (Right, Byte, Last);
                  if Last /= Byte'Last then
                     raise Program_Error with "completion signal was short";
                  end if;
               end Signaler;

               Set   : aliased Operations.Completion_Set (2);
               Other : Immediate_Operation := Start_Immediate (Set'Access);
            begin
               declare
                  Target : Delayed_Operation :=
                    Start_Delayed
                      (Set'Access,
                       Barrier'Access,
                       Sockets.Native_Descriptor (Left));
                  pragma Unreferenced (Target);
               begin
                  null;
               end;

               Returned := True;
               Cancellation_Requested := Barrier.Cancellation_Was_Requested;
               Target_Driven := Barrier.Source_Ready_Count = 1;

               declare
                  Batch : Operations.Completion_Batch (Set.Capacity);
               begin
                  Other_Preserved :=
                    Operations.Pending_Count (Set) = 0
                    and then Operations.Terminal_Count (Set) = 1;
                  Operations.Wait_Some (Set, Batch);
                  Other_Replayable :=
                    Other_Preserved
                    and then Batch.Count = 1
                    and then Natural (Batch.Ids (1)) = Operations.Id (Other);
               end;
               Operations.Consume (Other);
            end;
            Sockets.Close_Socket (Left);
            Sockets.Close_Socket (Right);
         exception
            when others =>
               Other_Replayable := False;
         end Worker;
      begin
         null;
      end;
      return
        (Returned               => Returned,
         Cancellation_Requested => Cancellation_Requested,
         Target_Driven          => Target_Driven,
         Other_Preserved        => Other_Preserved,
         Other_Replayable       => Other_Replayable);
   end Execute_Finalize;

   type Finalize_Adapter is new Model.Adapter with null record;

   overriding
   procedure Reset
     (Self     : in out Finalize_Adapter;
      Observed : out Model.State_Type;
      Status   : out Flyology_TLA.Replay.Adapter_Outcome);

   overriding
   procedure Apply
     (Self         : in out Finalize_Adapter;
      Index        : Positive;
      Action       : String;
      Role         : String;
      Input        : Model.Input_Type;
      Model_Source : String;
      Observed     : out Model.Outcome_Type;
      State        : out Model.State_Type;
      Status       : out Flyology_TLA.Replay.Adapter_Outcome);

   procedure Reset
     (Self     : in out Finalize_Adapter;
      Observed : out Model.State_Type;
      Status   : out Flyology_TLA.Replay.Adapter_Outcome)
   is
      pragma Unreferenced (Self);
   begin
      Observed :=
        (Target_State           => Model.State_Target_State_Pending,
         Target_Reported        => False,
         Other_State            => Model.State_Other_State_Terminal,
         Other_Reported         => False,
         Saved_Other_Reported   => False,
         Cancellation_Requested => False,
         Phase                  => Model.State_Phase_Ready,
         Last_Action            => Model.State_Last_Action_Init);
      Status := (Succeeded => True, Detail => Null_Unbounded_String);
   end Reset;

   procedure Apply
     (Self         : in out Finalize_Adapter;
      Index        : Positive;
      Action       : String;
      Role         : String;
      Input        : Model.Input_Type;
      Model_Source : String;
      Observed     : out Model.Outcome_Type;
      State        : out Model.State_Type;
      Status       : out Flyology_TLA.Replay.Adapter_Outcome)
   is
      pragma Unreferenced (Index, Input);
      Actual   : Finalize_Observation;
      Complete : Boolean;
   begin
      if Action /= "CompletionSetFinalize!Finalize"
        or else Role /= "finalize"
        or else Model_Source /= "CompletionSetFinalize!Finalize"
      then
         Observed := (Returned => False, Other_Replayable => False);
         Reset (Self, State, Status);
         Status :=
           (Succeeded => False,
            Detail    =>
              To_Unbounded_String ("unsupported modeled action or input"));
         return;
      end if;

      Actual := Execute_Finalize;
      Complete :=
        Actual.Returned
        and then Actual.Cancellation_Requested
        and then Actual.Target_Driven
        and then Actual.Other_Preserved
        and then Actual.Other_Replayable;
      Observed :=
        (Returned         => Actual.Returned,
         Other_Replayable => Actual.Other_Replayable);
      State :=
        (Target_State           =>
           (if Actual.Target_Driven
            then Model.State_Target_State_Idle
            else Model.State_Target_State_Pending),
         Target_Reported        => False,
         Other_State            =>
           (if Actual.Other_Preserved
            then Model.State_Other_State_Terminal
            else Model.State_Other_State_Idle),
         Other_Reported         => not Actual.Other_Replayable,
         Saved_Other_Reported   => False,
         Cancellation_Requested => Actual.Cancellation_Requested,
         Phase                  =>
           (if Complete
            then Model.State_Phase_Done
            else Model.State_Phase_Drain),
         Last_Action            =>
           (if Complete
            then Model.State_Last_Action_Finalize
            else Model.State_Last_Action_Begin_Finalize));
      Status :=
        (Succeeded => Complete,
         Detail    =>
           (if Complete
            then Null_Unbounded_String
            else Failure_Detail (Actual)));
   end Apply;

begin
   declare
      Config : Flyology_TLA.Command_Line.Configuration :=
        Flyology_TLA.Command_Line.Parse (Limits);
   begin
      if Flyology_TLA.Command_Line.Help_Requested (Config) then
         Flyology_TLA.Command_Line.Put_Help;
         return;
      end if;

      declare
         Trace   : constant Flyology_TLA.Traces.Trace :=
           Flyology_TLA.Command_Line.Load (Config);
         Adapter : Finalize_Adapter;
         Result  : Flyology_TLA.Replay.Replay_Result;
      begin
         Model.Run
           (Adapter, Trace, Flyology_TLA.Command_Line.Limits (Config), Result);
         Flyology_TLA.Command_Line.Report (Config, Result);
         Flyology_TLA.Command_Line.Set_Exit_Status (Result);
      end;
   end;
exception
   when Error : Flyology_TLA.Command_Line.Usage_Error =>
      Flyology_TLA.Command_Line.Fail
        (Ada.Exceptions.Exception_Message (Error), Show_Help => True);
   when Error : Flyology_TLA.Traces.Trace_Error =>
      Flyology_TLA.Command_Line.Fail
        ("cannot load trace: " & Ada.Exceptions.Exception_Message (Error));
end Operations_Finalize_Conformance;
