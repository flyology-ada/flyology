with Flyology.Buffers;
with Flyology.HTTP.Server.WebSocket_Handlers;

procedure WebSocket_Pool_Lifetime_Fail is
   package Buffers renames Flyology.Buffers;
   package WebSockets renames Flyology.HTTP.Server.WebSocket_Handlers;

   type Session_Access is access all WebSockets.Session;
   Item : Session_Access;

   procedure Allocate_From_Inner_Pool is
      Storage : aliased Buffers.Pool (Block_Size => 16, Capacity => 1);
   begin
      Item := new WebSockets.Session
        (Capacity    => 1,
         Byte_Limit  => 16,
         Budget      => null,
         Buffer_Pool => Storage'Access);
   end Allocate_From_Inner_Pool;
begin
   Allocate_From_Inner_Pool;
end WebSocket_Pool_Lifetime_Fail;
