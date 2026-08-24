with Ada.Unchecked_Deallocation;
with Flyology.Buffer_Test_Hooks;

package body Flyology.Buffers.Domains is
   protected Identity_Source is
      procedure Allocate (Identity : out Domain_Identity);
   private
      Next      : Domain_Identity := 1;
      Exhausted : Boolean := False;
   end Identity_Source;

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
      Reference : aliased Pool_Reference := Invalid_Pool;
      Token     : aliased Buffer_Token := No_Token;
   end record;

   overriding
   procedure Finalize (Guard : in out Owned_Move_Guard) is
   begin
      if Guard.Token.Slot /= No_Slot then
         Guard.Source.Reference := Guard.Reference;
         Guard.Source.Token := Guard.Token;
         Guard.Reference := Invalid_Pool;
         Guard.Token := No_Token;
      end if;
   end Finalize;

   protected type Transfer_Committer is
      procedure Commit
        (Source_Reference : not null access Pool_Reference;
         Source_Token     : not null access Buffer_Token;
         Target_Reference : not null access Pool_Reference;
         Target_Token     : not null access Buffer_Token);
   end Transfer_Committer;

   protected body Transfer_Committer is
      procedure Commit
        (Source_Reference : not null access Pool_Reference;
         Source_Token     : not null access Buffer_Token;
         Target_Reference : not null access Pool_Reference;
         Target_Token     : not null access Buffer_Token)
      is
      begin
         Target_Reference.all := Source_Reference.all;
         Target_Token.all := Source_Token.all;
         Source_Reference.all := Invalid_Pool;
         Source_Token.all := No_Token;
      end Commit;
   end Transfer_Committer;

   procedure Commit_Transfer
     (Source_Reference : not null access Pool_Reference;
      Source_Token     : not null access Buffer_Token;
      Target_Reference : not null access Pool_Reference;
      Target_Token     : not null access Buffer_Token)
   is
      Committer : Transfer_Committer;
   begin
      Committer.Commit (Source_Reference, Source_Token, Target_Reference, Target_Token);
   end Commit_Transfer;

   function Create (Configuration : Pool_Configuration_Array) return Buffer_Domain is
      Source : Positive := Configuration'First;
   begin
      if Configuration'Length = 0 then
         raise Constraint_Error with "buffer domain requires at least one pool";
      end if;

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
                 Capacity   => Configuration (Source).Capacity);
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

   function Has_Buffer (Item : Owned_Buffer) return Boolean
   is (Item.Token.Slot /= No_Slot);

   function Buffer_Pool (Item : Owned_Buffer) return Pool_Reference
   is (if Has_Buffer (Item) then Item.Reference else Invalid_Pool);

   function Length (Item : Owned_Buffer) return Natural
   is (Item.Token.Length);

   function Buffer_Capacity (Item : Owned_Buffer) return Positive
   is (Block_Size (Item.Domain.all, Item.Reference));

   procedure Acquire (Item : in out Owned_Buffer; Source : Pool_Reference) is
      Holder           : constant Pool_Holder_Access := Resolve (Item.Domain.all, Source);
      Buffer           : Unique_Buffer (Holder.Storage'Access);
      Source_Reference : aliased Pool_Reference := Source;
   begin
      if Has_Buffer (Item) then
         raise Program_Error with "acquire into an occupied domain buffer";
      end if;
      Flyology.Buffers.Acquire (Buffer);
      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Acquisition_Pre_Commit_Failure
      then
         raise Program_Error with "injected buffer domain acquisition pre-commit failure";
      end if;
      Commit_Transfer
        (Source_Reference'Access, Buffer.Token'Access, Item.Reference'Access, Item.Token'Access);
      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Acquisition_Post_Commit_Failure
      then
         raise Program_Error with "injected buffer domain acquisition post-commit failure";
      end if;
   end Acquire;

   procedure Try_Acquire
     (Item : in out Owned_Buffer; Source : Pool_Reference; Acquired : out Boolean)
   is
      Holder           : constant Pool_Holder_Access := Resolve (Item.Domain.all, Source);
      Buffer           : Unique_Buffer (Holder.Storage'Access);
      Source_Reference : aliased Pool_Reference := Source;
   begin
      if Has_Buffer (Item) then
         raise Program_Error with "acquire into an occupied domain buffer";
      end if;
      Flyology.Buffers.Try_Acquire (Buffer, Acquired);
      if Acquired then
         if Flyology.Buffer_Test_Hooks.Enabled
           and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Acquisition_Pre_Commit_Failure
         then
            raise Program_Error with "injected buffer domain try-acquisition pre-commit failure";
         end if;
         Commit_Transfer
           (Source_Reference'Access, Buffer.Token'Access, Item.Reference'Access, Item.Token'Access);
         if Flyology.Buffer_Test_Hooks.Enabled
           and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Acquisition_Post_Commit_Failure
         then
            raise Program_Error with "injected buffer domain try-acquisition post-commit failure";
         end if;
      end if;
   end Try_Acquire;

   procedure Acquire_For (Item : in out Owned_Buffer; Source : Pool_Reference; Timeout : Duration) is
      Holder           : constant Pool_Holder_Access := Resolve (Item.Domain.all, Source);
      Buffer           : Unique_Buffer (Holder.Storage'Access);
      Source_Reference : aliased Pool_Reference := Source;
   begin
      if Has_Buffer (Item) then
         raise Program_Error with "acquire into an occupied domain buffer";
      end if;
      Flyology.Buffers.Acquire_For (Buffer, Timeout);
      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Acquisition_Pre_Commit_Failure
      then
         raise Program_Error with "injected buffer domain timed-acquisition pre-commit failure";
      end if;
      Commit_Transfer
        (Source_Reference'Access, Buffer.Token'Access, Item.Reference'Access, Item.Token'Access);
      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Acquisition_Post_Commit_Failure
      then
         raise Program_Error with "injected buffer domain timed-acquisition post-commit failure";
      end if;
   end Acquire_For;

   procedure Release_Token
     (Domain : in out Buffer_Domain; Reference : Pool_Reference; Token : in out Buffer_Token)
   is
      Holder : constant Pool_Holder_Access := Resolve (Domain, Reference);
   begin
      Flyology.Buffers.Release_Token (Holder.Storage'Access, Token);
   end Release_Token;

   procedure Release (Item : in out Owned_Buffer) is
   begin
      if Has_Buffer (Item) then
         declare
            Holder           : constant Pool_Holder_Access := Resolve (Item.Domain.all, Item.Reference);
            Buffer           : Unique_Buffer (Holder.Storage'Access);
            Target_Reference : aliased Pool_Reference := Invalid_Pool;
         begin
            Commit_Transfer
              (Item.Reference'Access,
               Item.Token'Access,
               Target_Reference'Access,
               Buffer.Token'Access);
            if Flyology.Buffer_Test_Hooks.Enabled
              and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Release_Failure
            then
               raise Program_Error with "injected buffer domain release failure";
            end if;
            Flyology.Buffers.Release (Buffer);
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
      Guard.Token := Source.Token;
      Source.Reference := Invalid_Pool;
      Source.Token := No_Token;

      Commit_Transfer
        (Guard.Reference'Access, Guard.Token'Access, Target.Reference'Access, Target.Token'Access);
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
      Token     : Buffer_Token;
      Process   : not null access procedure (Data : Ada.Streams.Stream_Element_Array))
   is
      Holder : constant Pool_Holder_Access := Resolve (Domain, Reference);
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
      Observe (Item.Domain.all, Item.Reference, Item.Token, Process);
   end With_Readable_Data;

   procedure With_Writable_Data
     (Item    : in out Owned_Buffer;
      Process :
        not null access procedure (Data : in out Ada.Streams.Stream_Element_Array; Length : in out Natural))
   is
      Holder     : constant Pool_Holder_Access := Resolve (Item.Domain.all, Item.Reference);
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
         if Holder /= null and then Current (Holder.Storage).Outstanding /= 0 then
            raise Program_Error with "buffer domain finalized with live buffers";
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
