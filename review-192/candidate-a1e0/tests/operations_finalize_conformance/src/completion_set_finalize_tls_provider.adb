with Ada.Streams;

package body Completion_Set_Finalize_TLS_Provider is
   package TLS renames Flyology.IO.TLS;

   type Session is new TLS.Session with record
      Handshake_Calls : Natural := 0;
   end record;

   overriding
   function Handshake_Step (Item : in out Session) return TLS.Step_Status;

   overriding
   function Receive_Step
     (Item : in out Session;
      Data : out Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return TLS.Step_Status;

   overriding
   function Send_Step
     (Item : in out Session;
      Data : Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return TLS.Step_Status;

   overriding
   function Shutdown_Step (Item : in out Session) return TLS.Step_Status;

   overriding
   function Error_Message (Item : Session) return String;

   function Handshake_Step (Item : in out Session) return TLS.Step_Status is
   begin
      Item.Handshake_Calls := Item.Handshake_Calls + 1;
      return (if Item.Handshake_Calls = 1 then TLS.Want_Read else TLS.Failed);
   end Handshake_Step;

   function Receive_Step
     (Item : in out Session;
      Data : out Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return TLS.Step_Status
   is
      pragma Unreferenced (Item, Data, Last);
   begin
      return TLS.Failed;
   end Receive_Step;

   function Send_Step
     (Item : in out Session;
      Data : Ada.Streams.Stream_Element_Array;
      Last : in out Ada.Streams.Stream_Element_Offset) return TLS.Step_Status
   is
      pragma Unreferenced (Item, Data, Last);
   begin
      return TLS.Failed;
   end Send_Step;

   function Shutdown_Step (Item : in out Session) return TLS.Step_Status is
      pragma Unreferenced (Item);
   begin
      return TLS.Complete;
   end Shutdown_Step;

   function Error_Message (Item : Session) return String is
      pragma Unreferenced (Item);
   begin
      return "modeled handshake failure";
   end Error_Message;

   function Retain (Item : in out Provider) return TLS.Provider_Access is
      pragma Unreferenced (Item);
   begin
      return new Provider;
   end Retain;

   function Name (Item : Provider) return String is
      pragma Unreferenced (Item);
   begin
      return "completion-set-finalize";
   end Name;

   function Is_Available (Item : Provider) return Boolean is
      pragma Unreferenced (Item);
   begin
      return True;
   end Is_Available;

   function Create_Session
     (Item        : in out Provider;
      FD          : Flyology.IO.Descriptor;
      Side        : TLS.Role;
      Server_Name : String) return TLS.Session_Access
   is
      pragma Unreferenced (Item, FD, Side, Server_Name);
   begin
      return new Session;
   end Create_Session;
end Completion_Set_Finalize_TLS_Provider;
