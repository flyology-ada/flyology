with Ada.Real_Time;
with Ada.Text_IO;
with Flyology.Observability;
with Interfaces.C;
with System;
with System.Flyology.Contexts;

--  Reproduce the stack-arena scaling mechanism without scheduler or task
--  activation noise. This is an explicit measurement tool, not a behavioral
--  test: operation and mapping counts establish the mechanism, while the
--  bounded timing samples describe its cost on the current host.

procedure Stack_Arena_Scaling_Bench is
   package C renames Interfaces.C;
   package Contexts renames System.Flyology.Contexts;
   package Observation renames Flyology.Observability;

   use type Ada.Real_Time.Time;
   use type C.size_t;
   use type Contexts.Context_Access;
   use type Observation.Counter;

   Stack_Bytes   : constant C.size_t := 2 * 1_024 * 1_024;
   Maximum_Count : constant := 2_048;
   Checkpoints   : constant array (Positive range <>) of Positive := (256, 512, 1_024, Maximum_Count);

   type Context_Array is array (Positive range <>) of Contexts.Context_Access;
   Items : Context_Array (1 .. Maximum_Count) := (others => null);

   Return_To : Contexts.Context_Access := Contexts.Capture;

   procedure Unreachable_Entry (Argument : System.Address);

   procedure Unreachable_Entry (Argument : System.Address) is
      pragma Unreferenced (Argument);
   begin
      raise Program_Error with "benchmark context was dispatched";
   end Unreachable_Entry;

   function Nanoseconds (Span : Ada.Real_Time.Time_Span) return Long_Long_Integer
   is (Long_Long_Integer (Ada.Real_Time.To_Duration (Span) * 1_000_000_000.0));

   procedure Create_Range (First, Last : Positive);

   procedure Create_Range (First, Last : Positive) is
   begin
      for Index in First .. Last loop
         Items (Index) :=
           Contexts.Create
             (Stack_Size => Stack_Bytes,
              Start      => Unreachable_Entry'Address,
              Argument   => System.Null_Address,
              Return_To  => Return_To);
         if Items (Index) = null then
            raise Program_Error with "stack-arena benchmark could not create a context";
         end if;
      end loop;
   end Create_Range;

   procedure Destroy_All (Forward : Boolean; Nanoseconds_Per_Context : out Long_Long_Integer);

   procedure Destroy_All (Forward : Boolean; Nanoseconds_Per_Context : out Long_Long_Integer) is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      if Forward then
         for Index in Items'Range loop
            Contexts.Destroy (Items (Index));
         end loop;
      else
         for Index in reverse Items'Range loop
            Contexts.Destroy (Items (Index));
         end loop;
      end if;
      Nanoseconds_Per_Context :=
        Nanoseconds (Ada.Real_Time.Clock - Started) / Long_Long_Integer (Items'Length);
   end Destroy_All;

   Before, After       : Observation.Stack_Pool_Snapshot;
   Started             : Ada.Real_Time.Time;
   Previous            : Natural := 0;
   Forward_Nanoseconds : Long_Long_Integer;
   Reverse_Nanoseconds : Long_Long_Integer;
begin
   Before := Observation.Stack_Pool;
   for Checkpoint of Checkpoints loop
      Started := Ada.Real_Time.Clock;
      Create_Range (Previous + 1, Checkpoint);
      After := Observation.Stack_Pool;
      Ada.Text_IO.Put_Line
        ("live="
         & Checkpoint'Image
         & " create_ns_per="
         & Long_Long_Integer'Image
             (Nanoseconds (Ada.Real_Time.Clock - Started) / Long_Long_Integer (Checkpoint - Previous))
         & " arenas="
         & Observation.Counter'Image (After.Active_Arenas - Before.Active_Arenas)
         & " mappings="
         & Observation.Counter'Image (After.Arena_Mappings - Before.Arena_Mappings)
         & " shared="
         & Observation.Counter'Image (After.Shared_Stacks - Before.Shared_Stacks));
      Previous := Checkpoint;
   end loop;

   Destroy_All (Forward => True, Nanoseconds_Per_Context => Forward_Nanoseconds);
   Create_Range (Items'First, Items'Last);
   Destroy_All (Forward => False, Nanoseconds_Per_Context => Reverse_Nanoseconds);
   Ada.Text_IO.Put_Line
     ("destroy_forward_ns_per="
      & Forward_Nanoseconds'Image
      & " destroy_reverse_ns_per="
      & Reverse_Nanoseconds'Image);

   After := Observation.Stack_Pool;
   if After.Live_Stacks /= Before.Live_Stacks
     or else After.Active_Arenas /= Before.Active_Arenas
     or else After.Reserved_Bytes /= Before.Reserved_Bytes
     or else After.Arena_Mappings - Before.Arena_Mappings /= After.Arena_Unmappings - Before.Arena_Unmappings
   then
      raise Program_Error with "stack-arena benchmark retained pool state";
   end if;
   Contexts.Destroy (Return_To);
exception
   when others =>
      for Item of Items loop
         Contexts.Destroy (Item);
      end loop;
      Contexts.Destroy (Return_To);
      raise;
end Stack_Arena_Scaling_Bench;
