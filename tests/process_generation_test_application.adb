with Flyology;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with Flyology.Process_Generations;
with Flyology.Process_Generations.Agents;
with Flyology.Process_Generations.Messages;
with Flyology.Process_Generations.Protocol;

package body Process_Generation_Test_Application is
   procedure Run (Version : Ada.Streams.Stream_Element) is
      package Connections renames Flyology.IO.Connections;
      package Generations renames Flyology.Process_Generations;
      package Messages renames Flyology.Process_Generations.Messages;
      package Protocol renames Flyology.Process_Generations.Protocol;
      package Sockets renames Flyology.IO.Sockets;

      use type Ada.Streams.Stream_Element;
      use type Generations.Upgrade_Handle;
      use type Messages.Nonzero_U64;
      use type Messages.Topology_Digest;
      use type Protocol.Octet;

      type Handler_Context is limited record
         Image_Version : Ada.Streams.Stream_Element;
      end record;

      procedure Handle
        (Context      : in out Handler_Context;
         Connection   : in out Connections.Connection;
         Peer         : Sockets.Endpoint;
         Cancellation : not null access Connections.Cancellation_Token)
      is
         Request : Ada.Streams.Stream_Element_Array (1 .. 1);
      begin
         Connection.Receive_Exactly
           (Request, Timeout => 30.0, Token => Cancellation);
         Connection.Send_All
           ([1 => Context.Image_Version], Timeout => 5.0,
            Token => Cancellation);
         if Request (1) = Character'Pos ('H') then
            Connection.Receive_Exactly
              (Request, Timeout => 30.0, Token => Cancellation);
            Connection.Send_All
              ([1 => Context.Image_Version], Timeout => 5.0,
               Token => Cancellation);
         end if;
         pragma Unreferenced (Peer);
      end Handle;

      package Structured is new Flyology.IO.Structured_Servers
        (Handler_Context => Handler_Context,
         Handle          => Handle,
         Handler_Model   => Flyology.Native_Task);

      protected type Compensation_State is
         procedure Apply
           (Authority : Generations.Upgrade_Handle;
            Desired   : Generations.Compensation_Result;
            Result    : out Generations.Compensation_Result);
      private
         Applied : Boolean := False;
         Last    : Generations.Upgrade_Handle :=
           (Coordinator => 1, Upgrade => 1, Candidate => 1);
         Value   : Generations.Compensation_Result :=
           Generations.Not_Required;
      end Compensation_State;

      protected body Compensation_State is
         procedure Apply
           (Authority : Generations.Upgrade_Handle;
            Desired   : Generations.Compensation_Result;
            Result    : out Generations.Compensation_Result) is
         begin
            if Applied and then Last = Authority then
               Result := Value;
            else
               Applied := True;
               Last := Authority;
               Value := Desired;
               Result := Desired;
            end if;
         end Apply;
      end Compensation_State;

      type Application_Context is limited record
         Handler      : aliased Handler_Context :=
           (Image_Version => Version);
         Server       : aliased Structured.Server (Capacity => 4);
         Provision    : Messages.Provisioning_Data :=
           (Application_Signature => 1,
            Topology_Schema       => 1,
            Topology_Epoch        => 1,
            Digest                => (others => 0),
            Role                  => Generations.Canary_Safe);
         Recovery     : Compensation_State;
      end record;

      procedure Prepare
        (Context : in out Application_Context;
         Data    : Messages.Provisioning_Data) is
      begin
         if Data.Application_Signature /= 16#F1# or else
           Data.Topology_Schema /= 1
         then
            raise Program_Error with "incompatible test image provisioning";
         end if;
         Context.Provision := Data;
         if Data.Digest (0) = 16#FC# then
            delay 2.0;
         end if;
      end Prepare;

      procedure Run_Server
        (Context  : in out Application_Context;
         Listener : in out Sockets.Socket_Type;
         Role     : Generations.Candidate_Role) is
      begin
         pragma Unreferenced (Role);
         if Context.Provision.Digest (0) = 16#FB# then
            declare
               task Stop_After_Readiness;
               task body Stop_After_Readiness is
               begin
                  delay 0.500;
                  Structured.Request_Shutdown (Context.Server);
               end Stop_After_Readiness;
            begin
               Structured.Serve
                 (Context.Server, Listener, Context.Handler,
                  Drain_Timeout => 2.0);
            end;
         else
            Structured.Serve
              (Context.Server, Listener, Context.Handler,
               Drain_Timeout => 2.0);
         end if;
      end Run_Server;

      function Ready
        (Context : Application_Context;
         Data    : Messages.Provisioning_Data) return Boolean
      is
         Current : constant Structured.Snapshot :=
           Structured.Current (Context.Server);
      begin
         return Data.Topology_Epoch = Context.Provision.Topology_Epoch
           and then Data.Digest = Context.Provision.Digest
           and then Data.Digest (0) not in 16#F9# | 16#FF#
           and then Current.Accepting
           and then Current.Failures = 0;
      end Ready;

      procedure Request_Stop (Context : in out Application_Context) is
      begin
         Structured.Request_Shutdown (Context.Server);
      end Request_Stop;

      procedure Promoted
        (Context   : in out Application_Context;
         Authority : Generations.Upgrade_Handle) is
      begin
         pragma Unreferenced (Context, Authority);
      end Promoted;

      function Compensate
        (Context   : in out Application_Context;
         Authority : Generations.Upgrade_Handle)
         return Generations.Compensation_Result
      is
         Desired : constant Generations.Compensation_Result :=
           (if Context.Provision.Digest (0) = 16#FE# then
               Generations.Compensation_Failed
            else Generations.Compensated);
         Result : Generations.Compensation_Result;
      begin
         Context.Recovery.Apply (Authority, Desired, Result);
         return Result;
      end Compensate;

      package Agent is new Generations.Agents
        (Application_Context => Application_Context,
         Prepare             => Prepare,
         Run_Server          => Run_Server,
         Ready               => Ready,
         Request_Stop        => Request_Stop,
         Promoted            => Promoted,
         Compensate          => Compensate);

      Context : Application_Context;
   begin
      Agent.Run
        (Context, Ready_Timeout => 2.0, Drain_Timeout => 3.0);
   end Run;
end Process_Generation_Test_Application;
