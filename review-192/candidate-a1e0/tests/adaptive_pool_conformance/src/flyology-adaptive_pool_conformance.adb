with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Flyology.Adaptive_Pool_Test_Hooks;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Allocation_Algorithms.Buddy;
with Flyology.Data_Structures.Allocation_Pools.Adaptive;
with Flyology.Data_Structures.Arenas;
with Flyology.Data_Structures.Handles;
with Flyology.Data_Structures.Regions;
with Flyology.Data_Structures.Storage_Types.Unsigned_64s;
with Adaptive_Pool_Model;
with Flyology_TLA.Command_Line;
with Flyology_TLA.Replay;
with Flyology_TLA.Traces;
with Interfaces;
with System.Storage_Elements;

procedure Flyology.Adaptive_Pool_Conformance is

   package DS renames Flyology.Data_Structures;
   package Regions renames DS.Regions;
   package Arenas is new
     DS.Arenas (Algorithm => DS.Allocation_Algorithms.Buddy);
   package U64_Elements renames DS.Storage_Types.Unsigned_64s;
   package Pools is new
     DS.Allocation_Pools.Adaptive
       (Arena_Provider  => Arenas,
        Element         => U64_Elements.Element,
        Slots_Per_Chunk => 2,
        Maximum_Chunks  => 2);

   package SSE renames System.Storage_Elements;
   --  Qualification geometry is the minimized issue-161/#162 witness: two
   --  two-slot chunks inside one caller-owned region, not a production limit.
   type Fixture_Storage is new SSE.Storage_Array (1 .. 262_144)
   with Alignment => 64;

   use Ada.Strings.Unbounded;
   use type Adaptive_Pool_Model.Input_Value_Type;
   use type DS.Handles.Slot_Index;
   use type Interfaces.Unsigned_32;
   use type Pools.Allocation_Result;
   use type Pools.Handle;

   --  These fail-closed test limits exceed the canonical six-step witness
   --  while remaining local to this conformance executable.
   Limits : constant Flyology_TLA.Traces.Load_Limits :=
     (Maximum_File_Bytes   => 1_000_000,
      Maximum_Steps        => 10,
      Maximum_JSON_Depth   => 20,
      Maximum_Object_Names => 1_000,
      Maximum_Name_Bytes   => 4_096,
      Maximum_String_Bytes => 100_000,
      Maximum_Value_Bytes  => 500_000);

   type Adaptive_Adapter is new Adaptive_Pool_Model.Adapter with record
      Storage     : aliased Fixture_Storage := [others => 0];
      Region      : Regions.View;
      Arena       : Arenas.View;
      Pool        : Pools.View;
      Stale       : Pools.Handle := Pools.Null_Handle;
      Later       : Pools.Handle := Pools.Null_Handle;
      First       : Pools.Handle := Pools.Null_Handle;
      Second      : Pools.Handle := Pools.Null_Handle;
      Later_Live  : Boolean := False;
      First_Live  : Boolean := False;
      Second_Live : Boolean := False;
      Ready       : Boolean := False;
      Current     : Adaptive_Pool_Model.State_Type :=
        (Phase         => Adaptive_Pool_Model.State_Phase_Ready,
         Entry1        => Adaptive_Pool_Model.State_Entry1_Live,
         Entry2        => Adaptive_Pool_Model.State_Entry2_Live,
         Owner11       => Adaptive_Pool_Model.State_Owner11_None,
         Pool_Epoch    => 1,
         Result_Status => Adaptive_Pool_Model.State_Result_Status_None,
         Result_Chunk  => 0,
         Result_Slot   => 0,
         Result_Stamp  => 0,
         Result_Epoch  => 0,
         Pool_State    => Adaptive_Pool_Model.State_Pool_State_Ready,
         Arena_Block1  => Adaptive_Pool_Model.State_Arena_Block1_Allocated,
         Arena_Block2  => Adaptive_Pool_Model.State_Arena_Block2_Allocated,
         Last_Action   => Adaptive_Pool_Model.State_Last_Action_Init);
   end record;

   overriding
   procedure Reset
     (Self     : in out Adaptive_Adapter;
      Observed : out Adaptive_Pool_Model.State_Type;
      Status   : out Flyology_TLA.Replay.Adapter_Outcome);

   overriding
   procedure Apply
     (Self         : in out Adaptive_Adapter;
      Index        : Positive;
      Action       : String;
      Role         : String;
      Input        : Adaptive_Pool_Model.Input_Type;
      Model_Source : String;
      Observed     : out Adaptive_Pool_Model.Outcome_Type;
      State        : out Adaptive_Pool_Model.State_Type;
      Status       : out Flyology_TLA.Replay.Adapter_Outcome);

   function Entry_1_State return Adaptive_Pool_Model.State_Entry1_Type
   is (if Flyology.Adaptive_Pool_Test_Hooks.Chunk_Is_Live (1)
       then Adaptive_Pool_Model.State_Entry1_Live
       else Adaptive_Pool_Model.State_Entry1_Empty);

   function Entry_2_State return Adaptive_Pool_Model.State_Entry2_Type
   is (if Flyology.Adaptive_Pool_Test_Hooks.Chunk_Is_Live (2)
       then Adaptive_Pool_Model.State_Entry2_Live
       else Adaptive_Pool_Model.State_Entry2_Empty);

   procedure Fail
     (Status : out Flyology_TLA.Replay.Adapter_Outcome; Detail : String) is
   begin
      Status := (Succeeded => False, Detail => To_Unbounded_String (Detail));
   end Fail;

   procedure Allocate
     (Self  : in out Adaptive_Adapter;
      Data  : Interfaces.Unsigned_64;
      Value : out Pools.Handle)
   is
      Result : Pools.Allocation_Result;
   begin
      Pools.Try_Allocate (Self.Pool, Self.Arena, Data, Value, Result);
      if Result /= Pools.Allocated then
         raise Program_Error with "adaptive-pool allocation did not succeed";
      end if;
   end Allocate;

   procedure Reset
     (Self     : in out Adaptive_Adapter;
      Observed : out Adaptive_Pool_Model.State_Type;
      Status   : out Flyology_TLA.Replay.Adapter_Outcome)
   is
      Ignored  : Interfaces.Unsigned_64;
      Rejected : Boolean := False;
   begin
      Observed := Self.Current;
      if not Flyology.Adaptive_Pool_Test_Hooks.Enabled then
         Fail (Status, "adaptive-pool conformance hooks are disabled");
         return;
      end if;

      Flyology.Adaptive_Pool_Test_Hooks.Reset;
      --  The arena and pool locations and identity establish only the
      --  isolated issue-161 fixture; no value is stored as library policy.
      Regions.Attach
        (Self.Region,
         Self.Storage'Address,
         DS.Byte_Count (Self.Storage'Length));
      Arenas.Initialize
        (Self.Arena,
         Self.Region,
         64,
         (Usable_Capacity => 32_768, Minimum_Block_Size => 64),
         16#A161_A161_A161_A161#);
      Pools.Initialize (Self.Pool, Self.Region, 196_608, Self.Arena);

      Allocate (Self, 11, Self.Stale);
      declare
         Released : constant Pools.Handle := Self.Stale;
      begin
         Allocate (Self, 12, Self.First);
         Allocate (Self, 21, Self.Later);
         Pools.Release (Self.Pool, Self.Arena, Released);
         Pools.Release (Self.Pool, Self.Arena, Self.First);
         Self.First := Pools.Null_Handle;
      end;
      Self.Later_Live := True;

      if Self.Stale /= (Chunk => 1, Slot => 1, Stamp => 1, Epoch => 1)
        or else Self.Later.Chunk /= 2
      then
         Fail
           (Status,
            "implementation did not establish the modeled initial fixture");
         return;
      end if;

      begin
         Pools.Read (Self.Pool, Self.Arena, Self.Stale, Ignored);
      exception
         when DS.Handle_Error =>
            Rejected := True;
      end;
      if not Rejected then
         Fail (Status, "released fixture handle was not stale at reset");
         return;
      end if;

      Self.Current :=
        (Phase         => Adaptive_Pool_Model.State_Phase_Ready,
         Entry1        => Entry_1_State,
         Entry2        => Entry_2_State,
         Owner11       => Adaptive_Pool_Model.State_Owner11_None,
         Pool_Epoch    =>
           Adaptive_Pool_Model.State_Pool_Epoch_Type (Self.Stale.Epoch),
         Result_Status => Adaptive_Pool_Model.State_Result_Status_None,
         Result_Chunk  => 0,
         Result_Slot   => 0,
         Result_Stamp  => 0,
         Result_Epoch  => 0,
         Pool_State    => Adaptive_Pool_Model.State_Pool_State_Ready,
         Arena_Block1  => Adaptive_Pool_Model.State_Arena_Block1_Allocated,
         Arena_Block2  => Adaptive_Pool_Model.State_Arena_Block2_Allocated,
         Last_Action   => Adaptive_Pool_Model.State_Last_Action_Init);
      Self.Ready := True;
      Observed := Self.Current;
      Status := (Succeeded => True, Detail => Null_Unbounded_String);
   exception
      when Error : others =>
         Observed := Self.Current;
         Fail
           (Status,
            "fixture reset failed: "
            & Ada.Exceptions.Exception_Message (Error));
   end Reset;

   procedure Set_Allocation_Observation
     (Self        : in out Adaptive_Adapter;
      Value       : Pools.Handle;
      Owner       : Adaptive_Pool_Model.State_Owner11_Type;
      Phase       : Adaptive_Pool_Model.State_Phase_Type;
      Last_Action : Adaptive_Pool_Model.State_Last_Action_Type;
      Observed    : out Adaptive_Pool_Model.Outcome_Type;
      State       : out Adaptive_Pool_Model.State_Type) is
   begin
      if Value.Chunk = 1 and then Value.Slot = 1 then
         Self.Current.Owner11 := Owner;
      end if;
      Observed :=
        (Status => Adaptive_Pool_Model.Outcome_Status_Allocated,
         Chunk  => Adaptive_Pool_Model.Outcome_Chunk_Type (Value.Chunk),
         Slot   => Adaptive_Pool_Model.Outcome_Slot_Type (Value.Slot),
         Stamp  => Adaptive_Pool_Model.Outcome_Stamp_Type (Value.Stamp),
         Epoch  => Adaptive_Pool_Model.Outcome_Epoch_Type (Value.Epoch));
      Self.Current.Phase := Phase;
      Self.Current.Entry1 := Entry_1_State;
      Self.Current.Entry2 := Entry_2_State;
      Self.Current.Result_Status :=
        Adaptive_Pool_Model.State_Result_Status_Allocated;
      Self.Current.Result_Chunk :=
        Adaptive_Pool_Model.State_Result_Chunk_Type (Value.Chunk);
      Self.Current.Result_Slot :=
        Adaptive_Pool_Model.State_Result_Slot_Type (Value.Slot);
      Self.Current.Result_Stamp :=
        Adaptive_Pool_Model.State_Result_Stamp_Type (Value.Stamp);
      Self.Current.Result_Epoch :=
        Adaptive_Pool_Model.State_Result_Epoch_Type (Value.Epoch);
      Self.Current.Last_Action := Last_Action;
      State := Self.Current;
   end Set_Allocation_Observation;

   procedure Prepare_Contention_Fixture (Self : in out Adaptive_Adapter) is
      Empty  : array (1 .. 3) of Pools.Handle;
      Result : Pools.Allocation_Result;
   begin
      if Self.Later_Live then
         Pools.Release (Self.Pool, Self.Arena, Self.Later);
         Self.Later_Live := False;
      end if;
      if Self.First_Live then
         Pools.Release (Self.Pool, Self.Arena, Self.First);
         Self.First_Live := False;
      end if;
      if Self.Second_Live then
         Pools.Release (Self.Pool, Self.Arena, Self.Second);
         Self.Second_Live := False;
      end if;
      Pools.Destroy (Self.Pool, Self.Arena);
      Arenas.Destroy (Self.Arena);
      Regions.Detach (Self.Region);

      Flyology.Adaptive_Pool_Test_Hooks.Reset;
      Regions.Attach
        (Self.Region,
         Self.Storage'Address,
         DS.Byte_Count (Self.Storage'Length));
      Arenas.Initialize
        (Self.Arena,
         Self.Region,
         64,
         (Usable_Capacity => 32_768, Minimum_Block_Size => 64),
         16#A162_A162_A162_A162#);
      Pools.Initialize (Self.Pool, Self.Region, 196_608, Self.Arena);
      for Index in Empty'Range loop
         Pools.Try_Allocate
           (Self.Pool,
            Self.Arena,
            Interfaces.Unsigned_64 (161 + Index),
            Empty (Index),
            Result);
         if Result /= Pools.Allocated then
            raise Program_Error
              with "adaptive contention fixture allocation failed";
         end if;
      end loop;
      for Handle of Empty loop
         Pools.Release (Self.Pool, Self.Arena, Handle);
      end loop;
      Self.Stale := Pools.Null_Handle;
      Self.Later := Pools.Null_Handle;
      Self.First := Pools.Null_Handle;
      Self.Second := Pools.Null_Handle;
   end Prepare_Contention_Fixture;

   procedure Apply
     (Self         : in out Adaptive_Adapter;
      Index        : Positive;
      Action       : String;
      Role         : String;
      Input        : Adaptive_Pool_Model.Input_Type;
      Model_Source : String;
      Observed     : out Adaptive_Pool_Model.Outcome_Type;
      State        : out Adaptive_Pool_Model.State_Type;
      Status       : out Flyology_TLA.Replay.Adapter_Outcome)
   is
      pragma Unreferenced (Index);
      Read_Value     : Interfaces.Unsigned_64;
      Destroy_Failed : Boolean := False;
      Contended      : Boolean := False;
      Rejected       : Boolean := False;
      Probe          : Pools.View;
   begin
      Observed :=
        (Status => Adaptive_Pool_Model.Outcome_Status_None,
         Chunk  => 0,
         Slot   => 0,
         Stamp  => 0,
         Epoch  => 0);
      State := Self.Current;
      if not Self.Ready then
         Fail (Status, "adaptive-pool fixture is not ready");
         return;
      elsif Action /= Model_Source then
         Fail (Status, "modeled action and source differ");
         return;
      end if;

      if Action = "AdaptivePoolLifecycle!Destroy"
        and then Role = "destroy"
        and then Input.Value = 0
      then
         begin
            Pools.Destroy (Self.Pool, Self.Arena);
         exception
            when Program_Error =>
               Destroy_Failed := True;
         end;
         if not Destroy_Failed then
            Fail (Status, "destroy did not reject the live later chunk");
            return;
         end if;
         Observed :=
           (Status => Adaptive_Pool_Model.Outcome_Status_Destroy_Failed,
            Chunk  => 0,
            Slot   => 0,
            Stamp  => 0,
            Epoch  => 0);
         Self.Current.Phase := Adaptive_Pool_Model.State_Phase_Destroy_Failed;
         Self.Current.Entry1 := Entry_1_State;
         Self.Current.Entry2 := Entry_2_State;
         Self.Current.Result_Status :=
           Adaptive_Pool_Model.State_Result_Status_Destroy_Failed;
         Self.Current.Result_Chunk := 0;
         Self.Current.Result_Slot := 0;
         Self.Current.Result_Stamp := 0;
         Self.Current.Result_Epoch := 0;
         Self.Current.Last_Action :=
           Adaptive_Pool_Model.State_Last_Action_Destroy;
         State := Self.Current;

      elsif Action = "AdaptivePoolLifecycle!AllocateOne"
        and then Role = "allocate"
        and then Input.Value = 1
      then
         Allocate (Self, Interfaces.Unsigned_64 (Input.Value), Self.First);
         Self.First_Live := True;
         Set_Allocation_Observation
           (Self,
            Self.First,
            Adaptive_Pool_Model.State_Owner11_First,
            Adaptive_Pool_Model.State_Phase_Allocated_One,
            Adaptive_Pool_Model.State_Last_Action_Allocate_One,
            Observed,
            State);

      elsif Action = "AdaptivePoolLifecycle!AllocateTwo"
        and then Role = "allocate"
        and then Input.Value = 2
      then
         Allocate (Self, Interfaces.Unsigned_64 (Input.Value), Self.Second);
         Self.Second_Live := True;
         Set_Allocation_Observation
           (Self,
            Self.Second,
            Adaptive_Pool_Model.State_Owner11_Second,
            Adaptive_Pool_Model.State_Phase_Allocated_Two,
            Adaptive_Pool_Model.State_Last_Action_Allocate_Two,
            Observed,
            State);

      elsif Action = "AdaptivePoolLifecycle!ValidateOldHandle"
        and then Role = "validate"
        and then Input.Value = 0
      then
         begin
            Pools.Read (Self.Pool, Self.Arena, Self.Stale, Read_Value);
         exception
            when DS.Handle_Error =>
               Rejected := True;
         end;
         Observed :=
           (Status =>
              (if Rejected
               then Adaptive_Pool_Model.Outcome_Status_Rejected
               else Adaptive_Pool_Model.Outcome_Status_Accepted),
            Chunk  =>
              Adaptive_Pool_Model.Outcome_Chunk_Type (Self.Stale.Chunk),
            Slot   => Adaptive_Pool_Model.Outcome_Slot_Type (Self.Stale.Slot),
            Stamp  =>
              Adaptive_Pool_Model.Outcome_Stamp_Type (Self.Stale.Stamp),
            Epoch  =>
              Adaptive_Pool_Model.Outcome_Epoch_Type (Self.Stale.Epoch));
         Self.Current.Phase := Adaptive_Pool_Model.State_Phase_Done;
         Self.Current.Entry1 := Entry_1_State;
         Self.Current.Entry2 := Entry_2_State;
         Self.Current.Result_Status :=
           (if Rejected
            then Adaptive_Pool_Model.State_Result_Status_Rejected
            else Adaptive_Pool_Model.State_Result_Status_Accepted);
         Self.Current.Result_Chunk :=
           Adaptive_Pool_Model.State_Result_Chunk_Type (Self.Stale.Chunk);
         Self.Current.Result_Slot :=
           Adaptive_Pool_Model.State_Result_Slot_Type (Self.Stale.Slot);
         Self.Current.Result_Stamp :=
           Adaptive_Pool_Model.State_Result_Stamp_Type (Self.Stale.Stamp);
         Self.Current.Result_Epoch :=
           Adaptive_Pool_Model.State_Result_Epoch_Type (Self.Stale.Epoch);
         Self.Current.Last_Action :=
           Adaptive_Pool_Model.State_Last_Action_Validate_Old_Handle;
         State := Self.Current;

      elsif Action = "AdaptivePoolLifecycle!PrepareContention"
        and then Role = "prepare-contention"
        and then Input.Value = 0
      then
         Prepare_Contention_Fixture (Self);
         Observed :=
           (Status => Adaptive_Pool_Model.Outcome_Status_None,
            Chunk  => 0,
            Slot   => 0,
            Stamp  => 0,
            Epoch  => 0);
         Self.Current :=
           (Phase         => Adaptive_Pool_Model.State_Phase_Contention_Ready,
            Entry1        => Entry_1_State,
            Entry2        => Entry_2_State,
            Owner11       => Adaptive_Pool_Model.State_Owner11_None,
            Pool_Epoch    => 1,
            Result_Status => Adaptive_Pool_Model.State_Result_Status_None,
            Result_Chunk  => 0,
            Result_Slot   => 0,
            Result_Stamp  => 0,
            Result_Epoch  => 0,
            Pool_State    => Adaptive_Pool_Model.State_Pool_State_Ready,
            Arena_Block1  => Adaptive_Pool_Model.State_Arena_Block1_Allocated,
            Arena_Block2  => Adaptive_Pool_Model.State_Arena_Block2_Allocated,
            Last_Action   =>
              Adaptive_Pool_Model.State_Last_Action_Prepare_Contention);
         State := Self.Current;

      elsif Action = "AdaptivePoolLifecycle!DestroyContended"
        and then Role = "destroy-contended"
        and then Input.Value = 0
      then
         Flyology.Adaptive_Pool_Test_Hooks.Arm_Release_Contention
           (After_Releases => 1);
         begin
            Pools.Destroy (Self.Pool, Self.Arena);
         exception
            when DS.Busy_Error =>
               Contended := True;
         end;
         if not Contended then
            Fail (Status, "destroy did not report injected arena contention");
            return;
         end if;
         Pools.Attach (Probe, Self.Region, 196_608, Self.Arena);
         Pools.Detach (Probe);
         Observed :=
           (Status => Adaptive_Pool_Model.Outcome_Status_Destroy_Contended,
            Chunk  => 0,
            Slot   => 0,
            Stamp  => 0,
            Epoch  => 0);
         Self.Current.Phase := Adaptive_Pool_Model.State_Phase_Contention_Done;
         Self.Current.Entry1 := Entry_1_State;
         Self.Current.Entry2 := Entry_2_State;
         Self.Current.Result_Status :=
           Adaptive_Pool_Model.State_Result_Status_Destroy_Contended;
         Self.Current.Result_Chunk := 0;
         Self.Current.Result_Slot := 0;
         Self.Current.Result_Stamp := 0;
         Self.Current.Result_Epoch := 0;
         Self.Current.Pool_State := Adaptive_Pool_Model.State_Pool_State_Ready;
         Self.Current.Arena_Block1 :=
           Adaptive_Pool_Model.State_Arena_Block1_Free;
         Self.Current.Arena_Block2 :=
           Adaptive_Pool_Model.State_Arena_Block2_Allocated;
         Self.Current.Last_Action :=
           Adaptive_Pool_Model.State_Last_Action_Destroy_Contended;
         State := Self.Current;

      else
         Fail (Status, "unsupported modeled action or input");
         return;
      end if;
      Status := (Succeeded => True, Detail => Null_Unbounded_String);
   exception
      when Error : others =>
         Observed :=
           (Status => Adaptive_Pool_Model.Outcome_Status_None,
            Chunk  => 0,
            Slot   => 0,
            Stamp  => 0,
            Epoch  => 0);
         State := Self.Current;
         Fail
           (Status,
            "implementation action failed: "
            & Ada.Exceptions.Exception_Message (Error));
   end Apply;

   procedure Cleanup (Self : in out Adaptive_Adapter) is
   begin
      if Self.Later_Live then
         Pools.Release (Self.Pool, Self.Arena, Self.Later);
         Self.Later_Live := False;
      end if;
      if Self.First_Live then
         Pools.Release (Self.Pool, Self.Arena, Self.First);
         Self.First_Live := False;
      end if;
      if Self.Second_Live then
         Pools.Release (Self.Pool, Self.Arena, Self.Second);
         Self.Second_Live := False;
      end if;
      if Pools.Is_Attached (Self.Pool) then
         Pools.Destroy (Self.Pool, Self.Arena);
      end if;
      if Arenas.Is_Attached (Self.Arena) then
         Arenas.Destroy (Self.Arena);
      end if;
      if Regions.Is_Attached (Self.Region) then
         Regions.Detach (Self.Region);
      end if;
      Self.Ready := False;
   end Cleanup;

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
         Adapter : Adaptive_Adapter;
         Result  : Flyology_TLA.Replay.Replay_Result;
      begin
         Adaptive_Pool_Model.Run
           (Adapter, Trace, Flyology_TLA.Command_Line.Limits (Config), Result);
         Cleanup (Adapter);
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
end Flyology.Adaptive_Pool_Conformance;
