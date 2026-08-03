with Ada.Streams;

package body TLS_Test_Provider is
   package TLS renames Flyology.IO.TLS;
   use Ada.Streams;

   type Test_Session is new TLS.Session with record
      Fail_Finalize : Boolean := False;
      Block_Handshake : Boolean := False;
      Behavior      : Receive_Behavior := Return_Data;
      Send_Mode     : Send_Behavior := Return_Progress;
      Peer_Close    : Peer_Close_Point := No_Peer_Close;
      Handshakes    : Natural := 0;
      Receives      : Natural := 0;
      Sends         : Natural := 0;
      Shutdowns     : Natural := 0;
   end record;

   overriding function Handshake_Step
     (Item : in out Test_Session) return TLS.Step_Status;
   overriding function Receive_Step
     (Item : in out Test_Session;
      Data : out Stream_Element_Array;
      Last : in out Stream_Element_Offset) return TLS.Step_Status;
   overriding function Send_Step
     (Item : in out Test_Session;
      Data : Stream_Element_Array;
      Last : in out Stream_Element_Offset) return TLS.Step_Status;
   overriding function Shutdown_Step
     (Item : in out Test_Session) return TLS.Step_Status;
   overriding function Error_Message (Item : Test_Session) return String;
   overriding procedure Finalize (Item : in out Test_Session);

   protected Telemetry is
      procedure Reset;
      procedure Saw_Want;
      procedure Saw_Partial;
      procedure Read (Wants : out Natural; Partials : out Natural);
   private
      Wants    : Natural := 0;
      Partials : Natural := 0;
   end Telemetry;

   protected Handshake_Block is
      procedure Reset;
      procedure Enter;
      entry Wait_Entered;
      entry Wait_Release;
      procedure Release;
   private
      Has_Entered  : Boolean := False;
      Is_Released  : Boolean := False;
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
   end Telemetry;

   procedure Set_Finalize_Failure (Item : in out Provider) is
   begin
      Item.Fail_Finalize := True;
   end Set_Finalize_Failure;

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

   procedure Set_Receive_Behavior
     (Item     : in out Provider;
      Behavior : Receive_Behavior)
   is
   begin
      Item.Behavior := Behavior;
   end Set_Receive_Behavior;

   procedure Set_Send_Behavior
     (Item : in out Provider; Behavior : Send_Behavior) is
   begin
      Item.Send_Mode := Behavior;
   end Set_Send_Behavior;

   procedure Set_Peer_Close
     (Item : in out Provider; Point : Peer_Close_Point) is
   begin
      Item.Peer_Close := Point;
   end Set_Peer_Close;

   procedure Reset_Telemetry is
   begin
      Telemetry.Reset;
   end Reset_Telemetry;

   procedure Get_Telemetry
     (Want_Results     : out Natural;
      Partial_Progress : out Natural)
   is
   begin
      Telemetry.Read (Want_Results, Partial_Progress);
   end Get_Telemetry;

   overriding function Name (Item : Provider) return String is
      pragma Unreferenced (Item);
   begin
      return "test-provider";
   end Name;

   overriding function Is_Available (Item : Provider) return Boolean is
      pragma Unreferenced (Item);
   begin
      return True;
   end Is_Available;

   overriding function Create_Session
     (Item        : in out Provider;
      FD          : Flyology.IO.Descriptor;
      Side        : TLS.Role;
      Server_Name : String) return TLS.Session_Access
   is
      pragma Unreferenced (FD, Side, Server_Name);
   begin
      return new Test_Session'
        (TLS.Session with
         Fail_Finalize => Item.Fail_Finalize,
         Block_Handshake => Item.Block_Handshake,
         Behavior      => Item.Behavior,
         Send_Mode     => Item.Send_Mode,
         Peer_Close    => Item.Peer_Close,
         Handshakes    => 0,
         Receives      => 0,
         Sends         => 0,
         Shutdowns     => 0);
   end Create_Session;

   overriding function Handshake_Step
     (Item : in out Test_Session) return TLS.Step_Status
   is
   begin
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

   overriding function Receive_Step
     (Item : in out Test_Session;
      Data : out Stream_Element_Array;
      Last : in out Stream_Element_Offset) return TLS.Step_Status
   is
   begin
      Item.Receives := Item.Receives + 1;
      if Item.Receives = 1 then
         Telemetry.Saw_Want;
         return TLS.Want_Read;
      end if;
      case Item.Behavior is
         when Return_Data =>
            Data (Data'First) := 42;
            Last := Data'First;
            if Data'Length > 1 then
               Telemetry.Saw_Partial;
            end if;
            return TLS.Complete;
         when Orderly_EOF =>
            return TLS.Peer_Closed;
         when Invalid_Lower =>
            Last := Data'First - 1;
            return TLS.Complete;
         when Invalid_Upper =>
            Last := Data'Last + 1;
            return TLS.Complete;
         when Complete_Without_Receive_Progress =>
            return TLS.Complete;
      end case;
   end Receive_Step;

   overriding function Send_Step
     (Item : in out Test_Session;
      Data : Stream_Element_Array;
      Last : in out Stream_Element_Offset) return TLS.Step_Status
   is
   begin
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

   overriding function Shutdown_Step
     (Item : in out Test_Session) return TLS.Step_Status
   is
   begin
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

   overriding function Error_Message (Item : Test_Session) return String is
      pragma Unreferenced (Item);
   begin
      return "test provider failure";
   end Error_Message;

   overriding procedure Finalize (Item : in out Test_Session) is
   begin
      if Item.Fail_Finalize then
         raise Program_Error with "injected provider finalization failure";
      end if;
   end Finalize;
end TLS_Test_Provider;
