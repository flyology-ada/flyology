with Ada.Finalization;
with Flyology;
with Flyology.Memory_Regions;
with System.Storage_Elements;

procedure Memory_Regions_Smoke is
   package Regions renames Flyology.Memory_Regions;
   package Storage renames System.Storage_Elements;

   use type Regions.Region_Handle;
   use type Storage.Storage_Count;

   protected Results is
      procedure Finalized;
      procedure Cross_Task_Rejected;
      procedure Lightweight_Passed;
      function Finalization_Count return Natural;
      function Cross_Task_Was_Rejected return Boolean;
      function Lightweight_Was_Passed return Boolean;
   private
      Finalizations : Natural := 0;
      Cross_Rejected : Boolean := False;
      Light_Passed : Boolean := False;
   end Results;

   protected body Results is
      procedure Finalized is
      begin
         Finalizations := Finalizations + 1;
      end Finalized;

      procedure Cross_Task_Rejected is
      begin
         Cross_Rejected := True;
      end Cross_Task_Rejected;

      procedure Lightweight_Passed is
      begin
         Light_Passed := True;
      end Lightweight_Passed;

      function Finalization_Count return Natural is (Finalizations);
      function Cross_Task_Was_Rejected return Boolean is (Cross_Rejected);
      function Lightweight_Was_Passed return Boolean is (Light_Passed);
   end Results;

   type Tracked is new Ada.Finalization.Controlled with record
      Value : Natural := 0;
   end record;

   overriding procedure Finalize (Item : in out Tracked);

   overriding procedure Finalize (Item : in out Tracked) is
      pragma Unreferenced (Item);
   begin
      Results.Finalized;
   end Finalize;

   procedure Check_Explicit_Release is
      Pool : aliased Regions.Task_Pool;
      type Integer_Access is access Integer;
      for Integer_Access'Storage_Pool use Pool;
      type Tracked_Access is access Tracked;
      for Tracked_Access'Storage_Pool use Pool;

      Region : Regions.Region_Handle :=
        Regions.Create_Region (Pool, Chunk_Storage => 128);
      Number : Integer_Access;
      Object : Tracked_Access;
      Sample : Regions.Pool_Statistics;
      Unnamed_Accepted : Boolean := False;
   begin
      begin
         Object := new Tracked'(Ada.Finalization.Controlled with 1);
         Unnamed_Accepted := True;
      exception
         when Program_Error =>
            null;
      end;
      if Unnamed_Accepted then
         raise Program_Error with "unnamed region allocator was accepted";
      end if;

      Number := new (Region) Integer'(42);
      Object := new (Region) Tracked'(Ada.Finalization.Controlled with 7);
      if Number.all /= 42 or else Object.Value /= 7 then
         raise Program_Error with "region allocator corrupted an object";
      end if;

      Sample := Regions.Statistics (Pool);
      if Sample.Live_Regions /= 1
        or else Sample.Consumed_Storage = 0
        or else Sample.Reserved_Storage < Sample.Consumed_Storage
      then
         raise Program_Error with "invalid live-region accounting";
      end if;

      Regions.Release (Region);
      if Region /= null or else Results.Finalization_Count /= 1 then
         raise Program_Error with "explicit release did not finalize region";
      end if;

      Sample := Regions.Statistics (Pool);
      if Sample.Live_Regions /= 0
        or else Sample.Consumed_Storage /= 0
        or else Sample.Reserved_Storage /= 0
      then
         raise Program_Error with "released region retained accounting";
      end if;

      Regions.Release (Region);
   end Check_Explicit_Release;

   procedure Check_Pool_Finalization is
      Before : constant Natural := Results.Finalization_Count;
   begin
      declare
         Pool : aliased Regions.Task_Pool;
         type Tracked_Access is access Tracked;
         for Tracked_Access'Storage_Pool use Pool;
         Region : constant Regions.Region_Handle :=
           Regions.Create_Region (Pool);
         Object : constant Tracked_Access :=
           new (Region) Tracked'(Ada.Finalization.Controlled with 11);
         pragma Unreferenced (Object);
      begin
         null;
      end;

      if Results.Finalization_Count /= Before + 1 then
         raise Program_Error with "pool finalization did not release region";
      end if;
   end Check_Pool_Finalization;

   procedure Check_Cross_Task_Rejection is
      Pool : aliased Regions.Task_Pool;
      type Integer_Access is access Integer;
      for Integer_Access'Storage_Pool use Pool;
      Region : Regions.Region_Handle := Regions.Create_Region (Pool);

      task Intruder is
         entry Done;
      end Intruder;
      task body Intruder is
         Value : Integer_Access;
         pragma Unreferenced (Value);
      begin
         begin
            Value := new (Region) Integer'(99);
         exception
            when Regions.Ownership_Error =>
               Results.Cross_Task_Rejected;
         end;
         accept Done;
      end Intruder;
   begin
      Intruder.Done;
      Regions.Release (Region);
      if not Results.Cross_Task_Was_Rejected then
         raise Program_Error with "cross-task region use was accepted";
      end if;
   end Check_Cross_Task_Rejection;

   task Lightweight_Owner is
      pragma Task_Info (Flyology.Lightweight_Task);
      entry Done;
   end Lightweight_Owner;

   task body Lightweight_Owner is
      Pool : aliased Regions.Task_Pool;
      type Byte_Array is array (Storage.Storage_Offset range <>) of Character;
      type Byte_Array_Access is access Byte_Array;
      for Byte_Array_Access'Storage_Pool use Pool;
      Region : Regions.Region_Handle :=
        Regions.Create_Region (Pool, Chunk_Storage => 256);
      Buffer : Byte_Array_Access;
   begin
      Buffer := new (Region) Byte_Array'(1 .. 513 => 'x');
      if Buffer (Buffer'First) /= 'x'
        or else Buffer (Buffer'Last) /= 'x'
        or else Regions.Statistics (Pool).Live_Regions /= 1
      then
         raise Program_Error with "lightweight region allocation failed";
      end if;
      Regions.Release (Region);
      Results.Lightweight_Passed;
      accept Done;
   end Lightweight_Owner;

begin
   Check_Explicit_Release;
   Check_Pool_Finalization;
   Check_Cross_Task_Rejection;
   Lightweight_Owner.Done;
   if not Results.Lightweight_Was_Passed then
      raise Program_Error with "lightweight region task did not complete";
   end if;
end Memory_Regions_Smoke;
