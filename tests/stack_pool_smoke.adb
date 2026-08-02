with Ada.Unchecked_Deallocation;
with Gnatevl;
with Gnatevl.Observability;
with Interfaces;

procedure Stack_Pool_Smoke is
   package Observation renames Gnatevl.Observability;

   use type Interfaces.Unsigned_64;
   use type Observation.Stack_Pool_Snapshot;

   Small_Effective_Bytes : Observation.Counter := 0;

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
      Failed : Boolean := False;
   begin
      Before := Observation.Stack_Pool;
      for Index in Originals'Range loop
         Originals (Index) := new Original (Index <= Replacement_Count);
      end loop;
      Control.Wait_Originals;
      During := Observation.Stack_Pool;
      Small_Effective_Bytes := During.Live_Usable_Bytes / Original_Count;
      if During.Live_Stacks /= Original_Count
        or else During.Active_Arenas /= 1
        or else Small_Effective_Bytes < 16 * 1_024
        or else During.Arena_Mappings /= Before.Arena_Mappings + 1
        or else During.Shared_Stacks /= Before.Shared_Stacks + 63
      then
         Failed := True;
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
         Failed := True;
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
         Failed := True;
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
      if Failed then
         raise Program_Error with "partial stack-arena churn was inconsistent";
      end if;
   end Test_Partial_Churn;

   procedure Test_Head_Arena_Cleanup is
      protected Control is
         procedure Arrived;
         procedure Finished (Head : Boolean);
         procedure Release_Head;
         procedure Release_Older;
         entry Wait_Older;
         entry Wait_Both;
         entry Wait_Head_Finished;
         entry Wait_Older_Finished;
         entry Head_Gate;
         entry Older_Gate;
      private
         Arrivals       : Natural := 0;
         Head_Done      : Boolean := False;
         Older_Done     : Boolean := False;
         Head_Open      : Boolean := False;
         Older_Open     : Boolean := False;
      end Control;

      protected body Control is
         procedure Arrived is
         begin
            Arrivals := Arrivals + 1;
         end Arrived;

         procedure Finished (Head : Boolean) is
         begin
            if Head then
               Head_Done := True;
            else
               Older_Done := True;
            end if;
         end Finished;

         procedure Release_Head is
         begin
            Head_Open := True;
         end Release_Head;

         procedure Release_Older is
         begin
            Older_Open := True;
         end Release_Older;

         entry Wait_Older when Arrivals >= 1 is
         begin
            null;
         end Wait_Older;

         entry Wait_Both when Arrivals >= 2 is
         begin
            null;
         end Wait_Both;

         entry Wait_Head_Finished when Head_Done is
         begin
            null;
         end Wait_Head_Finished;

         entry Wait_Older_Finished when Older_Done is
         begin
            null;
         end Wait_Older_Finished;

         entry Head_Gate when Head_Open is
         begin
            null;
         end Head_Gate;

         entry Older_Gate when Older_Open is
         begin
            null;
         end Older_Gate;
      end Control;

      task type Older is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
         pragma Storage_Size (16 * 1_024);
      end Older;

      task type Head is
         pragma Task_Info (Gnatevl.Event_Loop_Task);
         pragma Storage_Size (128 * 1_024);
      end Head;

      task body Older is
      begin
         Control.Arrived;
         Control.Older_Gate;
         Control.Finished (Head => False);
      end Older;

      task body Head is
      begin
         Control.Arrived;
         Control.Head_Gate;
         Control.Finished (Head => True);
      end Head;

      type Older_Access is access Older;
      type Head_Access is access Head;
      procedure Free is new Ada.Unchecked_Deallocation
        (Older, Older_Access);
      procedure Free is new Ada.Unchecked_Deallocation
        (Head, Head_Access);

      Older_Worker : Older_Access;
      Head_Worker  : Head_Access;
      Before, During, After_Head : Observation.Stack_Pool_Snapshot;
      Failed : Boolean := False;
   begin
      Before := Observation.Stack_Pool;
      Older_Worker := new Older;
      Control.Wait_Older;
      Head_Worker := new Head;
      Control.Wait_Both;
      During := Observation.Stack_Pool;
      if During.Live_Stacks /= 2
        or else During.Active_Arenas /= 2
        or else During.Arena_Mappings /= Before.Arena_Mappings + 2
      then
         Failed := True;
      end if;

      --  The differently sized Head stack owns the newest list element.
      --  Destroy it while the older arena remains live, exercising the
      --  no-predecessor removal path rather than whole-pool cleanup.
      Control.Release_Head;
      Control.Wait_Head_Finished;
      Free (Head_Worker);
      After_Head := Observation.Stack_Pool;
      if After_Head.Live_Stacks /= 1
        or else After_Head.Active_Arenas /= 1
        or else After_Head.Arena_Unmappings /= Before.Arena_Unmappings + 1
      then
         Failed := True;
      end if;

      Control.Release_Older;
      Control.Wait_Older_Finished;
      Free (Older_Worker);
      Wait_Until_Empty;
      if Failed then
         raise Program_Error with "head stack-arena cleanup was inconsistent";
      end if;
   end Test_Head_Arena_Cleanup;

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
      Failed : Boolean := False;
   begin
      Control.Wait_All;
      During := Observation.Stack_Pool;
      --  The two requested sizes differ by 112 KiB on every platform. Forty
      --  small stacks fit in one arena and forty large stacks require two on
      --  both 16 KiB- and 4 KiB-page hosts.
      if During.Live_Stacks /= 2 * Count_Per_Size
        or else During.Active_Arenas /= 3
        or else During.Live_Usable_Bytes
          /= 2 * Count_Per_Size * Small_Effective_Bytes
             + Count_Per_Size * (128 - 16) * 1_024
      then
         Failed := True;
      end if;
      Control.Release;
      if Failed then
         raise Program_Error with "mixed stack sizes shared an invalid arena";
      end if;
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
   Test_Head_Arena_Cleanup;
   Test_Mixed_Sizes;
   Wait_Until_Empty;
end Stack_Pool_Smoke;
