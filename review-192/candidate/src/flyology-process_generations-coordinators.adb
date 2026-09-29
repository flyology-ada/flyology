with Ada.Exceptions;
with Ada.Real_Time;
with Flyology.Process_Generation_Policy;
with Flyology.Process_Generations.Command_Lines;
with Flyology.Process_Generations.Protocol;
with Flyology.Subprocesses.Bootstrap;
with Interfaces;

package body Flyology.Process_Generations.Coordinators is
   package Policy renames Flyology.Process_Generation_Policy;
   package Protocol renames Flyology.Process_Generations.Protocol;
   package Bootstrap renames Flyology.Subprocesses.Bootstrap;

   use type Ada.Exceptions.Exception_Id;
   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_64;
   use type Messages.Decode_Result;
   use type Messages.Topology_Digest;
   use type Protocol.Message_Kind;

   procedure Check_Cancelled (Token : access Flyology.Cancellation.Token) is
   begin
      if Token /= null and then Token.Requested then
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;
   end Check_Cancelled;

   function Failure_Message (Item : Coordinator_Snapshot) return String
   is (if Item.Failure_Size = 0 then "" else String (Item.Failure (1 .. Item.Failure_Size)));

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

   procedure Record_Failure (Item : in out Coordinator; Message : String) is
      Length : constant Natural := Natural'Min (Message'Length, Maximum_Failure_Length);
   begin
      if Item.State.Failure_Size = 0 and then Length > 0 then
         Item.State.Failure_Size := Length;
         Item.State.Failure := (others => ' ');
         for Index in 1 .. Length loop
            Item.State.Failure (Index) := Message (Message'First + Index - 1);
         end loop;
      end if;
   end Record_Failure;

   procedure Record_Failure (Item : in out Coordinator; Error : Ada.Exceptions.Exception_Occurrence) is
   begin
      Record_Failure (Item, Ada.Exceptions.Exception_Message (Error));
   end Record_Failure;

   procedure Apply (Item : in out Coordinator; Command : Upgrade_Command) is
   begin
      if not Policy.Command_Allowed (Item.State.Phase, Command) then
         raise Invalid_Phase
           with
             "command "
             & Upgrade_Command'Image (Command)
             & " is invalid in "
             & Upgrade_Phase'Image (Item.State.Phase);
      end if;
      Item.State.Phase := Policy.Phase_After (Item.State.Phase, Command);
   end Apply;

   procedure Normalize_For_Start (Item : in out Coordinator) is
   begin
      if not Item.State.Initialized then
         raise Program_Error with "process-generation coordinator is closed";
      elsif Item.State.Has_Candidate then
         raise Invalid_Phase with "an upgrade candidate is already owned";
      elsif Policy.Terminal (Item.State.Phase) then
         Item.State.Phase := Stable;
         Item.State.Candidate_Ready := False;
         Item.State.Candidate_Admitted := False;
         Item.State.Compensation := Not_Required;
         Item.State.Failure_Size := 0;
         Item.State.Failure := (others => ' ');
      elsif Item.State.Phase /= Stable then
         raise Invalid_Phase with "coordinator is not stable";
      end if;
   end Normalize_For_Start;

   procedure Allocate_Authority (Item : in out Coordinator; Authority : out Upgrade_Handle) is
   begin
      if Item.Upgrade_Exhausted or else Item.Generation_Exhausted then
         raise Identity_Exhausted with "process-generation identity space is exhausted";
      end if;
      Authority :=
        (Coordinator => Item.Identity, Upgrade => Item.Next_Upgrade, Candidate => Item.Next_Generation);
      if Interfaces.Unsigned_64 (Item.Next_Upgrade) = Interfaces.Unsigned_64'Last then
         Item.Upgrade_Exhausted := True;
      else
         Item.Next_Upgrade := Item.Next_Upgrade + 1;
      end if;
      if Interfaces.Unsigned_64 (Item.Next_Generation) = Interfaces.Unsigned_64'Last then
         Item.Generation_Exhausted := True;
      else
         Item.Next_Generation := Item.Next_Generation + 1;
      end if;
   end Allocate_Authority;

   procedure Require_Authority (Item : Coordinator; Authority : Upgrade_Handle) is
   begin
      if not Policy.Authority_Matches (Item.State.Authority, Authority) then
         raise Stale_Authority with "upgrade command has stale coordinator authority";
      end if;
   end Require_Authority;

   procedure Cleanup_Slot (Slot : in out Image_Slot) is
   begin
      if Transport.Is_Open (Slot.Control) then
         begin
            Transport.Close (Slot.Control);
         exception
            when others =>
               null;
         end;
      end if;
      if Handoffs.Is_Open (Slot.Capabilities) then
         begin
            Handoffs.Close (Slot.Capabilities);
         exception
            when others =>
               null;
         end;
      end if;
      if Flyology.Subprocesses.Is_Open (Slot.Child) then
         begin
            Flyology.Subprocesses.Close (Slot.Child);
         exception
            when others =>
               null;
         end;
      end if;
      Slot.Occupied := False;
   end Cleanup_Slot;

   procedure Wait_And_Release (Slot : in out Image_Slot; Timeout : Duration) is
      Status : Flyology.Subprocesses.Exit_Status;
   begin
      Flyology.Subprocesses.Wait (Slot.Child, Status, Timeout => Timeout);
      if not Flyology.Subprocesses.Successful (Status) then
         raise Upgrade_Error with "image agent exited unsuccessfully";
      end if;
      if Transport.Is_Open (Slot.Control) then
         Transport.Close (Slot.Control);
      end if;
      if Handoffs.Is_Open (Slot.Capabilities) then
         Handoffs.Close (Slot.Capabilities);
      end if;
      Flyology.Subprocesses.Close (Slot.Child);
      Slot.Occupied := False;
   exception
      when others =>
         Cleanup_Slot (Slot);
         raise;
   end Wait_And_Release;

   function Agent_Failure_Message (Frame : Protocol.Frame) return String is
   begin
      if Frame.Length = 0 then
         return "image agent reported failure";
      else
         declare
            Text : String (1 .. Natural (Frame.Length));
         begin
            for Index in Text'Range loop
               Text (Index) := Character'Val (Frame.Payload (Protocol.Payload_Index (Index - 1)));
            end loop;
            return Text;
         end;
      end if;
   end Agent_Failure_Message;

   procedure Expect
     (Slot    : in out Image_Slot;
      Kind    : Protocol.Message_Kind;
      Frame   : out Protocol.Frame;
      Timeout : Duration;
      Token   : access Flyology.Cancellation.Token := null)
   is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      if not Transport.Message_Available (Slot.Control, Timeout => Timeout, Token => Token) then
         raise Flyology.IO.Timeout_Error with "control response deadline expired";
      end if;
      Transport.Receive (Slot.Control, Frame, Timeout => Remaining (Started, Timeout));
      if Frame.Kind = Protocol.Failure_Message then
         raise Upgrade_Error with Agent_Failure_Message (Frame);
      elsif Frame.Kind /= Kind then
         raise Upgrade_Error
           with
             "expected "
             & Protocol.Message_Kind'Image (Kind)
             & ", received "
             & Protocol.Message_Kind'Image (Frame.Kind);
      end if;
   end Expect;

   procedure Validate_Proof (Frame : Protocol.Frame; Provision : Messages.Provisioning_Data) is
      Proof  : Messages.Topology_Proof;
      Result : Messages.Decode_Result;
   begin
      Messages.Decode_Topology_Proof (Frame.Payload, Frame.Length, Proof, Result);
      if Result /= Messages.Decoded
        or else Proof.Epoch /= Provision.Topology_Epoch
        or else Proof.Digest /= Provision.Digest
      then
         raise Upgrade_Error with "image topology proof does not match desired state";
      end if;
   end Validate_Proof;

   function Slot_Exited (Slot : Image_Slot) return Boolean
   is (Slot.Occupied
       and then Flyology.Subprocesses.Is_Open (Slot.Child)
       and then Flyology.Subprocesses.Has_Exited (Slot.Child));

   procedure Reconcile_Exited (Item : in out Coordinator) is
      Candidate_Dead : constant Boolean :=
        Item.State.Has_Candidate and then Slot_Exited (Item.Slots (Item.Candidate_Slot));
      Active_Dead    : constant Boolean :=
        Item.State.Has_Active and then Slot_Exited (Item.Slots (Item.Active_Slot));
   begin
      if Candidate_Dead then
         if Item.State.Phase in Canary | Revoking_Admission | Draining_Candidate | Compensating then
            Item.State.Compensation := Compensation_Pending;
         end if;
         Cleanup_Slot (Item.Slots (Item.Candidate_Slot));
         Item.State.Has_Candidate := False;
         Item.State.Candidate_Ready := False;
         Item.State.Candidate_Admitted := False;
         Record_Failure (Item, "candidate image exited unexpectedly");
         Item.State.Phase :=
           (if Policy.Promotion_Committed (Item.State.Phase) then Rollback_Required else Failed);
      end if;

      if Active_Dead then
         Cleanup_Slot (Item.Slots (Item.Active_Slot));
         Item.State.Has_Active := False;
         Record_Failure (Item, "active image exited unexpectedly");
         if Item.State.Has_Candidate then
            Cleanup_Slot (Item.Slots (Item.Candidate_Slot));
            Item.State.Has_Candidate := False;
            Item.State.Candidate_Ready := False;
            Item.State.Candidate_Admitted := False;
         end if;
         Item.State.Phase := (if Item.State.Rollback_Available then Rollback_Required else Failed);
      end if;
   end Reconcile_Exited;

   procedure Initialize
     (Item             : in out Coordinator;
      Identity         : Coordinator_Id;
      Listener         : in out Sockets.Socket_Type;
      First_Upgrade    : Upgrade_Id := 1;
      First_Generation : Image_Generation := 1) is
   begin
      if Item.State.Initialized then
         raise Program_Error with "coordinator is already initialized";
      elsif not Sockets.Is_Open (Listener) then
         raise Program_Error with "coordinator listener is closed";
      end if;
      Sockets.Move (Listener, Item.Listener);
      Item.Identity := Identity;
      Item.Next_Upgrade := First_Upgrade;
      Item.Next_Generation := First_Generation;
      Item.Upgrade_Exhausted := False;
      Item.Generation_Exhausted := False;
      Item.State :=
        (Initialized             => True,
         Phase                   => Stable,
         Authority               =>
           (Coordinator => Identity, Upgrade => First_Upgrade, Candidate => First_Generation),
         Has_Active              => False,
         Active_Generation       => First_Generation,
         Has_Candidate           => False,
         Candidate_Generation    => First_Generation,
         Candidate_Ready         => False,
         Candidate_Admitted      => False,
         Rollback_Available      => False,
         Desired_Topology_Epoch  => 1,
         Desired_Topology_Digest => (others => 0),
         Compensation            => Not_Required,
         Failure_Size            => 0,
         Failure                 => (others => ' '));
   end Initialize;

   function Snapshot (Item : in out Coordinator) return Coordinator_Snapshot is
   begin
      Reconcile_Exited (Item);
      return Item.State;
   end Snapshot;

   procedure Start_Upgrade
     (Item       : in out Coordinator;
      Executable : Flyology.Subprocesses.Command;
      Provision  : Messages.Provisioning_Data;
      Authority  : out Upgrade_Handle;
      Timeout    : Duration := 30.0;
      Token      : access Flyology.Cancellation.Token := null)
   is
      Started             : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Candidate           : Slot_Index;
      Command             : Flyology.Subprocesses.Command := Executable;
      Control_Socket      : Sockets.Socket_Type;
      Frame               : Protocol.Frame;
      Payload             : Protocol.Payload_Buffer;
      Transaction_Started : Boolean := False;
   begin
      Authority := (Coordinator => 1, Upgrade => 1, Candidate => 1);
      Reconcile_Exited (Item);
      Check_Cancelled (Token);
      Normalize_For_Start (Item);
      Candidate := (if Item.State.Has_Active then 1 - Item.Active_Slot else 0);
      Cleanup_Slot (Item.Slots (Candidate));
      Allocate_Authority (Item, Authority);
      Item.Candidate_Slot := Candidate;
      Item.State.Authority := Authority;
      Item.State.Has_Candidate := True;
      Item.State.Candidate_Generation := Authority.Candidate;
      Item.State.Candidate_Ready := False;
      Item.State.Candidate_Admitted := False;
      Item.State.Desired_Topology_Epoch := Provision.Topology_Epoch;
      Item.State.Desired_Topology_Digest := Provision.Digest;
      Item.State.Compensation := Not_Required;
      Apply (Item, Start_Upgrade);
      Transaction_Started := True;

      Command_Lines.Append_Authority (Command, Authority);
      Bootstrap.Spawn
        (Command, Item.Slots (Candidate).Child, Control_Socket, Item.Slots (Candidate).Capabilities);
      Check_Cancelled (Token);
      Item.Slots (Candidate).Occupied := True;
      Item.Slots (Candidate).Generation := Authority.Candidate;
      Item.Slots (Candidate).Artifact := Executable;
      Item.Slots (Candidate).Provision := Provision;
      Transport.Adopt (Item.Slots (Candidate).Control, Control_Socket, Authority);
      Apply (Item, Candidate_Started);

      Transport.Send
        (Item.Slots (Candidate).Control, Protocol.Hello, Timeout => Remaining (Started, Timeout));
      Expect (Item.Slots (Candidate), Protocol.Acknowledgment, Frame, Remaining (Started, Timeout), Token);
      Check_Cancelled (Token);
      Messages.Encode_Provision (Provision, Payload);
      Transport.Send
        (Item.Slots (Candidate).Control,
         Protocol.Provision,
         Payload,
         Messages.Provision_Length,
         Remaining (Started, Timeout));
      Transport.Send
        (Item.Slots (Candidate).Control, Protocol.Expect_Capability, Timeout => Remaining (Started, Timeout));
      Expect (Item.Slots (Candidate), Protocol.Capability_Ready, Frame, Remaining (Started, Timeout), Token);
      Check_Cancelled (Token);
      Handoffs.Send_Listener (Item.Slots (Candidate).Capabilities, Item.Listener, Handoffs.Borrow);
      Expect
        (Item.Slots (Candidate), Protocol.Capability_Adopted, Frame, Remaining (Started, Timeout), Token);
      Expect (Item.Slots (Candidate), Protocol.Prepared_Message, Frame, Remaining (Started, Timeout), Token);
      Validate_Proof (Frame, Provision);
      Check_Cancelled (Token);
      Apply (Item, Candidate_Prepared);
   exception
      when Error : others =>
         if not Transaction_Started then
            Ada.Exceptions.Reraise_Occurrence (Error);
         end if;
         if Ada.Exceptions.Exception_Identity (Error) = Flyology.Cancellation.Operation_Cancelled'Identity
         then
            if Policy.Cancellation_Allowed (Item.State.Phase) then
               Apply (Item, Cancel_Upgrade);
            end if;
            if Item.State.Has_Candidate then
               Cleanup_Slot (Item.Slots (Item.Candidate_Slot));
               Item.State.Has_Candidate := False;
               Item.State.Candidate_Ready := False;
               Item.State.Candidate_Admitted := False;
            end if;
            if Item.State.Phase = Cancelling then
               Apply (Item, Candidate_Stopped);
            end if;
            Ada.Exceptions.Reraise_Occurrence (Error);
         end if;
         Record_Failure (Item, Error);
         if Policy.Command_Allowed (Item.State.Phase, Record_Failure) then
            Apply (Item, Record_Failure);
         end if;
         if Item.State.Has_Candidate then
            Cleanup_Slot (Item.Slots (Item.Candidate_Slot));
            Item.State.Has_Candidate := False;
         end if;
         if Ada.Exceptions.Exception_Identity (Error) = Identity_Exhausted'Identity
           or else Ada.Exceptions.Exception_Identity (Error) = Invalid_Phase'Identity
           or else Ada.Exceptions.Exception_Identity (Error) = Program_Error'Identity
         then
            Ada.Exceptions.Reraise_Occurrence (Error);
         else
            raise Upgrade_Error with Ada.Exceptions.Exception_Message (Error);
         end if;
   end Start_Upgrade;

   procedure Begin_Canary
     (Item      : in out Coordinator;
      Authority : Upgrade_Handle;
      Timeout   : Duration := 30.0;
      Token     : access Flyology.Cancellation.Token := null)
   is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Frame        : Protocol.Frame;
      Decode       : Messages.Decode_Result;
      Compensation : Compensation_Result := Not_Required;
      Mutated      : Boolean := False;
   begin
      Reconcile_Exited (Item);
      Require_Authority (Item, Authority);
      Check_Cancelled (Token);
      if Item.State.Phase /= Prepared then
         raise Invalid_Phase with "candidate is not prepared";
      end if;
      Apply (Item, Start_Canary);
      Mutated := True;
      Item.State.Candidate_Admitted := True;
      Item.State.Compensation := Compensation_Pending;
      Transport.Send
        (Item.Slots (Item.Candidate_Slot).Control,
         Protocol.Start_Canary_Message,
         Timeout => Remaining (Started, Timeout));
      if not Transport.Message_Available
               (Item.Slots (Item.Candidate_Slot).Control, Remaining (Started, Timeout), Token)
      then
         raise Flyology.IO.Timeout_Error with "candidate readiness deadline expired";
      end if;
      Transport.Receive
        (Item.Slots (Item.Candidate_Slot).Control, Frame, Timeout => Remaining (Started, Timeout));
      Check_Cancelled (Token);
      if Frame.Kind = Protocol.Ready_Message then
         Validate_Proof (Frame, Item.Slots (Item.Candidate_Slot).Provision);
         Item.State.Candidate_Ready := True;
         Item.State.Compensation := Not_Required;
      elsif Frame.Kind = Protocol.Admission_Revoked_Message then
         --  The agent failed readiness after admission may have begun. It
         --  performs the normal cancellation ordering before reporting why.
         Apply (Item, Cancel_Upgrade);
         Item.State.Candidate_Admitted := False;
         Apply (Item, Admission_Revoked);
         Expect
           (Item.Slots (Item.Candidate_Slot), Protocol.Drained_Message, Frame, Remaining (Started, Timeout));
         Apply (Item, Candidate_Drained);
         Expect
           (Item.Slots (Item.Candidate_Slot),
            Protocol.Compensation_Message,
            Frame,
            Remaining (Started, Timeout));
         Messages.Decode_Compensation (Frame.Payload, Frame.Length, Compensation, Decode);
         if Decode /= Messages.Decoded then
            raise Upgrade_Error with "invalid compensation result";
         end if;
         Item.State.Compensation := Compensation;
         Apply (Item, Compensation_Finished);
         Transport.Receive
           (Item.Slots (Item.Candidate_Slot).Control, Frame, Timeout => Remaining (Started, Timeout));
         if Frame.Kind /= Protocol.Failure_Message then
            raise Upgrade_Error with "candidate recovery omitted its readiness failure";
         end if;
         Wait_And_Release (Item.Slots (Item.Candidate_Slot), Remaining (Started, Timeout));
         Item.State.Has_Candidate := False;
         Item.State.Candidate_Ready := False;
         Record_Failure (Item, Agent_Failure_Message (Frame));
         raise Upgrade_Error with Agent_Failure_Message (Frame);
      elsif Frame.Kind = Protocol.Failure_Message then
         raise Upgrade_Error with Agent_Failure_Message (Frame);
      else
         raise Upgrade_Error with "candidate returned an invalid readiness response";
      end if;
   exception
      when Error : others =>
         if not Mutated then
            Ada.Exceptions.Reraise_Occurrence (Error);
         end if;
         --  A mismatched readiness proof leaves a responsive admitted
         --  candidate. Revoke, drain, and compensate it before recording the
         --  original error. A poisoned or closed channel falls through to
         --  conservative process cleanup with compensation left pending.
         if Item.State.Phase = Canary and then Item.State.Has_Candidate then
            begin
               Cancel (Item, Authority, Compensation, Remaining (Started, Timeout));
            exception
               when others =>
                  null;
            end;
         end if;
         Record_Failure (Item, Error);
         if Policy.Command_Allowed (Item.State.Phase, Record_Failure) then
            Apply (Item, Record_Failure);
         end if;
         if Item.State.Has_Candidate then
            Cleanup_Slot (Item.Slots (Item.Candidate_Slot));
            Item.State.Has_Candidate := False;
         end if;
         if Ada.Exceptions.Exception_Identity (Error) = Stale_Authority'Identity
           or else Ada.Exceptions.Exception_Identity (Error) = Invalid_Phase'Identity
           or else Ada.Exceptions.Exception_Identity (Error)
                   = Flyology.Cancellation.Operation_Cancelled'Identity
         then
            Ada.Exceptions.Reraise_Occurrence (Error);
         else
            raise Upgrade_Error with Ada.Exceptions.Exception_Message (Error);
         end if;
   end Begin_Canary;

   procedure Cancel
     (Item         : in out Coordinator;
      Authority    : Upgrade_Handle;
      Compensation : out Compensation_Result;
      Timeout      : Duration := 30.0)
   is
      Started    : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Frame      : Protocol.Frame;
      Result     : Messages.Decode_Result;
      Was_Canary : Boolean;
      Mutated    : Boolean := False;
   begin
      Compensation := Not_Required;
      Reconcile_Exited (Item);
      Require_Authority (Item, Authority);
      if Item.State.Phase not in Prepared | Canary then
         raise Invalid_Phase with "candidate cannot be cancelled in this phase";
      end if;
      Was_Canary := Item.State.Phase = Canary;
      Apply (Item, Cancel_Upgrade);
      Mutated := True;
      if Was_Canary then
         Item.State.Compensation := Compensation_Pending;
      end if;
      Transport.Send
        (Item.Slots (Item.Candidate_Slot).Control,
         Protocol.Cancel_Message,
         Timeout => Remaining (Started, Timeout));
      if Was_Canary then
         if not Transport.Message_Available
                  (Item.Slots (Item.Candidate_Slot).Control, Remaining (Started, Timeout))
         then
            raise Flyology.IO.Timeout_Error with "candidate revocation deadline expired";
         end if;
         Transport.Receive (Item.Slots (Item.Candidate_Slot).Control, Frame, Remaining (Started, Timeout));
         if Frame.Kind = Protocol.Ready_Message then
            --  Readiness and cancellation may cross after the coordinator's
            --  non-consuming cancellation wake. The queued Cancel still wins.
            Validate_Proof (Frame, Item.Slots (Item.Candidate_Slot).Provision);
            Expect
              (Item.Slots (Item.Candidate_Slot),
               Protocol.Admission_Revoked_Message,
               Frame,
               Remaining (Started, Timeout));
         elsif Frame.Kind /= Protocol.Admission_Revoked_Message then
            if Frame.Kind = Protocol.Failure_Message then
               raise Upgrade_Error with Agent_Failure_Message (Frame);
            end if;
            raise Upgrade_Error with "candidate returned an invalid revocation response";
         end if;
         Item.State.Candidate_Admitted := False;
         Apply (Item, Admission_Revoked);
         Expect
           (Item.Slots (Item.Candidate_Slot), Protocol.Drained_Message, Frame, Remaining (Started, Timeout));
         Apply (Item, Candidate_Drained);
         Expect
           (Item.Slots (Item.Candidate_Slot),
            Protocol.Compensation_Message,
            Frame,
            Remaining (Started, Timeout));
         Messages.Decode_Compensation (Frame.Payload, Frame.Length, Compensation, Result);
         if Result /= Messages.Decoded then
            raise Upgrade_Error with "invalid compensation result";
         end if;
         Item.State.Compensation := Compensation;
         Apply (Item, Compensation_Finished);
      else
         Expect
           (Item.Slots (Item.Candidate_Slot), Protocol.Acknowledgment, Frame, Remaining (Started, Timeout));
         Apply (Item, Candidate_Stopped);
      end if;
      Wait_And_Release (Item.Slots (Item.Candidate_Slot), Remaining (Started, Timeout));
      Item.State.Has_Candidate := False;
      Item.State.Candidate_Ready := False;
      Item.State.Candidate_Admitted := False;
   exception
      when Error : others =>
         if not Mutated then
            Ada.Exceptions.Reraise_Occurrence (Error);
         end if;
         Record_Failure (Item, Error);
         if Policy.Command_Allowed (Item.State.Phase, Record_Failure) then
            Apply (Item, Record_Failure);
         end if;
         if Item.State.Has_Candidate then
            Cleanup_Slot (Item.Slots (Item.Candidate_Slot));
            Item.State.Has_Candidate := False;
         end if;
         if Ada.Exceptions.Exception_Identity (Error) = Stale_Authority'Identity
           or else Ada.Exceptions.Exception_Identity (Error) = Invalid_Phase'Identity
         then
            Ada.Exceptions.Reraise_Occurrence (Error);
         else
            raise Upgrade_Error with Ada.Exceptions.Exception_Message (Error);
         end if;
   end Cancel;

   procedure Promote (Item : in out Coordinator; Authority : Upgrade_Handle; Timeout : Duration := 30.0) is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Frame        : Protocol.Frame;
      Previous     : constant Slot_Index := Item.Active_Slot;
      Had_Previous : Boolean;
      Mutated      : Boolean := False;
   begin
      Reconcile_Exited (Item);
      Require_Authority (Item, Authority);
      if Item.State.Phase /= Canary or else not Item.State.Candidate_Ready then
         raise Invalid_Phase with "candidate is not ready for promotion";
      end if;
      Had_Previous := Item.State.Has_Active;
      if Had_Previous then
         --  Retain the artifact and desired topology, not the old runtime.
         --  They are sufficient to construct a fresh reversal generation.
         Item.Rollback_Artifact := Item.Slots (Previous).Artifact;
         Item.Rollback_Provision := Item.Slots (Previous).Provision;
         Item.State.Rollback_Available := True;
      end if;
      Apply (Item, Promote_Upgrade);
      Mutated := True;
      Transport.Send
        (Item.Slots (Item.Candidate_Slot).Control,
         Protocol.Promote_Message,
         Timeout => Remaining (Started, Timeout));
      Expect (Item.Slots (Item.Candidate_Slot), Protocol.Acknowledgment, Frame, Remaining (Started, Timeout));
      Apply (Item, Previous_Drain_Started);
      if Had_Previous then
         Transport.Send
           (Item.Slots (Previous).Control, Protocol.Drain_Message, Timeout => Remaining (Started, Timeout));
         Expect (Item.Slots (Previous), Protocol.Drained_Message, Frame, Remaining (Started, Timeout));
         Wait_And_Release (Item.Slots (Previous), Remaining (Started, Timeout));
      end if;
      Apply (Item, Previous_Drained);
      Item.Active_Slot := Item.Candidate_Slot;
      Item.State.Has_Active := True;
      Item.State.Active_Generation := Authority.Candidate;
      Item.State.Has_Candidate := False;
      Item.State.Candidate_Admitted := False;
      Item.State.Candidate_Ready := False;
      Apply (Item, Commit_Finished);
   exception
      when Error : others =>
         if not Mutated then
            Ada.Exceptions.Reraise_Occurrence (Error);
         end if;
         Record_Failure (Item, Error);
         if Policy.Command_Allowed (Item.State.Phase, Require_Rollback) then
            Apply (Item, Require_Rollback);
         end if;
         if Ada.Exceptions.Exception_Identity (Error) = Stale_Authority'Identity
           or else Ada.Exceptions.Exception_Identity (Error) = Invalid_Phase'Identity
         then
            Ada.Exceptions.Reraise_Occurrence (Error);
         else
            raise Upgrade_Error with Ada.Exceptions.Exception_Message (Error);
         end if;
   end Promote;

   procedure Start_Initial
     (Item       : in out Coordinator;
      Executable : Flyology.Subprocesses.Command;
      Provision  : Messages.Provisioning_Data;
      Authority  : out Upgrade_Handle;
      Timeout    : Duration := 30.0;
      Token      : access Flyology.Cancellation.Token := null)
   is
      Started      : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Compensation : Compensation_Result;
   begin
      Start_Upgrade (Item, Executable, Provision, Authority, Timeout, Token);
      Begin_Canary (Item, Authority, Remaining (Started, Timeout), Token);
      if Token /= null and then Token.Requested then
         Cancel (Item, Authority, Compensation, Remaining (Started, Timeout));
         raise Flyology.Cancellation.Operation_Cancelled;
      end if;
      Promote (Item, Authority, Remaining (Started, Timeout));
   end Start_Initial;

   procedure Rollback_To_Previous
     (Item : in out Coordinator; Authority : out Upgrade_Handle; Timeout : Duration := 30.0)
   is
      Started           : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Target_Artifact   : constant Flyology.Subprocesses.Command := Item.Rollback_Artifact;
      Target_Provision  : constant Messages.Provisioning_Data := Item.Rollback_Provision;
      Forward_Available : Boolean := False;
      Forward_Artifact  : Flyology.Subprocesses.Command;
      Forward_Provision : Messages.Provisioning_Data := Target_Provision;
      Frame             : Protocol.Frame;
      Reversal_Started  : Boolean := False;
   begin
      Authority := (Coordinator => 1, Upgrade => 1, Candidate => 1);
      Reconcile_Exited (Item);
      Forward_Available := Item.State.Has_Candidate or else Item.State.Has_Active;
      if not Item.State.Initialized then
         raise Program_Error with "process-generation coordinator is closed";
      elsif not Item.State.Rollback_Available then
         raise Invalid_Phase with "no previous image artifact is retained";
      elsif Item.State.Phase not in Completed | Rollback_Required then
         raise Invalid_Phase with "rollback requires a completed or uncertain promotion";
      end if;
      Reversal_Started := True;

      if Item.State.Has_Candidate then
         Forward_Artifact := Item.Slots (Item.Candidate_Slot).Artifact;
         Forward_Provision := Item.Slots (Item.Candidate_Slot).Provision;
      elsif Item.State.Has_Active then
         Forward_Artifact := Item.Slots (Item.Active_Slot).Artifact;
         Forward_Provision := Item.Slots (Item.Active_Slot).Provision;
      end if;

      --  An uncertain promotion can leave either image accepting. Retire all
      --  owned generations before introducing the fresh rollback generation.
      for Index in Item.Slots'Range loop
         if Item.Slots (Index).Occupied then
            begin
               if Transport.Is_Open (Item.Slots (Index).Control) then
                  Transport.Send
                    (Item.Slots (Index).Control,
                     Protocol.Drain_Message,
                     Timeout => Remaining (Started, Timeout));
                  Expect (Item.Slots (Index), Protocol.Drained_Message, Frame, Remaining (Started, Timeout));
                  Wait_And_Release (Item.Slots (Index), Remaining (Started, Timeout));
               else
                  Cleanup_Slot (Item.Slots (Index));
               end if;
            exception
               when others =>
                  --  Process.Close is the conservative fencing boundary when
                  --  cooperative drain cannot be acknowledged.
                  Cleanup_Slot (Item.Slots (Index));
            end;
         end if;
      end loop;

      Item.State.Phase := Stable;
      Item.State.Has_Active := False;
      Item.State.Has_Candidate := False;
      Item.State.Candidate_Ready := False;
      Item.State.Candidate_Admitted := False;
      Item.State.Compensation := Not_Required;
      Item.State.Failure_Size := 0;
      Item.State.Failure := (others => ' ');

      Start_Initial (Item, Target_Artifact, Target_Provision, Authority, Remaining (Started, Timeout));
      Item.State.Rollback_Available := Forward_Available;
      if Forward_Available then
         Item.Rollback_Artifact := Forward_Artifact;
         Item.Rollback_Provision := Forward_Provision;
      end if;
   exception
      when others =>
         if Reversal_Started then
            Item.State.Phase := Rollback_Required;
         end if;
         raise;
   end Rollback_To_Previous;

   procedure Shutdown (Item : in out Coordinator; Timeout : Duration := 30.0) is
      Failed  : Boolean := False;
      Failure : Ada.Exceptions.Exception_Occurrence;
      Frame   : Protocol.Frame;
   begin
      if not Item.State.Initialized then
         return;
      end if;
      Reconcile_Exited (Item);
      for Index in Item.Slots'Range loop
         if Item.Slots (Index).Occupied then
            declare
               Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
            begin
               begin
                  if Transport.Is_Open (Item.Slots (Index).Control) then
                     Transport.Send
                       (Item.Slots (Index).Control,
                        Protocol.Drain_Message,
                        Timeout => Remaining (Started, Timeout));
                     Expect
                       (Item.Slots (Index), Protocol.Drained_Message, Frame, Remaining (Started, Timeout));
                     Wait_And_Release (Item.Slots (Index), Remaining (Started, Timeout));
                  else
                     Cleanup_Slot (Item.Slots (Index));
                  end if;
               exception
                  when Error : others =>
                     if not Failed then
                        Ada.Exceptions.Save_Occurrence (Failure, Error);
                        Failed := True;
                     end if;
                     Cleanup_Slot (Item.Slots (Index));
               end;
            end;
         end if;
      end loop;
      if Sockets.Is_Open (Item.Listener) then
         begin
            Sockets.Close_Socket (Item.Listener);
         exception
            when Error : others =>
               if not Failed then
                  Ada.Exceptions.Save_Occurrence (Failure, Error);
                  Failed := True;
               end if;
         end;
      end if;
      Item.State.Initialized := False;
      Item.State.Phase := Stable;
      Item.State.Has_Active := False;
      Item.State.Has_Candidate := False;
      if Failed then
         raise Upgrade_Error with Ada.Exceptions.Exception_Message (Failure);
      end if;
   end Shutdown;

   overriding
   procedure Finalize (Item : in out Coordinator) is
   begin
      for Index in Item.Slots'Range loop
         Cleanup_Slot (Item.Slots (Index));
      end loop;
      if Sockets.Is_Open (Item.Listener) then
         begin
            Sockets.Close_Socket (Item.Listener);
         exception
            when others =>
               null;
         end;
      end if;
      Item.State.Initialized := False;
   exception
      when others =>
         null;
   end Finalize;
end Flyology.Process_Generations.Coordinators;
