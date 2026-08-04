with Ada.Unchecked_Deallocation;

package body Flyology.Buffers is
   use type Interfaces.Unsigned_64;

   procedure Free is new Ada.Unchecked_Deallocation
     (Ada.Streams.Stream_Element_Array, Storage_Access);

   protected body Pool_State is
      procedure Allocate (Slot : out Natural; Version : out Generation) is
         Selected : Positive;
      begin
         if Free_Count > 0 then
            Selected := Positive (Free_Slots (Free_Count));
            Free_Slots (Free_Count) := No_Slot;
            Free_Count := Free_Count - 1;
         else
            Selected := Positive (Next_Unused);
            Next_Unused := Next_Unused + 1;
         end if;

         if Versions (Selected) = Generation'Last then
            raise Program_Error with "buffer generation space exhausted";
         end if;
         Versions (Selected) := Versions (Selected) + 1;
         In_Use (Selected) := True;
         Used_Count := Used_Count + 1;
         Slot := Selected;
         Version := Versions (Selected);
      end Allocate;

      entry Acquire (Slot : out Natural; Version : out Generation)
        when Free_Count > 0 or else Next_Unused <= Slot_Count
      is
      begin
         Allocate (Slot, Version);
      end Acquire;

      procedure Try_Acquire
        (Slot     : out Natural;
         Version  : out Generation;
         Acquired : out Boolean)
      is
      begin
         if Free_Count = 0 and then Next_Unused > Slot_Count then
            Slot := No_Slot;
            Version := No_Generation;
            Acquired := False;
            return;
         end if;
         Allocate (Slot, Version);
         Acquired := True;
      end Try_Acquire;

      procedure Release (Slot : Positive; Version : Generation) is
      begin
         if Slot > Slot_Count
           or else not In_Use (Slot)
           or else Versions (Slot) /= Version
         then
            raise Program_Error with "invalid or stale buffer ownership";
         end if;
         In_Use (Slot) := False;
         Used_Count := Used_Count - 1;
         Free_Count := Free_Count + 1;
         Free_Slots (Free_Count) := Slot;
      end Release;

      function Current return Pool_Snapshot is
        (Available   => Free_Count + Slot_Count - Next_Unused + 1,
         Outstanding => Used_Count);
   end Pool_State;

   type Attach_Guard
     (Target : not null access Unique_Buffer;
      Token  : not null access Buffer_Token) is
     new Ada.Finalization.Limited_Controlled with null record;

   overriding procedure Finalize (Item : in out Attach_Guard) is
   begin
      if Item.Token.Slot /= No_Slot
        and then not Owns (Item.Target.all, Item.Token.all)
      then
         Release_Token (Item.Target.Owner, Item.Token.all);
      end if;
   end Finalize;

   type Release_Guard
     (Owner : not null access Pool) is
     new Ada.Finalization.Limited_Controlled with record
      Token : Buffer_Token := No_Token;
   end record;

   overriding procedure Finalize (Item : in out Release_Guard) is
   begin
      Release_Token (Item.Owner, Item.Token);
   end Finalize;

   function Has_Buffer (Item : Unique_Buffer) return Boolean is
     (Item.Token.Slot /= No_Slot);

   function Length (Item : Unique_Buffer) return Natural is
     (Item.Token.Length);

   function Buffer_Capacity (Item : Unique_Buffer) return Positive is
     (Item.Owner.Block_Size);

   procedure Acquire (Item : in out Unique_Buffer) is
      Token : aliased Buffer_Token := No_Token;
      Guard : Attach_Guard (Item'Unchecked_Access, Token'Access);
      pragma Unreferenced (Guard);
   begin
      if Has_Buffer (Item) then
         raise Program_Error with "acquire into an occupied buffer";
      end if;
      Item.Owner.State.Acquire (Token.Slot, Token.Version);
      Attach (Item, Token);
   end Acquire;

   procedure Try_Acquire
     (Item     : in out Unique_Buffer;
      Acquired : out Boolean)
   is
      Token   : aliased Buffer_Token := No_Token;
      Guard   : Attach_Guard (Item'Unchecked_Access, Token'Access);
      pragma Unreferenced (Guard);
   begin
      if Has_Buffer (Item) then
         raise Program_Error with "acquire into an occupied buffer";
      end if;
      Item.Owner.State.Try_Acquire
        (Token.Slot, Token.Version, Acquired);
      if Acquired then
         Attach (Item, Token);
      end if;
   end Try_Acquire;

   procedure Acquire_For
     (Item    : in out Unique_Buffer;
      Timeout : Duration)
   is
      Acquired_Token : aliased Buffer_Token := No_Token;
      Guard : Attach_Guard
        (Item'Unchecked_Access, Acquired_Token'Access);
      pragma Unreferenced (Guard);
      Acquired : Boolean;
   begin
      if Has_Buffer (Item) then
         raise Program_Error with "acquire into an occupied buffer";
      elsif Timeout < 0.0 then
         Acquire (Item);
      elsif Timeout = 0.0 then
         Try_Acquire (Item, Acquired);
         if not Acquired then
            raise Timeout_Error with "buffer acquisition timed out";
         end if;
      else
         select
            Item.Owner.State.Acquire
              (Acquired_Token.Slot, Acquired_Token.Version);
            Attach (Item, Acquired_Token);
         or
            delay Timeout;
            raise Timeout_Error with "buffer acquisition timed out";
         end select;
      end if;
   end Acquire_For;

   procedure Release (Item : in out Unique_Buffer) is
      Guard : Release_Guard (Item.Owner);
   begin
      if Has_Buffer (Item) then
         Detach (Item, Guard.Token);
      end if;
   end Release;

   procedure Move
     (Source : in out Unique_Buffer;
      Target : in out Unique_Buffer)
   is
      Token : aliased Buffer_Token := No_Token;
      Guard : Attach_Guard (Source'Unchecked_Access, Token'Access);
      pragma Unreferenced (Guard);
   begin
      if Source.Owner /= Target.Owner then
         raise Program_Error with "buffers belong to different pools";
      elsif not Has_Buffer (Source) then
         raise Program_Error with "move from a vacant buffer";
      elsif Has_Buffer (Target) then
         raise Program_Error with "move into an occupied buffer";
      end if;
      Detach (Source, Token);
      Attach (Target, Token);
   end Move;

   procedure Set_Tag
     (Item  : in out Unique_Buffer;
      Value : Interfaces.Unsigned_64) is
   begin
      if not Has_Buffer (Item) then
         raise Program_Error with "tag update on a vacant buffer";
      end if;
      Item.Token.Tag := Value;
   end Set_Tag;

   function Tag (Item : Unique_Buffer) return Interfaces.Unsigned_64 is
     (Item.Token.Tag);

   function First_Offset (Item : Unique_Buffer) return Storage_Offset is
     (Storage_Offset (Item.Token.Slot - 1)
      * Storage_Offset (Item.Owner.Block_Size) + 1);

   procedure With_Readable_Data
     (Item    : Unique_Buffer;
      Process : not null access procedure
        (Data : Ada.Streams.Stream_Element_Array))
   is
   begin
      if not Has_Buffer (Item) then
         raise Program_Error with "read borrow from a vacant buffer";
      end if;
      declare
         First : constant Storage_Offset := First_Offset (Item);
         Last  : constant Storage_Offset :=
           First + Storage_Offset (Item.Token.Length) - 1;
      begin
         Process.all (Item.Owner.Data.all (First .. Last));
      end;
   end With_Readable_Data;

   procedure With_Writable_Data
     (Item    : in out Unique_Buffer;
      Process : not null access procedure
        (Data   : in out Ada.Streams.Stream_Element_Array;
         Length : in out Natural))
   is
      New_Length : Natural;
   begin
      if not Has_Buffer (Item) then
         raise Program_Error with "write borrow from a vacant buffer";
      end if;
      New_Length := Item.Token.Length;
      declare
         First : constant Storage_Offset := First_Offset (Item);
         Last  : constant Storage_Offset :=
           First + Storage_Offset (Item.Owner.Block_Size) - 1;
      begin
         Process.all (Item.Owner.Data.all (First .. Last), New_Length);
      end;
      if New_Length > Item.Owner.Block_Size then
         raise Constraint_Error with "buffer length exceeds capacity";
      end if;
      Item.Token.Length := New_Length;
   end With_Writable_Data;

   procedure Copy_From
     (Item : in out Unique_Buffer;
      Data : Ada.Streams.Stream_Element_Array)
   is
      procedure Copy
        (Target : in out Ada.Streams.Stream_Element_Array;
         Count  : in out Natural)
      is
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

   function Current (Item : Pool) return Pool_Snapshot is
     (Item.State.Current);

   overriding procedure Initialize (Item : in out Pool) is
      Last : constant Storage_Offset :=
        Storage_Offset (Item.Block_Size) * Storage_Offset (Item.Capacity);
   begin
      Item.Data := new Ada.Streams.Stream_Element_Array (1 .. Last);
   end Initialize;

   overriding procedure Finalize (Item : in out Pool) is
   begin
      if Item.State.Current.Outstanding /= 0 then
         raise Program_Error with "buffer pool finalized with live buffers";
      end if;
      Free (Item.Data);
   end Finalize;

   function Owns
     (Item  : Unique_Buffer;
      Token : Buffer_Token) return Boolean is
     (Token.Slot /= No_Slot
      and then Item.Token.Slot = Token.Slot
      and then Item.Token.Version = Token.Version);

   procedure Detach
     (Item  : in out Unique_Buffer;
      Token : out Buffer_Token) is
   begin
      if not Has_Buffer (Item) then
         raise Program_Error with "detach from a vacant buffer";
      end if;
      Token := Item.Token;
      Item.Token := No_Token;
   end Detach;

   procedure Attach
     (Item  : in out Unique_Buffer;
      Token : in out Buffer_Token) is
   begin
      if Has_Buffer (Item) then
         raise Program_Error with "attach to an occupied buffer";
      elsif Token.Slot = No_Slot
        or else Token.Slot > Item.Owner.Capacity
        or else Token.Length > Item.Owner.Block_Size
      then
         raise Program_Error with "invalid buffer token";
      end if;
      Item.Token := Token;
      Token := No_Token;
   end Attach;

   procedure Release_Token
     (Owner : not null access Pool;
      Token : in out Buffer_Token) is
   begin
      if Token.Slot /= No_Slot then
         Owner.State.Release (Positive (Token.Slot), Token.Version);
         Token := No_Token;
      end if;
   end Release_Token;

   overriding procedure Finalize (Item : in out Unique_Buffer) is
   begin
      if Has_Buffer (Item) then
         Item.Owner.State.Release
           (Positive (Item.Token.Slot), Item.Token.Version);
         Item.Token := No_Token;
      end if;
   end Finalize;

end Flyology.Buffers;
