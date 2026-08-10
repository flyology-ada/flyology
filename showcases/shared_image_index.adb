with Ada.Characters.Conversions;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Wide_Wide_Unbounded;
with Ada.Text_IO;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Byte_Strings;
with Flyology.Data_Structures.Regions;
with Flyology.Shared_Memory;
with Flyology.Shared_Memory.Segments;
with Flyology.Shared_Memory.Unix_Sockets;
with Flyology_TUI.Backends;
with Flyology_TUI.Backends.POSIX;
with Flyology_TUI.Colors;
with Flyology_TUI.Components.Indicators;
with Flyology_TUI.Components.Tables;
with Flyology_TUI.Events;
with Flyology_TUI.Layouts;
with Flyology_TUI.Styles;
with Flyology_TUI.Surfaces;
with Flyology_TUI.Themes;
with Flyology_TUI.Views;
with Interfaces;
with Interfaces.C;
with Showcase_Support;
with Shared_Image_Index_Support;
procedure Shared_Image_Index is
   package CLI renames Ada.Command_Line;
   package Directories renames Ada.Directories;
   package Env renames Ada.Environment_Variables;
   package Wide_Text renames Ada.Strings.Wide_Wide_Unbounded;
   package RT renames Ada.Real_Time;
   package IO renames Ada.Text_IO;
   package C renames Interfaces.C;
   package DS renames Flyology.Data_Structures;
   package Regions renames DS.Regions;
   package Strings renames DS.Byte_Strings;
   package Shared renames Flyology.Shared_Memory;
   package Segments renames Shared.Segments;
   package Unix renames Shared.Unix_Sockets;
   package TUI_Backends renames Flyology_TUI.Backends;
   package TUI_POSIX renames Flyology_TUI.Backends.POSIX;
   package TUI_Colors renames Flyology_TUI.Colors;
   package Indicators renames Flyology_TUI.Components.Indicators;
   package TUI_Events renames Flyology_TUI.Events;
   package TUI_Layouts renames Flyology_TUI.Layouts;
   package TUI_Styles renames Flyology_TUI.Styles;
   package TUI_Surfaces renames Flyology_TUI.Surfaces;
   package TUI_Themes renames Flyology_TUI.Themes;
   package TUI_Views renames Flyology_TUI.Views;
   package Model renames Shared_Image_Index_Support;
   package Job_Rings renames Model.Job_Rings;
   package Result_Rings renames Model.Result_Rings;
   package Image_Maps renames Model.Image_Maps;
   use type C.int;
   use type Ada.Streams.Stream_Element_Offset;
   use type DS.Byte_Count;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Ada.Directories.File_Kind;
   use type Job_Rings.Push_Result;
   use type Result_Rings.Pop_Result;
   use type RT.Time;
   use type Segments.Find_Or_Create_Result;
   use type Segments.Lookup_Result;
   use type Segments.Segment_Open_Result;
   use type TUI_Backends.Input_Status;
   use type TUI_Events.Key_Kind;
   use type TUI_Events.Terminal_Event_Kind;
   Segment_Config : constant Segments.Configuration :=
     (Schema               => 16#5348_4F57_494D_4701#,
      Registry_Capacity    => 8,
      Maximum_Name_Length  => 64,
      Allocation_Alignment => 64);
   function Socketpair
     (Left, Right : access C.int) return C.int;
   pragma Import
     (C, Socketpair, "flyology_showcase_image_socketpair");
   function Spawn_Worker
     (Program        : C.char_array;
      Socket         : C.int;
      Corpus         : C.char_array;
      Worker_Id      : C.int;
      Segment_Length : C.unsigned_long_long;
      Index_Capacity : C.int;
      Width          : C.int;
      Height         : C.int;
      Passes         : C.int;
      Index_Rounds   : C.int;
      PID            : access C.int) return C.int;
   pragma Import
     (C, Spawn_Worker, "flyology_showcase_spawn_image_worker");
   function Poll_Worker (PID : C.int) return C.int;
   pragma Import
     (C, Poll_Worker, "flyology_showcase_poll_image_worker");
   function Close_Descriptor (Descriptor : C.int) return C.int;
   pragma Import (C, Close_Descriptor, "close");
   function Kill_Process (PID, Signal : C.int) return C.int;
   pragma Import (C, Kill_Process, "kill");
   function Is_A_Terminal (Descriptor : C.int) return C.int;
   pragma Import (C, Is_A_Terminal, "isatty");
   function Trimmed (Value : String) return String is
     (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both));
   function Image (Value : Natural) return String is
     (Trimmed (Natural'Image (Value)));
   function Image (Value : DS.Byte_Count) return String is
     (Trimmed (DS.Byte_Count'Image (Value)));
   function Image (Value : Model.U64) return String is
     (Trimmed (Model.U64'Image (Value)));
   function Pad (Text : String; Width : Positive) return String is
      Result : String (1 .. Width) := (others => ' ');
      Count  : constant Natural := Natural'Min (Text'Length, Width);
   begin
      if Count > 0 then
         Result (1 .. Count) := Text (Text'First .. Text'First + Count - 1);
      end if;
      return Result;
   end Pad;
   function Wide (Value : String) return Wide_Wide_String is
     (Ada.Characters.Conversions.To_Wide_Wide_String (Value));
   function Batch_Token
     (Batch        : Model.U64;
      Worker_Limit : Natural) return Ada.Streams.Stream_Element_Array
   is
      Result : Ada.Streams.Stream_Element_Array (1 .. 16);
      Limit  : constant Model.U64 := Model.U64 (Worker_Limit);
   begin
      for Byte_Index in 0 .. 7 loop
         Result
           (Result'First + Ada.Streams.Stream_Element_Offset (Byte_Index)) :=
             Ada.Streams.Stream_Element
           (Interfaces.Shift_Right
              (Batch, Byte_Index * 8) and 16#FF#);
         Result
           (Result'First +
            Ada.Streams.Stream_Element_Offset (Byte_Index + 8)) :=
             Ada.Streams.Stream_Element
           (Interfaces.Shift_Right
              (Limit, Byte_Index * 8) and 16#FF#);
      end loop;
      return Result;
   end Batch_Token;
   function Next_Power_Of_Two (Value : Positive) return Positive is
      Result : Positive := 1;
   begin
      while Result < Value loop
         if Result > Positive'Last / 2 then
            raise Constraint_Error with "image index capacity overflows";
         end if;
         Result := Result * 2;
      end loop;
      return Result;
   end Next_Power_Of_Two;
   function Align_64 (Value : DS.Byte_Count) return DS.Byte_Count is
     ((Value + 63) / 64 * 64);
   function Align_Mapping (Value : DS.Byte_Count) return DS.Byte_Count is
     ((Value + 65_535) / 65_536 * 65_536);
   function Segment_Length (Index_Capacity : Positive) return DS.Byte_Count is
      Total : DS.Byte_Count :=
        Segments.Required_Registry_Storage (Segment_Config);
   begin
      Total := Align_64 (Total) + Align_64
        (Job_Rings.Required_Storage (Model.Job_Ring_Capacity));
      Total := Align_64 (Total) + Align_64
        (Result_Rings.Required_Storage (Model.Result_Ring_Capacity));
      Total := Align_64 (Total) + Align_64
        (Image_Maps.Required_Storage (Index_Capacity));
      Total := Align_64 (Total) + Align_64
        (Strings.Required_Storage (Model.Gate_Capacity));
      Total := Align_64 (Total) + Align_64
        (Strings.Required_Storage (Model.Race_Capacity));
      --  Darwin POSIX shared memory uses the host VM-page geometry.  A
      --  64-KiB multiple is exact on the supported 4-, 16-, and 64-KiB page
      --  configurations while leaving the object layouts themselves at their
      --  required 64-byte alignment.
      return Align_Mapping (Total + 4_096);
   end Segment_Length;
   function Interactive_Terminal return Boolean is
     (Is_A_Terminal (0) = 1
      and then Is_A_Terminal (1) = 1
      and then not Env.Exists ("NO_COLOR")
      and then (not Env.Exists ("TERM") or else Env.Value ("TERM") /= "dumb"));
   Dashboard_Terminal : TUI_POSIX.POSIX_Backend;
   Dashboard_Active : Boolean := False;
   procedure Begin_Dashboard
     (Terminal_Width, Terminal_Height : out Natural)
   is
      Available : Boolean := False;
   begin
      Terminal_Width := 80;
      Terminal_Height := 24;
      if Interactive_Terminal then
         TUI_POSIX.Open (Dashboard_Terminal);
         TUI_POSIX.Current_Size
           (Dashboard_Terminal,
            Terminal_Width,
            Terminal_Height,
            Available);
         if not Available then
            Terminal_Width := 80;
            Terminal_Height := 24;
         end if;
         Dashboard_Active := True;
      end if;
   exception
      when others =>
         TUI_POSIX.Close (Dashboard_Terminal);
         Dashboard_Active := False;
         raise;
   end Begin_Dashboard;
   procedure End_Dashboard is
   begin
      if Dashboard_Active then
         TUI_POSIX.Close (Dashboard_Terminal);
         Dashboard_Active := False;
      end if;
   end End_Dashboard;
   Muted_Style : constant TUI_Styles.Style :=
     TUI_Styles.With_Foreground
       (TUI_Styles.Default,
        TUI_Colors.Basic (TUI_Colors.Bright_Black));
   Border_Style : constant TUI_Styles.Style := Muted_Style;
   Title_Style : constant TUI_Styles.Style :=
     TUI_Styles.Emphasized
       (TUI_Styles.With_Foreground
          (TUI_Styles.Default, TUI_Colors.True_Color (90, 86, 224)));
   Movement_Style : constant TUI_Styles.Style :=
     TUI_Styles.With_Foreground
       (TUI_Styles.Default, TUI_Colors.True_Color (117, 113, 249));
   Completion_Style : constant TUI_Styles.Style :=
     TUI_Styles.Emphasized
       (TUI_Styles.With_Foreground
          (TUI_Styles.Default, TUI_Colors.True_Color (0, 170, 118)));
   Warning_Style : constant TUI_Styles.Style :=
     TUI_Styles.Emphasized
       (TUI_Styles.With_Foreground
          (TUI_Styles.Default, TUI_Colors.True_Color (214, 139, 44)));
   Error_Style : constant TUI_Styles.Style :=
     TUI_Styles.Emphasized
       (TUI_Styles.With_Foreground
          (TUI_Styles.Default, TUI_Colors.True_Color (198, 40, 80)));
   Dashboard_Theme : constant TUI_Themes.Theme :=
     (Primary     => TUI_Styles.Default,
      Muted       => Muted_Style,
      Selected    => Completion_Style,
      Focused     => Warning_Style,
      Border      => Border_Style,
      Input       => TUI_Styles.Default,
      Placeholder => Muted_Style,
      Error       => Error_Style,
      Success     => Completion_Style);
   type Count_Array is array (Positive range <>) of Natural;
   type Extent_Id is
     (Pending_Jobs, Completed_Results, Image_Index, Start_Gate, Startup_Race);
   type Layout_Entry is record
      Location : DS.Region_Offset := 0;
      Length   : DS.Byte_Count := 0;
   end record;
   type Segment_Layout is array (Extent_Id) of Layout_Entry;
   function Extent_Name (Id : Extent_Id) return String is
     (case Id is
         when Pending_Jobs      => Model.Job_Ring_Name,
         when Completed_Results => Model.Result_Ring_Name,
         when Image_Index       => Model.Index_Name,
         when Start_Gate        => Model.Gate_Name,
         when Startup_Race      => Model.Race_Name);
   function Extent_Kind (Id : Extent_Id) return String is
     (case Id is
         when Pending_Jobs | Completed_Results => "MPMC ring",
         when Image_Index                       => "hash map",
         when Start_Gate | Startup_Race         => "byte string");

   type Segment_Column is
     (Name_Column, Offset_Column, Length_Column, Kind_Column,
      Activity_Column);

   type Segment_Row is record
      Id       : Extent_Id;
      Location : DS.Region_Offset;
      Length   : DS.Byte_Count;
      Activity : Wide_Text.Unbounded_Wide_Wide_String;
   end record;

   function Segment_Row_Id (Item : Segment_Row) return Extent_Id is (Item.Id);

   function Segment_Cell
     (Item   : Segment_Row;
      Column : Segment_Column) return Wide_Wide_String
   is
     (case Column is
         when Name_Column     => Wide (Extent_Name (Item.Id)),
         when Offset_Column   =>
           Wide ("@" & Image (DS.Byte_Count (Item.Location))),
         when Length_Column   => Wide ("+" & Image (Item.Length)),
         when Kind_Column     => Wide (Extent_Kind (Item.Id)),
         when Activity_Column =>
           Wide_Text.To_Wide_Wide_String (Item.Activity));

   function Segment_Less
     (Left, Right : Segment_Row;
      Column      : Segment_Column) return Boolean
   is
      pragma Unreferenced (Column);
   begin
      return Left.Id < Right.Id;
   end Segment_Less;

   package Segment_Tables is new Flyology_TUI.Components.Tables
     (Item_Type => Segment_Row,
      Id_Type   => Extent_Id,
      Column_Id => Segment_Column,
      Id_Of     => Segment_Row_Id,
      Cell      => Segment_Cell,
      Less      => Segment_Less,
      Capacity  => 5);
   Last_Work_Bucket : Natural := Natural'Last;
   function Framed_Panel
     (Title         : String;
      Contents      : TUI_Surfaces.Surface;
      Width, Height : Natural) return TUI_Surfaces.Surface
   is
      Inner_Width : constant Natural :=
        (if Width > 4 then Width - 4 else 0);
      Inner_Height : constant Natural :=
        (if Height > 4 then Height - 4 else 0);
      Content : TUI_Surfaces.Surface :=
        TUI_Surfaces.Create (Inner_Width, Inner_Height);
      Frame : constant TUI_Layouts.Block :=
        (Width      => Width,
         Height     => Height,
         Padding    => (Top => 1, Right => 1, Bottom => 1, Left => 1),
         Border     => TUI_Layouts.Rounded,
         Appearance => Border_Style,
         others     => <>);
   begin
      if Inner_Height > 0 then
         Content.Write (0, 0, Wide (Title), Title_Style);
      end if;
      if Inner_Height > 1 then
         Content.Overlay
           (Indicators.Divider (Inner_Width, Theme => Dashboard_Theme), 0, 1);
      end if;
      if Inner_Height > 2 then
         Content.Overlay (Contents, 0, 2);
      end if;
      return TUI_Layouts.Render (Frame, Content);
   end Framed_Panel;
   function Segment_Body
     (Layout         : Segment_Layout;
      Mapped_Length  : DS.Byte_Count;
      Queued         : Natural;
      Completed      : Natural;
      Total          : Positive;
      Workers_Ready  : Natural;
      Workers_Done   : Natural;
      Worker_Count   : Positive;
      Queue_Pressure : Natural;
      Index_Retries  : Natural;
      Registry_Retries : Natural;
      Width, Height  : Natural) return TUI_Surfaces.Surface
   is
      Result : TUI_Surfaces.Surface := TUI_Surfaces.Create (Width, Height);
      Valid : constant TUI_Surfaces.Surface :=
        Indicators.Badge
          ("VALID", Indicators.Success_Tone, Dashboard_Theme);

      function Activity_For (Id : Extent_Id) return String is
        (case Id is
            when Pending_Jobs =>
              "push " & Image (Queued) & " / pressure " &
              Image (Queue_Pressure),
            when Completed_Results =>
              "drain " & Image (Completed) & "/" & Image (Total),
            when Image_Index =>
              "publish " & Image (Completed) & " / retries " &
              Image (Index_Retries),
            when Start_Gate =>
              "attached " & Image (Workers_Ready) & "/" &
              Image (Worker_Count) & " / done " & Image (Workers_Done),
            when Startup_Race =>
              "creator 1 / retries " & Image (Registry_Retries));

      function Make_Row (Id : Extent_Id) return Segment_Row is
        (Id       => Id,
         Location => Layout (Id).Location,
         Length   => Layout (Id).Length,
         Activity => Wide_Text.To_Unbounded_Wide_Wide_String
           (Wide (Activity_For (Id))));

      Rows : constant Segment_Tables.Item_Array :=
        (1 => Make_Row (Pending_Jobs),
         2 => Make_Row (Completed_Results),
         3 => Make_Row (Image_Index),
         4 => Make_Row (Start_Gate),
         5 => Make_Row (Startup_Race));
      Table_Y : constant Natural :=
        (if Height >= 8 then 2 elsif Height >= 7 then 1 else 0);
      Available_Height : constant Natural := Height - Table_Y;
      Visible_Rows : constant Natural :=
        (if Available_Height > 1
         then Natural'Min (5, Available_Height - 1) else 0);
      Column_Space : constant Natural :=
        (if Width > 6 then Width - 6 else 0);
      Name_Width : constant Natural := Column_Space * 32 / 100;
      Offset_Width : constant Natural := Column_Space * 14 / 100;
      Length_Width : constant Natural := Column_Space * 14 / 100;
      Kind_Width : constant Natural := Column_Space * 18 / 100;
      Activity_Width : constant Natural :=
        Column_Space - Name_Width - Offset_Width - Length_Width - Kind_Width;
      Columns : constant Segment_Tables.Column_Definitions :=
        [Name_Column =>
           (Heading       =>
              Wide_Text.To_Unbounded_Wide_Wide_String ("Name"),
            Width         => Name_Width,
            Minimum_Width => 0,
            Align         => Segment_Tables.Align_Left,
            Sortable      => False),
         Offset_Column =>
           (Heading       =>
              Wide_Text.To_Unbounded_Wide_Wide_String ("Offset"),
            Width         => Offset_Width,
            Minimum_Width => 0,
            Align         => Segment_Tables.Align_Right,
            Sortable      => False),
         Length_Column =>
           (Heading       =>
              Wide_Text.To_Unbounded_Wide_Wide_String ("Length"),
            Width         => Length_Width,
            Minimum_Width => 0,
            Align         => Segment_Tables.Align_Right,
            Sortable      => False),
         Kind_Column =>
           (Heading       =>
              Wide_Text.To_Unbounded_Wide_Wide_String ("Kind"),
            Width         => Kind_Width,
            Minimum_Width => 0,
            Align         => Segment_Tables.Align_Left,
            Sortable      => False),
         Activity_Column =>
           (Heading       =>
              Wide_Text.To_Unbounded_Wide_Wide_String ("Activity"),
            Width         => Activity_Width,
            Minimum_Width => 0,
            Align         => Segment_Tables.Align_Left,
            Sortable      => False)];
      Table : Segment_Tables.Model :=
        Segment_Tables.Create
          (Rows, Columns, Viewport_Rows => Visible_Rows, Enabled => True);
      Table_Look : constant Segment_Tables.Appearance :=
        (Header   => Muted_Style,
         Normal   => TUI_Styles.Default,
         Selected => Title_Style,
         Focused  => Movement_Style,
         Muted    => Muted_Style,
         Divider  => Border_Style);
   begin
      if Height = 0 or else Width = 0 then
         return Result;
      end if;
      if Table_Y > 0 then
         Result.Overlay (Valid, 0, 0);
      end if;
      if Table_Y > 0 and then Width > 9 then
         Result.Write
           (9, 0,
            Wide
              ("SHOWIMG/1  " & Image (Mapped_Length) &
               " bytes  64-byte alignment"),
            Muted_Style);
      end if;
      if Table_Y > 1 then
         Result.Write
           (0, 1, "registry: fixed capacity, exact names, stored offsets",
            Muted_Style);
      end if;
      Segment_Tables.Select_Id (Table, Image_Index);
      Result.Overlay
        (Segment_Tables.Render (Table, Table_Look), 0, Table_Y);
      return Result;
   end Segment_Body;
   procedure Put_Stored_Layout
     (Layout        : Segment_Layout;
      Mapped_Length : DS.Byte_Count;
      File          : IO.File_Type)
   is
   begin
      IO.Put_Line
        (File,
         "  stored segment layout: " & Image (Mapped_Length) &
         " mapped bytes");
      for Id in Extent_Id loop
         IO.Put_Line
           (File,
            "    " & Pad (Extent_Name (Id), 24) & " offset=" &
            Pad (Image (DS.Byte_Count (Layout (Id).Location)), 7) &
            " length=" & Pad (Image (Layout (Id).Length), 7) &
            " " & Extent_Kind (Id) & " ready");
      end loop;
   end Put_Stored_Layout;
   procedure Show_Work
     (Generated          : Natural;
      Queued             : Natural;
      Completed          : Natural;
      Total              : Positive;
      Batch              : Positive;
      Workers_Ready      : Natural;
      Workers_Done       : Natural;
      Worker_Count       : Positive;
      Maximum_Worker_Count : Positive;
      Generator_Paused   : Boolean;
      Source_Waiting     : Boolean;
      Producer_Backoffs  : Natural;
      Source_Gaps        : Natural;
      Queue_Pressure     : Natural;
      Index_Retries      : Natural;
      Registry_Retries   : Natural;
      Per_Worker         : Count_Array;
      Width, Height      : Positive;
      Passes             : Positive;
      Layout             : Segment_Layout;
      Mapped_Length      : DS.Byte_Count;
      Started            : RT.Time;
      Terminal_Width     : Natural;
      Terminal_Height    : Natural;
      Stop_Pending       : Boolean)
   is
      Percent : constant Natural := Completed * 100 / Total;
      Bucket  : constant Natural := Percent / 10;
      Elapsed : constant Duration := RT.To_Duration (RT.Clock - Started);
      Rate    : constant Long_Float :=
        (if Elapsed <= 0.0 then 0.0
         else Long_Float (Completed) / Long_Float (Elapsed));
      MiB     : constant Long_Float :=
        Long_Float (Completed) * Long_Float (Width) * Long_Float (Height) *
        3.0 * Long_Float (Passes) / 1_048_576.0;
      function Workload_Body
        (Content_Width, Content_Height : Natural)
         return TUI_Surfaces.Surface
      is
         Result : TUI_Surfaces.Surface :=
           TUI_Surfaces.Create (Content_Width, Content_Height);
         State_Label : constant Wide_Wide_String :=
           (if Stop_Pending then "STOPPING"
            elsif Generator_Paused then "BACKOFF"
            elsif Source_Waiting then "SOURCE GAP"
            else "FLOW");
         State_Tone : constant Indicators.Tone :=
           (if Stop_Pending then Indicators.Warning_Tone
            elsif Generator_Paused then Indicators.Warning_Tone
            elsif Source_Waiting then Indicators.Neutral
            else Indicators.Success_Tone);
         State_Badge : constant TUI_Surfaces.Surface :=
           Indicators.Badge (State_Label, State_Tone, Dashboard_Theme);
         Gauge_Width : constant Natural :=
           (if Content_Width > 7 then Content_Width - 7 else Content_Width);
         Progress : constant Indicators.Ratio :=
           Indicators.Ratio
             (Long_Float (Completed) / Long_Float (Total));
         procedure Put_Value
           (Row : Natural; Key, Value : String)
         is
         begin
            if Row < Content_Height then
               Result.Overlay
                 (Indicators.Key_Value
                    (Wide (Key), Wide (Value), Content_Width,
                     Dashboard_Theme),
                  0, Row);
            end if;
         end Put_Value;
      begin
         if Content_Height = 0 or else Content_Width = 0 then
            return Result;
         end if;
         Result.Overlay (State_Badge, 0, 0);
         if Content_Height > 1 then
            Result.Write
               (0, 1,
                (if Stop_Pending then
                   "generation stopped; admitted work is draining"
                elsif Generator_Paused then
                   "producer paused at saturation; extra workers are draining"
                elsif Source_Waiting then
                   "irregular upstream gap; workers continue consuming"
                else
                   "generation and indexing share one bounded pipeline"),
               Muted_Style);
         end if;
         if Content_Height > 2 then
            Result.Overlay
              (Indicators.Gauge
                 (Progress, Gauge_Width, Dashboard_Theme),
               0, 2);
            if Content_Width > Gauge_Width then
               Result.Write
                 (Gauge_Width + 1, 2,
                  Wide (Pad (Image (Percent) & "%", 6)), Title_Style);
            end if;
         end if;
         Put_Value (3, "generated", Image (Generated) & " / " & Image (Total));
         Put_Value (4, "queued", Image (Queued) & " / " & Image (Total));
         Put_Value (5, "indexed", Image (Completed) & " / " & Image (Total));
         Put_Value
           (6, "workers",
            Image (Workers_Ready) & " ready  " & Image (Workers_Done) &
            " done  " & Image (Worker_Count) & " active");
         Put_Value
           (7, "throughput",
            Showcase_Support.Fixed_Image (Rate, 1) & " images/s  " &
            Showcase_Support.Fixed_Image
              ((if Elapsed <= 0.0 then 0.0
                else MiB / Long_Float (Elapsed)), 1) & " MiB/s");
         Put_Value
           (8, "flow",
            Image (Producer_Backoffs) & " backoffs  " &
            Image (Source_Gaps) & " source gaps");
         Put_Value
           (9, "contention",
            Image (Queue_Pressure) & " queue  " & Image (Index_Retries) &
            " index  " & Image (Registry_Retries) & " registry");
         return Result;
      end Workload_Body;
      function Workers_Body
        (Content_Width, Content_Height : Natural)
         return TUI_Surfaces.Surface
      is
         Result : TUI_Surfaces.Surface :=
           TUI_Surfaces.Create (Content_Width, Content_Height);
         Available_Rows : constant Natural :=
           (if Content_Height > 2 then Content_Height - 2 else 0);
         Visible_Rows : constant Natural :=
           Natural'Min (Maximum_Worker_Count, Available_Rows);
         Expected : constant Positive :=
           Natural'Max (1, (Total + Worker_Count - 1) / Worker_Count);
         Gauge_Width : constant Natural :=
           (if Content_Width > 29 then Content_Width - 29 else 0);
      begin
         if Content_Height = 0 or else Content_Width = 0 then
            return Result;
         end if;
         Result.Write
           (0, 0,
            Wide
              (Image (Workers_Ready) & " ready  " &
               Image (Worker_Count) & " active  " &
               Image (Maximum_Worker_Count) & " slots"),
            Muted_Style);
         if Content_Height > 1 then
            Result.Overlay
              (Indicators.Divider
                 (Content_Width, Theme => Dashboard_Theme),
               0, 1);
         end if;
         if Visible_Rows > 0 then
            for Worker in 1 .. Visible_Rows loop
               declare
                  Row : constant Natural := Worker + 1;
                  Active : constant Boolean := Worker <= Worker_Count;
                  Count : constant Natural := Per_Worker (Worker);
                  Fraction : constant Indicators.Ratio :=
                    Indicators.Ratio
                      (Long_Float'Min
                         (1.0, Long_Float (Count) / Long_Float (Expected)));
                  Count_Label : constant String :=
                    (if Active then Image (Count) & " images"
                     elsif Count = 0 then "available"
                     else "drained " & Image (Count));
                  Count_X : constant Natural :=
                    (if Count_Label'Length >= Content_Width then 0
                     else Content_Width - Count_Label'Length);
               begin
                  Result.Put
                    (0, Row, (if Active then "●" else "○"),
                     (if Active and then Count > 0 then Completion_Style
                      elsif Active then Movement_Style else Muted_Style));
                  if Content_Width > 2 then
                     Result.Write
                       (2, Row, Wide ("worker " & Pad (Image (Worker), 2)),
                        (if Active then TUI_Styles.Default else Muted_Style));
                  end if;
                  if Gauge_Width > 0 then
                     Result.Overlay
                       (Indicators.Gauge
                          ((if Active then Fraction else 0.0),
                           Gauge_Width, Dashboard_Theme),
                        12, Row);
                  end if;
                  Result.Write
                    (Count_X, Row, Wide (Count_Label),
                     (if Active then Muted_Style else Border_Style));
               end;
            end loop;
         end if;
         if Maximum_Worker_Count > Visible_Rows
           and then Content_Height > 2
         then
            Result.Write
              (0, Content_Height - 1,
               Wide
                 ("+" & Image (Maximum_Worker_Count - Visible_Rows) &
                  " worker slots; resize to inspect"),
               Muted_Style);
         end if;
         return Result;
      end Workers_Body;
      function Current_View return TUI_Views.View is
         Canvas_Width : constant Natural := Natural'Max (1, Terminal_Width);
         Canvas_Height : constant Natural := Natural'Max (1, Terminal_Height);
         Canvas : TUI_Surfaces.Surface :=
           TUI_Surfaces.Create (Canvas_Width, Canvas_Height);
         Body_Y : constant Natural := Natural'Min (2, Canvas_Height);
         Body_Height : constant Natural :=
           (if Canvas_Height > 3 then Canvas_Height - 3 else 0);
         State_Label : constant String :=
           (if Stop_Pending then "stopping"
            elsif Generator_Paused then "backoff"
            elsif Source_Waiting then "source gap"
            else "flow");
         State_Tone : constant Indicators.Tone :=
           (if Stop_Pending or else Generator_Paused
            then Indicators.Warning_Tone
            elsif Source_Waiting then Indicators.Neutral
            else Indicators.Success_Tone);
         Status : constant TUI_Surfaces.Surface :=
           Indicators.Status_Line
             ([Indicators.Make_Segment
                 (Wide ("epoch " & Image (Batch)), Indicators.Critical),
               Indicators.Make_Segment
                 (Wide (State_Label), Indicators.Critical, State_Tone),
               Indicators.Make_Segment
                 (Wide (Image (Percent) & "% indexed"), Indicators.High,
                  Indicators.Success_Tone),
               Indicators.Make_Segment
                 (Wide
                    (Image (Worker_Count) & "/" &
                     Image (Maximum_Worker_Count) & " workers"),
                  Indicators.Normal),
               Indicators.Make_Segment
                 (Wide ("segment valid / 5 extents"), Indicators.Low,
                  Indicators.Success_Tone)],
              Canvas_Width, Dashboard_Theme);
         Result : TUI_Views.View;
      begin
         Canvas.Write (0, 0, "FLYOLOGY", Title_Style);
         if Canvas_Width > 10 then
            Canvas.Write
              (10, 0, "shared image index", TUI_Styles.Default);
         end if;
         if Canvas_Height > 1 then
            Canvas.Overlay (Status, 0, 1);
         end if;
         if Canvas_Width < 44 or else Canvas_Height < 12 then
            if Canvas_Height > 3 then
               Canvas.Write
                 (0, 3, "Terminal too small for the dashboard", Warning_Style);
            end if;
            if Canvas_Height > 5 then
               Canvas.Overlay
                 (Indicators.Gauge
                    (Indicators.Ratio
                       (Long_Float (Completed) / Long_Float (Total)),
                     Canvas_Width, Dashboard_Theme),
                  0, 5);
            end if;
         elsif Canvas_Width >= 108 and then Body_Height >= 26 then
            declare
               Right_Width : constant Natural :=
                 Natural'Max (34, Canvas_Width / 3);
               Left_Width : constant Natural :=
                 Canvas_Width - Right_Width - 1;
               Work_Height : constant Natural :=
                 Natural'Max (12, (Body_Height - 1) / 2);
               Segment_Height : constant Natural :=
                 Body_Height - Work_Height - 1;
            begin
               Canvas.Overlay
                 (Framed_Panel
                    ("PIPELINE",
                     Workload_Body
                       (Left_Width - 4,
                        (if Work_Height > 6 then Work_Height - 6 else 0)),
                     Left_Width, Work_Height),
                  0, Body_Y);
               Canvas.Overlay
                 (Framed_Panel
                    ("SHARED SEGMENT",
                     Segment_Body
                       (Layout, Mapped_Length, Queued, Completed, Total,
                        Workers_Ready, Workers_Done, Worker_Count,
                        Queue_Pressure, Index_Retries, Registry_Retries,
                        Left_Width - 4,
                        (if Segment_Height > 6
                         then Segment_Height - 6 else 0)),
                     Left_Width, Segment_Height),
                  0, Body_Y + Work_Height + 1);
               Canvas.Overlay
                 (Framed_Panel
                    ("WORKERS",
                     Workers_Body
                       (Right_Width - 4,
                        (if Body_Height > 6 then Body_Height - 6 else 0)),
                     Right_Width, Body_Height),
                  Left_Width + 1, Body_Y);
            end;
         elsif Canvas_Width >= 72 and then Body_Height >= 12 then
            declare
               Right_Width : constant Natural :=
                 Natural'Max (30, Canvas_Width * 2 / 5);
               Left_Width : constant Natural :=
                 Canvas_Width - Right_Width - 1;
               Overview_Height : constant Natural :=
                 Body_Height - 6;
               Work_Rows : constant Natural :=
                 Natural'Min (8, Overview_Height);
               Segment_Rows : constant Natural := Overview_Height - Work_Rows;
               Overview : constant TUI_Surfaces.Surface :=
                 TUI_Layouts.Join_Vertically
                   (Workload_Body (Left_Width - 4, Work_Rows),
                    Segment_Body
                      (Layout, Mapped_Length, Queued, Completed, Total,
                       Workers_Ready, Workers_Done, Worker_Count,
                       Queue_Pressure, Index_Retries, Registry_Retries,
                       Left_Width - 4, Segment_Rows));
            begin
               Canvas.Overlay
                 (Framed_Panel
                    ("PIPELINE + SEGMENT", Overview,
                     Left_Width, Body_Height),
                  0, Body_Y);
               Canvas.Overlay
                 (Framed_Panel
                    ("WORKERS",
                     Workers_Body
                       (Right_Width - 4,
                        (if Body_Height > 6 then Body_Height - 6 else 0)),
                     Right_Width, Body_Height),
                  Left_Width + 1, Body_Y);
            end;
         else
            Canvas.Overlay
              (Framed_Panel
                 ("PIPELINE",
                  Workload_Body
                    (Canvas_Width - 4,
                     (if Body_Height > 6 then Body_Height - 6 else 0)),
                  Canvas_Width, Body_Height),
               0, Body_Y);
         end if;
         if Canvas_Height > 0 then
            Canvas.Write
               (0, Canvas_Height - 1,
               (if Stop_Pending then
                   "stop requested; draining admitted images"
                else "q / Esc  stop admission and drain"),
               (if Stop_Pending then Warning_Style else Muted_Style));
         end if;
         Result := TUI_Views.From_Surface (Canvas);
         Result.Alternate_Screen := True;
         Result.Bracketed_Paste := False;
         Result.Window_Title :=
           Wide_Text.To_Unbounded_Wide_Wide_String
             ("Flyology shared image index");
         return Result;
      end Current_View;
   begin
      if Dashboard_Active then
         TUI_POSIX.Render (Dashboard_Terminal, Current_View);
      elsif Bucket /= Last_Work_Bucket then
         IO.Put_Line
           ("index " & Image (Percent) & "% completed=" & Image (Completed) &
            " queue-pressure=" & Image (Queue_Pressure) &
            " index-retries=" & Image (Index_Retries));
         Last_Work_Bucket := Bucket;
      end if;
   end Show_Work;
   procedure Reserve
     (Segment          : Segments.View;
      Name             : String;
      Requested_Length : DS.Byte_Count;
      Claim            : out Segments.Creation_Claim;
      Location         : out DS.Region_Offset)
   is
      Handle  : Segments.Named_Handle;
      Outcome : Segments.Find_Or_Create_Result;
      Failure : Interfaces.Unsigned_32;
      Extent  : DS.Byte_Count;
   begin
      loop
         Segments.Try_Find_Or_Create
           (Segment, Name, Requested_Length, Handle, Claim, Outcome, Failure);
         exit when Outcome = Segments.Created;
         if Outcome /= Segments.Registry_Busy then
            raise Program_Error with
              "cannot reserve segment extent " & Name & ": " & Outcome'Image;
         end if;
         delay 0.0;
      end loop;
      Segments.Claimed_Extent (Segment, Claim, Location, Extent);
      if Extent < Requested_Length then
         raise Program_Error with
           "segment reservation is shorter than requested";
      end if;
   end Reserve;
   procedure Resolve_Ready_Extent
     (Segment  : Segments.View;
      Name     : String;
      Location : out DS.Region_Offset;
      Length   : out DS.Byte_Count)
   is
      Handle  : Segments.Named_Handle;
      Outcome : Segments.Lookup_Result;
      Failure : Interfaces.Unsigned_32;
   begin
      loop
         Segments.Try_Find (Segment, Name, Handle, Outcome, Failure);
         exit when Outcome = Segments.Found;
         if Outcome not in Segments.Registry_Busy |
           Segments.Initialization_In_Progress
         then
            raise Program_Error with
              "cannot resolve ready segment extent " & Name & ": " &
              Outcome'Image;
         end if;
         delay 0.0;
      end loop;
      Segments.Resolve (Segment, Handle, Location, Length);
   end Resolve_Ready_Extent;
   procedure Run_Coordinator is
      Corpus         : constant String := CLI.Argument (2);
      Worker_Count   : constant Positive := Positive'Value (CLI.Argument (3));
      Image_Count    : constant Positive := Positive'Value (CLI.Argument (4));
      Width          : constant Positive := Positive'Value (CLI.Argument (5));
      Height         : constant Positive := Positive'Value (CLI.Argument (6));
      Passes         : constant Positive := Positive'Value (CLI.Argument (7));
      Index_Rounds   : constant Positive := Positive'Value (CLI.Argument (8));
      Batch_Limit    : constant Natural := Natural'Value (CLI.Argument (9));
      Maximum_Workers : constant Positive :=
        (if Worker_Count >= 28 then 32 else Worker_Count + 4);
      Index_Capacity : constant Positive :=
        Next_Power_Of_Two (Image_Count * 2);
      Job_Length     : constant DS.Byte_Count :=
        Job_Rings.Required_Storage (Model.Job_Ring_Capacity);
      Result_Length  : constant DS.Byte_Count :=
        Result_Rings.Required_Storage (Model.Result_Ring_Capacity);
      Index_Length   : constant DS.Byte_Count :=
        Image_Maps.Required_Storage (Index_Capacity);
      Gate_Length    : constant DS.Byte_Count :=
        Strings.Required_Storage (Model.Gate_Capacity);
      Mapping_Size   : constant DS.Byte_Count :=
        Segment_Length (Index_Capacity);
      Program        : constant String :=
        Directories.Containing_Directory
          (Directories.Full_Name (CLI.Command_Name)) &
        "/shared_image_index_worker";
      Session_Started : constant RT.Time := RT.Clock;
      Random_State   : Model.U64 := 16#F10A_0B1E_5EED_2026#;
      Work_Started   : RT.Time;
      Last_Batch_Elapsed : Duration := 0.0;
      Session_Work_Elapsed : Duration := 0.0;
      Backing        : Shared.Backing_Object;
      Map            : Shared.Mapping;
      Segment        : Segments.View;
      Region         : Regions.View;
      Segment_State  : Segments.Segment_Open_Result;
      Jobs           : Job_Rings.View;
      Results        : Result_Rings.View;
      Index          : Image_Maps.View;
      Gate           : Strings.View;
      Claim          : Segments.Creation_Claim;
      Layout         : Segment_Layout := (others => <>);
      type PID_Array is array (Positive range <>) of aliased C.int;
      PIDs           : PID_Array (1 .. Maximum_Workers) := (others => -1);
      type Socket_Array is array (Positive range <>) of C.int;
      Worker_Sockets : Socket_Array (1 .. Maximum_Workers) := (others => -1);
      Spawned        : Natural := 0;
      Active_Workers : Natural := Worker_Count;
      Peak_Workers   : Natural := Worker_Count;
      Final_Batch_Workers : Natural := Worker_Count;
      Dynamic_Joins  : Natural := 0;
      Dynamic_Leaves : Natural := 0;
      Per_Worker     : Count_Array (1 .. Maximum_Workers) := (others => 0);
      type Hash_Array is array (Positive range <>) of Model.U64;
      Expected_Hash  : Hash_Array (1 .. Image_Count) := (others => 0);
      type Seen_Array is array (Positive range <>) of Boolean;
      Seen           : Seen_Array (1 .. Image_Count) := (others => False);
      type Worker_Boolean_Array is array (Positive range <>) of Boolean;
      Batch_Done     : Worker_Boolean_Array (1 .. Maximum_Workers) :=
        (others => False);
      Workers_Ready  : Natural := 0;
      Workers_Raced  : Natural := 0;
      Workers_Done   : Natural := 0;
      Workers_Exited : Natural := 0;
      Race_Winners   : Natural := 0;
      Extra_Workers_Active : Boolean := False;
      Batch          : Natural := 0;
      Batch_Target   : Natural := Image_Count;
      Queued         : Natural := 0;
      Sentinels      : Natural := 0;
      Completed      : Natural := 0;
      Queue_Pressure : Natural := 0;
      Producer_Backoffs : Natural := 0;
      Source_Gaps       : Natural := 0;
      Index_Retries  : Natural := 0;
      Registry_Retries : Natural := 0;
      Session_Images : Model.U64 := 0;
      Session_Image_High_Water : Natural := 0;
      Session_Dynamic_Worker_Images : Model.U64 := 0;
      Session_Queue_Pressure : Model.U64 := 0;
      Session_Producer_Backoffs : Model.U64 := 0;
      Session_Source_Gaps : Model.U64 := 0;
      Session_Index_Retries : Model.U64 := 0;
      Last_Render    : RT.Time;
      Initial_Terminal_Width  : Natural := 80;
      Initial_Terminal_Height : Natural := 24;
      procedure Stop_Children is
         Ignored : C.int;
      begin
         for Worker in Worker_Sockets'Range loop
            if Worker_Sockets (Worker) >= 0 then
               Ignored := Close_Descriptor (Worker_Sockets (Worker));
               Worker_Sockets (Worker) := -1;
            end if;
         end loop;
         for Worker in 1 .. Spawned loop
            if PIDs (Worker) > 0 then
               Ignored := Kill_Process (PIDs (Worker), 15);
            end if;
         end loop;
         for Attempt in 1 .. 5_000 loop
            declare
               Remaining : Natural := 0;
            begin
               for Worker in 1 .. Spawned loop
                  if PIDs (Worker) > 0 then
                     declare
                        Status : constant C.int := Poll_Worker (PIDs (Worker));
                     begin
                        if Status in -1 | 1 then
                           PIDs (Worker) := -1;
                        else
                           Remaining := Remaining + 1;
                        end if;
                     end;
                  end if;
               end loop;
               exit when Remaining = 0;
            end;
            delay 0.001;
         end loop;
      end Stop_Children;
      procedure Check_Children is
      begin
         for Worker in 1 .. Spawned loop
            if PIDs (Worker) > 0 then
               declare
                  Status : C.int := Poll_Worker (PIDs (Worker));
               begin
                  if Status = 2 then
                     Status := Poll_Worker (PIDs (Worker));
                  end if;
                  if Status = 1 then
                     PIDs (Worker) := -1;
                  elsif Status = -1 then
                     raise Program_Error with
                       "worker " & Image (Worker) & " exited unsuccessfully";
                  end if;
               end;
            end if;
         end loop;
      end Check_Children;
      procedure Consume (Value : Model.Image_Result) is
         Worker : Positive;
      begin
         if Value.Worker_Id = 0
           or else Natural (Value.Worker_Id) > Maximum_Workers
         then
            raise Program_Error with "result has invalid worker identity";
         end if;
         Worker := Positive (Value.Worker_Id);
         if (Value.Flags and Model.Worker_Attached) /= 0 then
            Workers_Ready := Workers_Ready + 1;
         elsif (Value.Flags and Model.Worker_Race_Done) /= 0 then
            Workers_Raced := Workers_Raced + 1;
            Registry_Retries := Registry_Retries +
              Natural (Value.Index_Retries);
            if (Value.Flags and Model.Worker_Won_Race) /= 0 then
               Race_Winners := Race_Winners + 1;
            end if;
         elsif (Value.Flags and Model.Worker_Batch_Done) /= 0 then
            if Batch = 0 or else Value.Batch_Id /= Model.U64 (Batch) then
               raise Program_Error with "worker reported the wrong epoch";
            elsif Batch_Done (Worker) then
               raise Program_Error with "worker reported an epoch twice";
            end if;
            Batch_Done (Worker) := True;
            Workers_Done := Workers_Done + 1;
         elsif (Value.Flags and Model.Worker_Finished) /= 0 then
            if Workers_Ready = 0 or else Workers_Raced = 0 then
               raise Program_Error with "worker departure counters underflow";
            end if;
            Workers_Ready := Workers_Ready - 1;
            Workers_Raced := Workers_Raced - 1;
            Workers_Exited := Workers_Exited + 1;
         elsif (Value.Flags and Model.Image_Complete) /= 0 then
            if Batch = 0 or else Value.Batch_Id /= Model.U64 (Batch) then
               raise Program_Error with "image result has the wrong epoch";
            elsif Value.Image_Id = 0
              or else Value.Image_Id > Model.U64 (Image_Count)
            then
               raise Program_Error with "result has invalid image identity";
            elsif Seen (Positive (Value.Image_Id)) then
               raise Program_Error with "duplicate image result";
            end if;
            Seen (Positive (Value.Image_Id)) := True;
            Expected_Hash (Positive (Value.Image_Id)) := Value.Content_Hash;
            Completed := Completed + 1;
            Per_Worker (Worker) := Per_Worker (Worker) + 1;
            Queue_Pressure := Queue_Pressure + Natural (Value.Queue_Retries);
            Index_Retries := Index_Retries + Natural (Value.Index_Retries);
         else
            raise Program_Error with "result has unknown event flags";
         end if;
      end Consume;
      procedure Drain_Results (Limit : Positive := 64) is
         Value   : Model.Image_Result;
         Outcome : Result_Rings.Pop_Result;
      begin
         for Attempt in 1 .. Limit loop
            Result_Rings.Try_Pop (Results, Value, Outcome);
            exit when Outcome /= Result_Rings.Popped;
            Consume (Value);
         end loop;
      end Drain_Results;
      procedure Wait_For (Target : String) is
         Started : constant RT.Time := RT.Clock;
      begin
         loop
            Drain_Results;
            Check_Children;
            exit when
              (Target = "attached" and then Workers_Ready = Active_Workers)
              or else
                (Target = "raced" and then Workers_Raced = Active_Workers)
              or else
                (Target = "topology"
                 and then Workers_Ready = Active_Workers
                 and then Workers_Raced = Active_Workers)
              or else
                (Target = "exited" and then Workers_Ready = 0);
            if RT.To_Duration (RT.Clock - Started) > 30.0 then
               raise Program_Error with
                 "timed out waiting for workers to be " & Target;
            end if;
            delay 0.001;
         end loop;
      end Wait_For;
      procedure Advance_Gate
        (Next_Batch  : Model.U64;
         Worker_Limit : Natural)
      is
      begin
         loop
            begin
               Strings.Assign
                 (Gate, Batch_Token (Next_Batch, Worker_Limit));
               exit;
            exception
               when DS.Busy_Error => delay 0.0;
            end;
         end loop;
      end Advance_Gate;
      procedure Start_Worker (Worker : Positive) is
         Left, Right : aliased C.int := -1;
         Status : C.int;
      begin
         if Worker > Maximum_Workers or else PIDs (Worker) >= 0 then
            raise Program_Error with "worker process slot is unavailable";
         elsif Socketpair (Left'Access, Right'Access) /= 0 then
            raise Program_Error with "worker socketpair creation failed";
         end if;
         Status := Spawn_Worker
           (C.To_C (Program), Right, C.To_C (Corpus), C.int (Worker),
            C.unsigned_long_long (Mapping_Size), C.int (Index_Capacity),
            C.int (Width), C.int (Height), C.int (Passes),
            C.int (Index_Rounds), PIDs (Worker)'Access);
         declare
            Ignored : constant C.int := Close_Descriptor (Right);
            pragma Unreferenced (Ignored);
         begin
            Right := -1;
         end;
         if Status /= 0 then
            raise Program_Error with
              "worker spawn failed (error" & C.int'Image (Status) & ")";
         end if;
         Spawned := Natural'Max (Spawned, Worker);
         Unix.Send (Unix.Socket_Descriptor (Left), Backing, Unix.Borrow);
         Worker_Sockets (Worker) := Left;
      end Start_Worker;
      procedure Close_Handoff_Sockets is
      begin
         for Worker in Worker_Sockets'Range loop
            if Worker_Sockets (Worker) >= 0 then
               declare
                  Ignored : constant C.int :=
                    Close_Descriptor (Worker_Sockets (Worker));
                  pragma Unreferenced (Ignored);
               begin
                  Worker_Sockets (Worker) := -1;
               end;
            end if;
         end loop;
      end Close_Handoff_Sockets;
      procedure Reap_Departed
        (First_Worker : Positive;
         Last_Worker  : Positive)
      is
         Started : constant RT.Time := RT.Clock;
      begin
         loop
            Check_Children;
            exit when
              (for all Worker in First_Worker .. Last_Worker =>
                 PIDs (Worker) < 0);
            if RT.To_Duration (RT.Clock - Started) > 30.0 then
               raise Program_Error with
                 "timed out reaping dynamically departed workers";
            end if;
            delay 0.001;
         end loop;
      end Reap_Departed;
      procedure Join_Workers (Target_Workers : Positive) is
         Previous_Workers : constant Positive := Positive (Active_Workers);
      begin
         if Target_Workers <= Previous_Workers then
            raise Program_Error with "dynamic join does not increase workers";
         end if;
         for Worker in Previous_Workers + 1 .. Target_Workers loop
            Start_Worker (Worker);
         end loop;
         Active_Workers := Target_Workers;
         Wait_For ("attached");
         Close_Handoff_Sockets;
         Wait_For ("raced");
         if Race_Winners /= 1 then
            raise Program_Error with
              "registry race designated " & Image (Race_Winners) &
              " creators after dynamic join";
         end if;
         --  Joiners wait outside the job ring until these acknowledgments
         --  have arrived.  Raising the limit is their admission event.
         Advance_Gate (Model.U64 (Batch), Target_Workers);
         Peak_Workers := Natural'Max (Peak_Workers, Target_Workers);
         Dynamic_Joins :=
           Dynamic_Joins + Target_Workers - Previous_Workers;
      end Join_Workers;
      procedure Retire_Workers (Target_Workers : Positive) is
         Previous_Workers : constant Positive := Positive (Active_Workers);
      begin
         if Target_Workers >= Previous_Workers then
            raise Program_Error with
              "dynamic retirement does not reduce workers";
         end if;
         --  Lowering the limit tells departing workers to stop dequeuing.
         --  A worker drains and publishes its one possible in-flight job,
         --  then emits Worker_Finished before detaching.
         Advance_Gate (Model.U64 (Batch), Target_Workers);
         Active_Workers := Target_Workers;
         Wait_For ("topology");
         Reap_Departed (Target_Workers + 1, Previous_Workers);
         Dynamic_Leaves :=
           Dynamic_Leaves + Previous_Workers - Target_Workers;
      end Retire_Workers;
      function External_Stop_Requested return Boolean is
        (Env.Exists ("FLYOLOGY_SHOWCASE_STOP_FILE")
         and then Directories.Exists
           (Env.Value ("FLYOLOGY_SHOWCASE_STOP_FILE")));
      procedure Put_Summary (File : IO.File_Type) is
      begin
         IO.Put_Line (File, "shared image index session complete");
         IO.Put_Line
           (File, "  completed epochs:      " & Image (Batch));
         IO.Put_Line
           (File, "  image slots per epoch: " & Image (Image_Count) & " (" &
            Image (Width) & "x" & Image (Height) & " P6 PPM)");
         IO.Put_Line
           (File, "  final-epoch admitted: " & Image (Batch_Target) & " / " &
            Image (Image_Count));
         IO.Put_Line
           (File, "  generated images total: " & Image (Session_Images));
         IO.Put_Line
           (File, "  initial workers:       " & Image (Worker_Count));
         IO.Put_Line
           (File, "  peak workers:          " & Image (Peak_Workers));
         IO.Put_Line
           (File, "  final-epoch workers:   " &
            Image (Final_Batch_Workers));
         IO.Put_Line
           (File, "  dynamic joins/leaves:  " & Image (Dynamic_Joins) & "/" &
            Image (Dynamic_Leaves));
         IO.Put_Line
           (File, "  dynamic-worker images: " &
            Image (Session_Dynamic_Worker_Images));
         IO.Put_Line
           (File, "  pixel-analysis passes: " & Image (Passes));
         IO.Put_Line
           (File, "  registry race winners: " & Image (Race_Winners));
         IO.Put_Line
           (File, "  final-epoch queue pressure: " & Image (Queue_Pressure));
         IO.Put_Line
           (File, "  producer saturation backoffs: " &
            Image (Session_Producer_Backoffs));
         IO.Put_Line
           (File, "  irregular source gaps: " & Image (Session_Source_Gaps));
         IO.Put_Line
           (File, "  session queue pressure:    " &
            Image (Session_Queue_Pressure));
         IO.Put_Line
           (File, "  final-epoch index retries: " & Image (Index_Retries));
         IO.Put_Line
           (File, "  session index retries:     " &
            Image (Session_Index_Retries));
         IO.Put_Line
           (File,
            "  verified final map:    " & Image (Image_Maps.Length (Index)) &
            " entries" &
            (if Index_Rounds > 1 and then Session_Image_High_Water > 0
             then " (images + contention key)" else ""));
         IO.Put_Line
           (File,
            "  final-epoch processing: " & Showcase_Support.Fixed_Image
              (Long_Float (Last_Batch_Elapsed), 3) & " s");
         IO.Put_Line
           (File,
            "  session processing:    " & Showcase_Support.Fixed_Image
              (Long_Float (Session_Work_Elapsed), 3) & " s");
         IO.Put_Line
           (File,
            "  session wall time:     " & Showcase_Support.Fixed_Image
              (Long_Float (RT.To_Duration (RT.Clock - Session_Started)), 3) &
            " s");
         IO.Put_Line
           (File,
            "  one segment remained live while workers joined on saturation " &
            "and drained after recovery");
         IO.Put_Line
           (File,
            "  backing descriptor closed before final worker shutdown; " &
            "mappings stayed live");
         Put_Stored_Layout (Layout, Mapping_Size, File);
      end Put_Summary;
      procedure Write_Summary is
      begin
         if Env.Exists ("FLYOLOGY_SHOWCASE_SUMMARY_FILE") then
            declare
               Report : IO.File_Type;
            begin
               IO.Create
                 (Report, IO.Out_File,
                  Env.Value ("FLYOLOGY_SHOWCASE_SUMMARY_FILE"));
               Put_Summary (Report);
               IO.Close (Report);
            exception
               when others =>
                  if IO.Is_Open (Report) then
                     IO.Close (Report);
                  end if;
                  raise;
            end;
         else
            IO.New_Line;
            Put_Summary (IO.Standard_Output);
         end if;
      end Write_Summary;
   begin
      if CLI.Argument_Count /= 9 then
         raise Constraint_Error with "coordinator argument contract mismatch";
      elsif Worker_Count > 32 then
         raise Constraint_Error with "worker count must not exceed 32";
      elsif Image_Count > 100_000 then
         raise Constraint_Error with "image count must not exceed 100000";
      elsif Width > 2_048 or else Height > 2_048 then
         raise Constraint_Error with "image dimensions must not exceed 2048";
      elsif Batch_Limit = 0
        and then not Interactive_Terminal
        and then not Env.Exists ("FLYOLOGY_SHOWCASE_STOP_FILE")
      then
         raise Constraint_Error with
           "unbounded coordinator requires a stop-request path";
      end if;
      if not Directories.Exists (Corpus) then
         Directories.Create_Path (Corpus);
      elsif Directories.Kind (Corpus) /= Directories.Directory then
         raise Constraint_Error with "corpus path is not a directory";
      end if;
      if not Interactive_Terminal then
         IO.Put_Line
           ("configuration: " & Image (Worker_Count) & " initial / " &
            Image (Maximum_Workers) & " maximum workers, " &
            Image (Image_Count) & " image slots per epoch, " &
            Image (Mapping_Size) & " shared bytes");
      end if;
      Shared.Create_Anonymous (Backing, Mapping_Size);
      Shared.Map (Map, Backing);
      Segments.Create_Or_Attach
        (Segment, Map, Segment_Config, Segment_State);
      if Segment_State /= Segments.Initialized_New then
         raise Program_Error with "coordinator did not initialize segment";
      end if;
      Segments.Attach_Region (Segment, Region);
      Reserve
        (Segment, Model.Job_Ring_Name, Job_Length, Claim,
         Layout (Pending_Jobs).Location);
      Layout (Pending_Jobs).Length := Job_Length;
      Job_Rings.Initialize
        (Jobs, Region, Layout (Pending_Jobs).Location,
         Model.Job_Ring_Capacity);
      Segments.Publish (Segment, Claim);
      Reserve
        (Segment, Model.Result_Ring_Name, Result_Length, Claim,
         Layout (Completed_Results).Location);
      Layout (Completed_Results).Length := Result_Length;
      Result_Rings.Initialize
        (Results, Region, Layout (Completed_Results).Location,
         Model.Result_Ring_Capacity);
      Segments.Publish (Segment, Claim);
      Reserve
        (Segment, Model.Index_Name, Index_Length, Claim,
         Layout (Image_Index).Location);
      Layout (Image_Index).Length := Index_Length;
      Image_Maps.Initialize
        (Index, Region, Layout (Image_Index).Location, Index_Capacity);
      Segments.Publish (Segment, Claim);
      Reserve
        (Segment, Model.Gate_Name, Gate_Length, Claim,
         Layout (Start_Gate).Location);
      Layout (Start_Gate).Length := Gate_Length;
      Strings.Initialize
        (Gate, Region, Layout (Start_Gate).Location, Model.Gate_Capacity);
      Segments.Publish (Segment, Claim);
      for Worker in 1 .. Active_Workers loop
         Start_Worker (Worker);
      end loop;
      Wait_For ("attached");
      Close_Handoff_Sockets;
      Advance_Gate (1, Active_Workers);
      Wait_For ("raced");
      if Race_Winners /= 1 then
         raise Program_Error with
           "registry race designated " & Image (Race_Winners) & " creators";
      end if;
      Resolve_Ready_Extent
        (Segment, Model.Race_Name, Layout (Startup_Race).Location,
         Layout (Startup_Race).Length);
      Begin_Dashboard
        (Initial_Terminal_Width, Initial_Terminal_Height);
      declare
         protected type Dashboard_Control is
            procedure Resize (Width, Height : Natural);
            procedure Request_Stop;
            function Stop_Requested return Boolean;
            procedure Dimensions (Width, Height : out Natural);
            procedure Mark_Input_Stopped (Failed : Boolean);
            entry Wait_For_Input;
            function Input_Failed return Boolean;
         private
            Current_Width  : Natural := Initial_Terminal_Width;
            Current_Height : Natural := Initial_Terminal_Height;
            Stop_Pending   : Boolean := False;
            Input_Running  : Boolean := True;
            Input_Did_Fail : Boolean := False;
         end Dashboard_Control;
         protected body Dashboard_Control is
            procedure Resize (Width, Height : Natural) is
            begin
               Current_Width := Width;
               Current_Height := Height;
            end Resize;
            procedure Request_Stop is
            begin
               Stop_Pending := True;
            end Request_Stop;
            function Stop_Requested return Boolean is (Stop_Pending);
            procedure Dimensions (Width, Height : out Natural) is
            begin
               Width := Current_Width;
               Height := Current_Height;
            end Dimensions;
            procedure Mark_Input_Stopped (Failed : Boolean) is
            begin
               Input_Did_Fail := Failed;
               Input_Running := False;
            end Mark_Input_Stopped;
            entry Wait_For_Input when not Input_Running is
            begin
               null;
            end Wait_For_Input;
            function Input_Failed return Boolean is (Input_Did_Fail);
         end Dashboard_Control;
         Dashboard : Dashboard_Control;
         task Input_Worker;
         task body Input_Worker is
            Event  : TUI_Events.Terminal_Event;
            Status : TUI_Backends.Input_Status;
         begin
            if Dashboard_Active then
               loop
                  TUI_POSIX.Next_Event
                    (Dashboard_Terminal, Event, Status);
                  exit when Status in TUI_Backends.Interrupted |
                    TUI_Backends.End_Of_Input;
                  case Event.Kind is
                     when TUI_Events.Resize =>
                        Dashboard.Resize (Event.Width, Event.Height);
                     when TUI_Events.Interrupt =>
                        Dashboard.Request_Stop;
                     when TUI_Events.Key_Press =>
                        case Event.Key.Kind is
                           when TUI_Events.Escape_Key =>
                              Dashboard.Request_Stop;
                           when TUI_Events.Text_Key =>
                              declare
                                 Key : constant Wide_Wide_String :=
                                   Wide_Text.To_Wide_Wide_String
                                     (Event.Key.Value);
                              begin
                                 if Key = "q" or else Key = "Q"
                                   or else
                                     (Key = "c"
                                      and then Event.Key.Modified.Control)
                                 then
                                    Dashboard.Request_Stop;
                                 end if;
                              end;
                           when others => null;
                        end case;
                     when others => null;
                  end case;
               end loop;
            end if;
            Dashboard.Mark_Input_Stopped (False);
         exception
            when others =>
               Dashboard.Mark_Input_Stopped (True);
         end Input_Worker;
         procedure Stop_Dashboard_Input (Check_Failure : Boolean := True) is
         begin
            if Dashboard_Active then
               begin
                  TUI_POSIX.Interrupt (Dashboard_Terminal);
               exception
                  when others => null;
               end;
            end if;
            Dashboard.Wait_For_Input;
            if Check_Failure and then Dashboard.Input_Failed then
               raise Program_Error with "terminal input task failed";
            end if;
         end Stop_Dashboard_Input;
         procedure Render_Current
           (Generated        : Natural;
            Generator_Paused : Boolean;
            Source_Waiting   : Boolean)
         is
            Terminal_Width, Terminal_Height : Natural;
         begin
            Dashboard.Dimensions (Terminal_Width, Terminal_Height);
            Show_Work
              (Generated, Queued, Completed, Image_Count, Positive (Batch),
               Workers_Ready, Workers_Done, Positive (Active_Workers),
               Maximum_Workers, Generator_Paused, Source_Waiting,
               Producer_Backoffs, Source_Gaps, Queue_Pressure, Index_Retries,
               Registry_Retries, Per_Worker, Width, Height, Passes, Layout,
               Mapping_Size, Work_Started, Terminal_Width, Terminal_Height,
               Dashboard.Stop_Requested or else External_Stop_Requested);
         end Render_Current;
      begin
         Batch := 1;
         loop
            Queued := 0;
            Sentinels := 0;
            Completed := 0;
            Workers_Done := 0;
            Queue_Pressure := 0;
            Producer_Backoffs := 0;
            Source_Gaps := 0;
            Index_Retries := 0;
            Per_Worker := (others => 0);
            Seen := (others => False);
            Batch_Done := (others => False);
            Extra_Workers_Active := False;
            Batch_Target := Image_Count;
            Last_Work_Bucket := Natural'Last;
            Work_Started := RT.Clock;
            Last_Render := Work_Started;
            declare
               Generator_Paused : Boolean := False;
               Source_Waiting   : Boolean := False;
               Pending_Image    : Natural := 0;
               Recovery_Queued  : Natural := 0;
               Burst_Remaining  : Natural := 72 + (Batch * 17) mod 32;
               Source_Resume    : RT.Time := RT.Clock;
               High_Water       : constant Natural :=
                 Natural'Max (8, Model.Job_Ring_Capacity / 2);
               Low_Water        : constant Natural :=
                 Natural'Max (1, High_Water / 2);
               Stop_Observed    : Boolean := False;
               procedure Observe_Stop is
               begin
                  if not Stop_Observed
                    and then
                      (Dashboard.Stop_Requested
                       or else External_Stop_Requested)
                  then
                     Stop_Observed := True;
                     Batch_Target := Queued;
                     Pending_Image := 0;
                     Generator_Paused := False;
                     Source_Waiting := False;
                  end if;
               end Observe_Stop;
            begin
               while Completed < Batch_Target
                 or else Workers_Done < Active_Workers
               loop
                  Observe_Stop;
                  if Generator_Paused
                    and then Queued - Completed <= Low_Water
                  then
                     Generator_Paused := False;
                     Recovery_Queued := Queued;
                  end if;
                  if Source_Waiting and then RT.Clock >= Source_Resume then
                     Source_Waiting := False;
                     Burst_Remaining := 8 + (Queued * 13 + Batch * 17) mod 96;
                  end if;
                  if not Generator_Paused
                    and then not Source_Waiting
                    and then not Stop_Observed
                    and then Queued < Image_Count
                  then
                     if Pending_Image = 0 then
                        Pending_Image := Queued + 1;
                        Model.Generate_Image
                          (Model.Image_Path (Corpus, Pending_Image), Width,
                           Height, Random_State);
                     end if;
                     Observe_Stop;
                     if not Stop_Observed then
                        declare
                           Job : constant Model.Image_Job :=
                             (Batch_Id => Model.U64 (Batch),
                              Image_Id => Model.U64 (Pending_Image));
                           Outcome : Job_Rings.Push_Result;
                        begin
                           Job_Rings.Try_Push (Jobs, Job, Outcome);
                           case Outcome is
                              when Job_Rings.Pushed =>
                                 Queued := Queued + 1;
                                 Pending_Image := 0;
                                 if Queued - Completed >= High_Water
                                   and then Queued < Image_Count
                                 then
                                    Generator_Paused := True;
                                    Producer_Backoffs :=
                                      Producer_Backoffs + 1;
                                 end if;
                                 Burst_Remaining := Burst_Remaining - 1;
                                 if Burst_Remaining = 0
                                   and then Queued < Image_Count
                                 then
                                    Source_Waiting := True;
                                    Source_Gaps := Source_Gaps + 1;
                                    Source_Resume :=
                                      RT.Clock + RT.Milliseconds
                                        (20 + (Queued * 29 + Batch * 11)
                                         mod 81);
                                 end if;
                              when Job_Rings.Full |
                                Job_Rings.Push_Contended =>
                                 Generator_Paused := True;
                                 Producer_Backoffs := Producer_Backoffs + 1;
                                 Queue_Pressure := Queue_Pressure + 1;
                           end case;
                        end;
                     end if;
                  elsif (Stop_Observed or else Queued = Image_Count)
                    and then Active_Workers = Worker_Count
                    and then Sentinels < Active_Workers
                  then
                     declare
                        Job : constant Model.Image_Job :=
                          (Batch_Id => Model.U64 (Batch), Image_Id => 0);
                        Outcome : Job_Rings.Push_Result;
                     begin
                        Job_Rings.Try_Push (Jobs, Job, Outcome);
                        case Outcome is
                           when Job_Rings.Pushed =>
                              Sentinels := Sentinels + 1;
                           when Job_Rings.Full | Job_Rings.Push_Contended =>
                              Queue_Pressure := Queue_Pressure + 1;
                        end case;
                     end;
                  end if;
                  Drain_Results;
                  Check_Children;
                  if Dashboard.Input_Failed then
                     raise Program_Error with "terminal input task failed";
                  end if;
                  if Generator_Paused
                    and then not Stop_Observed
                    and then not Extra_Workers_Active
                    and then Maximum_Workers > Worker_Count
                  then
                     Join_Workers (Maximum_Workers);
                     Extra_Workers_Active := True;
                  elsif Extra_Workers_Active
                    and then
                      (Stop_Observed
                       or else
                         (not Generator_Paused
                          and then
                            (Queued = Image_Count
                             or else
                               Queued - Recovery_Queued >= High_Water / 2)))
                  then
                     Retire_Workers (Worker_Count);
                     Extra_Workers_Active := False;
                  end if;
                  if RT.To_Duration (RT.Clock - Last_Render) >= 0.075 then
                     Render_Current
                       (Queued + (if Pending_Image = 0 then 0 else 1),
                        Generator_Paused, Source_Waiting);
                     Last_Render := RT.Clock;
                  end if;
                  if RT.To_Duration (RT.Clock - Work_Started) > 900.0 then
                     raise Program_Error with "shared image index timed out";
                  end if;
                  delay 0.000_5;
               end loop;
            end;
            for Image_Id in 1 .. Batch_Target loop
               declare
                  Value : Model.Image_Result;
                  Found : Boolean;
               begin
                  loop
                     begin
                        Image_Maps.Get
                          (Index, Model.U64 (Image_Id), Value, Found);
                        exit;
                     exception
                        when DS.Busy_Error => delay 0.0;
                     end;
                  end loop;
                  if not Found
                    or else Value.Batch_Id /= Model.U64 (Batch)
                    or else Value.Content_Hash /= Expected_Hash (Image_Id)
                  then
                     raise Program_Error with
                       "shared index verification failed for epoch " &
                       Image (Batch) & ", image " & Image (Image_Id);
                  end if;
               end;
            end loop;
            Session_Image_High_Water :=
              Natural'Max (Session_Image_High_Water, Batch_Target);
            if Image_Maps.Length (Index) /=
              Session_Image_High_Water +
                (if Index_Rounds > 1 and then Session_Image_High_Water > 0
                 then 1 else 0)
            then
               raise Program_Error with
                 "shared index contains unexpected entries";
            end if;
            Last_Batch_Elapsed := RT.To_Duration (RT.Clock - Work_Started);
            Session_Work_Elapsed :=
              Session_Work_Elapsed + Last_Batch_Elapsed;
            Session_Images := Session_Images + Model.U64 (Batch_Target);
            if Maximum_Workers > Worker_Count then
               for Worker in Worker_Count + 1 .. Maximum_Workers loop
                  Session_Dynamic_Worker_Images :=
                    Session_Dynamic_Worker_Images +
                    Model.U64 (Per_Worker (Worker));
               end loop;
            end if;
            Session_Queue_Pressure :=
              Session_Queue_Pressure + Model.U64 (Queue_Pressure);
            Session_Producer_Backoffs :=
              Session_Producer_Backoffs + Model.U64 (Producer_Backoffs);
            Session_Source_Gaps :=
              Session_Source_Gaps + Model.U64 (Source_Gaps);
            Session_Index_Retries :=
              Session_Index_Retries + Model.U64 (Index_Retries);
            Render_Current (Queued, False, False);
            exit when Dashboard.Stop_Requested or else External_Stop_Requested
              or else (Batch_Limit > 0 and then Batch >= Batch_Limit);
            if Batch = Natural'Last then
               raise Program_Error with "safety epoch identity exhausted";
            end if;
            Batch := Batch + 1;
            Advance_Gate (Model.U64 (Batch), Active_Workers);
         end loop;
         Final_Batch_Workers := Active_Workers;
         Shared.Close (Backing);
         Active_Workers := 0;
         Advance_Gate (Model.U64 (Batch) + 1, 0);
         Wait_For ("exited");
         for Attempt in 1 .. 30_000 loop
            Check_Children;
            exit when (for all PID of PIDs => PID < 0);
            delay 0.001;
         end loop;
         if not (for all PID of PIDs => PID < 0) then
            raise Program_Error with "workers did not exit after session stop";
         end if;
         Stop_Dashboard_Input;
      exception
         when others =>
            Stop_Dashboard_Input (Check_Failure => False);
            raise;
      end;
      End_Dashboard;
      Write_Summary;
      Strings.Detach (Gate);
      Image_Maps.Detach (Index);
      Result_Rings.Detach (Results);
      Job_Rings.Detach (Jobs);
      Regions.Detach (Region);
      Segments.Detach (Segment);
      Shared.Unmap (Map);
   exception
      when Error : others =>
         End_Dashboard;
         Stop_Children;
         IO.Put_Line
           (IO.Standard_Error,
            "shared image index failed: " &
            Ada.Exceptions.Exception_Information (Error));
         raise;
   end Run_Coordinator;
begin
   if CLI.Argument_Count = 0 then
      IO.Put_Line
        ("usage: shared_image_index coordinator CORPUS WORKERS IMAGES WIDTH " &
         "HEIGHT PASSES INDEX_ROUNDS EPOCH_LIMIT");
      CLI.Set_Exit_Status (CLI.Failure);
   elsif CLI.Argument (1) = "coordinator" then
      Run_Coordinator;
   else
      raise Constraint_Error with "unknown shared image index mode";
   end if;
exception
   when others =>
      End_Dashboard;
      raise;
end Shared_Image_Index;
