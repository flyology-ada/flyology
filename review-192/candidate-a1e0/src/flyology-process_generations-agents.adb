with Ada.Exceptions;
with Ada.Real_Time;
with Flyology.IO.Socket_Handoffs;
with Flyology.Process_Generations.Command_Lines;
with Flyology.Process_Generations.Protocol;
with Flyology.Process_Generations.Transport;
with Flyology.Subprocesses.Bootstrap;

package body Flyology.Process_Generations.Agents is
   package Bootstrap renames Flyology.Subprocesses.Bootstrap;
   package Handoffs renames Flyology.IO.Socket_Handoffs;
   package Protocol renames Flyology.Process_Generations.Protocol;
   package Transport renames Flyology.Process_Generations.Transport;

   use type Ada.Real_Time.Time;
   use type Messages.Decode_Result;
   use type Protocol.Message_Kind;

   Poll_Interval : constant Duration := 0.005;

   function Expired (Started : Ada.Real_Time.Time; Timeout : Duration) return Boolean
   is (Timeout >= 0.0 and then Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started) >= Timeout);

   function Remaining (Started : Ada.Real_Time.Time; Timeout : Duration) return Duration is
      Elapsed : constant Duration := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
   begin
      if Timeout < 0.0 then
         return Flyology.IO.Infinite;
      elsif Elapsed >= Timeout then
         return 0.0;
      else
         return Timeout - Elapsed;
      end if;
   end Remaining;

   procedure Run
     (Context         : in out Application_Context;
      Ready_Timeout   : Duration := 30.0;
      Drain_Timeout   : Duration := 30.0;
      Control_Timeout : Duration := Flyology.IO.Infinite)
   is
      Authority        : constant Upgrade_Handle := Command_Lines.Read_Authority;
      Control_Socket   : Flyology.IO.Sockets.Socket_Type;
      Capabilities     : Handoffs.Handoff_Channel;
      Control          : Transport.Control_Channel;
      Listener         : Flyology.IO.Sockets.Socket_Type;
      Frame            : Protocol.Frame;
      Provisioning     : Messages.Provisioning_Data;
      Decode           : Messages.Decode_Result;
      Payload          : Protocol.Payload_Buffer := (others => 0);
      Failure_Reported : Boolean := False;

      procedure Expect (Kind : Protocol.Message_Kind) is
      begin
         Transport.Receive (Control, Frame, Timeout => Control_Timeout);
         if Frame.Kind /= Kind then
            raise Agent_Error
              with "unexpected process-generation command " & Protocol.Message_Kind'Image (Frame.Kind);
         end if;
      end Expect;

      procedure Send_Failure_Text (Message : String) is
         Length : constant Natural := Natural'Min (Message'Length, Protocol.Maximum_Payload);
      begin
         if Failure_Reported then
            return;
         end if;
         Payload := (others => 0);
         if Length > 0 then
            for Index in 0 .. Length - 1 loop
               Payload (Index) := Protocol.Octet (Character'Pos (Message (Message'First + Index)));
            end loop;
         end if;
         begin
            Transport.Send (Control, Protocol.Failure_Message, Payload, Length, Timeout => Control_Timeout);
            Failure_Reported := True;
         exception
            when others =>
               null;
         end;
      exception
         --  Failure reporting must never replace the original agent error.
         when others =>
            null;
      end Send_Failure_Text;

      procedure Send_Failure (Occurrence : Ada.Exceptions.Exception_Occurrence) is
      begin
         Send_Failure_Text (Ada.Exceptions.Exception_Message (Occurrence));
      end Send_Failure;
   begin
      Bootstrap.Adopt_Inherited (Control_Socket, Capabilities);
      Transport.Adopt (Control, Control_Socket, Authority);
      Expect (Protocol.Hello);
      Transport.Send (Control, Protocol.Acknowledgment, Timeout => Control_Timeout);

      Expect (Protocol.Provision);
      Messages.Decode_Provision (Frame.Payload, Frame.Length, Provisioning, Decode);
      if Decode /= Messages.Decoded then
         raise Agent_Error with "invalid provisioning payload " & Messages.Decode_Result'Image (Decode);
      end if;
      Prepare (Context, Provisioning);

      Expect (Protocol.Expect_Capability);
      if Frame.Length /= 0 then
         raise Agent_Error with "listener expectation payload is not empty";
      end if;
      Transport.Send (Control, Protocol.Capability_Ready, Timeout => Control_Timeout);
      Handoffs.Receive_Listener (Capabilities, Listener);
      Transport.Send (Control, Protocol.Capability_Adopted, Timeout => Control_Timeout);
      Messages.Encode_Topology_Proof
        ((Epoch => Provisioning.Topology_Epoch, Digest => Provisioning.Digest), Payload);
      Transport.Send
        (Control,
         Protocol.Prepared_Message,
         Payload,
         Messages.Topology_Proof_Length,
         Timeout => Control_Timeout);

      declare
         protected Server_Result is
            procedure Finish (Failed : Boolean);
            procedure Snapshot (Finished, Failed : out Boolean);
         private
            Is_Finished : Boolean := False;
            Has_Failed  : Boolean := False;
         end Server_Result;

         protected body Server_Result is
            procedure Finish (Failed : Boolean) is
            begin
               Has_Failed := Failed;
               Is_Finished := True;
            end Finish;

            procedure Snapshot (Finished, Failed : out Boolean) is
            begin
               Finished := Is_Finished;
               Failed := Has_Failed;
            end Snapshot;
         end Server_Result;

         task Server is
            pragma Task_Info (Flyology.Native_Task);
            entry Start;
         end Server;

         task body Server is
         begin
            select
               accept Start;
               begin
                  Run_Server (Context, Listener, Provisioning.Role);
                  Server_Result.Finish (False);
               exception
                  when others =>
                     Server_Result.Finish (True);
               end;
            or
               terminate;
            end select;
         end Server;

         Started : Boolean := False;

         procedure Await_Server_Stop is
            Began : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
         begin
            while not Server'Terminated loop
               if Expired (Began, Drain_Timeout) then
                  Send_Failure_Text ("candidate server did not drain before its deadline");
                  raise Agent_Error with "candidate server did not drain before its deadline";
               end if;
               delay Poll_Interval;
            end loop;
         end Await_Server_Stop;

         procedure Stop_Server is
            Finished, Failed : Boolean;
         begin
            if Started then
               Request_Stop (Context);
               Await_Server_Stop;
               Server_Result.Snapshot (Finished, Failed);
               if not Finished or else Failed then
                  raise Agent_Error with "managed server failed while draining";
               end if;
            end if;
         end Stop_Server;

         procedure Cancel_Started_Server is
            Result : Compensation_Result;
         begin
            Request_Stop (Context);
            Transport.Send (Control, Protocol.Admission_Revoked_Message, Timeout => Control_Timeout);
            Await_Server_Stop;
            Transport.Send (Control, Protocol.Drained_Message, Timeout => Control_Timeout);
            begin
               Result := Compensate (Context, Authority);
            exception
               when others =>
                  Result := Compensation_Failed;
            end;
            Messages.Encode_Compensation (Result, Payload);
            Transport.Send
              (Control,
               Protocol.Compensation_Message,
               Payload,
               Messages.Compensation_Length,
               Timeout => Control_Timeout);
         end Cancel_Started_Server;

         procedure Receive_Command is
            Began            : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
            Finished, Failed : Boolean;
            Slice            : Duration;
         begin
            if Started then
               loop
                  Server_Result.Snapshot (Finished, Failed);
                  if Finished then
                     raise Agent_Error
                       with
                         (if Failed
                          then "managed server failed after readiness"
                          else "managed server stopped before a drain command");
                  elsif Expired (Began, Control_Timeout) then
                     raise Flyology.IO.Timeout_Error with "control command deadline expired";
                  end if;
                  Slice :=
                    (if Control_Timeout < 0.0
                     then Poll_Interval
                     else Duration'Min (Poll_Interval, Remaining (Began, Control_Timeout)));
                  exit when Transport.Message_Available (Control, Timeout => Slice);
               end loop;
               Transport.Receive (Control, Frame, Timeout => Remaining (Began, Control_Timeout));
            else
               Transport.Receive (Control, Frame, Timeout => Control_Timeout);
            end if;
         end Receive_Command;
      begin
         loop
            Receive_Command;
            case Frame.Kind is
               when Protocol.Start_Canary_Message                      =>
                  begin
                     if Started then
                        raise Agent_Error with "candidate server already started";
                     end if;
                     Server.Start;
                     Started := True;
                     declare
                        Began            : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
                        Finished, Failed : Boolean;
                     begin
                        loop
                           Server_Result.Snapshot (Finished, Failed);
                           if Transport.Message_Available (Control, Timeout => 0.0) then
                              Transport.Receive (Control, Frame, Timeout => Control_Timeout);
                              if Frame.Kind = Protocol.Cancel_Message then
                                 Cancel_Started_Server;
                                 return;
                              else
                                 raise Agent_Error with "unexpected command during readiness";
                              end if;
                           elsif Ready (Context, Provisioning) then
                              exit;
                           elsif Finished then
                              raise Agent_Error
                                with
                                  (if Failed
                                   then "candidate server failed"
                                   else "candidate server stopped before " & "readiness");
                           elsif Expired (Began, Ready_Timeout) then
                              raise Agent_Error with "candidate readiness deadline expired";
                           end if;
                           delay Poll_Interval;
                        end loop;
                     end;
                     Messages.Encode_Topology_Proof
                       ((Epoch => Provisioning.Topology_Epoch, Digest => Provisioning.Digest), Payload);
                     Transport.Send
                       (Control,
                        Protocol.Ready_Message,
                        Payload,
                        Messages.Topology_Proof_Length,
                        Timeout => Control_Timeout);
                  exception
                     when Error : others =>
                        --  Admission may have begun before readiness failed.
                        --  Use the same ordered recovery boundary as an
                        --  operator cancellation before reporting the error.
                        if Started and then not Server'Terminated then
                           Request_Stop (Context);
                        end if;
                        Transport.Send
                          (Control, Protocol.Admission_Revoked_Message, Timeout => Control_Timeout);
                        if Started then
                           Await_Server_Stop;
                        end if;
                        Transport.Send (Control, Protocol.Drained_Message, Timeout => Control_Timeout);
                        declare
                           Result : Compensation_Result;
                        begin
                           begin
                              Result := Compensate (Context, Authority);
                           exception
                              when others =>
                                 Result := Compensation_Failed;
                           end;
                           Messages.Encode_Compensation (Result, Payload);
                           Transport.Send
                             (Control,
                              Protocol.Compensation_Message,
                              Payload,
                              Messages.Compensation_Length,
                              Timeout => Control_Timeout);
                        end;
                        Send_Failure (Error);
                        return;
                  end;

               when Protocol.Cancel_Message                            =>
                  if Started then
                     Cancel_Started_Server;
                  else
                     Transport.Send (Control, Protocol.Acknowledgment, Timeout => Control_Timeout);
                  end if;
                  return;

               when Protocol.Promote_Message                           =>
                  if not Started or else not Ready (Context, Provisioning) then
                     raise Agent_Error with "candidate is not ready for promotion";
                  end if;
                  Promoted (Context, Authority);
                  Transport.Send (Control, Protocol.Acknowledgment, Timeout => Control_Timeout);

               when Protocol.Drain_Message | Protocol.Shutdown_Message =>
                  Stop_Server;
                  Transport.Send (Control, Protocol.Drained_Message, Timeout => Control_Timeout);
                  return;

               when others                                             =>
                  raise Agent_Error with "command is invalid for a prepared image agent";
            end case;
         end loop;
      exception
         when others =>
            if Started and then not Server'Terminated then
               begin
                  Request_Stop (Context);
               exception
                  when others =>
                     null;
               end;
            end if;
            raise;
      end;
   exception
      when Error : others =>
         Send_Failure (Error);
         raise;
   end Run;
end Flyology.Process_Generations.Agents;
