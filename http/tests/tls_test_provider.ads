with Flyology.IO.TLS;

--  Test-only non-cryptographic implementation of the public TLS provider SPI.
package TLS_Test_Provider is
   type Operation_Kind is
     (Handshake_Operation,
      Receive_Operation,
      Send_Operation,
      Shutdown_Operation);

   type Output_Effect is
     (Preserve_Output,
      Advance_Output,
      Before_First,
      After_Last);

   type Script_Step is record
      Status : Flyology.IO.TLS.Step_Status := Flyology.IO.TLS.Complete;
      Effect : Output_Effect := Preserve_Output;
      Count  : Natural := 0;
   end record;

   type Step_Script is array (Positive range <>) of Script_Step;

   type Operation_Counts is array (Operation_Kind) of Natural;

   type State_Telemetry is record
      Calls                    : Operation_Counts := [others => 0];
      Sessions_Created         : Natural := 0;
      Sessions_Finalized       : Natural := 0;
      Sessions_Live            : Natural := 0;
      Finalized_While_FD_Open  : Natural := 0;
   end record;

   type Receive_Behavior is
     (Return_Data, Orderly_EOF, Invalid_Lower, Invalid_Upper,
      Complete_Without_Receive_Progress);
   type Send_Behavior is (Return_Progress, Complete_Without_Send_Progress);
   type Create_Behavior is (Create_Normally, Raise_On_Create, Return_Null);
   type Peer_Close_Point is
     (No_Peer_Close, Handshake_Peer_Close, Send_Peer_Close,
      Shutdown_Peer_Close);

   type Provider is new Flyology.IO.TLS.Provider with private;

   procedure Set_Finalize_Failure (Item : in out Provider);
   procedure Set_Available (Item : in out Provider; Value : Boolean);
   procedure Set_Create_Behavior
     (Item : in out Provider; Behavior : Create_Behavior);
   procedure Set_Create_Delay
     (Item : in out Provider; Delay_For : Duration)
   with Pre => Delay_For >= 0.0;
   procedure Set_Block_Handshake (Item : in out Provider);
   procedure Wait_Handshake_Blocked;
   procedure Release_Handshake;
   procedure Set_Receive_Behavior
     (Item     : in out Provider;
      Behavior : Receive_Behavior);
   procedure Set_Send_Behavior
     (Item : in out Provider; Behavior : Send_Behavior);
   procedure Set_Peer_Close
     (Item : in out Provider; Point : Peer_Close_Point);
   procedure Set_Script
     (Item      : in out Provider;
      Operation : Operation_Kind;
      Steps     : Step_Script);
   procedure Reset_Telemetry;
   procedure Get_Telemetry
     (Want_Results     : out Natural;
      Partial_Progress : out Natural);
   procedure Reset_State_Telemetry;
   procedure Get_State_Telemetry (State : out State_Telemetry);
   procedure Wait_For_First_Call (Operation : Operation_Kind);

   overriding function Name (Item : Provider) return String;
   overriding function Is_Available (Item : Provider) return Boolean;
   overriding function Retain
     (Item : in out Provider) return Flyology.IO.TLS.Provider_Access;
   overriding function Create_Session
     (Item        : in out Provider;
      FD          : Flyology.IO.Descriptor;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String) return Flyology.IO.TLS.Session_Access;

private
   Maximum_Script_Length : constant := 16;
   type Stored_Steps is
     array (Positive range 1 .. Maximum_Script_Length) of Script_Step;
   type Stored_Script is record
      Length : Natural range 0 .. Maximum_Script_Length := 0;
      Steps  : Stored_Steps;
   end record;
   type Stored_Scripts is array (Operation_Kind) of Stored_Script;

   type Provider is new Flyology.IO.TLS.Provider with record
      Fail_Finalize : Boolean := False;
      Available     : Boolean := True;
      Create_Mode   : Create_Behavior := Create_Normally;
      Create_Delay  : Duration := 0.0;
      Block_Handshake : Boolean := False;
      Behavior      : Receive_Behavior := Return_Data;
      Send_Mode     : Send_Behavior := Return_Progress;
      Peer_Close    : Peer_Close_Point := No_Peer_Close;
      Scripts       : Stored_Scripts;
   end record;
end TLS_Test_Provider;
