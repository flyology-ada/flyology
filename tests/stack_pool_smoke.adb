with Ada.Unchecked_Deallocation;
with Gnatevl;
with Gnatevl.Observability;
with Interfaces;

procedure Stack_Pool_Smoke is
   package Observation renames Gnatevl.Observability;

   use type Interfaces.Unsigned_64;
   use type Observation.Stack_Pool_Snapshot;

   procedure Wait_Until_Empty is
      Value : Observation.Stack_Pool_Snapshot;
   begin
      --  A terminating wrapper can notify its native master immediately
      --  before the final scheduler-side reap. Bound that short handoff.
      for Attempt in 1 .. 100 loop
         Value := Observation.Stack_Pool;
         exit when Value.Live_Stacks = 0 and then Value.Active_Arenas = 0;
         delay 0.001;
      end loop;
      if Value.Live_Stacks /= 0
        or else Value.Active_Arenas /= 0
        or else Value.Reserved_Bytes /= 0
        or else Value.Arena_Unmappings /= Value.Arena_Mappings
      then
         raise Program_Error with "empty stack arenas survived finalization";
      end if;
   end Wait_Until_Empty;

   procedure Test_Partial_Churn is
      Original_Count    : constant := 64;
      Replacement_Count : constant := Original_Count / 2;

      protected Control is
         procedure Arrived;
         procedure Finished;
         procedure Release_First;
         procedure Release_Final;
         entry Wait_Originals;
         entry Wait_Replacements;
         entry Wait_First_Finished;
         entry Wait_All_Finished;
         entry First_Gate;
         entry Final_Gate;
      private
         Arrivals       : Natural := 0;
         Finishes       : Natural := 0;
         First_Open     : Boolean := False;
         Final_Open     : Boolean := False;
      end Control;

      protected body Control is
         procedure Arrived is
         begin
            Arrivals := Arrivals + 1;
         end Arrived;

         procedure Finished is
         begin
            Finishes := Finishes + 1;
         end Finished;

         procedure Release_First is
         begin
            First_Open := True;
         end Release_First;

         procedure Release_Final is
         begin
            Final_Open := True;
         end Release_Final;

         entry Wait_Originals when Arrivals >= Original_Count is
         begin
            null;
         end Wait_Originals;

         entry Wait_Replacements
           when Arrivals >= Original_Count + Replacement_Count
         is
         begin
            null;
         end Wait_Replacements;

         entry Wait_First_Finished when Finishes >= Replacement_Count is
         begin
            null;
         end Wait_First_Finished;

         entry Wait_All_Finished
           when Finishes >= Original_Count + Replacement_Count
         is
         begin
            null;
         end Wait_All_Finished;

         entry First_Gate when First_Open is
         begin
            null;
         end First_Gate;

         entry Final_Gate when Final_Open is
         begin
            null;
         end Final_Gate;
      end Control;

      task type Original (First_Half : Boolean) is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
         pragma Storage_Size (16 * 1_024);
      end Original;

      task body Original is
      begin
         Control.Arrived;
         if First_Half then
            Control.First_Gate;
         else
            Control.Final_Gate;
         end if;
         Control.Finished;
      end Original;

      task type Replacement is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
         pragma Storage_Size (16 * 1_024);
      end Replacement;

      task body Replacement is
      begin
         Control.Arrived;
         Control.Final_Gate;
         Control.Finished;
      end Replacement;

      type Original_Access is access Original;
      type Replacement_Access is access Replacement;
      procedure Free is new Ada.Unchecked_Deallocation
        (Original, Original_Access);
      procedure Free is new Ada.Unchecked_Deallocation
        (Replacement, Replacement_Access);

      Originals : array (1 .. Original_Count) of Original_Access;
      Replacements : array (1 .. Replacement_Count) of Replacement_Access :=
        (others => null);
      Before, During, Partial, Refilled : Observation.Stack_Pool_Snapshot;
   begin
      Before := Observation.Stack_Pool;
      for Index in Originals'Range loop
         Originals (Index) := new Original (Index <= Replacement_Count);
      end loop;
      Control.Wait_Originals;
      During := Observation.Stack_Pool;
      if During.Live_Stacks /= Original_Count
        or else During.Active_Arenas /= 1
        or else During.Live_Usable_Bytes
          /= Original_Count * 48 * 1_024
        or else During.Arena_Mappings /= Before.Arena_Mappings + 1
        or else During.Shared_Stacks /= Before.Shared_Stacks + 63
      then
         raise Program_Error with "same-sized stacks did not share an arena";
      end if;

      Control.Release_First;
      Control.Wait_First_Finished;
      for Index in 1 .. Replacement_Count loop
         Free (Originals (Index));
      end loop;
      Partial := Observation.Stack_Pool;
      if Partial.Live_Stacks /= Replacement_Count
        or else Partial.Active_Arenas /= 1
        or else Partial.Discarded_Stacks
          /= Before.Discarded_Stacks + Replacement_Count
      then
         raise Program_Error with "partial arena slots were not discarded";
      end if;

      for Index in Replacements'Range loop
         Replacements (Index) := new Replacement;
      end loop;
      Control.Wait_Replacements;
      Refilled := Observation.Stack_Pool;
      if Refilled.Live_Stacks /= Original_Count
        or else Refilled.Active_Arenas /= 1
        or else Refilled.Arena_Mappings /= During.Arena_Mappings
        or else Refilled.Shared_Stacks
          /= During.Shared_Stacks + Replacement_Count
      then
         raise Program_Error with "discarded stack slots were not reused";
      end if;

      Control.Release_Final;
      Control.Wait_All_Finished;
      for Index in Replacement_Count + 1 .. Original_Count loop
         Free (Originals (Index));
      end loop;
      for Index in Replacements'Range loop
         Free (Replacements (Index));
      end loop;
      Wait_Until_Empty;
   end Test_Partial_Churn;

   procedure Test_Mixed_Sizes is
      Count_Per_Size : constant := 40;

      protected Control is
         procedure Arrived;
         procedure Release;
         entry Wait_All;
         entry Gate;
      private
         Arrivals : Natural := 0;
         Open     : Boolean := False;
      end Control;

      protected body Control is
         procedure Arrived is
         begin
            Arrivals := Arrivals + 1;
         end Arrived;

         procedure Release is
         begin
            Open := True;
         end Release;

         entry Wait_All when Arrivals = 2 * Count_Per_Size is
         begin
            null;
         end Wait_All;

         entry Gate when Open is
         begin
            null;
         end Gate;
      end Control;

      task type Small is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
         pragma Storage_Size (16 * 1_024);
      end Small;

      task type Large is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
         pragma Storage_Size (128 * 1_024);
      end Large;

      task body Small is
      begin
         Control.Arrived;
         Control.Gate;
      end Small;

      task body Large is
      begin
         Control.Arrived;
         Control.Gate;
      end Large;

      Small_Workers : array (1 .. Count_Per_Size) of Small;
      Large_Workers : array (1 .. Count_Per_Size) of Large;
      pragma Unreferenced (Small_Workers, Large_Workers);
      During : Observation.Stack_Pool_Snapshot;
   begin
      Control.Wait_All;
      During := Observation.Stack_Pool;
      --  Forty 48 KiB effective stacks fit in one arena. Forty 160 KiB
      --  effective stacks require two on both 16 KiB- and 4 KiB-page hosts.
      if During.Live_Stacks /= 2 * Count_Per_Size
        or else During.Active_Arenas /= 3
        or else During.Live_Usable_Bytes
          /= Count_Per_Size * (48 + 160) * 1_024
      then
         raise Program_Error with "mixed stack sizes shared an invalid arena";
      end if;
      Control.Release;
   end Test_Mixed_Sizes;

begin
   if Observation.Stack_Pool /=
     Observation.Stack_Pool_Snapshot'
       (Active_Arenas    => 0,
        Live_Stacks      => 0,
        Live_Usable_Bytes => 0,
        Reserved_Bytes   => 0,
        Arena_Mappings   => 0,
        Arena_Unmappings => 0,
        Shared_Stacks    => 0,
        Discarded_Stacks => 0)
   then
      raise Program_Error with "native-default startup touched stack pool";
   end if;

   Test_Partial_Churn;
   Test_Mixed_Sizes;
   Wait_Until_Empty;
end Stack_Pool_Smoke;
