with Ada.Unchecked_Deallocation;
with Flyology.Buffer_Test_Hooks;

package body Flyology.Buffers.Domains is
   use type Interfaces.Unsigned_64;

   protected Identity_Source is
      procedure Allocate (Identity : out Domain_Identity);
   private
      Next      : Domain_Identity := 1;
      Exhausted : Boolean := False;
   end Identity_Source;

   protected body Reservation_Gate is
      procedure Begin_Claim
        (Requested         : Pool_Reservation;
         Source            : Pool_Reference;
         Claim_Reference   : not null access Pool_Reference;
         Claim_Reservation : not null access Pool_Reservation;
         Result            : out Acquisition_Result)
      is
      begin
         if Is_Valid (Claim_Reference.all) or else Is_Valid (Claim_Reservation.all) then
            raise Program_Error with "buffer acquisition guard is already occupied";
         elsif not Is_Valid (Requested) then
            case Lifecycle is
               when Available =>
                  if Claims = Maximum_Claims then
                     Result := Claim_Limit_Reached;
                  else
                     Claims := Claims + 1;
                     Claim_Reference.all := Source;
                     Result := Buffer_Acquired;
                  end if;
               when Reserved =>
                  Result := Pool_Reserved;
               when Released_Pending_Ack =>
                  Result := Reservation_Releasing;
               when Permanently_Exhausted =>
                  Result := Pool_Permanently_Exhausted;
            end case;
            return;
         end if;

         if Requested.Pool /= Source then
            raise Program_Error with "reservation does not name the acquisition pool";
         elsif Requested.Generation < Generation then
            Result := Reservation_Stale;
            return;
         elsif Requested.Generation > Generation then
            raise Program_Error with "future buffer pool reservation generation";
         end if;

         case Lifecycle is
            when Available =>
               Result := Reservation_Not_Active;
            when Reserved =>
               if Claims = Maximum_Claims then
                  Result := Claim_Limit_Reached;
               else
                  Claims := Claims + 1;
                  Claim_Reference.all := Source;
                  Claim_Reservation.all := Requested;
                  Result := Buffer_Acquired;
               end if;
            when Released_Pending_Ack =>
               Result := Reservation_Releasing;
            when Permanently_Exhausted =>
               Result := Pool_Permanently_Exhausted;
         end case;
      end Begin_Claim;

      procedure End_Claim
        (Reference   : not null access Pool_Reference;
         Reservation : not null access Pool_Reservation)
      is
      begin
         if not Is_Valid (Reference.all) or else Claims = 0 then
            raise Program_Error with "invalid buffer acquisition claim release";
         elsif Is_Valid (Reservation.all) then
            if Reservation.Pool /= Reference.all
              or else Reservation.Generation /= Generation
              or else Lifecycle /= Reserved
            then
               raise Program_Error with "stale buffer reservation claim release";
            end if;
         elsif Lifecycle /= Available then
            raise Program_Error with "ordinary buffer claim crossed a reservation boundary";
         end if;
         Claims := Claims - 1;
         Reference.all := Invalid_Pool;
         Reservation.all := Invalid_Reservation;
      end End_Claim;

      procedure Try_Reserve
        (Reference  : Pool_Reference;
         Base_Empty : Boolean;
         Force_Final_Generation : Boolean;
         Target     : not null access Pool_Reservation;
         Reserved_Result : out Boolean;
         In_Use     : out Boolean)
      is
      begin
         if Is_Valid (Target.all) then
            raise Program_Error with "reservation claim is already occupied";
         end if;
         Reserved_Result := False;
         In_Use := False;
         case Lifecycle is
            when Available =>
               if Claims /= 0 or else not Base_Empty then
                  In_Use := True;
               else
                  if Flyology.Buffer_Test_Hooks.Enabled and then Force_Final_Generation then
                     Generation := Reservation_Generation'Last;
                  end if;
                  Lifecycle := Reserved;
                  Target.all := (Pool => Reference, Generation => Generation);
                  Reserved_Result := True;
               end if;
            when Reserved | Released_Pending_Ack =>
               In_Use := True;
            when Permanently_Exhausted =>
               null;
         end case;
      end Try_Reserve;

      procedure Commit_Reservation
        (Source : not null access Pool_Reservation;
         Target : not null access Pool_Reservation)
      is
      begin
         if not Is_Valid (Source.all)
           or else Is_Valid (Target.all)
           or else Source.Generation /= Generation
           or else Lifecycle /= Reserved
         then
            raise Program_Error with "invalid reservation publication";
         end if;
         Target.all := Source.all;
         Source.all := Invalid_Reservation;
      end Commit_Reservation;

      procedure Rollback_Reservation (Target : not null access Pool_Reservation) is
      begin
         if not Is_Valid (Target.all) then
            return;
         elsif Target.Generation /= Generation
           or else Lifecycle /= Reserved
           or else Claims /= 0
         then
            raise Program_Error with "reservation rollback crossed an active lifecycle";
         end if;
         Lifecycle := Available;
         Target.all := Invalid_Reservation;
      end Rollback_Reservation;

      procedure Prepare_Release
        (Source     : Pool_Reservation;
         Base_Empty : Boolean;
         Target     : not null access Pool_Reservation;
         Prepared   : out Boolean;
         Live_Claims : out Boolean;
         Already_Acknowledged : out Boolean)
      is
      begin
         if Is_Valid (Target.all) then
            raise Program_Error with "reservation release token is already occupied";
         end if;
         Prepared := False;
         Live_Claims := False;
         Already_Acknowledged := False;
         if Source.Generation < Generation then
            Already_Acknowledged := True;
            return;
         elsif Source.Generation > Generation then
            raise Program_Error with "future reservation release generation";
         end if;

         case Lifecycle is
            when Available =>
               raise Program_Error with "unknown current reservation release";
            when Reserved =>
               if Claims /= 0 or else not Base_Empty then
                  Live_Claims := True;
               else
                  Lifecycle := Released_Pending_Ack;
                  Target.all := Source;
                  Prepared := True;
               end if;
            when Released_Pending_Ack =>
               if Claims /= 0 then
                  raise Program_Error with "pending release retained buffer claims";
               elsif not Base_Empty then
                  Live_Claims := True;
               else
                  Target.all := Source;
                  Prepared := True;
               end if;
            when Permanently_Exhausted =>
               Already_Acknowledged := True;
         end case;
      end Prepare_Release;

      procedure Acknowledge
        (Target : not null access Pool_Reservation; Authorized : Boolean)
      is
      begin
         if not Authorized or else not Is_Valid (Target.all) then
            raise Program_Error with "unauthorized or vacant reservation acknowledgment";
         elsif Target.Generation < Generation then
            Target.all := Invalid_Reservation;
            return;
         elsif Target.Generation > Generation then
            raise Program_Error with "future reservation acknowledgment generation";
         end if;

         case Lifecycle is
            when Released_Pending_Ack =>
               if Claims /= 0 then
                  raise Program_Error with "reservation acknowledgment retained live claims";
               elsif Generation = Reservation_Generation'Last then
                  Lifecycle := Permanently_Exhausted;
               else
                  Generation := Generation + 1;
                  Lifecycle := Available;
               end if;
               Target.all := Invalid_Reservation;
            when Permanently_Exhausted =>
               Target.all := Invalid_Reservation;
            when Available | Reserved =>
               raise Program_Error with "reservation acknowledgment is not pending";
         end case;
      end Acknowledge;

      function Valid_Claim (Reservation : Pool_Reservation) return Boolean
      is
        (Claims /= 0
         and then
           (if Is_Valid (Reservation)
            then Lifecycle = Reserved and then Reservation.Generation = Generation
            else Lifecycle = Available));

      function State return Reservation_State
      is (Lifecycle);

      function Claim_Count return Natural
      is (Claims);
   end Reservation_Gate;

   protected body Identity_Source is
      procedure Allocate (Identity : out Domain_Identity) is
      begin
         if Exhausted then
            raise Program_Error with "buffer domain identity space exhausted";
         end if;
         Identity := Next;
         if Next = Domain_Identity'Last then
            Exhausted := True;
         else
            Next := Next + 1;
         end if;
      end Allocate;
   end Identity_Source;

   procedure Free is new Ada.Unchecked_Deallocation (Pool_Holder, Pool_Holder_Access);

   type Owned_Move_Guard (Source : not null access Owned_Buffer)
   is new Ada.Finalization.Limited_Controlled with record
      Reference   : aliased Pool_Reference := Invalid_Pool;
      Reservation : aliased Pool_Reservation := Invalid_Reservation;
      Token       : aliased Buffer_Token := No_Token;
   end record;

   overriding
   procedure Finalize (Guard : in out Owned_Move_Guard) is
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

   protected type Transfer_Committer is
      procedure Commit
        (Source_Reference : not null access Pool_Reference;
         Source_Reservation : not null access Pool_Reservation;
         Source_Token     : not null access Buffer_Token;
         Target_Reference : not null access Pool_Reference;
         Target_Reservation : not null access Pool_Reservation;
         Target_Token     : not null access Buffer_Token);
   end Transfer_Committer;

   protected body Transfer_Committer is
      procedure Commit
        (Source_Reference : not null access Pool_Reference;
         Source_Reservation : not null access Pool_Reservation;
         Source_Token     : not null access Buffer_Token;
         Target_Reference : not null access Pool_Reference;
         Target_Reservation : not null access Pool_Reservation;
         Target_Token     : not null access Buffer_Token)
      is
      begin
         Target_Reference.all := Source_Reference.all;
         Target_Reservation.all := Source_Reservation.all;
         Target_Token.all := Source_Token.all;
         Source_Reference.all := Invalid_Pool;
         Source_Reservation.all := Invalid_Reservation;
         Source_Token.all := No_Token;
      end Commit;
   end Transfer_Committer;

   procedure Commit_Transfer
     (Source_Reference : not null access Pool_Reference;
      Source_Reservation : not null access Pool_Reservation;
      Source_Token     : not null access Buffer_Token;
      Target_Reference : not null access Pool_Reference;
      Target_Reservation : not null access Pool_Reservation;
      Target_Token     : not null access Buffer_Token)
   is
      Committer : Transfer_Committer;
   begin
      Committer.Commit
        (Source_Reference,
         Source_Reservation,
         Source_Token,
         Target_Reference,
         Target_Reservation,
         Target_Token);
   end Commit_Transfer;

   type Acquisition_Claim_Guard (Domain : not null access Buffer_Domain)
   is new Ada.Finalization.Limited_Controlled with record
      Reference   : aliased Pool_Reference := Invalid_Pool;
      Reservation : aliased Pool_Reservation := Invalid_Reservation;
   end record;

   overriding
   procedure Finalize (Guard : in out Acquisition_Claim_Guard) is
   begin
      if Is_Valid (Guard.Reference) then
         Resolve (Guard.Domain.all, Guard.Reference).Gate.End_Claim
           (Guard.Reference'Access, Guard.Reservation'Access);
      end if;
   end Finalize;

   type Acquisition_Kind is (Blocking_Acquisition, Immediate_Acquisition, Timed_Acquisition);

   type Domain_Release_Guard (Domain : not null access Buffer_Domain)
   is new Ada.Finalization.Limited_Controlled with record
      Reference   : aliased Pool_Reference := Invalid_Pool;
      Reservation : aliased Pool_Reservation := Invalid_Reservation;
      Token       : aliased Buffer_Token := No_Token;
   end record;

   overriding
   procedure Finalize (Guard : in out Domain_Release_Guard) is
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
      end if;
   end Finalize;

   function Create (Configuration : Pool_Configuration_Array) return Buffer_Domain is
      Source : Positive := Configuration'First;
   begin
      if Configuration'Length = 0 then
         raise Constraint_Error with "buffer domain requires at least one pool";
      end if;
      for Item of Configuration loop
         if Item.Maximum_Claims < Item.Capacity then
            raise Constraint_Error with "buffer pool maximum claims is smaller than capacity";
         end if;
      end loop;

      return Result : Buffer_Domain (Configuration'Length) do
         for Target in Result.Pools'Range loop
            if Flyology.Buffer_Test_Hooks.Enabled
              and then Flyology.Buffer_Test_Hooks.Consume_Domain_Allocation_Failure
            then
               raise Storage_Error with "injected buffer domain allocation failure";
            end if;
            Result.Pools (Target) :=
              new Pool_Holder
                (Block_Size => Configuration (Source).Block_Size,
                 Capacity   => Configuration (Source).Capacity,
                 Maximum_Claims => Configuration (Source).Maximum_Claims);
            if Flyology.Buffer_Test_Hooks.Enabled then
               Flyology.Buffer_Test_Hooks.Note_Domain_Pool_Allocated;
            end if;
            if Target /= Result.Pools'Last then
               Source := Source + 1;
            end if;
         end loop;
      end return;
   end Create;

   function Is_Valid (Reference : Pool_Reference) return Boolean
   is (Reference.Domain /= No_Domain
       and then Reference.Slot /= 0
       and then Reference.Generation /= No_Catalogue_Generation);

   function Is_Valid (Reservation : Pool_Reservation) return Boolean
   is (Is_Valid (Reservation.Pool)
       and then Reservation.Generation /= No_Reservation_Generation);

   function Reserved_Pool (Reservation : Pool_Reservation) return Pool_Reference
   is (if Is_Valid (Reservation) then Reservation.Pool else Invalid_Pool);

   function Pool_Count (Domain : Buffer_Domain) return Positive
   is (Domain.Number_Of_Pools);

   function Pool_At (Domain : Buffer_Domain; Index : Positive) return Pool_Reference is
   begin
      if Index > Domain.Number_Of_Pools then
         raise Constraint_Error with "buffer pool index is outside domain";
      end if;
      return
        (Domain     => Domain.Identity,
         Slot       => Index,
         Generation => Initial_Catalogue_Generation);
   end Pool_At;

   function Belongs_To (Domain : Buffer_Domain; Reference : Pool_Reference) return Boolean
   is (Domain.Identity /= No_Domain
       and then Reference.Domain = Domain.Identity
       and then Reference.Slot in Domain.Pools'Range
       and then Reference.Generation = Initial_Catalogue_Generation
       and then Domain.Pools (Reference.Slot) /= null);

   function Resolve
     (Domain : Buffer_Domain; Reference : Pool_Reference) return Pool_Holder_Access
   is
   begin
      if not Belongs_To (Domain, Reference) then
         raise Program_Error with "buffer pool reference does not belong to domain";
      end if;
      return Domain.Pools (Reference.Slot);
   end Resolve;

   function Block_Size (Domain : Buffer_Domain; Reference : Pool_Reference) return Positive
   is (Resolve (Domain, Reference).Block_Size);

   function Capacity (Domain : Buffer_Domain; Reference : Pool_Reference) return Positive
   is (Resolve (Domain, Reference).Capacity);

   function Current (Domain : Buffer_Domain; Reference : Pool_Reference) return Pool_Snapshot
   is (Flyology.Buffers.Current (Resolve (Domain, Reference).Storage));

   function Resolve_Ownership
     (Domain      : Buffer_Domain;
      Reference   : Pool_Reference;
      Reservation : Pool_Reservation) return Pool_Holder_Access
   is
      Holder : constant Pool_Holder_Access := Resolve (Domain, Reference);
   begin
      if Is_Valid (Reservation) and then Reservation.Pool /= Reference then
         raise Program_Error with "buffer ownership reservation does not match its pool";
      elsif not Holder.Gate.Valid_Claim (Reservation) then
         raise Program_Error with "buffer ownership claim is not current";
      end if;
      return Holder;
   end Resolve_Ownership;

   function Has_Buffer (Item : Owned_Buffer) return Boolean
   is (Item.Token.Slot /= No_Slot);

   function Buffer_Pool (Item : Owned_Buffer) return Pool_Reference
   is (if Has_Buffer (Item) then Item.Reference else Invalid_Pool);

   function Buffer_Reservation (Item : Owned_Buffer) return Pool_Reservation
   is (if Has_Buffer (Item) then Item.Reservation else Invalid_Reservation);

   function Length (Item : Owned_Buffer) return Natural
   is (Item.Token.Length);

   function Buffer_Capacity (Item : Owned_Buffer) return Positive
   is (Resolve_Ownership (Item.Domain.all, Item.Reference, Item.Reservation).Block_Size);

   procedure Acquire_Core
     (Item        : in out Owned_Buffer;
      Source      : Pool_Reference;
      Reservation : Pool_Reservation;
      Qualified   : Boolean;
      Kind        : Acquisition_Kind;
      Timeout     : Duration;
      Result      : out Acquisition_Result)
   is
   begin
      if Has_Buffer (Item) then
         raise Program_Error with "acquire into an occupied domain buffer";
      elsif Qualified and then not Is_Valid (Reservation) then
         raise Program_Error with "invalid buffer pool reservation";
      end if;

      declare
         Holder : constant Pool_Holder_Access := Resolve (Item.Domain.all, Source);
         Guard  : Acquisition_Claim_Guard (Item.Domain);
         Buffer : Unique_Buffer (Holder.Storage'Access);
         Acquired : Boolean;
      begin
         if Qualified and then Reservation.Pool /= Source then
            raise Program_Error with "buffer reservation belongs to a different pool";
         end if;
         Holder.Gate.Begin_Claim
           (Reservation,
            Source,
            Guard.Reference'Access,
            Guard.Reservation'Access,
            Result);
         if Result /= Buffer_Acquired then
            return;
         end if;

         case Kind is
            when Blocking_Acquisition =>
               Flyology.Buffers.Acquire (Buffer);
            when Immediate_Acquisition =>
               Flyology.Buffers.Try_Acquire (Buffer, Acquired);
               if not Acquired then
                  Result := Pool_Empty;
                  return;
               end if;
            when Timed_Acquisition =>
               begin
                  Flyology.Buffers.Acquire_For (Buffer, Timeout);
               exception
                  when Timeout_Error =>
                     Result := Acquisition_Timed_Out;
                     return;
               end;
         end case;

         if Flyology.Buffer_Test_Hooks.Enabled
           and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Acquisition_Pre_Commit_Failure
         then
            raise Program_Error with "injected buffer domain acquisition pre-commit failure";
         end if;
         Commit_Transfer
           (Guard.Reference'Access,
            Guard.Reservation'Access,
            Buffer.Token'Access,
            Item.Reference'Access,
            Item.Reservation'Access,
            Item.Token'Access);
         if Flyology.Buffer_Test_Hooks.Enabled
           and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Acquisition_Post_Commit_Failure
         then
            raise Program_Error with "injected buffer domain acquisition post-commit failure";
         end if;
         Result := Buffer_Acquired;
      end;
   end Acquire_Core;

   procedure Acquire
     (Item : in out Owned_Buffer; Source : Pool_Reference; Result : out Acquisition_Result) is
   begin
      Acquire_Core
        (Item, Source, Invalid_Reservation, False, Blocking_Acquisition, 0.0, Result);
   end Acquire;

   procedure Acquire
     (Item        : in out Owned_Buffer;
      Reservation : Pool_Reservation;
      Result      : out Acquisition_Result) is
   begin
      Acquire_Core
        (Item,
         Reserved_Pool (Reservation),
         Reservation,
         True,
         Blocking_Acquisition,
         0.0,
         Result);
   end Acquire;

   procedure Try_Acquire
     (Item : in out Owned_Buffer; Source : Pool_Reference; Result : out Acquisition_Result) is
   begin
      Acquire_Core
        (Item, Source, Invalid_Reservation, False, Immediate_Acquisition, 0.0, Result);
   end Try_Acquire;

   procedure Try_Acquire
     (Item        : in out Owned_Buffer;
      Reservation : Pool_Reservation;
      Result      : out Acquisition_Result) is
   begin
      Acquire_Core
        (Item,
         Reserved_Pool (Reservation),
         Reservation,
         True,
         Immediate_Acquisition,
         0.0,
         Result);
   end Try_Acquire;

   procedure Acquire_For
     (Item    : in out Owned_Buffer;
      Source  : Pool_Reference;
      Timeout : Duration;
      Result  : out Acquisition_Result) is
   begin
      Acquire_Core
        (Item, Source, Invalid_Reservation, False, Timed_Acquisition, Timeout, Result);
   end Acquire_For;

   procedure Acquire_For
     (Item        : in out Owned_Buffer;
      Reservation : Pool_Reservation;
      Timeout     : Duration;
      Result      : out Acquisition_Result) is
   begin
      Acquire_Core
        (Item,
         Reserved_Pool (Reservation),
         Reservation,
         True,
         Timed_Acquisition,
         Timeout,
         Result);
   end Acquire_For;

   procedure Release_Token
     (Domain      : in out Buffer_Domain;
      Reference   : not null access Pool_Reference;
      Reservation : not null access Pool_Reservation;
      Token       : not null access Buffer_Token)
   is
      Holder : constant Pool_Holder_Access :=
        Resolve_Ownership (Domain, Reference.all, Reservation.all);
   begin
      if Token.Slot /= No_Slot then
         Flyology.Buffers.Release_Token (Holder.Storage'Access, Token);
         if Flyology.Buffer_Test_Hooks.Enabled
           and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Release_Claim_Gap_Failure
         then
            raise Program_Error with "injected failure after buffer pool release commit";
         end if;
      end if;
      Holder.Gate.End_Claim (Reference, Reservation);
   end Release_Token;

   procedure Release (Item : in out Owned_Buffer) is
   begin
      if Has_Buffer (Item) then
         declare
            Holder : constant Pool_Holder_Access :=
              Resolve_Ownership (Item.Domain.all, Item.Reference, Item.Reservation);
            Guard  : Domain_Release_Guard (Item.Domain);
            pragma Unreferenced (Holder);
         begin
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
               raise Program_Error with "injected buffer domain release failure";
            end if;
            Release_Token
              (Item.Domain.all,
               Guard.Reference'Access,
               Guard.Reservation'Access,
               Guard.Token'Access);
            if Flyology.Buffer_Test_Hooks.Enabled
              and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Release_Post_Commit_Failure
            then
               raise Program_Error with "injected buffer domain release post-commit failure";
            end if;
         end;
      end if;
   end Release;

   procedure Move (Source : in out Owned_Buffer; Target : in out Owned_Buffer) is
      Guard : Owned_Move_Guard (Source'Unchecked_Access);
   begin
      if Source.Domain /= Target.Domain then
         raise Program_Error with "domain buffers belong to different domains";
      elsif not Has_Buffer (Source) then
         raise Program_Error with "move from a vacant domain buffer";
      elsif Has_Buffer (Target) then
         raise Program_Error with "move into an occupied domain buffer";
      end if;

      Guard.Reference := Source.Reference;
      Guard.Reservation := Source.Reservation;
      Guard.Token := Source.Token;
      Source.Reference := Invalid_Pool;
      Source.Reservation := Invalid_Reservation;
      Source.Token := No_Token;

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

   procedure Set_Tag (Item : in out Owned_Buffer; Value : Interfaces.Unsigned_64) is
   begin
      if not Has_Buffer (Item) then
         raise Program_Error with "tag update on a vacant domain buffer";
      end if;
      Item.Token.Tag := Value;
   end Set_Tag;

   function Tag (Item : Owned_Buffer) return Interfaces.Unsigned_64
   is (Item.Token.Tag);

   function First_Offset
     (Holder : Pool_Holder; Token : Buffer_Token) return Ada.Streams.Stream_Element_Offset
   is (Ada.Streams.Stream_Element_Offset (Token.Slot - 1)
       * Ada.Streams.Stream_Element_Offset (Holder.Block_Size)
       + 1);

   procedure Observe
     (Domain    : Buffer_Domain;
      Reference : Pool_Reference;
      Reservation : Pool_Reservation;
      Token     : Buffer_Token;
      Process   : not null access procedure (Data : Ada.Streams.Stream_Element_Array))
   is
      Holder : constant Pool_Holder_Access := Resolve_Ownership (Domain, Reference, Reservation);
      First  : Ada.Streams.Stream_Element_Offset;
      Last   : Ada.Streams.Stream_Element_Offset;
   begin
      if Token.Slot = No_Slot
        or else Token.Slot > Holder.Capacity
        or else Token.Length > Holder.Block_Size
      then
         raise Program_Error with "invalid domain buffer token";
      end if;
      First := First_Offset (Holder.all, Token);
      Last := First + Ada.Streams.Stream_Element_Offset (Token.Length) - 1;
      Process.all (Holder.Storage.Data.all (First .. Last));
   end Observe;

   procedure With_Readable_Data
     (Item : Owned_Buffer; Process : not null access procedure (Data : Ada.Streams.Stream_Element_Array)) is
   begin
      if not Has_Buffer (Item) then
         raise Program_Error with "read borrow from a vacant domain buffer";
      end if;
      Observe (Item.Domain.all, Item.Reference, Item.Reservation, Item.Token, Process);
   end With_Readable_Data;

   procedure With_Writable_Data
     (Item    : in out Owned_Buffer;
      Process :
        not null access procedure (Data : in out Ada.Streams.Stream_Element_Array; Length : in out Natural))
   is
      Holder     : constant Pool_Holder_Access :=
        Resolve_Ownership (Item.Domain.all, Item.Reference, Item.Reservation);
      New_Length : Natural := Item.Token.Length;
      First      : Ada.Streams.Stream_Element_Offset;
      Last       : Ada.Streams.Stream_Element_Offset;
   begin
      if not Has_Buffer (Item) then
         raise Program_Error with "write borrow from a vacant domain buffer";
      elsif Item.Token.Slot > Holder.Capacity or else Item.Token.Length > Holder.Block_Size then
         raise Program_Error with "invalid domain buffer token";
      end if;
      First := First_Offset (Holder.all, Item.Token);
      Last := First + Ada.Streams.Stream_Element_Offset (Holder.Block_Size) - 1;
      Process.all (Holder.Storage.Data.all (First .. Last), New_Length);
      if New_Length > Holder.Block_Size then
         raise Constraint_Error with "buffer length exceeds capacity";
      end if;
      Item.Token.Length := New_Length;
   end With_Writable_Data;

   procedure Copy_From (Item : in out Owned_Buffer; Data : Ada.Streams.Stream_Element_Array) is
      procedure Copy (Target : in out Ada.Streams.Stream_Element_Array; Count : in out Natural) is
         Cursor : Ada.Streams.Stream_Element_Offset := Target'First;
      begin
         if Data'Length > Target'Length then
            raise Constraint_Error with "payload exceeds buffer capacity";
         end if;
         for Element of Data loop
            Target (Cursor) := Element;
            Cursor := Cursor + 1;
         end loop;
         Count := Data'Length;
      end Copy;
   begin
      With_Writable_Data (Item, Copy'Access);
   end Copy_From;

   overriding
   procedure Initialize (Domain : in out Buffer_Domain) is
   begin
      Identity_Source.Allocate (Domain.Identity);
   end Initialize;

   overriding
   procedure Finalize (Domain : in out Buffer_Domain) is
   begin
      for Holder of Domain.Pools loop
         if Holder /= null then
            if Current (Holder.Storage).Outstanding /= 0
              or else Holder.Gate.Claim_Count /= 0
            then
               raise Program_Error with "buffer domain finalized with live buffers";
            elsif Holder.Gate.State in Reserved | Released_Pending_Ack then
               raise Program_Error with "buffer domain finalized with a live reservation";
            end if;
         end if;
      end loop;
      for Index in reverse Domain.Pools'Range loop
         if Domain.Pools (Index) /= null then
            Free (Domain.Pools (Index));
            if Flyology.Buffer_Test_Hooks.Enabled then
               Flyology.Buffer_Test_Hooks.Note_Domain_Pool_Freed;
            end if;
         end if;
      end loop;
      Domain.Identity := No_Domain;
   end Finalize;

   overriding
   procedure Finalize (Item : in out Owned_Buffer) is
   begin
      Release (Item);
   end Finalize;

end Flyology.Buffers.Domains;
