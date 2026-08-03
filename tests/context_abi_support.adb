with Ada.Streams;
with Flyology.Execution_Groups;
with Flyology.IO.Sockets;
with Flyology.IO.Timers;

package body Context_ABI_Support is
   package Groups renames Flyology.Execution_Groups;
   package Sockets renames Flyology.IO.Sockets;

   use type Ada.Streams.Stream_Element;

   function Machine_Probe
     (Action : Action_Code) return Interfaces.C.unsigned;
   pragma Import
     (C, Machine_Probe, "flyology_test_context_probe");

   Reader_Socket : GNAT.Sockets.Socket_Type := GNAT.Sockets.No_Socket;
   protected Descriptor_Gate is
      procedure Configure (Reader : GNAT.Sockets.Socket_Type);
      procedure Request;
      entry Wait_For_Request;
      function Reader return GNAT.Sockets.Socket_Type;
   private
      Requested : Boolean := False;
   end Descriptor_Gate;

   protected body Descriptor_Gate is
      procedure Configure (Reader : GNAT.Sockets.Socket_Type) is
      begin
         Reader_Socket := Reader;
      end Configure;

      procedure Request is
      begin
         Requested := True;
      end Request;

      entry Wait_For_Request when Requested is
      begin
         Requested := False;
      end Wait_For_Request;

      function Reader return GNAT.Sockets.Socket_Type is (Reader_Socket);
   end Descriptor_Gate;

   procedure Configure (Reader : GNAT.Sockets.Socket_Type) is
   begin
      Descriptor_Gate.Configure (Reader);
   end Configure;

   procedure Wait_For_Descriptor_Request is
   begin
      Descriptor_Gate.Wait_For_Request;
   end Wait_For_Descriptor_Request;

   function Probe (Action : Action_Code) return Interfaces.C.unsigned is
     (Machine_Probe (Action));

   function Callback (Action : Action_Code) return Interfaces.C.unsigned is
      Item : Ada.Streams.Stream_Element_Array (1 .. 1);
   begin
      case Action is
         when No_Switch =>
            null;
         when Cooperative_Yield =>
            delay 0.0;
         when Timer_Suspension =>
            Flyology.IO.Timers.Sleep_For (0.005);
         when Descriptor_Readiness =>
            Descriptor_Gate.Request;
            Sockets.Receive_Exactly
              (Descriptor_Gate.Reader, Item, Timeout => 1.0);
            if Item (1) /= 16#5A# then
               return 1;
            end if;
         when Cross_Group_Move =>
            Groups.Migrate (1);
            delay 0.0;
            Groups.Migrate (Groups.Default_Group);
      end case;
      return 0;
   exception
      when others =>
         return 1;
   end Callback;

end Context_ABI_Support;
