with Ada.Finalization;
with Flyology.Buffer_Test_Hooks;

package body Flyology.Buffers.Domains.Drivers is

   type Owned_Restore_Guard (Source : not null access Owned_Buffer)
   is new Ada.Finalization.Limited_Controlled with record
      Reference : aliased Pool_Reference := Invalid_Pool;
      Token     : aliased Buffer_Token := No_Token;
   end record;

   overriding
   procedure Finalize (Guard : in out Owned_Restore_Guard) is
   begin
      if Guard.Token.Slot /= No_Slot then
         Guard.Source.Reference := Guard.Reference;
         Guard.Source.Token := Guard.Token;
         Guard.Reference := Invalid_Pool;
         Guard.Token := No_Token;
      end if;
   end Finalize;

   type Capability_Restore_Guard
     (Domain : not null access Buffer_Domain;
      Source : not null access Buffer_Capability)
   is new Ada.Finalization.Limited_Controlled with record
      Reference : aliased Pool_Reference := Invalid_Pool;
      Token     : aliased Buffer_Token := No_Token;
   end record;

   overriding
   procedure Finalize (Guard : in out Capability_Restore_Guard) is
   begin
      if Guard.Token.Slot /= No_Slot then
         Guard.Source.Reference := Guard.Reference;
         Guard.Source.Token := Guard.Token;
         Guard.Reference := Invalid_Pool;
         Guard.Token := No_Token;
      end if;
   end Finalize;

   type Release_Guard (Domain : not null access Buffer_Domain)
   is new Ada.Finalization.Limited_Controlled with record
      Reference : aliased Pool_Reference := Invalid_Pool;
      Token     : aliased Buffer_Token := No_Token;
   end record;

   overriding
   procedure Finalize (Guard : in out Release_Guard) is
   begin
      if Guard.Token.Slot /= No_Slot then
         begin
            Release_Token (Guard.Domain.all, Guard.Reference, Guard.Token);
         exception
            when others =>
               null;
         end;
         Guard.Reference := Invalid_Pool;
         Guard.Token := No_Token;
      end if;
   end Finalize;

   procedure Disarm (Guard : in out Release_Guard) is
   begin
      Guard.Reference := Invalid_Pool;
      Guard.Token := No_Token;
   end Disarm;

   function Has_Buffer (Item : Buffer_Capability) return Boolean
   is (Item.Token.Slot /= No_Slot);

   function Belongs_To
     (Domain : not null access Buffer_Domain; Item : Buffer_Capability) return Boolean
   is (Has_Buffer (Item) and then Domains.Belongs_To (Domain.all, Item.Reference));

   procedure Validate
     (Domain : not null access Buffer_Domain; Item : Buffer_Capability)
   is
   begin
      if not Has_Buffer (Item) then
         raise Program_Error with "operation on a vacant buffer capability";
      elsif not Belongs_To (Domain, Item) then
         raise Program_Error with "buffer capability belongs to a different domain";
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
      Guard.Token := Item.Token;
      Item.Reference := Invalid_Pool;
      Item.Token := No_Token;

      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Transfer_Failure
      then
         raise Program_Error with "injected buffer domain transfer failure";
      end if;

      Commit_Transfer
        (Guard.Reference'Access, Guard.Token'Access, Target.Reference'Access, Target.Token'Access);
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
      Guard.Token := Source.Token;
      Source.Reference := Invalid_Pool;
      Source.Token := No_Token;

      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Transfer_Failure
      then
         raise Program_Error with "injected buffer domain transfer failure";
      end if;

      Commit_Transfer
        (Guard.Reference'Access, Guard.Token'Access, Item.Reference'Access, Item.Token'Access);
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
      Guard.Token := Source.Token;
      Source.Reference := Invalid_Pool;
      Source.Token := No_Token;

      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Transfer_Failure
      then
         raise Program_Error with "injected buffer domain transfer failure";
      end if;

      Commit_Transfer
        (Guard.Reference'Access, Guard.Token'Access, Target.Reference'Access, Target.Token'Access);
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
        (Item.Reference'Access, Item.Token'Access, Guard.Reference'Access, Guard.Token'Access);
      if Flyology.Buffer_Test_Hooks.Enabled
        and then Flyology.Buffer_Test_Hooks.Consume_Next_Domain_Release_Failure
      then
         raise Program_Error with "injected buffer domain capability release failure";
      end if;
      Release_Token (Domain.all, Guard.Reference, Guard.Token);
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
      Observe (Domain.all, Item.Reference, Item.Token, Process);
   end With_Readable_Data;

end Flyology.Buffers.Domains.Drivers;
