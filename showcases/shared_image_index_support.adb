with Ada.IO_Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings;
with Ada.Strings.Fixed;

package body Shared_Image_Index_Support is
   package Streams renames Ada.Streams;
   package Files renames Ada.Streams.Stream_IO;

   use type Streams.Stream_Element_Offset;
   use type Streams.Stream_Element_Array;
   use type Files.Count;
   use type U64;

   function Create_Job
     (Data : Image_Job) return Job_Representation.Value
   is
      Builder : Job_Representation.Value_Builder := Job_Representation.Start;
   begin
      Job_Representation.Store_U64 (Builder, 0, Data.Batch_Id);
      Job_Representation.Store_U64 (Builder, 8, Data.Image_Id);
      return Job_Representation.Freeze (Builder);
   end Create_Job;

   function Observe_Job
     (Item : Job_Representation.Const_Ref) return Image_Job is
     (Batch_Id => Job_Representation.Load_U64 (Item, 0),
      Image_Id => Job_Representation.Load_U64 (Item, 8));

   procedure Construct_Job
     (Item : in out Job_Representation.Builder; Data : Image_Job) is
   begin
      Job_Representation.Store_U64 (Item, 0, Data.Batch_Id);
      Job_Representation.Store_U64 (Item, 8, Data.Image_Id);
   end Construct_Job;

   procedure Store_Result
     (Item : in out Result_Representation.Value_Builder;
      Data : Image_Result) is
   begin
      Result_Representation.Store_U64 (Item, 0, Data.Batch_Id);
      Result_Representation.Store_U64 (Item, 8, Data.Image_Id);
      Result_Representation.Store_U64 (Item, 16, Data.Content_Hash);
      Result_Representation.Store_U64 (Item, 24, Data.Red_Total);
      Result_Representation.Store_U64 (Item, 32, Data.Green_Total);
      Result_Representation.Store_U64 (Item, 40, Data.Blue_Total);
      Result_Representation.Store_U64 (Item, 48, Data.Pixel_Count);
      Result_Representation.Store_U32 (Item, 56, Data.Worker_Id);
      Result_Representation.Store_U32 (Item, 60, Data.Index_Retries);
      Result_Representation.Store_U32 (Item, 64, Data.Queue_Retries);
      Result_Representation.Store_U32 (Item, 68, Data.Flags);
   end Store_Result;

   procedure Store_Result
     (Item : in out Result_Representation.Builder;
      Data : Image_Result) is
   begin
      Result_Representation.Store_U64 (Item, 0, Data.Batch_Id);
      Result_Representation.Store_U64 (Item, 8, Data.Image_Id);
      Result_Representation.Store_U64 (Item, 16, Data.Content_Hash);
      Result_Representation.Store_U64 (Item, 24, Data.Red_Total);
      Result_Representation.Store_U64 (Item, 32, Data.Green_Total);
      Result_Representation.Store_U64 (Item, 40, Data.Blue_Total);
      Result_Representation.Store_U64 (Item, 48, Data.Pixel_Count);
      Result_Representation.Store_U32 (Item, 56, Data.Worker_Id);
      Result_Representation.Store_U32 (Item, 60, Data.Index_Retries);
      Result_Representation.Store_U32 (Item, 64, Data.Queue_Retries);
      Result_Representation.Store_U32 (Item, 68, Data.Flags);
   end Store_Result;

   function Create_Result
     (Data : Image_Result) return Result_Representation.Value
   is
      Builder : Result_Representation.Value_Builder :=
        Result_Representation.Start;
   begin
      Store_Result (Builder, Data);
      return Result_Representation.Freeze (Builder);
   end Create_Result;

   function Observe_Result
     (Item : Result_Representation.Const_Ref) return Image_Result is
     (Batch_Id      => Result_Representation.Load_U64 (Item, 0),
      Image_Id      => Result_Representation.Load_U64 (Item, 8),
      Content_Hash  => Result_Representation.Load_U64 (Item, 16),
      Red_Total     => Result_Representation.Load_U64 (Item, 24),
      Green_Total   => Result_Representation.Load_U64 (Item, 32),
      Blue_Total    => Result_Representation.Load_U64 (Item, 40),
      Pixel_Count   => Result_Representation.Load_U64 (Item, 48),
      Worker_Id     => Result_Representation.Load_U32 (Item, 56),
      Index_Retries => Result_Representation.Load_U32 (Item, 60),
      Queue_Retries => Result_Representation.Load_U32 (Item, 64),
      Flags         => Result_Representation.Load_U32 (Item, 68));

   procedure Construct_Result
     (Item : in out Result_Representation.Builder; Data : Image_Result) is
   begin
      Store_Result (Item, Data);
   end Construct_Result;

   function Image_Path (Directory : String; Image_Id : Positive) return String
   is
      Raw : constant String := Ada.Strings.Fixed.Trim
        (Positive'Image (Image_Id), Ada.Strings.Both);
      Padded : String (1 .. 8) := (others => '0');
   begin
      if Raw'Length > Padded'Length then
         raise Constraint_Error with "image identifier exceeds filename width";
      end if;
      Padded (Padded'Last - Raw'Length + 1 .. Padded'Last) := Raw;
      return Directory & "/image-" & Padded & ".ppm";
   end Image_Path;

   function Header (Width, Height : Positive) return String is
     ("P6" & ASCII.LF
      & Ada.Strings.Fixed.Trim (Positive'Image (Width), Ada.Strings.Both)
      & " "
      & Ada.Strings.Fixed.Trim (Positive'Image (Height), Ada.Strings.Both)
      & ASCII.LF & "255" & ASCII.LF);

   function To_Bytes (Text : String) return Streams.Stream_Element_Array is
      Result : Streams.Stream_Element_Array
        (1 .. Streams.Stream_Element_Offset (Text'Length));
   begin
      for Index in Text'Range loop
         Result
           (Streams.Stream_Element_Offset (Index - Text'First + 1)) :=
             Streams.Stream_Element (Character'Pos (Text (Index)));
      end loop;
      return Result;
   end To_Bytes;

   function Next_Random (State : in out U64) return U64 is
   begin
      if State = 0 then
         State := 16#9E37_79B9_7F4A_7C15#;
      end if;
      State := State xor Interfaces.Shift_Left (State, 13);
      State := State xor Interfaces.Shift_Right (State, 7);
      State := State xor Interfaces.Shift_Left (State, 17);
      return State;
   end Next_Random;

   procedure Generate_Image
     (Path   : String;
      Width  : Positive;
      Height : Positive;
      State  : in out U64)
   is
      File : Files.File_Type;
      Prefix : constant Streams.Stream_Element_Array :=
        To_Bytes (Header (Width, Height));
      Remaining : Natural := Width * Height * 3;
      Buffer : Streams.Stream_Element_Array (1 .. 64 * 1_024);
   begin
      Files.Create (File, Files.Out_File, Path);
      Files.Write (File, Prefix);
      while Remaining > 0 loop
         declare
            Count : constant Natural := Natural'Min (Remaining, Buffer'Length);
         begin
            for Index in 1 .. Count loop
               Buffer (Streams.Stream_Element_Offset (Index)) :=
                 Streams.Stream_Element (Next_Random (State) and 16#FF#);
            end loop;
            Files.Write
              (File, Buffer
                 (Buffer'First ..
                    Buffer'First + Streams.Stream_Element_Offset (Count) - 1));
            Remaining := Remaining - Count;
         end;
      end loop;
      Files.Close (File);
   exception
      when others =>
         if Files.Is_Open (File) then
            Files.Close (File);
         end if;
         raise;
   end Generate_Image;

   procedure Analyze_Image
     (Path      : String;
      Width     : Positive;
      Height    : Positive;
      Passes    : Positive;
      Worker_Id : Positive;
      Result    : out Image_Result)
   is
      Prefix : constant Streams.Stream_Element_Array :=
        To_Bytes (Header (Width, Height));
      Pixel_Bytes : constant Natural := Width * Height * 3;
      Expected_Size : constant Files.Count :=
        Files.Count
          (Prefix'Length + Streams.Stream_Element_Offset (Pixel_Bytes));
      File : Files.File_Type;
      Buffer : Streams.Stream_Element_Array (1 .. 64 * 1_024);
      Last : Streams.Stream_Element_Offset;
      Hash : U64 := 16#CBF2_9CE4_8422_2325#;
      Red, Green, Blue : U64 := 0;
   begin
      Result :=
        (Batch_Id       => 0,
         Image_Id        => 0,
         Content_Hash    => 0,
         Red_Total       => 0,
         Green_Total     => 0,
         Blue_Total      => 0,
         Pixel_Count     => 0,
         Worker_Id       => 0,
         Index_Retries   => 0,
         Queue_Retries   => 0,
         Flags           => 0);
      for Pass in 1 .. Passes loop
         Files.Open (File, Files.In_File, Path);
         if Files.Size (File) /= Expected_Size then
            raise Ada.IO_Exceptions.Data_Error with
              "PPM file has unexpected size: " & Path;
         end if;
         declare
            Observed : Streams.Stream_Element_Array (Prefix'Range);
         begin
            Files.Read (File, Observed, Last);
            if Last /= Observed'Last or else Observed /= Prefix then
               raise Ada.IO_Exceptions.Data_Error with
                 "PPM header mismatch: " & Path;
            end if;
         end;
         declare
            Remaining : Natural := Pixel_Bytes;
            Channel   : Natural := 0;
         begin
            while Remaining > 0 loop
               Files.Read (File, Buffer, Last);
               if Last < Buffer'First then
                  raise Ada.IO_Exceptions.Data_Error with
                    "PPM payload is truncated: " & Path;
               end if;
               declare
                  Count : constant Natural :=
                    Natural (Last - Buffer'First + 1);
               begin
                  if Count > Remaining then
                     raise Ada.IO_Exceptions.Data_Error with
                       "PPM payload exceeds expected size";
                  end if;
                  for Index in Buffer'First .. Last loop
                     declare
                        Value : constant U64 := U64 (Buffer (Index));
                     begin
                        Hash := (Hash xor Value) * 16#0000_0100_0000_01B3#;
                        if Pass = 1 then
                           case Channel is
                              when 0 => Red := Red + Value;
                              when 1 => Green := Green + Value;
                              when others => Blue := Blue + Value;
                           end case;
                           Channel := (Channel + 1) mod 3;
                        end if;
                     end;
                  end loop;
                  Remaining := Remaining - Count;
               end;
            end loop;
         end;
         Files.Close (File);
      end loop;
      Result :=
        (Batch_Id      => 0,
         Image_Id      => 0,
         Content_Hash  => Hash,
         Red_Total     => Red,
         Green_Total   => Green,
         Blue_Total    => Blue,
         Pixel_Count   => U64 (Width) * U64 (Height),
         Worker_Id     => U32 (Worker_Id),
         Index_Retries => 0,
         Queue_Retries => 0,
         Flags         => Image_Complete);
   exception
      when others =>
         if Files.Is_Open (File) then
            Files.Close (File);
         end if;
         raise;
   end Analyze_Image;
end Shared_Image_Index_Support;
