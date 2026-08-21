with Ada.Finalization;
with Interfaces;
with System;

--  Internal ownership-transfer support for completion-driven providers.
--  @exclude
package Flyology.Buffers.Drivers is

   --  @exclude
   type Detached_Buffer is
     limited new Ada.Finalization.Limited_Controlled with private;

   --  Move an acquired public handle into internal provider storage.
   --  @param Item Acquired source handle, vacant after the move
   --  @param Target Vacant provider-owned destination
   --  @exclude
   procedure Move_From
     (Item   : in out Unique_Buffer;
      Target : in out Detached_Buffer);

   --  Restore provider-owned storage to its original public handle.
   --  @param Source Provider-owned source, vacant after the move
   --  @param Item Vacant destination from the same pool
   --  @exclude
   procedure Move_To
     (Source : in out Detached_Buffer;
      Item   : in out Unique_Buffer);

   --  Move provider-owned storage without exposing its raw token.
   --  @param Source Provider-owned source, vacant after the move
   --  @param Target Vacant provider-owned destination
   --  @exclude
   procedure Move
     (Source : in out Detached_Buffer;
      Target : in out Detached_Buffer);

   --  Release provider-owned storage to its pool.
   --  @param Item Provider-owned storage to release
   --  @exclude
   procedure Release (Item : in out Detached_Buffer);

   --  Set channel-local metadata retained with provider-owned storage.
   --  @param Item Provider-owned storage to update
   --  @param Value Opaque channel metadata
   --  @exclude
   procedure Set_Channel_Metadata
     (Item  : in out Detached_Buffer;
      Value : Interfaces.Unsigned_64);

   --  Return channel-local metadata retained with provider-owned storage.
   --  @param Item Provider-owned storage to inspect
   --  @return Opaque channel metadata
   --  @exclude
   function Channel_Metadata
     (Item : Detached_Buffer) return Interfaces.Unsigned_64;

   --  Report whether provider storage owns a pool token.
   --  @param Item Provider-owned storage
   --  @return True when Item owns a token
   --  @exclude
   function Has_Buffer (Item : Detached_Buffer) return Boolean;

   --  Report whether provider storage and a public handle share a pool.
   --  @param Source Provider-owned storage
   --  @param Target Public handle to compare
   --  @return True when Source owns a token from Target's pool
   --  @exclude
   function Same_Pool
     (Source : Detached_Buffer;
      Target : Unique_Buffer) return Boolean;

   --  Return the first address of provider-owned storage.
   --  @param Item Provider-owned storage
   --  @return Stable first byte address
   --  @exclude
   function Address (Item : Detached_Buffer) return System.Address
     with Pre => Has_Buffer (Item);

   --  Return provider-owned storage capacity.
   --  @param Item Provider-owned storage
   --  @return Pool block capacity
   --  @exclude
   function Capacity (Item : Detached_Buffer) return Positive
     with Pre => Has_Buffer (Item);

   --  Return provider-owned readable length.
   --  @param Item Provider-owned storage
   --  @return Current readable byte length
   --  @exclude
   function Length (Item : Detached_Buffer) return Natural
     with Pre => Has_Buffer (Item);

   --  Set provider-owned readable length.
   --  @param Item Provider-owned storage
   --  @param Length New readable byte length
   --  @exclude
   procedure Set_Length
     (Item   : in out Detached_Buffer;
      Length : Natural)
     with Pre => Has_Buffer (Item) and then Length <= Capacity (Item);

private
   type Pool_Access is access all Pool;

   type Detached_Buffer is
     limited new Ada.Finalization.Limited_Controlled with record
      Owner : Pool_Access := null;
      Token : Buffer_Token := No_Token;
   end record;

   --  Release abandoned provider-owned storage to its pool.
   --  @param Item Provider-owned storage to release
   --  @exclude
   overriding procedure Finalize (Item : in out Detached_Buffer);

end Flyology.Buffers.Drivers;
