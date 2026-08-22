with Flyology.IO.TLS;
with Flyology.IO.TLS.ALPN;

--  Deterministic non-cryptographic implementation of the optional ALPN SPI.

package TLS_ALPN_Test_Provider is

   type Selection_Kind is (No_Selection, Select_H2, Select_HTTP_1_1);
   type Offer_Kind is (No_Offer, H2_Only, H2_Then_HTTP_1_1, Other_Offer);

   type Provider is new Flyology.IO.TLS.ALPN.Provider with private;

   procedure Set_Selection (Item : in out Provider; Selection : Selection_Kind);
   procedure Set_Handshake_Status (Item : in out Provider; Status : Flyology.IO.TLS.Step_Status);

   procedure Reset_Observations;
   function Last_Offer return Offer_Kind;
   procedure Wait_For_Handshake;

   overriding
   function Name (Item : Provider) return String;
   overriding
   function Is_Available (Item : Provider) return Boolean;
   overriding
   function Retain (Item : in out Provider) return Flyology.IO.TLS.Provider_Access;
   overriding
   function Create_Session
     (Item : in out Provider; FD : Flyology.IO.Descriptor; Side : Flyology.IO.TLS.Role; Server_Name : String)
      return Flyology.IO.TLS.Session_Access;
   overriding
   function Create_Session
     (Item        : in out Provider;
      FD          : Flyology.IO.Descriptor;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String;
      Protocols   : Flyology.IO.TLS.ALPN.Protocol_List) return Flyology.IO.TLS.Session_Access;

private
   type Provider is new Flyology.IO.TLS.ALPN.Provider with record
      Selection        : Selection_Kind := No_Selection;
      Handshake_Status : Flyology.IO.TLS.Step_Status := Flyology.IO.TLS.Complete;
   end record;

end TLS_ALPN_Test_Provider;
