with Flyology.IO.TLS;

--  Test-only non-cryptographic implementation of the public TLS provider SPI.
package TLS_Test_Provider is
   type Receive_Behavior is
     (Return_Data, Orderly_EOF, Invalid_Lower, Invalid_Upper);

   type Provider is new Flyology.IO.TLS.Provider with private;

   procedure Set_Finalize_Failure (Item : in out Provider);
   procedure Set_Receive_Behavior
     (Item     : in out Provider;
      Behavior : Receive_Behavior);
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
      Behavior      : Receive_Behavior := Return_Data;
   end record;
end TLS_Test_Provider;
