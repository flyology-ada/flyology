with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Text_IO;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Allocation_Algorithms.Buddy;
with Flyology.Data_Structures.Allocation_Pools.Adaptive;
with Flyology.Data_Structures.Arenas;
with Flyology.Data_Structures.Byte_Strings;
with Flyology.Data_Structures.Dynamic.Byte_Strings;
with Flyology.Data_Structures.Dynamic.Hash_Maps;
with Flyology.Data_Structures.Dynamic.Vectors;
with Flyology.Data_Structures.Hash_Maps;
with Flyology.Data_Structures.Regions;
with Flyology.Data_Structures.Rings.SPSC;
with Flyology.Data_Structures.Storage_Types.Unsigned_64s;
with Flyology.Data_Structures.Vectors;
with Interfaces;
with Flyology.Data_Structures.Guard_Test_Hooks;
with Flyology.Data_Structures.Layouts;
with System;
with System.Atomic_Primitives;
with System.Storage_Elements;

procedure Flyology.Data_Structures.Guard_Epoch_Smoke is
   package DS renames Flyology.Data_Structures;
   package E renames DS.Storage_Types.Unsigned_64s;
   package V is new DS.Vectors (E.Element);
   package R is new DS.Rings.SPSC (E.Element);
   package A is new DS.Arenas (DS.Allocation_Algorithms.Buddy);
   package DV is new DS.Dynamic.Vectors (A, E.Element);
   package DB is new DS.Dynamic.Byte_Strings (A);
   package DM is new DS.Dynamic.Hash_Maps (A, E.Element, E.Element);
   package M is new DS.Hash_Maps (E.Element, E.Element);
   package P is new DS.Allocation_Pools.Adaptive (A, E.Element, 2, 2);
   package AP renames System.Atomic_Primitives;
   use type AP.uint32;
   use type System.Storage_Elements.Storage_Offset;
   use type DS.Byte_Count;
   Buffer         : aliased Ada.Streams.Stream_Element_Array (1 .. 262_144) :=
     (others => 0);
   for Buffer'Alignment use 64;
   Region         : DS.Region_View;
   Arena          : A.View;
   Vector         : V.View;
   Replacement    : V.View;
   Bytes          : DS.Byte_Strings.View;
   DVector        : DV.View;
   DBytes         : DB.View;
   DMap           : DM.View;
   Map            : M.View;
   Pool           : P.View;
   Ring           : R.View;
   Location       : constant DS.Region_Offset := 65_536;
   Guard          : constant System.Address := Buffer'Address + 65_536 + 44;
   Mode           : constant String := Ada.Command_Line.Argument (1);
   Hook_Count     : Natural := 0;
   Peer_Rejected  : Boolean := False;
   Stale_Rejected : Boolean := False;
   N              : Natural;

   --  Real distinct native task; its output view is never shared with owner.
   task Peer is
      entry Check;
      entry Stop;
   end Peer;
   task body Peer is
      Ring_Probe   : R.View;
      Vector_Probe : V.View;
   begin
      loop
         select
            accept Check do
               Ada.Text_IO.Put_Line
                 ("peer auxiliary="
                  & AP.uint32'Image (AP.Atomic_Load_32 (Guard, AP.Acquire)));
               begin
                  if Mode = "vector-reattach" then
                     V.Attach (Vector_Probe, Region, Location, 2);
                     V.Detach (Vector_Probe);
                  else
                     R.Attach (Ring_Probe, Region, Location, 2);
                     R.Detach (Ring_Probe);
                  end if;
                  Ada.Text_IO.Put_Line ("peer attach=OK");
               exception
                  when Ex : DS.Layout_Error | DS.Busy_Error =>
                     Peer_Rejected := True;
                     Ada.Text_IO.Put_Line
                       ("peer attach="
                        & Ada.Exceptions.Exception_Message (Ex));
               end;
            end Check;
         or
            accept Stop;
            exit;
         end select;
      end loop;
   end Peer;

   procedure Observe
     (Core : DS.Layouts.Local_View; Guard_Address : System.Address)
   is
      pragma Unreferenced (Core, Guard_Address);
   begin
      Hook_Count := Hook_Count + 1;
      Peer.Check;
   end Observe;
begin
   DS.Regions.Attach (Region, Buffer'Address, DS.Byte_Count (Buffer'Length));
   A.Initialize
     (Arena,
      Region,
      64,
      (Usable_Capacity => 32_768, Minimum_Block_Size => 64),
      1);
   if Mode = "vector"
     or else Mode = "vector-timed"
     or else Mode = "vector-reattach"
   then
      V.Initialize (Vector, Region, Location, 2);
   elsif Mode = "bytes" or else Mode = "bytes-timed" then
      DS.Byte_Strings.Initialize (Bytes, Region, Location, 16);
   elsif Mode = "dynamic-vector" then
      DV.Initialize (DVector, Region, Location, Arena, 2);
   elsif Mode = "dynamic-bytes" then
      DB.Initialize (DBytes, Region, Location, Arena, 2);
   elsif Mode = "dynamic-map" then
      DM.Initialize (DMap, Region, Location, Arena, 2);
   elsif Mode = "map-control" then
      M.Initialize (Map, Region, Location, 2);
   elsif Mode = "adaptive-destroy" or else Mode = "adaptive-allocate-control"
   then
      P.Initialize (Pool, Region, Location, Arena);
   else
      raise Program_Error with "unknown fixture mode";
   end if;
   --  No operation is active during exclusive reuse; no payload allocated.
   if Mode = "vector-reattach" then
      --  Vector Attach now validates the live length under this guard (#126).
      --  A stale Acquire must not make a fresh Attach see spurious contention.
      V.Initialize (Replacement, Region, Location, 2);
   else
      R.Initialize (Ring, Region, Location, 2);
   end if;
   Peer.Check;
   if DS.Guard_Test_Hooks.Enabled then
      DS.Guard_Test_Hooks.Set_Observer (Observe'Unrestricted_Access);
   end if;
   begin
      if Mode = "vector" or else Mode = "vector-reattach" then
         N := V.Length (Vector);
      elsif Mode = "vector-timed" then
         N := V.Length (Vector, 0.001);
      elsif Mode = "bytes" then
         N := DS.Byte_Strings.Length (Bytes);
      elsif Mode = "bytes-timed" then
         N := DS.Byte_Strings.Length (Bytes, 0.001);
      elsif Mode = "dynamic-vector" then
         N := DV.Length (DVector);
      elsif Mode = "dynamic-bytes" then
         N := DB.Length (DBytes);
      elsif Mode = "dynamic-map" then
         N := DM.Length (DMap);
      elsif Mode = "map-control" then
         N := M.Length (Map);
      elsif Mode = "adaptive-destroy" then
         P.Destroy (Pool, Arena);
      else
         declare
            Handle : P.Handle;
            Result : P.Allocation_Result;
         begin
            P.Try_Allocate (Pool, Arena, 7, Handle, Result);
         end;
      end if;
   exception
      when Ex : DS.Layout_Error =>
         Stale_Rejected := True;
         Ada.Text_IO.Put_Line
           ("stale call=" & Ada.Exceptions.Exception_Message (Ex));
   end;
   Ada.Text_IO.Put_Line
     ("after auxiliary="
      & AP.uint32'Image (AP.Atomic_Load_32 (Guard, AP.Acquire)));
   if DS.Guard_Test_Hooks.Enabled then
      DS.Guard_Test_Hooks.Reset;
   end if;
   --  A fresh Vector.Attach acquires the guard under #126. Remove the
   --  stale-call observer before asking the peer to make that valid call.
   Peer.Check;
   Peer.Stop;
   Ada.Text_IO.Put_Line ("hook count=" & Natural'Image (Hook_Count));
   pragma Assert (Stale_Rejected);
   pragma Assert (AP.Atomic_Load_32 (Guard, AP.Acquire) = 0);
   pragma Assert (Hook_Count = 0 and then not Peer_Rejected);
   Ada.Text_IO.Put_Line ("CONFIRMED " & Mode);
end Flyology.Data_Structures.Guard_Epoch_Smoke;
