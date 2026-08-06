with Ada.Streams;

package body TLS_ALPN_Test_Provider is
   package TLS renames Flyology.IO.TLS;
   package ALPN renames Flyology.IO.TLS.ALPN;

   type Test_Session is new TLS.Session and ALPN.Session with record
      Selection        : Selection_Kind := No_Selection;
      Handshake_Status : TLS.Step_Status := TLS.Complete;
   end record;

   overriding function Handshake_Step
     (Item : in out Test_Session) return TLS.Step_Status;
   overriding function Receive_Step
     (Item : in out Test_Session;
      Data : out Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return TLS.Step_Status;
   overriding function Send_Step
     (Item : in out Test_Session;
      Data : Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return TLS.Step_Status;
   overriding function Shutdown_Step
     (Item : in out Test_Session) return TLS.Step_Status;
   overriding function Error_Message (Item : Test_Session) return String;
   overriding function Selected_Protocol (Item : Test_Session) return String;

   protected Observations is
      procedure Reset;
      procedure Set_Offer (Value : Offer_Kind);
      procedure Saw_Handshake;
      function Offer return Offer_Kind;
      entry Wait_Handshake;
   private
      Value          : Offer_Kind := No_Offer;
      Handshake_Seen : Boolean := False;
   end Observations;

   protected body Observations is
      procedure Reset is
      begin
         Value := No_Offer;
         Handshake_Seen := False;
      end Reset;

      procedure Set_Offer (Value : Offer_Kind) is
      begin
         Observations.Value := Value;
      end Set_Offer;

      procedure Saw_Handshake is
      begin
         Handshake_Seen := True;
      end Saw_Handshake;

      function Offer return Offer_Kind is (Value);

      entry Wait_Handshake when Handshake_Seen is
      begin
         null;
      end Wait_Handshake;
   end Observations;

   function Classify (Protocols : ALPN.Protocol_List) return Offer_Kind is
   begin
      if ALPN.Count (Protocols) = 0 then
         return No_Offer;
      elsif ALPN.Count (Protocols) = 1
        and then ALPN.Identifier (Protocols, 1) = "h2"
      then
         return H2_Only;
      elsif ALPN.Count (Protocols) = 2
        and then ALPN.Identifier (Protocols, 1) = "h2"
        and then ALPN.Identifier (Protocols, 2) = "http/1.1"
      then
         return H2_Then_HTTP_1_1;
      else
         return Other_Offer;
      end if;
   end Classify;

   function New_Session (Item : Provider) return TLS.Session_Access is
   begin
      return new Test_Session'
        (TLS.Session with
         Selection        => Item.Selection,
         Handshake_Status => Item.Handshake_Status);
   end New_Session;

   procedure Set_Selection
     (Item : in out Provider; Selection : Selection_Kind) is
   begin
      Item.Selection := Selection;
   end Set_Selection;

   procedure Set_Handshake_Status
     (Item : in out Provider; Status : TLS.Step_Status) is
   begin
      Item.Handshake_Status := Status;
   end Set_Handshake_Status;

   procedure Reset_Observations is
   begin
      Observations.Reset;
   end Reset_Observations;

   function Last_Offer return Offer_Kind is (Observations.Offer);

   procedure Wait_For_Handshake is
   begin
      Observations.Wait_Handshake;
   end Wait_For_Handshake;

   overriding function Name (Item : Provider) return String is
      pragma Unreferenced (Item);
   begin
      return "test-alpn-provider";
   end Name;

   overriding function Is_Available (Item : Provider) return Boolean is
      pragma Unreferenced (Item);
   begin
      return True;
   end Is_Available;

   overriding function Retain
     (Item : in out Provider) return TLS.Provider_Access is
   begin
      return new Provider'(Item);
   end Retain;

   overriding function Create_Session
     (Item        : in out Provider;
      FD          : Flyology.IO.Descriptor;
      Side        : TLS.Role;
      Server_Name : String) return TLS.Session_Access
   is
      pragma Unreferenced (FD, Side, Server_Name);
   begin
      Observations.Set_Offer (No_Offer);
      return New_Session (Item);
   end Create_Session;

   overriding function Create_Session
     (Item        : in out Provider;
      FD          : Flyology.IO.Descriptor;
      Side        : TLS.Role;
      Server_Name : String;
      Protocols   : ALPN.Protocol_List) return TLS.Session_Access
   is
      pragma Unreferenced (FD, Side, Server_Name);
   begin
      Observations.Set_Offer (Classify (Protocols));
      return New_Session (Item);
   end Create_Session;

   overriding function Handshake_Step
     (Item : in out Test_Session) return TLS.Step_Status is
   begin
      Observations.Saw_Handshake;
      return Item.Handshake_Status;
   end Handshake_Step;

   overriding function Receive_Step
     (Item : in out Test_Session;
      Data : out Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return TLS.Step_Status
   is
      pragma Unreferenced (Item, Data, Last);
   begin
      return TLS.Peer_Closed;
   end Receive_Step;

   overriding function Send_Step
     (Item : in out Test_Session;
      Data : Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return TLS.Step_Status
   is
      pragma Unreferenced (Item);
   begin
      if Data'Length = 0 then
         return TLS.Complete;
      end if;
      Last := Data'Last;
      return TLS.Complete;
   end Send_Step;

   overriding function Shutdown_Step
     (Item : in out Test_Session) return TLS.Step_Status
   is
      pragma Unreferenced (Item);
   begin
      return TLS.Complete;
   end Shutdown_Step;

   overriding function Error_Message (Item : Test_Session) return String is
      pragma Unreferenced (Item);
   begin
      return "test ALPN provider failure";
   end Error_Message;

   overriding function Selected_Protocol (Item : Test_Session) return String is
   begin
      case Item.Selection is
         when No_Selection    => return "";
         when Select_H2       => return "h2";
         when Select_HTTP_1_1 => return "http/1.1";
      end case;
   end Selected_Protocol;

end TLS_ALPN_Test_Provider;
