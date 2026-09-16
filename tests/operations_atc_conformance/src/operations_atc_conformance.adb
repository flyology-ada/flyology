with Ada.Command_Line;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology.Operations.ATC_Testing;
with Flyology_TLA.Replay;
with Flyology_TLA.Traces;

procedure Operations_ATC_Conformance is
   package Testing renames Flyology.Operations.ATC_Testing;
   package Replay renames Flyology_TLA.Replay;
   package Traces renames Flyology_TLA.Traces;
   use Ada.Strings.Unbounded;
   use type Replay.Verdict;

   Limits : constant Traces.Load_Limits :=
     (Maximum_File_Bytes   => 1_000_000,
      Maximum_Steps        => 16,
      Maximum_JSON_Depth   => 32,
      Maximum_Object_Names => 512,
      Maximum_Name_Bytes   => 4_096,
      Maximum_String_Bytes => 4_096,
      Maximum_Value_Bytes  => 32_768);

   function Boolean_JSON (Value : Boolean) return String
   is (if Value then "true" else "false");

   function Number_JSON (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Label (Index : Natural) return String is
   begin
      case Index is
         when 0      =>
            return "Init";

         when 1      =>
            return "ATCDrive";

         when 2      =>
            return "ATCProtectedReturn";

         when 3      =>
            return "ATCDriverReturn";

         when 4      =>
            return "ATCStableDeliver";

         when 5      =>
            return "ATCUse";

         when 6      =>
            return "ATCCancel";

         when others =>
            raise Program_Error with "invalid ATC replay step";
      end case;
   end Label;

   function Stage (Index : Natural) return String is
   begin
      case Index is
         when 0      =>
            return "Idle";

         when 1      =>
            return "Driving";

         when 2      =>
            return "Requested";

         when 3      =>
            return "Returned";

         when 4      =>
            return "Delivered";

         when 5      =>
            return "Used";

         when 6      =>
            return "Cancelled";

         when others =>
            raise Program_Error with "invalid ATC replay step";
      end case;
   end Stage;

   function Source (Value : Testing.Observed_Source) return String is
   begin
      case Value is
         when Testing.Immediate  =>
            return "Immediate";

         when Testing.Dependency =>
            return "Dependency";

         when Testing.None       =>
            return "None";
      end case;
   end Source;

   function Child_State (Value : Testing.Observed_Child_State) return String is
   begin
      case Value is
         when Testing.Vacant   =>
            return "Vacant";

         when Testing.Pending  =>
            return "Pending";

         when Testing.Terminal =>
            return "Terminal";
      end case;
   end Child_State;

   function Outcome (Value : Testing.Observed_Outcome) return String is
   begin
      case Value is
         when Testing.No_Outcome        =>
            return "None";

         when Testing.Success           =>
            return "Succeeded";

         when Testing.Cancelled_Outcome =>
            return "Cancelled";

         when Testing.Failed_Outcome    =>
            return "Failed";
      end case;
   end Outcome;

   function State_JSON
     (Item : Testing.Observation; Index : Natural) return String is
   begin
      if not Item.Reached then
         raise Program_Error
           with "ATC owner boundary was not observed:" & Natural'Image (Index);
      end if;
      return
        "{""stage"":"""
        & Stage (Index)
        & ""","
        & """depth"":"
        & Number_JSON (Item.Depth)
        & ","
        & """stabilizing"":"
        & Boolean_JSON (Item.Stabilizing)
        & ","
        & """dirty"":"
        & (if Item.Dirty then "1" else "0")
        & ","
        & """source"":"""
        & Source (Item.Source)
        & ""","
        & """deadline"":"
        & Boolean_JSON (Item.Deadline)
        & ","
        & """child"":"
        & Boolean_JSON (Item.Child)
        & ","
        & """childState"":"""
        & Child_State (Item.Child_State)
        & ""","
        & """childDeadline"":"
        & Boolean_JSON (Item.Child_Deadline)
        & ","
        & """root"":"""
        & (if Item.Root_Terminal then "Terminal" else "Pending")
        & ""","
        & """gate"":"""
        & (if Item.Gate_Terminal then "Terminal" else "Pending")
        & ""","
        & """rootOutcome"":"""
        & Outcome (Item.Root_Outcome)
        & ""","
        & """gateOutcome"":"""
        & Outcome (Item.Gate_Outcome)
        & ""","
        & """deferral"":"
        & Number_JSON (Item.Deferral)
        & ","
        & """requested"":"
        & Boolean_JSON (Item.Request_Pending)
        & ","
        & """delivered"":"
        & Boolean_JSON (Item.Delivered)
        & ","
        & """waitFailed"":"
        & Boolean_JSON (Item.Wait_Failed)
        & ","
        & """action"":"""
        & Label (Index)
        & """}";
   end State_JSON;

   function Outcome_JSON (Item : Testing.Observation) return String
   is ("{""delivered"":"
       & Boolean_JSON (Item.Delivered)
       & ",""waitFailed"":"
       & Boolean_JSON (Item.Wait_Failed)
       & "}");

   type ATC_Adapter is new Replay.Adapter with record
      Scenario : Unbounded_String;
      Observed : Testing.Observation_Array;
   end record;

   overriding
   procedure Reset
     (Self                : in out ATC_Adapter;
      Observed_State_JSON : out Unbounded_String;
      Outcome             : out Replay.Adapter_Outcome);

   overriding
   procedure Apply
     (Self                  : in out ATC_Adapter;
      Command               : Replay.Replay_Command;
      Observed_Outcome_JSON : out Unbounded_String;
      Observed_State_JSON   : out Unbounded_String;
      Outcome               : out Replay.Adapter_Outcome);

   procedure Reset
     (Self                : in out ATC_Adapter;
      Observed_State_JSON : out Unbounded_String;
      Outcome             : out Replay.Adapter_Outcome) is
   begin
      --  One owner task records each real boundary as it executes. Replay
      --  compares those immutable observations in the same action order.
      Testing.Run_Replay
        ((if To_String (Self.Scenario) = "stabilizer"
          then "stabilize"
          else To_String (Self.Scenario)),
         Self.Observed);
      Observed_State_JSON :=
        To_Unbounded_String (State_JSON (Self.Observed (0), 0));
      Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
   end Reset;

   procedure Apply
     (Self                  : in out ATC_Adapter;
      Command               : Replay.Replay_Command;
      Observed_Outcome_JSON : out Unbounded_String;
      Observed_State_JSON   : out Unbounded_String;
      Outcome               : out Replay.Adapter_Outcome)
   is
      Index : constant Positive := Command.Index;
   begin
      if Index > Self.Observed'Last
        or else To_String (Command.Action)
                /= "CompletionSetFinalize!" & Label (Index)
        or else To_String (Command.Role) /= "owner"
        or else To_String (Command.Input_JSON)
                /= "{""event"":""" & Label (Index) & """}"
      then
         Outcome :=
           (Succeeded => False,
            Detail    =>
              To_Unbounded_String ("unexpected ATC replay command"));
         return;
      end if;
      Observed_Outcome_JSON :=
        To_Unbounded_String (Outcome_JSON (Self.Observed (Index)));
      Observed_State_JSON :=
        To_Unbounded_String (State_JSON (Self.Observed (Index), Index));
      Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
   end Apply;

begin
   if Ada.Command_Line.Argument_Count /= 2 then
      raise Program_Error
        with "usage: operations_atc_conformance SCENARIO TRACE";
   end if;
   declare
      Adapter : ATC_Adapter :=
        (Replay.Adapter
         with
           Scenario => To_Unbounded_String (Ada.Command_Line.Argument (1)),
           Observed => <>);
      Trace   : constant Traces.Trace :=
        Traces.Load (Ada.Command_Line.Argument (2), Limits);
      Result  : Replay.Replay_Result;
   begin
      Replay.Run (Adapter, Trace, Limits, Result);
      if Result.Status /= Replay.Conformant then
         raise Program_Error
           with
             "ATC replay diverged at step"
             & Result.Failure_Step'Image
             & ": "
             & To_String (Result.Detail);
      end if;
      Ada.Text_IO.Put_Line
        ("ATC replay "
         & Ada.Command_Line.Argument (1)
         & " matched"
         & Result.Compared_Steps'Image
         & " owner transitions");
   end;
end Operations_ATC_Conformance;
