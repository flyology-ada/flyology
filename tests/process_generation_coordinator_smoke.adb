with Ada.Command_Line;
with Ada.Directories;
with Ada.Real_Time;
with Ada.Streams;
with Flyology.Cancellation;
with Flyology.IO.Sockets;
with Flyology.Process_Generations;
with Flyology.Process_Generations.Coordinators;
with Flyology.Process_Generations.Messages;
with Flyology.Process_Generations.Protocol;
with Flyology.Subprocesses;
with Interfaces;

procedure Process_Generation_Coordinator_Smoke is
   package Coordinators renames Flyology.Process_Generations.Coordinators;
   package Generations renames Flyology.Process_Generations;
   package Messages renames Flyology.Process_Generations.Messages;
   package Protocol renames Flyology.Process_Generations.Protocol;
   package Sockets renames Flyology.IO.Sockets;
   package Subprocesses renames Flyology.Subprocesses;

   use type Ada.Streams.Stream_Element;
   use type Ada.Real_Time.Time;
   use type Generations.Compensation_Result;
   use type Generations.Image_Generation;
   use type Generations.Upgrade_Phase;
   use type Interfaces.Unsigned_64;

   Bin_Directory : constant String :=
     Ada.Directories.Containing_Directory (Ada.Directories.Full_Name (Ada.Command_Line.Command_Name));
   V1_Path       : constant String := Ada.Directories.Compose (Bin_Directory, "process_generation_agent_v1");
   V2_Path       : constant String := Ada.Directories.Compose (Bin_Directory, "process_generation_agent_v2");

   function Provision
     (Epoch : Messages.Nonzero_U64; Mode : Ada.Streams.Stream_Element := 0) return Messages.Provisioning_Data
   is
      Digest : Messages.Topology_Digest := (others => 0);
   begin
      Digest (0) := Protocol.Octet (Mode);
      Digest (1) := Protocol.Octet (Interfaces.Unsigned_64 (Epoch) mod 256);
      return
        (Application_Signature => 16#F1#,
         Topology_Schema       => 1,
         Topology_Epoch        => Epoch,
         Digest                => Digest,
         Role                  => Generations.Canary_Safe);
   end Provision;

   function Command (Path : String) return Subprocesses.Command
   is (Subprocesses.To_Command (Path));

   function Query (Address : Sockets.Endpoint) return Ada.Streams.Stream_Element is
      Client : Sockets.Socket_Type;
      Reply  : Ada.Streams.Stream_Element_Array (1 .. 1);
   begin
      Sockets.Create_Socket (Client);
      Sockets.Connect (Client, Address, Timeout => 2.0);
      Sockets.Send_All (Client, [1 => Character'Pos ('Q')], Timeout => 2.0);
      Sockets.Receive_Exactly (Client, Reply, Timeout => 2.0);
      return Reply (1);
   end Query;

   procedure Assert (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Assert;

   Listener                   : Sockets.Socket_Type;
   Address                    : Sockets.Endpoint;
   Manager                    : Coordinators.Coordinator;
   First, Candidate, Reversal : Generations.Upgrade_Handle;
   Compensation               : Generations.Compensation_Result;
   Held                       : Sockets.Socket_Type;
   Held_Reply                 : Ada.Streams.Stream_Element_Array (1 .. 1);
begin
   Sockets.Create_Socket (Listener);
   Sockets.Set_Socket_Option (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
   Sockets.Bind_Socket (Listener, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Sockets.Listen_Socket (Listener, Length => 16);
   Address := Sockets.Get_Socket_Name (Listener);
   Coordinators.Initialize (Manager, 17, Listener);

   Coordinators.Start_Initial (Manager, Command (V1_Path), Provision (1), First, Timeout => 5.0);
   Assert (Coordinators.Snapshot (Manager).Phase = Generations.Completed, "initial image did not commit");
   Assert (Query (Address) = Character'Pos ('1'), "v1 did not become active");

   declare
      Stop       : aliased Flyology.Cancellation.Token;
      Cancelled  : Boolean := False;
      Unexpected : Boolean := False;
      pragma Atomic (Cancelled);
      pragma Atomic (Unexpected);
      Ignored    : Generations.Upgrade_Handle;

      task Start_Slow_Upgrade;
      task body Start_Slow_Upgrade is
      begin
         begin
            Coordinators.Start_Upgrade
              (Manager,
               Command (V2_Path),
               Provision (2, 16#FC#),
               Ignored,
               Timeout => 5.0,
               Token   => Stop'Access);
            Unexpected := True;
         exception
            when Flyology.Cancellation.Operation_Cancelled =>
               Cancelled := True;
         end;
      end Start_Slow_Upgrade;
   begin
      delay 0.100;
      Stop.Request;
      while not Start_Slow_Upgrade'Terminated loop
         delay 0.010;
      end loop;
      Assert (Cancelled and then not Unexpected, "in-flight provisioning ignored cancellation");
      Assert
        (Coordinators.Snapshot (Manager).Phase = Generations.Cancelled
         and then not Coordinators.Snapshot (Manager).Has_Candidate,
         "cancelled provisioning retained a candidate");
      Assert (Query (Address) = Character'Pos ('1'), "startup cancellation disturbed the active image");
   end;

   Coordinators.Start_Upgrade (Manager, Command (V2_Path), Provision (2, 16#F9#), Candidate, Timeout => 5.0);
   declare
      Stop       : aliased Flyology.Cancellation.Token;
      Cancelled  : Boolean := False;
      Unexpected : Boolean := False;
      pragma Atomic (Cancelled);
      pragma Atomic (Unexpected);

      task Start_Slow_Canary;
      task body Start_Slow_Canary is
      begin
         begin
            Coordinators.Begin_Canary (Manager, Candidate, Timeout => 5.0, Token => Stop'Access);
            Unexpected := True;
         exception
            when Flyology.Cancellation.Operation_Cancelled =>
               Cancelled := True;
         end;
      end Start_Slow_Canary;
   begin
      delay 0.100;
      Stop.Request;
      while not Start_Slow_Canary'Terminated loop
         delay 0.010;
      end loop;
      Assert (Cancelled and then not Unexpected, "in-flight canary readiness ignored cancellation");
      declare
         Sample : constant Coordinators.Coordinator_Snapshot := Coordinators.Snapshot (Manager);
      begin
         Assert
           (Sample.Phase = Generations.Cancelled
            and then not Sample.Has_Candidate
            and then not Sample.Candidate_Admitted
            and then Sample.Compensation = Generations.Compensated,
            "readiness cancellation did not compensate the canary");
      end;
      Assert (Query (Address) = Character'Pos ('1'), "readiness cancellation disturbed the active image");
   end;

   Sockets.Create_Socket (Held);
   Sockets.Connect (Held, Address, Timeout => 2.0);
   Sockets.Send_All (Held, [1 => Character'Pos ('H')], Timeout => 2.0);
   Sockets.Receive_Exactly (Held, Held_Reply, Timeout => 2.0);
   Assert (Held_Reply (1) = Character'Pos ('1'), "held v1 session failed");

   declare
      Bad    : Messages.Provisioning_Data := Provision (2);
      Failed : Boolean := False;
   begin
      Bad.Application_Signature := 16#F2#;
      begin
         Coordinators.Start_Upgrade (Manager, Command (V2_Path), Bad, Candidate, Timeout => 5.0);
      exception
         when Coordinators.Upgrade_Error =>
            Failed := True;
      end;
      Assert (Failed, "incompatible candidate was accepted");
      Assert (Query (Address) = Character'Pos ('1'), "failed startup disturbed the active image");
   end;

   Coordinators.Start_Upgrade (Manager, Command (V2_Path), Provision (3), Candidate, Timeout => 5.0);
   declare
      Stale    : Generations.Upgrade_Handle := Candidate;
      Rejected : Boolean := False;
      Before   : constant Coordinators.Coordinator_Snapshot := Coordinators.Snapshot (Manager);
   begin
      Stale.Candidate := Stale.Candidate + 1;
      begin
         Coordinators.Begin_Canary (Manager, Stale, Timeout => 2.0);
      exception
         when Coordinators.Stale_Authority =>
            Rejected := True;
      end;
      Assert (Rejected, "stale canary authority was accepted");
      Assert
        (Coordinators.Snapshot (Manager).Phase = Before.Phase
         and then Coordinators.Snapshot (Manager).Has_Candidate,
         "stale authority mutated coordinator state");
   end;
   Coordinators.Begin_Canary (Manager, Candidate, Timeout => 5.0);
   Coordinators.Cancel (Manager, Candidate, Compensation, Timeout => 5.0);
   Assert (Compensation = Generations.Compensated, "canary compensation was not retained");
   Assert (Query (Address) = Character'Pos ('1'), "canary cancellation disturbed v1");

   Coordinators.Start_Upgrade (Manager, Command (V2_Path), Provision (4, 16#FE#), Candidate, Timeout => 5.0);
   Coordinators.Begin_Canary (Manager, Candidate, Timeout => 5.0);
   Coordinators.Cancel (Manager, Candidate, Compensation, Timeout => 5.0);
   Assert (Compensation = Generations.Compensation_Failed, "compensation failure was not retained");
   Assert (Query (Address) = Character'Pos ('1'), "failed compensation disturbed v1 admission");

   Coordinators.Start_Upgrade (Manager, Command (V2_Path), Provision (5), Candidate, Timeout => 5.0);
   Coordinators.Begin_Canary (Manager, Candidate, Timeout => 5.0);
   Sockets.Send_All (Held, [1 => Character'Pos ('R')], Timeout => 2.0);
   Sockets.Receive_Exactly (Held, Held_Reply, Timeout => 2.0);
   Assert (Held_Reply (1) = Character'Pos ('1'), "v1 connection did not survive candidate overlap");
   Coordinators.Promote (Manager, Candidate, Timeout => 5.0);
   Assert (Query (Address) = Character'Pos ('2'), "v2 did not become active");

   Coordinators.Rollback_To_Previous (Manager, Reversal, Timeout => 5.0);
   Assert (Reversal.Candidate /= First.Candidate, "rollback reused the original image generation");
   Assert (Query (Address) = Character'Pos ('1'), "rollback did not construct a fresh v1 image");

   Coordinators.Start_Upgrade (Manager, Command (V2_Path), Provision (6), Candidate, Timeout => 5.0);
   Coordinators.Begin_Canary (Manager, Candidate, Timeout => 5.0);
   Coordinators.Promote (Manager, Candidate, Timeout => 5.0);
   Assert (Query (Address) = Character'Pos ('2'), "v2 did not recommit");

   Coordinators.Start_Upgrade (Manager, Command (V1_Path), Provision (7, 16#FB#), Candidate, Timeout => 5.0);
   Coordinators.Begin_Canary (Manager, Candidate, Timeout => 5.0);
   declare
      Began  : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Sample : Coordinators.Coordinator_Snapshot;
   begin
      loop
         Sample := Coordinators.Snapshot (Manager);
         exit when Sample.Phase = Generations.Failed;
         if Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Began) >= 3.0 then
            raise Program_Error with "post-readiness server exit was not reconciled";
         end if;
         delay 0.010;
      end loop;
      Assert
        (not Sample.Has_Candidate
         and then not Sample.Candidate_Ready
         and then not Sample.Candidate_Admitted
         and then Sample.Compensation = Generations.Compensation_Pending,
         "server exit retained candidate admission state");
   end;
   Assert (Query (Address) = Character'Pos ('2'), "candidate server exit disturbed the active image");

   Coordinators.Start_Upgrade (Manager, Command (V1_Path), Provision (8, 16#FF#), Candidate, Timeout => 5.0);
   declare
      Failed : Boolean := False;
   begin
      begin
         Coordinators.Begin_Canary (Manager, Candidate, Timeout => 3.0);
      exception
         when Coordinators.Upgrade_Error =>
            Failed := True;
      end;
      Assert (Failed, "topology readiness mismatch was accepted");
      Assert (Query (Address) = Character'Pos ('2'), "failed readiness disturbed v2");
   end;

   Coordinators.Shutdown (Manager, Timeout => 5.0);
end Process_Generation_Coordinator_Smoke;
