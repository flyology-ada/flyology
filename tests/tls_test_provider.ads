with Flyology.IO.TLS;

--  Test-only non-cryptographic implementation of the public TLS provider SPI.
package TLS_Test_Provider is
   type Receive_Behavior is
     (Return_Data, Orderly_EOF, Invalid_Lower, Invalid_Upper,
      Complete_Without_Receive_Progress);
   type Send_Behavior is (Return_Progress, Complete_Without_Send_Progress);
   type Peer_Close_Point is
     (No_Peer_Close, Handshake_Peer_Close, Send_Peer_Close,
      Shutdown_Peer_Close);

   type Provider is new Flyology.IO.TLS.Provider with private;

   procedure Set_Finalize_Failure (Item : in out Provider);
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
   procedure Reset_Telemetry;
   procedure Get_Telemetry
     (Want_Results     : out Natural;
      Partial_Progress : out Natural);

   overriding function Name (Item : Provider) return String;
   overriding function Is_Available (Item : Provider) return Boolean;
   overriding function Create_Session
     (Item        : in out Provider;
      FD          : Flyology.IO.Descriptor;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String) return Flyology.IO.TLS.Session_Access;

private
   type Provider is new Flyology.IO.TLS.Provider with record
      Fail_Finalize : Boolean := False;
      Block_Handshake : Boolean := False;
      Behavior      : Receive_Behavior := Return_Data;
      Send_Mode     : Send_Behavior := Return_Progress;
      Peer_Close    : Peer_Close_Point := No_Peer_Close;
   end record;
end TLS_Test_Provider;
