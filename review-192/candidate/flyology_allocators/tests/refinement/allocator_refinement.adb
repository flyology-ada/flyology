with Ada.Command_Line;
with Ada.Streams;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Allocator_Refinement_Support;
with Flyology_Allocators;
with Flyology_Allocators.Allocation_Algorithms.Best_Fit;
with Flyology_Allocators.Allocation_Algorithms.Best_Fit_Kernel.Testing;
with Flyology_Allocators.Allocation_Algorithms.Buddy;
with Flyology_Allocators.Allocation_Algorithms.Buddy_Kernel.Testing;
with Flyology_Allocators.Allocation_Algorithms.TLSF;
with Flyology_Allocators.Allocation_Algorithms.TLSF_Kernel.Testing;
with Flyology_Allocators.Arenas;
with Flyology_Allocators.Regions;
with Interfaces;

procedure Allocator_Refinement is
   package FA renames Flyology_Allocators;
   package Support renames Allocator_Refinement_Support;
   package Fixed renames Ada.Strings.Fixed;
   package Text renames Ada.Strings.Unbounded;

   use type FA.Allocation_Algorithms.Allocation_Handle;
   use type FA.Allocation_Algorithms.Allocation_Result;
   use type Interfaces.Unsigned_64;
   use type Support.Canonical_Block_State;

   package Buddy_Arenas is new FA.Arenas (FA.Allocation_Algorithms.Buddy);
   package Best_Fit_Arenas is new FA.Arenas (FA.Allocation_Algorithms.Best_Fit);
   package TLSF_Arenas is new FA.Arenas (FA.Allocation_Algorithms.TLSF);

   package Buddy_Testing renames FA.Allocation_Algorithms.Buddy_Kernel.Testing;
   package Best_Fit_Testing renames FA.Allocation_Algorithms.Best_Fit_Kernel.Testing;
   package TLSF_Testing renames FA.Allocation_Algorithms.TLSF_Kernel.Testing;

   type Client_ID is (A, B, C, D);
   type Hint_Matrix is array (Client_ID) of Support.Hint_Array;
   Client_Names : constant array (Client_ID) of Character := [A => 'a', B => 'b', C => 'c', D => 'd'];

   Storage_Length : constant := 8_192;
   subtype Storage_Range is Ada.Streams.Stream_Element_Offset range 1 .. Storage_Length;
   type Storage_Array is array (Storage_Range) of Ada.Streams.Stream_Element;

   function Image (Value : Natural) return String
   is (Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Image (Value : Interfaces.Unsigned_64) return String
   is (Fixed.Trim (Interfaces.Unsigned_64'Image (Value), Ada.Strings.Both));

   function Image (Value : Interfaces.Unsigned_32) return String
   is (Fixed.Trim (Interfaces.Unsigned_32'Image (Value), Ada.Strings.Both));

   function Signed_Image (Value : Integer) return String
   is (Fixed.Trim (Integer'Image (Value), Ada.Strings.Both));

   procedure Append (Target : in out Text.Unbounded_String; Value : String) is
   begin
      Text.Append (Target, Value);
   end Append;

   procedure Sort (Value : in out Support.Snapshot) is
      Block      : Support.Block_Info;
      Index_Item : Support.Index_Info;
   begin
      for Right in 2 .. Value.Block_Count loop
         Block := Value.Blocks (Right);
         declare
            Left : Natural := Right;
         begin
            while Left > 1 and then Value.Blocks (Left - 1).Start > Block.Start loop
               Value.Blocks (Left) := Value.Blocks (Left - 1);
               Left := Left - 1;
            end loop;
            Value.Blocks (Left) := Block;
         end;
      end loop;
      for Right in 2 .. Value.Index_Count loop
         Index_Item := Value.Index (Right);
         declare
            Left : Natural := Right;
         begin
            while Left > 1 and then Value.Index (Left - 1).Start > Index_Item.Start loop
               Value.Index (Left) := Value.Index (Left - 1);
               Left := Left - 1;
            end loop;
            Value.Index (Left) := Index_Item;
         end;
      end loop;
   end Sort;

   function Blocks_Image (Value : Support.Snapshot) return String is
      Result : Text.Unbounded_String;
   begin
      if Value.Block_Count = 0 then
         return "-";
      end if;
      for Index in 1 .. Value.Block_Count loop
         if Index > 1 then
            Append (Result, ",");
         end if;
         Append
           (Result,
            Image (Value.Blocks (Index).Start)
            & ":"
            & Image (Value.Blocks (Index).Size)
            & ":"
            & (if Value.Blocks (Index).State = Support.Free_Block then "F" else "A")
            & ":"
            & Image (Value.Blocks (Index).Generation));
      end loop;
      return Text.To_String (Result);
   end Blocks_Image;

   function Index_Image (Value : Support.Snapshot) return String is
      Result : Text.Unbounded_String;
   begin
      if Value.Index_Count = 0 then
         return "-";
      end if;
      for Index in 1 .. Value.Index_Count loop
         if Index > 1 then
            Append (Result, ",");
         end if;
         Append (Result, Image (Value.Index (Index).Start) & ":" & Image (Value.Index (Index).Size));
      end loop;
      return Text.To_String (Result);
   end Index_Image;

   function Classes_Image (Algorithm : String; Value : Support.Snapshot) return String is
      Result : Text.Unbounded_String;
   begin
      if Algorithm /= "TLSF" then
         return "-";
      elsif Value.Index_Count = 0 then
         return "-";
      end if;
      for Index in 1 .. Value.Index_Count loop
         if Index > 1 then
            Append (Result, ",");
         end if;
         Append
           (Result,
            Image (Value.Index (Index).Start)
            & ":"
            & Image (Value.Index (Index).Size)
            & ":"
            & Signed_Image (Value.Index (Index).Class_First)
            & ":"
            & Signed_Image (Value.Index (Index).Class_Second));
      end loop;
      return Text.To_String (Result);
   end Classes_Image;

   function Maps_Image (Algorithm : String; Value : Support.Snapshot) return String is
      Result : Text.Unbounded_String;
   begin
      if Algorithm /= "TLSF" then
         return "-";
      end if;
      Append (Result, Image (Value.First_Map) & ":");
      for First in Value.Second_Maps'Range loop
         if First > Value.Second_Maps'First then
            Append (Result, ",");
         end if;
         Append (Result, Image (Value.Second_Maps (First)));
      end loop;
      return Text.To_String (Result);
   end Maps_Image;

   function Hints_Image (Value : Hint_Matrix) return String is
      Result : Text.Unbounded_String;
   begin
      for Client in Client_ID loop
         if Client /= Client_ID'First then
            Append (Result, ";");
         end if;
         Append (Result, String'(1 => Client_Names (Client)) & ":");
         for Size in Support.Hint_Array'Range loop
            if Size > Support.Hint_Array'First then
               Append (Result, ",");
            end if;
            if Value (Client) (Size) < 0 then
               Append (Result, "-1");
            else
               Append (Result, Image (Value (Client) (Size)));
            end if;
         end loop;
      end loop;
      return Text.To_String (Result);
   end Hints_Image;

   type Start_Array is array (Client_ID) of Integer;
   type Generation_Array is array (Client_ID) of Interfaces.Unsigned_64;

   function Handles_Image (Starts : Start_Array; Generations : Generation_Array) return String is
      Result : Text.Unbounded_String;
   begin
      for Client in Client_ID loop
         if Client /= Client_ID'First then
            Append (Result, ";");
         end if;
         Append (Result, String'(1 => Client_Names (Client)) & ":");
         if Starts (Client) < 0 then
            Append (Result, "-1:0");
         else
            Append (Result, Image (Starts (Client)) & ":" & Image (Generations (Client)));
         end if;
      end loop;
      return Text.To_String (Result);
   end Handles_Image;

   procedure Emit
     (Algorithm   : String;
      Step        : Natural;
      Operation   : String;
      Request     : Natural;
      Result      : String;
      Value       : in out Support.Snapshot;
      Hints       : Hint_Matrix;
      Starts      : Start_Array;
      Generations : Generation_Array) is
   begin
      Sort (Value);
      Ada.Text_IO.Put_Line
        ("@@REFINEMENT@@|"
         & Algorithm
         & "|"
         & Image (Step)
         & "|"
         & Operation
         & "|"
         & Image (Request)
         & "|"
         & Result
         & "|gen="
         & Image (Value.Generation)
         & "|blocks="
         & Blocks_Image (Value)
         & "|index="
         & Index_Image (Value)
         & "|classes="
         & Classes_Image (Algorithm, Value)
         & "|maps="
         & Maps_Image (Algorithm, Value)
         & "|hints="
         & Hints_Image (Hints)
         & "|handles="
         & Handles_Image (Starts, Generations));
   end Emit;

   function Result_Image (Value : FA.Allocation_Algorithms.Allocation_Result) return String
   is (case Value is
         when FA.Allocation_Algorithms.Allocated            => "allocated",
         when FA.Allocation_Algorithms.Exhausted            => "exhausted",
         when FA.Allocation_Algorithms.Allocation_Contended => "contended");

   procedure Run_Buddy is
      type View_Array is array (Client_ID) of Buddy_Arenas.View;
      type Handle_Array is array (Client_ID) of Buddy_Arenas.Allocation_Handle;
      Storage : aliased Storage_Array := [others => 0]
      with Alignment => 64;
      Region  : FA.Regions.View;
      Views   : View_Array;
      Handles : Handle_Array := [others => Buddy_Arenas.Null_Allocation];
      Hints   : Hint_Matrix := [others => Support.Empty_Hints];
      Starts  : Start_Array := [others => -1];
      Gens    : Generation_Array := [others => 0];
      Value   : Support.Snapshot;
      Result  : FA.Allocation_Algorithms.Allocation_Result;
      Step    : Natural := 0;

      procedure Capture is
      begin
         Buddy_Testing.Capture (Views (A), Value);
         for Client in Client_ID loop
            Buddy_Testing.Capture_Hints (Views (Client), Hints (Client));
            if Handles (Client) = Buddy_Arenas.Null_Allocation then
               Starts (Client) := -1;
               Gens (Client) := 0;
            else
               Starts (Client) := Buddy_Testing.Handle_Start (Views (Client), Handles (Client));
               Gens (Client) := Handles (Client).Generation;
            end if;
         end loop;
      end Capture;

      procedure Allocate (Client : Client_ID; Size : Positive) is
      begin
         Buddy_Arenas.Try_Allocate (Views (Client), Size * 64, Handles (Client), Result);
         Step := Step + 1;
         Capture;
         Emit
           ("Buddy",
            Step,
            "allocate-" & String'(1 => Client_Names (Client)),
            Size,
            Result_Image (Result),
            Value,
            Hints,
            Starts,
            Gens);
      end Allocate;

      procedure Release (Client : Client_ID) is
      begin
         Buddy_Arenas.Release (Views (Client), Handles (Client));
         Handles (Client) := Buddy_Arenas.Null_Allocation;
         Step := Step + 1;
         Capture;
         Emit
           ("Buddy",
            Step,
            "release-" & String'(1 => Client_Names (Client)),
            0,
            "released",
            Value,
            Hints,
            Starts,
            Gens);
      end Release;
   begin
      FA.Regions.Attach (Region, Storage (Storage'First)'Address, FA.Byte_Count (Storage'Length));
      Buddy_Arenas.Initialize (Views (A), Region, 64, (Usable_Capacity => 512, Minimum_Block_Size => 64), 31);
      for Client in B .. D loop
         Buddy_Arenas.Attach
           (Views (Client), Region, 64, (Usable_Capacity => 512, Minimum_Block_Size => 64), 31);
      end loop;
      Capture;
      Emit ("Buddy", 0, "init", 0, "none", Value, Hints, Starts, Gens);

      Allocate (A, 4);
      Release (A);
      Allocate (B, 4);
      Allocate (A, 4);
      Release (B);
      Release (A);
      Allocate (C, 8);
      Release (C);
      Allocate (C, 8);
      Release (C);

      for Client in Client_ID loop
         Buddy_Arenas.Detach (Views (Client));
      end loop;
      FA.Regions.Detach (Region);
   end Run_Buddy;

   procedure Run_Best_Fit is
      type View_Array is array (Client_ID) of Best_Fit_Arenas.View;
      type Handle_Array is array (Client_ID) of Best_Fit_Arenas.Allocation_Handle;
      Storage : aliased Storage_Array := [others => 0]
      with Alignment => 64;
      Region  : FA.Regions.View;
      Views   : View_Array;
      Handles : Handle_Array := [others => Best_Fit_Arenas.Null_Allocation];
      Hints   : constant Hint_Matrix := [others => Support.Empty_Hints];
      Starts  : Start_Array := [others => -1];
      Gens    : Generation_Array := [others => 0];
      Value   : Support.Snapshot;
      Result  : FA.Allocation_Algorithms.Allocation_Result;
      Step    : Natural := 0;

      procedure Capture is
      begin
         Best_Fit_Testing.Capture (Views (A), Value);
         for Client in Client_ID loop
            if Handles (Client) = Best_Fit_Arenas.Null_Allocation then
               Starts (Client) := -1;
               Gens (Client) := 0;
            else
               Starts (Client) :=
                 Integer
                   (Interfaces.Unsigned_32
                      (Handles (Client).Token and Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last)));
               Gens (Client) := Handles (Client).Generation;
            end if;
         end loop;
      end Capture;

      procedure Allocate (Client : Client_ID; Size : Positive) is
      begin
         Best_Fit_Arenas.Try_Allocate (Views (Client), (Size - 1) * 64, Handles (Client), Result);
         Step := Step + 1;
         Capture;
         Emit
           ("BestFit",
            Step,
            "allocate-" & String'(1 => Client_Names (Client)),
            Size,
            Result_Image (Result),
            Value,
            Hints,
            Starts,
            Gens);
      end Allocate;

      procedure Release (Client : Client_ID) is
      begin
         Best_Fit_Arenas.Release (Views (Client), Handles (Client));
         Handles (Client) := Best_Fit_Arenas.Null_Allocation;
         Step := Step + 1;
         Capture;
         Emit
           ("BestFit",
            Step,
            "release-" & String'(1 => Client_Names (Client)),
            0,
            "released",
            Value,
            Hints,
            Starts,
            Gens);
      end Release;
   begin
      FA.Regions.Attach (Region, Storage (Storage'First)'Address, FA.Byte_Count (Storage'Length));
      Best_Fit_Arenas.Initialize
        (Views (A), Region, 64, (Usable_Capacity => 512, Minimum_Block_Size => 64), 32);
      for Client in B .. D loop
         Best_Fit_Arenas.Attach
           (Views (Client), Region, 64, (Usable_Capacity => 512, Minimum_Block_Size => 64), 32);
      end loop;
      Capture;
      Emit ("BestFit", 0, "init", 0, "none", Value, Hints, Starts, Gens);

      Allocate (A, 2);
      Allocate (B, 2);
      Allocate (C, 2);
      Allocate (D, 2);
      Release (B);
      Release (C);
      Allocate (B, 4);
      Release (B);
      Release (A);
      Release (D);
      Allocate (A, 8);
      Release (A);

      for Client in Client_ID loop
         Best_Fit_Arenas.Detach (Views (Client));
      end loop;
      FA.Regions.Detach (Region);
   end Run_Best_Fit;

   procedure Run_TLSF is
      type View_Array is array (Client_ID) of TLSF_Arenas.View;
      type Handle_Array is array (Client_ID) of TLSF_Arenas.Allocation_Handle;
      Storage : aliased Storage_Array := [others => 0]
      with Alignment => 64;
      Region  : FA.Regions.View;
      Views   : View_Array;
      Handles : Handle_Array := [others => TLSF_Arenas.Null_Allocation];
      Hints   : constant Hint_Matrix := [others => Support.Empty_Hints];
      Starts  : Start_Array := [others => -1];
      Gens    : Generation_Array := [others => 0];
      Value   : Support.Snapshot;
      Result  : FA.Allocation_Algorithms.Allocation_Result;
      Step    : Natural := 0;

      procedure Capture is
      begin
         TLSF_Testing.Capture (Views (A), Value);
         for Client in Client_ID loop
            if Handles (Client) = TLSF_Arenas.Null_Allocation then
               Starts (Client) := -1;
               Gens (Client) := 0;
            else
               Starts (Client) :=
                 Integer
                   (Interfaces.Unsigned_32
                      (Handles (Client).Token and Interfaces.Unsigned_64 (Interfaces.Unsigned_32'Last)));
               Gens (Client) := Handles (Client).Generation;
            end if;
         end loop;
      end Capture;

      procedure Allocate (Client : Client_ID; Size : Positive) is
      begin
         TLSF_Arenas.Try_Allocate (Views (Client), (Size - 1) * 64, Handles (Client), Result);
         Step := Step + 1;
         Capture;
         Emit
           ("TLSF",
            Step,
            "allocate-" & String'(1 => Client_Names (Client)),
            Size,
            Result_Image (Result),
            Value,
            Hints,
            Starts,
            Gens);
      end Allocate;

      procedure Release (Client : Client_ID) is
      begin
         TLSF_Arenas.Release (Views (Client), Handles (Client));
         Handles (Client) := TLSF_Arenas.Null_Allocation;
         Step := Step + 1;
         Capture;
         Emit
           ("TLSF",
            Step,
            "release-" & String'(1 => Client_Names (Client)),
            0,
            "released",
            Value,
            Hints,
            Starts,
            Gens);
      end Release;
   begin
      FA.Regions.Attach (Region, Storage (Storage'First)'Address, FA.Byte_Count (Storage'Length));
      TLSF_Arenas.Initialize (Views (A), Region, 64, (Usable_Capacity => 512, Minimum_Block_Size => 64), 33);
      for Client in B .. D loop
         TLSF_Arenas.Attach
           (Views (Client), Region, 64, (Usable_Capacity => 512, Minimum_Block_Size => 64), 33);
      end loop;
      Capture;
      Emit ("TLSF", 0, "init", 0, "none", Value, Hints, Starts, Gens);

      Allocate (A, 2);
      Allocate (B, 2);
      Allocate (C, 2);
      Allocate (D, 2);
      Release (B);
      Release (C);
      Allocate (B, 4);
      Release (B);
      Release (A);
      Release (D);
      Allocate (A, 8);
      Release (A);

      for Client in Client_ID loop
         TLSF_Arenas.Detach (Views (Client));
      end loop;
      FA.Regions.Detach (Region);
   end Run_TLSF;

begin
   if Ada.Command_Line.Argument_Count /= 1 then
      raise Program_Error with "usage: allocator_refinement Buddy|BestFit|TLSF";
   elsif Ada.Command_Line.Argument (1) = "Buddy" then
      Run_Buddy;
   elsif Ada.Command_Line.Argument (1) = "BestFit" then
      Run_Best_Fit;
   elsif Ada.Command_Line.Argument (1) = "TLSF" then
      Run_TLSF;
   else
      raise Program_Error with "unknown allocator refinement algorithm";
   end if;
end Allocator_Refinement;
