with Flyology.Buffer_Test_Hooks;

package body Flyology.Buffers.Domains.Drivers is

   procedure Reserve
     (Claim  : in out Reservation_Claim;
      Pool   : Pool_Reference;
      Result : out Reservation_Result)
   is
   begin
      if Has_Reservation (Claim) then
         raise Program_Error with "reserve into an occupied reservation claim";
      end if;
      declare
         Holder      : constant Pool_Holder_Access := Resolve (Claim.Domain.all, Pool);
         Snapshot    : constant Pool_Snapshot := Current (Holder.Storage);
         Acquired    : Boolean;
         In_Use      : Boolean;
         Force_Final : Boolean := False;
      begin
         if Flyology.Buffer_Test_Hooks.Enabled then
            Force_Final :=
              Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Reservation_Final_Generation;
         end if;
         Holder.Gate.Try_Reserve
           (Pool,
            Snapshot.Outstanding = 0,
            Force_Final,
            Claim.Reference'Access,
            Acquired,
            In_Use);
         if Flyology.Buffer_Test_Hooks.Enabled and then Force_Final and then not Acquired then
            Flyology.Buffer_Test_Hooks.Arm_Next_Domain_Reservation_Final_Generation;
         end if;
         if Acquired then
            if Flyology.Buffer_Test_Hooks.Enabled
              and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Reservation_Publication_Failure
            then
               raise Program_Error with "injected reservation publication failure";
            end if;
            Result := Reservation_Acquired;
         elsif In_Use then
            Result := Reservation_In_Use;
         else
            Result := Reservation_Generation_Exhausted;
         end if;
      end;
   end Reserve;

   function Has_Reservation (Claim : Reservation_Claim) return Boolean
   is (Is_Valid (Claim.Reference));

   procedure Commit_Reservation
     (Claim : in out Reservation_Claim; Target : aliased in out Pool_Reservation)
   is
   begin
      if not Has_Reservation (Claim) then
         raise Program_Error with "commit from a vacant reservation claim";
      elsif Is_Valid (Target) then
         raise Program_Error with "commit into an occupied reservation target";
      end if;
      Resolve (Claim.Domain.all, Reserved_Pool (Claim.Reference)).Gate.Commit_Reservation
        (Claim.Reference'Access, Target'Access);
   end Commit_Reservation;

   procedure Rollback_Reservation
     (Domain : not null access Buffer_Domain; Target : aliased in out Pool_Reservation)
   is
   begin
      if Is_Valid (Target) then
         Resolve (Domain.all, Reserved_Pool (Target)).Gate.Rollback_Reservation (Target'Access);
      end if;
   end Rollback_Reservation;

   overriding
   procedure Finalize (Claim : in out Reservation_Claim) is
   begin
      if Has_Reservation (Claim) then
         Resolve (Claim.Domain.all, Reserved_Pool (Claim.Reference)).Gate.Rollback_Reservation
           (Claim.Reference'Access);
      end if;
   end Finalize;

   procedure Prepare_Release
     (Token       : in out Reservation_Release;
      Reservation : Pool_Reservation;
      Result      : out Release_Preparation_Result)
   is
      Holder   : Pool_Holder_Access;
      Snapshot : Pool_Snapshot;
      Prepared : Boolean;
      Live     : Boolean;
      Old      : Boolean;
   begin
      if Has_Release (Token) then
         raise Program_Error with "prepare into an occupied reservation release token";
      elsif not Is_Valid (Reservation) then
         raise Program_Error with "prepare of an invalid reservation";
      end if;
      Holder := Resolve (Token.Domain.all, Reserved_Pool (Reservation));
      Snapshot := Current (Holder.Storage);
      Holder.Gate.Prepare_Release
        (Reservation,
         Snapshot.Outstanding = 0,
         Token.Reference'Access,
         Prepared,
         Live,
         Old);
      if Prepared then
         if Flyology.Buffer_Test_Hooks.Enabled
           and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Prepare_Release_Publication_Failure
         then
            raise Program_Error with "injected release preparation publication failure";
         end if;
         Result := Release_Prepared;
      elsif Live then
         Result := Live_Claims_Remain;
      elsif Old then
         Result := Release_Already_Acknowledged;
      else
         raise Program_Error with "incomplete reservation release classification";
      end if;
   end Prepare_Release;

   function Has_Release (Token : Reservation_Release) return Boolean
   is (Is_Valid (Token.Reference));

   function Matches
     (Token : Reservation_Release; Reservation : Pool_Reservation) return Boolean
   is (Has_Release (Token) and then Token.Reference = Reservation);

   function Is_Authorized (Token : Reservation_Release) return Boolean
   is (Has_Release (Token) and then Token.Ack_Authorized);

   procedure Authorize
     (Token : in out Reservation_Release; Reservation : Pool_Reservation) is
   begin
      if not Matches (Token, Reservation) then
         raise Program_Error with "release token does not match retiring reservation";
      end if;
      Token.Ack_Authorized := True;
   end Authorize;

   procedure Acknowledge (Token : in out Reservation_Release) is
      Holder : Pool_Holder_Access;
   begin
      if not Has_Release (Token) or else not Token.Ack_Authorized then
         raise Program_Error with "acknowledge of a vacant or unauthorized release token";
      end if;
      Holder := Resolve (Token.Domain.all, Reserved_Pool (Token.Reference));
      Holder.Gate.Acknowledge (Token.Reference'Access, Token.Ack_Authorized);
      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Acknowledge_Post_Commit_Failure
      then
         raise Program_Error with "injected reservation acknowledgment post-commit failure";
      end if;
      Token.Ack_Authorized := False;
   end Acknowledge;

   overriding
   procedure Finalize (Token : in out Reservation_Release) is
   begin
      if Has_Release (Token) and then Token.Ack_Authorized then
         begin
            Acknowledge (Token);
         exception
            when others =>
               null;
         end;
      end if;
      Token.Reference := Invalid_Reservation;
      Token.Ack_Authorized := False;
   end Finalize;

   function Active_Claims
     (Domain : not null access Buffer_Domain; Pool : Pool_Reference) return Natural
   is (Resolve (Domain.all, Pool).Gate.Claim_Count);

   type Owned_Restore_Guard (Source : not null access Owned_Buffer)
   is new Ada.Finalization.Limited_Controlled with record
      Reference   : aliased Pool_Reference := Invalid_Pool;
      Reservation : aliased Pool_Reservation := Invalid_Reservation;
      Token       : aliased Buffer_Token := No_Token;
   end record;

   overriding
   procedure Finalize (Guard : in out Owned_Restore_Guard) is
   begin
      if Guard.Token.Slot /= No_Slot then
         Guard.Source.Reference := Guard.Reference;
         Guard.Source.Reservation := Guard.Reservation;
         Guard.Source.Token := Guard.Token;
         Guard.Reference := Invalid_Pool;
         Guard.Reservation := Invalid_Reservation;
         Guard.Token := No_Token;
      end if;
   end Finalize;

   type Capability_Restore_Guard
     (Domain : not null access Buffer_Domain;
      Source : not null access Buffer_Capability)
   is new Ada.Finalization.Limited_Controlled with record
      Reference   : aliased Pool_Reference := Invalid_Pool;
      Reservation : aliased Pool_Reservation := Invalid_Reservation;
      Token       : aliased Buffer_Token := No_Token;
   end record;

   overriding
   procedure Finalize (Guard : in out Capability_Restore_Guard) is
   begin
      if Guard.Token.Slot /= No_Slot then
         Guard.Source.Reference := Guard.Reference;
         Guard.Source.Reservation := Guard.Reservation;
         Guard.Source.Token := Guard.Token;
         Guard.Reference := Invalid_Pool;
         Guard.Reservation := Invalid_Reservation;
         Guard.Token := No_Token;
      end if;
   end Finalize;

   type Release_Guard (Domain : not null access Buffer_Domain)
   is new Ada.Finalization.Limited_Controlled with record
      Reference   : aliased Pool_Reference := Invalid_Pool;
      Reservation : aliased Pool_Reservation := Invalid_Reservation;
      Token       : aliased Buffer_Token := No_Token;
   end record;

   overriding
   procedure Finalize (Guard : in out Release_Guard) is
   begin
      if Is_Valid (Guard.Reference) then
         begin
            Release_Token
              (Guard.Domain.all,
               Guard.Reference'Access,
               Guard.Reservation'Access,
               Guard.Token'Access);
         exception
            when others =>
               null;
         end;
         Guard.Reference := Invalid_Pool;
         Guard.Reservation := Invalid_Reservation;
         Guard.Token := No_Token;
      end if;
   end Finalize;

   procedure Disarm (Guard : in out Release_Guard) is
   begin
      Guard.Reference := Invalid_Pool;
      Guard.Reservation := Invalid_Reservation;
      Guard.Token := No_Token;
   end Disarm;

   function Has_Buffer (Item : Buffer_Capability) return Boolean
   is (Item.Token.Slot /= No_Slot);

   function Belongs_To
     (Domain : not null access Buffer_Domain; Item : Buffer_Capability) return Boolean
   is (Has_Buffer (Item) and then Domains.Belongs_To (Domain.all, Item.Reference));

   procedure Commit_Prevalidated_From_Owned
     (Source : in out Owned_Buffer;
      Target : in out Buffer_Capability)
   is
   begin
      Target.Reference := Source.Reference;
      Target.Reservation := Source.Reservation;
      Target.Token := Source.Token;
      Source.Reference := Invalid_Pool;
      Source.Reservation := Invalid_Reservation;
      Source.Token := No_Token;
   end Commit_Prevalidated_From_Owned;

   procedure Commit_Prevalidated_Move
     (Source : in out Buffer_Capability;
      Target : in out Buffer_Capability)
   is
   begin
      Target.Reference := Source.Reference;
      Target.Reservation := Source.Reservation;
      Target.Token := Source.Token;
      Source.Reference := Invalid_Pool;
      Source.Reservation := Invalid_Reservation;
      Source.Token := No_Token;
   end Commit_Prevalidated_Move;

   procedure Validate
     (Domain : not null access Buffer_Domain; Item : Buffer_Capability)
   is
   begin
      if not Has_Buffer (Item) then
         raise Program_Error with "operation on a vacant buffer capability";
      elsif not Belongs_To (Domain, Item) then
         raise Program_Error with "buffer capability belongs to a different domain";
      elsif Resolve_Ownership (Domain.all, Item.Reference, Item.Reservation) = null then
         raise Program_Error with "buffer capability ownership is not current";
      elsif Item.Token.Slot > Domains.Capacity (Domain.all, Item.Reference)
        or else Item.Token.Length > Domains.Block_Size (Domain.all, Item.Reference)
      then
         raise Program_Error with "invalid buffer capability token";
      end if;
   end Validate;

   procedure Move_From
     (Domain : not null access Buffer_Domain;
      Item   : in out Owned_Buffer;
      Target : in out Buffer_Capability)
   is
      Guard : Owned_Restore_Guard (Item'Unchecked_Access);
   begin
      if Item.Domain /= Domain then
         raise Program_Error with "public buffer belongs to a different domain";
      elsif not Domains.Has_Buffer (Item) then
         raise Program_Error with "move from a vacant domain buffer";
      elsif Has_Buffer (Target) then
         raise Program_Error with "move into an occupied buffer capability";
      end if;

      Guard.Reference := Item.Reference;
      Guard.Reservation := Item.Reservation;
      Guard.Token := Item.Token;
      Item.Reference := Invalid_Pool;
      Item.Reservation := Invalid_Reservation;
      Item.Token := No_Token;

      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Transfer_Failure
      then
         raise Program_Error with "injected buffer domain transfer failure";
      end if;

      Commit_Transfer
        (Guard.Reference'Access,
         Guard.Reservation'Access,
         Guard.Token'Access,
         Target.Reference'Access,
         Target.Reservation'Access,
         Target.Token'Access);
      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Transfer_Post_Commit_Failure
      then
         raise Program_Error with "injected buffer domain post-commit failure";
      end if;
   end Move_From;

   procedure Move_To
     (Domain : not null access Buffer_Domain;
      Source : aliased in out Buffer_Capability;
      Item   : in out Owned_Buffer)
   is
      Guard : Capability_Restore_Guard (Domain, Source'Access);
   begin
      Validate (Domain, Source);
      if Item.Domain /= Domain then
         raise Program_Error with "public buffer belongs to a different domain";
      elsif Domains.Has_Buffer (Item) then
         raise Program_Error with "move into an occupied domain buffer";
      end if;

      Guard.Reference := Source.Reference;
      Guard.Reservation := Source.Reservation;
      Guard.Token := Source.Token;
      Source.Reference := Invalid_Pool;
      Source.Reservation := Invalid_Reservation;
      Source.Token := No_Token;

      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Transfer_Failure
      then
         raise Program_Error with "injected buffer domain transfer failure";
      end if;

      Commit_Transfer
        (Guard.Reference'Access,
         Guard.Reservation'Access,
         Guard.Token'Access,
         Item.Reference'Access,
         Item.Reservation'Access,
         Item.Token'Access);
      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Transfer_Post_Commit_Failure
      then
         raise Program_Error with "injected buffer domain post-commit failure";
      end if;
   end Move_To;

   procedure Move
     (Domain : not null access Buffer_Domain;
      Source : aliased in out Buffer_Capability;
      Target : in out Buffer_Capability)
   is
      Guard : Capability_Restore_Guard (Domain, Source'Access);
   begin
      Validate (Domain, Source);
      if Has_Buffer (Target) then
         raise Program_Error with "move into an occupied buffer capability";
      end if;

      Guard.Reference := Source.Reference;
      Guard.Reservation := Source.Reservation;
      Guard.Token := Source.Token;
      Source.Reference := Invalid_Pool;
      Source.Reservation := Invalid_Reservation;
      Source.Token := No_Token;

      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Transfer_Failure
      then
         raise Program_Error with "injected buffer domain transfer failure";
      end if;

      Commit_Transfer
        (Guard.Reference'Access,
         Guard.Reservation'Access,
         Guard.Token'Access,
         Target.Reference'Access,
         Target.Reservation'Access,
         Target.Token'Access);
      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Transfer_Post_Commit_Failure
      then
         raise Program_Error with "injected buffer domain post-commit failure";
      end if;
   end Move;

   procedure Release
     (Domain : not null access Buffer_Domain; Item : aliased in out Buffer_Capability)
   is
      Guard : Release_Guard (Domain);
   begin
      if not Has_Buffer (Item) then
         return;
      end if;
      Validate (Domain, Item);
      Commit_Transfer
        (Item.Reference'Access,
         Item.Reservation'Access,
         Item.Token'Access,
         Guard.Reference'Access,
         Guard.Reservation'Access,
         Guard.Token'Access);
      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Release_Failure
      then
         raise Program_Error with "injected buffer domain capability release failure";
      end if;
      Release_Token
        (Domain.all,
         Guard.Reference'Access,
         Guard.Reservation'Access,
         Guard.Token'Access);
      Disarm (Guard);
      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Release_Post_Commit_Failure
      then
         raise Program_Error with "injected buffer domain capability release post-commit failure";
      end if;
   end Release;

   function Buffer_Pool
     (Domain : not null access Buffer_Domain; Item : Buffer_Capability) return Pool_Reference
   is
   begin
      Validate (Domain, Item);
      return Item.Reference;
   end Buffer_Pool;

   function Buffer_Reservation
     (Domain : not null access Buffer_Domain; Item : Buffer_Capability)
      return Pool_Reservation
   is
   begin
      Validate (Domain, Item);
      return Item.Reservation;
   end Buffer_Reservation;

   function Length
     (Domain : not null access Buffer_Domain; Item : Buffer_Capability) return Natural
   is
   begin
      Validate (Domain, Item);
      return Item.Token.Length;
   end Length;

   function Capacity
     (Domain : not null access Buffer_Domain; Item : Buffer_Capability) return Positive
   is
   begin
      Validate (Domain, Item);
      return Domains.Block_Size (Domain.all, Item.Reference);
   end Capacity;

   procedure With_Readable_Data
     (Domain  : not null access Buffer_Domain;
      Item    : Buffer_Capability;
      Process : not null access procedure (Data : Ada.Streams.Stream_Element_Array))
   is
   begin
      Validate (Domain, Item);
      Observe (Domain.all, Item.Reference, Item.Reservation, Item.Token, Process);
   end With_Readable_Data;

end Flyology.Buffers.Domains.Drivers;
