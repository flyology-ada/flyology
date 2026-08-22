package body Flyology.Buffers.Drivers is

   function Has_Buffer (Item : Detached_Buffer) return Boolean is
     (Item.Owner /= null and then Item.Token.Slot /= No_Slot);

   function Same_Pool
     (Source : Detached_Buffer;
      Target : Unique_Buffer) return Boolean is
     (Has_Buffer (Source) and then Source.Owner = Target.Owner);

   procedure Move_From
     (Item   : in out Unique_Buffer;
      Target : in out Detached_Buffer)
   is
   begin
      if not Flyology.Buffers.Has_Buffer (Item) then
         raise Program_Error with "move from a vacant buffer";
      elsif Has_Buffer (Target) then
         raise Program_Error with "move into an occupied detached buffer";
      end if;
      Target.Owner := Item.Owner.all'Unchecked_Access;
      Detach (Item, Target.Token);
   end Move_From;

   procedure Move_To
     (Source : in out Detached_Buffer;
      Item   : in out Unique_Buffer)
   is
   begin
      if not Has_Buffer (Source) then
         raise Program_Error with "move from a vacant detached buffer";
      elsif Flyology.Buffers.Has_Buffer (Item) then
         raise Program_Error with "move into an occupied buffer";
      elsif Source.Owner /= Item.Owner then
         raise Program_Error with "buffers belong to different pools";
      end if;
      Attach (Item, Source.Token);
      Source.Owner := null;
   end Move_To;

   procedure Move
     (Source : in out Detached_Buffer;
      Target : in out Detached_Buffer)
   is
   begin
      if not Has_Buffer (Source) then
         raise Program_Error with "move from a vacant detached buffer";
      elsif Has_Buffer (Target) then
         raise Program_Error with "move into an occupied detached buffer";
      end if;
      Target.Owner := Source.Owner;
      Target.Token := Source.Token;
      Source.Token := No_Token;
      Source.Owner := null;
   end Move;

   procedure Release (Item : in out Detached_Buffer) is
   begin
      if Has_Buffer (Item) then
         Release_Token (Item.Owner, Item.Token);
         Item.Owner := null;
      end if;
   end Release;

   procedure Set_Channel_Metadata
     (Item  : in out Detached_Buffer;
      Value : Interfaces.Unsigned_64)
   is
   begin
      if not Has_Buffer (Item) then
         raise Program_Error with "metadata on a vacant detached buffer";
      end if;
      Item.Token.Channel_Metadata := Value;
   end Set_Channel_Metadata;

   function Channel_Metadata
     (Item : Detached_Buffer) return Interfaces.Unsigned_64 is
     (Item.Token.Channel_Metadata);

   function Address (Item : Detached_Buffer) return System.Address is
      First : constant Storage_Offset :=
        Storage_Offset (Item.Token.Slot - 1)
        * Storage_Offset (Item.Owner.Block_Size) + 1;
   begin
      return Item.Owner.Data.all (First)'Address;
   end Address;

   function Capacity (Item : Detached_Buffer) return Positive is
     (Item.Owner.Block_Size);

   function Length (Item : Detached_Buffer) return Natural is
     (Item.Token.Length);

   procedure Set_Length
     (Item   : in out Detached_Buffer;
      Length : Natural)
   is
   begin
      if Length > Item.Owner.Block_Size then
         raise Constraint_Error with "buffer length exceeds capacity";
      end if;
      Item.Token.Length := Length;
   end Set_Length;

   overriding procedure Finalize (Item : in out Detached_Buffer) is
   begin
      Release (Item);
   end Finalize;

end Flyology.Buffers.Drivers;
