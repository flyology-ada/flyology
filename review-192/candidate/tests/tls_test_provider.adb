with Ada.Streams;
with Interfaces.C;

package body TLS_Test_Provider is
   package TLS renames Flyology.IO.TLS;
   use Ada.Streams;
   use type Interfaces.C.int;
   use type TLS.Step_Status;

   type Test_Session is new TLS.Session with record
      FD              : Flyology.IO.Descriptor := Flyology.IO.Invalid_Descriptor;
      Fail_Finalize   : Boolean := False;
      Block_Handshake : Boolean := False;
      Behavior        : Receive_Behavior := Return_Data;
      Send_Mode       : Send_Behavior := Return_Progress;
      Peer_Close      : Peer_Close_Point := No_Peer_Close;
      Scripts         : Stored_Scripts;
      Positions       : Operation_Counts := [others => 0];
      Handshakes      : Natural := 0;
      Receives        : Natural := 0;
      Sends           : Natural := 0;
      Shutdowns       : Natural := 0;
   end record;

   overriding
   function Handshake_Step (Item : in out Test_Session) return TLS.Step_Status;
   overriding
   function Receive_Step
     (Item : in out Test_Session; Data : out Stream_Element_Array; Last : in out Stream_Element_Offset)
      return TLS.Step_Status;
   overriding
   function Send_Step
     (Item : in out Test_Session; Data : Stream_Element_Array; Last : in out Stream_Element_Offset)
      return TLS.Step_Status;
   overriding
   function Shutdown_Step (Item : in out Test_Session) return TLS.Step_Status;
   overriding
   function Error_Message (Item : Test_Session) return String;
   overriding
   procedure Finalize (Item : in out Test_Session);

   function Next_Step
     (Scripts     : Stored_Scripts;
      Positions   : in out Operation_Counts;
      Operation   : Operation_Kind;
      Is_Scripted : out Boolean) return Script_Step;

   procedure Apply_Output
     (Step       : Script_Step;
      Data_First : Stream_Element_Offset;
      Data_Last  : Stream_Element_Offset;
      Last       : in out Stream_Element_Offset);

   function FD_Is_Open (FD : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_fd_is_open";

   protected Telemetry is
      procedure Reset;
      procedure Reset_State;
      procedure Saw_Want;
      procedure Saw_Partial;
      procedure Read (Wants : out Natural; Partials : out Natural);
      procedure Session_Created;
      procedure Session_Finalized (FD_Was_Open : Boolean);
      procedure Saw_Call (Operation : Operation_Kind);
      procedure Read_State (State : out State_Telemetry);
      entry Wait_Handshake;
      entry Wait_Receive;
      entry Wait_Send;
      entry Wait_Shutdown;
   private
      Wants    : Natural := 0;
      Partials : Natural := 0;
      State    : State_Telemetry;
   end Telemetry;

   protected Handshake_Block is
      procedure Reset;
      procedure Enter;
      entry Wait_Entered;
      entry Wait_Release;
      procedure Release;
   private
      Has_Entered : Boolean := False;
      Is_Released : Boolean := False;
   end Handshake_Block;

   protected body Handshake_Block is
      procedure Reset is
      begin
         Has_Entered := False;
         Is_Released := False;
      end Reset;
      procedure Enter is
      begin
         Has_Entered := True;
      end Enter;
      entry Wait_Entered when Has_Entered is
      begin
         null;
      end Wait_Entered;
      entry Wait_Release when Is_Released is
      begin
         null;
      end Wait_Release;
      procedure Release is
      begin
         Is_Released := True;
      end Release;
   end Handshake_Block;

   protected body Telemetry is
      procedure Reset is
      begin
         Wants := 0;
         Partials := 0;
      end Reset;
      procedure Saw_Want is
      begin
         Wants := Wants + 1;
      end Saw_Want;
      procedure Saw_Partial is
      begin
         Partials := Partials + 1;
      end Saw_Partial;
      procedure Read (Wants : out Natural; Partials : out Natural) is
      begin
         Wants := Telemetry.Wants;
         Partials := Telemetry.Partials;
      end Read;
      procedure Reset_State is
      begin
         if State.Sessions_Live /= 0 then
            raise Program_Error with "cannot reset TLS telemetry while sessions are live";
         end if;
         State := (others => <>);
      end Reset_State;
      procedure Session_Created is
      begin
         State.Sessions_Created := State.Sessions_Created + 1;
         State.Sessions_Live := State.Sessions_Live + 1;
      end Session_Created;
      procedure Session_Finalized (FD_Was_Open : Boolean) is
      begin
         State.Sessions_Finalized := State.Sessions_Finalized + 1;
         if State.Sessions_Live = 0 then
            raise Program_Error with "TLS session telemetry underflow";
         end if;
         State.Sessions_Live := State.Sessions_Live - 1;
         if FD_Was_Open then
            State.Finalized_While_FD_Open := State.Finalized_While_FD_Open + 1;
         end if;
      end Session_Finalized;
      procedure Saw_Call (Operation : Operation_Kind) is
      begin
         State.Calls (Operation) := State.Calls (Operation) + 1;
      end Saw_Call;
      procedure Read_State (State : out State_Telemetry) is
      begin
         State := Telemetry.State;
      end Read_State;
      entry Wait_Handshake when State.Calls (Handshake_Operation) >= 1 is
      begin
         null;
      end Wait_Handshake;
      entry Wait_Receive when State.Calls (Receive_Operation) >= 1 is
      begin
         null;
      end Wait_Receive;
      entry Wait_Send when State.Calls (Send_Operation) >= 1 is
      begin
         null;
      end Wait_Send;
      entry Wait_Shutdown when State.Calls (Shutdown_Operation) >= 1 is
      begin
         null;
      end Wait_Shutdown;
   end Telemetry;

   procedure Set_Finalize_Failure (Item : in out Provider) is
   begin
      Item.Fail_Finalize := True;
   end Set_Finalize_Failure;

   procedure Set_Available (Item : in out Provider; Value : Boolean) is
   begin
      Item.Available := Value;
   end Set_Available;

   procedure Set_Create_Behavior (Item : in out Provider; Behavior : Create_Behavior) is
   begin
      Item.Create_Mode := Behavior;
   end Set_Create_Behavior;

   procedure Set_Create_Delay (Item : in out Provider; Delay_For : Duration) is
   begin
      Item.Create_Delay := Delay_For;
   end Set_Create_Delay;

   procedure Set_Block_Handshake (Item : in out Provider) is
   begin
      Item.Block_Handshake := True;
      Handshake_Block.Reset;
   end Set_Block_Handshake;

   procedure Wait_Handshake_Blocked is
   begin
      Handshake_Block.Wait_Entered;
   end Wait_Handshake_Blocked;

   procedure Release_Handshake is
   begin
      Handshake_Block.Release;
   end Release_Handshake;

   procedure Set_Receive_Behavior (Item : in out Provider; Behavior : Receive_Behavior) is
   begin
      Item.Behavior := Behavior;
   end Set_Receive_Behavior;

   procedure Set_Send_Behavior (Item : in out Provider; Behavior : Send_Behavior) is
   begin
      Item.Send_Mode := Behavior;
   end Set_Send_Behavior;

   procedure Set_Peer_Close (Item : in out Provider; Point : Peer_Close_Point) is
   begin
      Item.Peer_Close := Point;
   end Set_Peer_Close;

   procedure Set_Script (Item : in out Provider; Operation : Operation_Kind; Steps : Step_Script) is
   begin
      if Steps'Length > Maximum_Script_Length then
         raise Constraint_Error with "TLS test script is too long";
      end if;
      Item.Scripts (Operation).Length := Steps'Length;
      if Steps'Length > 0 then
         for Offset in 0 .. Steps'Length - 1 loop
            Item.Scripts (Operation).Steps (Offset + 1) := Steps (Steps'First + Offset);
         end loop;
      end if;
   end Set_Script;

   procedure Reset_Telemetry is
   begin
      Telemetry.Reset;
   end Reset_Telemetry;

   procedure Get_Telemetry (Want_Results : out Natural; Partial_Progress : out Natural) is
   begin
      Telemetry.Read (Want_Results, Partial_Progress);
   end Get_Telemetry;

   procedure Reset_State_Telemetry is
   begin
      Telemetry.Reset_State;
   end Reset_State_Telemetry;

   procedure Get_State_Telemetry (State : out State_Telemetry) is
   begin
      Telemetry.Read_State (State);
   end Get_State_Telemetry;

   procedure Wait_For_First_Call (Operation : Operation_Kind) is
   begin
      case Operation is
         when Handshake_Operation =>
            Telemetry.Wait_Handshake;

         when Receive_Operation   =>
            Telemetry.Wait_Receive;

         when Send_Operation      =>
            Telemetry.Wait_Send;

         when Shutdown_Operation  =>
            Telemetry.Wait_Shutdown;
      end case;
   end Wait_For_First_Call;

   overriding
   function Name (Item : Provider) return String is
      pragma Unreferenced (Item);
   begin
      return "test-provider";
   end Name;

   overriding
   function Is_Available (Item : Provider) return Boolean is
   begin
      return Item.Available;
   end Is_Available;

   overriding
   function Retain (Item : in out Provider) return TLS.Provider_Access is
   begin
      if not Item.Available then
         raise TLS.TLS_Error with "test provider is unavailable";
      end if;
      return
        new Provider'
          (Fail_Finalize   => Item.Fail_Finalize,
           Available       => Item.Available,
           Create_Mode     => Item.Create_Mode,
           Create_Delay    => Item.Create_Delay,
           Block_Handshake => Item.Block_Handshake,
           Behavior        => Item.Behavior,
           Send_Mode       => Item.Send_Mode,
           Peer_Close      => Item.Peer_Close,
           Scripts         => Item.Scripts);
   end Retain;

   overriding
   function Create_Session
     (Item : in out Provider; FD : Flyology.IO.Descriptor; Side : TLS.Role; Server_Name : String)
      return TLS.Session_Access
   is
      pragma Unreferenced (Side, Server_Name);
      Result : TLS.Session_Access;
   begin
      if Item.Create_Delay > 0.0 then
         delay Item.Create_Delay;
      end if;
      case Item.Create_Mode is
         when Create_Normally =>
            null;

         when Raise_On_Create =>
            raise TLS.TLS_Error with "injected session creation failure";

         when Return_Null     =>
            return null;
      end case;
      Result :=
        new Test_Session'
          (TLS.Session
           with
             FD              => FD,
             Fail_Finalize   => Item.Fail_Finalize,
             Block_Handshake => Item.Block_Handshake,
             Behavior        => Item.Behavior,
             Send_Mode       => Item.Send_Mode,
             Peer_Close      => Item.Peer_Close,
             Scripts         => Item.Scripts,
             Positions       => [others => 0],
             Handshakes      => 0,
             Receives        => 0,
             Sends           => 0,
             Shutdowns       => 0);
      Telemetry.Session_Created;
      return Result;
   end Create_Session;

   function Next_Step
     (Scripts     : Stored_Scripts;
      Positions   : in out Operation_Counts;
      Operation   : Operation_Kind;
      Is_Scripted : out Boolean) return Script_Step
   is
      Script : Stored_Script renames Scripts (Operation);
   begin
      Telemetry.Saw_Call (Operation);
      Is_Scripted := Script.Length > 0;
      if not Is_Scripted then
         return (others => <>);
      end if;

      Positions (Operation) := Positions (Operation) + 1;
      if Positions (Operation) > Script.Length then
         raise Program_Error with "TLS test provider script exhausted";
      end if;
      return Script.Steps (Positions (Operation));
   end Next_Step;

   procedure Apply_Output
     (Step       : Script_Step;
      Data_First : Stream_Element_Offset;
      Data_Last  : Stream_Element_Offset;
      Last       : in out Stream_Element_Offset) is
   begin
      case Step.Effect is
         when Preserve_Output =>
            null;

         when Advance_Output  =>
            if Step.Count = 0 then
               null;
            else
               Last := Data_First + Stream_Element_Offset (Step.Count - 1);
            end if;

         when Before_First    =>
            Last := Data_First - 1;

         when After_Last      =>
            Last := Data_Last + 1;
      end case;
   end Apply_Output;

   overriding
   function Handshake_Step (Item : in out Test_Session) return TLS.Step_Status is
      Is_Scripted : Boolean;
      Step        : constant Script_Step :=
        Next_Step (Item.Scripts, Item.Positions, Handshake_Operation, Is_Scripted);
   begin
      if Is_Scripted then
         return Step.Status;
      end if;
      Item.Handshakes := Item.Handshakes + 1;
      if Item.Peer_Close = Handshake_Peer_Close then
         return TLS.Peer_Closed;
      end if;
      if Item.Block_Handshake and then Item.Handshakes = 1 then
         Handshake_Block.Enter;
         Handshake_Block.Wait_Release;
      end if;
      if Item.Handshakes = 1 then
         Telemetry.Saw_Want;
         return TLS.Want_Write;
      end if;
      return TLS.Complete;
   end Handshake_Step;

   overriding
   function Receive_Step
     (Item : in out Test_Session; Data : out Stream_Element_Array; Last : in out Stream_Element_Offset)
      return TLS.Step_Status
   is
      Is_Scripted : Boolean;
      Step        : constant Script_Step :=
        Next_Step (Item.Scripts, Item.Positions, Receive_Operation, Is_Scripted);
   begin
      if Is_Scripted then
         Apply_Output (Step, Data'First, Data'Last, Last);
         if Step.Status = TLS.Complete and then Last in Data'Range then
            Data (Data'First .. Last) := [others => 42];
         end if;
         return Step.Status;
      end if;
      Item.Receives := Item.Receives + 1;
      if Item.Receives = 1 then
         Telemetry.Saw_Want;
         return TLS.Want_Read;
      end if;
      case Item.Behavior is
         when Return_Data                       =>
            Data (Data'First) := 42;
            Last := Data'First;
            if Data'Length > 1 then
               Telemetry.Saw_Partial;
            end if;
            return TLS.Complete;

         when Orderly_EOF                       =>
            return TLS.Peer_Closed;

         when Invalid_Lower                     =>
            Last := Data'First - 1;
            return TLS.Complete;

         when Invalid_Upper                     =>
            Last := Data'Last + 1;
            return TLS.Complete;

         when Complete_Without_Receive_Progress =>
            return TLS.Complete;
      end case;
   end Receive_Step;

   overriding
   function Send_Step
     (Item : in out Test_Session; Data : Stream_Element_Array; Last : in out Stream_Element_Offset)
      return TLS.Step_Status
   is
      Is_Scripted : Boolean;
      Step        : constant Script_Step :=
        Next_Step (Item.Scripts, Item.Positions, Send_Operation, Is_Scripted);
   begin
      if Is_Scripted then
         Apply_Output (Step, Data'First, Data'Last, Last);
         return Step.Status;
      end if;
      Item.Sends := Item.Sends + 1;
      if Item.Peer_Close = Send_Peer_Close then
         return TLS.Peer_Closed;
      end if;
      if Item.Sends = 1 then
         Telemetry.Saw_Want;
         return TLS.Want_Write;
      end if;
      if Item.Send_Mode = Complete_Without_Send_Progress then
         return TLS.Complete;
      end if;
      Last := Data'First;
      if Data'Length > 1 then
         Telemetry.Saw_Partial;
      end if;
      return TLS.Complete;
   end Send_Step;

   overriding
   function Shutdown_Step (Item : in out Test_Session) return TLS.Step_Status is
      Is_Scripted : Boolean;
      Step        : constant Script_Step :=
        Next_Step (Item.Scripts, Item.Positions, Shutdown_Operation, Is_Scripted);
   begin
      if Is_Scripted then
         return Step.Status;
      end if;
      Item.Shutdowns := Item.Shutdowns + 1;
      if Item.Peer_Close = Shutdown_Peer_Close then
         return TLS.Peer_Closed;
      end if;
      if Item.Shutdowns = 1 then
         Telemetry.Saw_Want;
         return TLS.Want_Write;
      end if;
      return TLS.Complete;
   end Shutdown_Step;

   overriding
   function Error_Message (Item : Test_Session) return String is
      pragma Unreferenced (Item);
   begin
      return "test provider failure";
   end Error_Message;

   overriding
   procedure Finalize (Item : in out Test_Session) is
   begin
      Telemetry.Session_Finalized (FD_Is_Open (Interfaces.C.int (Item.FD)) /= 0);
      if Item.Fail_Finalize then
         raise Program_Error with "injected provider finalization failure";
      end if;
   end Finalize;
end TLS_Test_Provider;
