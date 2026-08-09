with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Byte_Strings;
with Flyology.Data_Structures.Regions;
with Flyology.Shared_Memory;
with Flyology.Shared_Memory.Segments;
with Flyology.Shared_Memory.Unix_Sockets;
with Interfaces;
with Interfaces.C;
with Showcase_Support;
with Shared_Image_Index_Support;

procedure Shared_Image_Index is
   package CLI renames Ada.Command_Line;
   package Directories renames Ada.Directories;
   package Env renames Ada.Environment_Variables;
   package UStrings renames Ada.Strings.Unbounded;
   package RT renames Ada.Real_Time;
   package IO renames Ada.Text_IO;
   package C renames Interfaces.C;
   package DS renames Flyology.Data_Structures;
   package Regions renames DS.Regions;
   package Strings renames DS.Byte_Strings;
   package Shared renames Flyology.Shared_Memory;
   package Segments renames Shared.Segments;
   package Unix renames Shared.Unix_Sockets;
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

   ESC : constant Character := Character'Val (27);
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

   --  Keep the glyph layer ASCII. Ada.Text_IO represents Character as
   --  Latin-1 on some supported hosts and would otherwise transcode hand-made
   --  UTF-8 bytes a second time. Color, spacing, and status hierarchy carry
   --  the presentation while output remains portable and unambiguous.
   Round_Top_Left     : constant String := "/";
   Round_Top_Right    : constant String := "\";
   Round_Bottom_Left  : constant String := "\";
   Round_Bottom_Right : constant String := "/";
   Horizontal         : constant String := "-";
   Vertical           : constant String := "|";
   Full_Block         : constant String := "#";
   Light_Block        : constant String := ".";
   Solid_Dot          : constant String := "o";

   function Repeat (Text : String; Count : Natural) return String is
      Result : String (1 .. Text'Length * Count);
   begin
      for Index in 1 .. Count loop
         Result
           ((Index - 1) * Text'Length + 1 .. Index * Text'Length) := Text;
      end loop;
      return Result;
   end Repeat;

   function Paint (Text, Color : String) return String is
     (ESC & "[" & Color & "m" & Text & ESC & "[0m");

   function Pill (Text, Color : String) return String is
     (ESC & "[1;38;5;16;48;5;" & Color & "m " & Text & " " &
      ESC & "[0m");

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

   function ANSI_Enabled return Boolean is
     (Is_A_Terminal (1) = 1
      and then not Env.Exists ("NO_COLOR")
      and then (not Env.Exists ("TERM") or else Env.Value ("TERM") /= "dumb"));

   function Batch_Status (Batch : Positive) return String is
      (if Env.Exists ("FLYOLOGY_SHOWCASE_CONTINUOUS")
        and then Env.Value ("FLYOLOGY_SHOWCASE_CONTINUOUS") = "1"
      then
        " Corpus epoch " & Image (Batch) &
        " | q or Esc requests a drained stop"
      else " Corpus epoch " & Image (Batch));

   function Managed_Screen return Boolean is
     (Env.Exists ("FLYOLOGY_SHOWCASE_MANAGED_SCREEN")
      and then Env.Value ("FLYOLOGY_SHOWCASE_MANAGED_SCREEN") = "1");

   Dashboard_Active : Boolean := False;
   Frame : UStrings.Unbounded_String;

   procedure Begin_Dashboard is
   begin
      if ANSI_Enabled then
         if not Managed_Screen then
            IO.Put (ESC & "[2J" & ESC & "[H" & ESC & "[?25l");
         end if;
         Dashboard_Active := True;
      end if;
   end Begin_Dashboard;

   procedure End_Dashboard is
   begin
      if Dashboard_Active then
         if not Managed_Screen then
            IO.Put (ESC & "[?25h");
            IO.Flush;
         end if;
         Dashboard_Active := False;
      end if;
   end End_Dashboard;

   procedure Begin_Frame is
   begin
      --  Modern terminals buffer synchronized updates until mode 2026 is
      --  released; older terminals safely ignore the private mode sequence.
      Frame := UStrings.To_Unbounded_String (ESC & "[?2026h" & ESC & "[H");
   end Begin_Frame;

   procedure End_Frame is
   begin
      UStrings.Append (Frame, ESC & "[?2026l");
      IO.Put (UStrings.To_String (Frame));
      IO.Flush;
   end End_Frame;

   function Meter
     (Done, Total : Natural; Width : Positive := 32) return String
   is
      Filled : constant Natural :=
        (if Total = 0 then 0 else Natural'Min (Width, Done * Width / Total));
   begin
      return Paint (Repeat (Full_Block, Filled), "38;5;212") &
        Paint (Repeat (Light_Block, Width - Filled), "38;5;238");
   end Meter;

   procedure ANSI_Line (Text : String; Color : String := "") is
   begin
      UStrings.Append (Frame, ESC & "[2K");
      if Color'Length > 0 then
         UStrings.Append (Frame, ESC & "[" & Color & "m");
      end if;
      UStrings.Append (Frame, Text);
      if Color'Length > 0 then
         UStrings.Append (Frame, ESC & "[0m");
      end if;
      UStrings.Append (Frame, Character'Val (10));
   end ANSI_Line;

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

   Last_Work_Bucket : Natural := Natural'Last;

   procedure Show_Segment_Layout
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
      Registry_Retries : Natural)
   is
      Pulse_Color : constant String :=
        (case (Queued + Completed) mod 4 is
            when 0 => "38;5;141",
            when 1 => "38;5;177",
            when 2 => "38;5;212",
            when others => "38;5;177");
   begin
      ANSI_Line
        ("  " & Round_Top_Left & Repeat (Horizontal, 2) &
         Paint (" shared segment ", "1;38;5;81") &
         Repeat (Horizontal, 46) & Round_Top_Right, "38;5;240");
      ANSI_Line
        ("  " & Vertical & " " & Pill ("VALID", "42") &
         "  schema SHOWIMG/1   slots 8   align 64", "38;5;252");
      ANSI_Line
        ("  " & Vertical & " exact map  " & Image (Mapped_Length) &
         " bytes", "38;5;245");
      ANSI_Line
        ("  " & Vertical & " " & Paint ("REGISTRY", "1;38;5;141") &
         "  fixed capacity / exact names", "38;5;245");
      for Id in Extent_Id loop
         declare
            Item : Layout_Entry renames Layout (Id);
            Activity : constant String :=
              (case Id is
                  when Pending_Jobs =>
                    "push=" & Image (Queued) & " pressure=" &
                    Image (Queue_Pressure),
                  when Completed_Results =>
                    "drain=" & Image (Completed) & "/" & Image (Total),
                  when Image_Index =>
                    "publish=" & Image (Completed) & " retries=" &
                    Image (Index_Retries),
                  when Start_Gate =>
                    "attached=" & Image (Workers_Ready) & "/" &
                    Image (Worker_Count),
                  when Startup_Race =>
                    "creator=1 retries=" & Image (Registry_Retries));
            Complete : constant Boolean :=
              Completed = Total and then Workers_Done = Worker_Count;
            Marker : constant String :=
              (if Complete then Paint (Solid_Dot, "38;5;114")
               else Paint (Solid_Dot, Pulse_Color));
         begin
            ANSI_Line
              ("  " & Vertical & " " & Marker & " " &
               Paint
                 (Pad (Extent_Name (Id), 24),
                  (if Id = Image_Index then "1;38;5;212"
                   elsif Id in Pending_Jobs | Completed_Results then
                     "1;38;5;81"
                   elsif Id = Startup_Race then "1;38;5;141"
                   else "1;38;5;221")) &
               "  " & Pad (Image (DS.Byte_Count (Item.Location)), 7) &
               "  " & Pad (Image (Item.Length), 7) & "  " &
               Pad (Extent_Kind (Id), 11) & Paint (Activity, "38;5;245"));
         end;
      end loop;
      ANSI_Line
        ("  " & Round_Bottom_Left & Repeat (Horizontal, 2) &
         " offsets only / no native addresses " &
         Repeat (Horizontal, 27) & Round_Bottom_Right, "38;5;240");
   end Show_Segment_Layout;

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
      Started            : RT.Time)
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
   begin
      if ANSI_Enabled then
         Begin_Frame;
         ANSI_Line
           ("  " & Paint ("flyology", "1;38;5;212") &
            Paint (" / shared image index", "1;38;5;255") & "   " &
            Pill ("LIVE", "42"));
         ANSI_Line ("  " & Batch_Status (Batch), "38;5;245");
         ANSI_Line ("");
         ANSI_Line
           ("  /--" & Paint (" workload ", "1;38;5;212") &
            Repeat (Horizontal, 53) & "\", "38;5;240");
         ANSI_Line
           ("  | " &
            Pill
              ((if Generator_Paused then "BACKOFF"
                elsif Source_Waiting then "SOURCE"
                else "FLOW"),
               (if Generator_Paused then "221"
                elsif Source_Waiting then "141"
                else "81")) & Paint
              ((if Generator_Paused then
                  "  producer paused at saturation / workers draining"
                elsif Source_Waiting then
                  "  irregular upstream gap / workers keep consuming"
                else
                  "  generating + indexing through one bounded pipeline"),
               "38;5;252"));
         ANSI_Line
           ("  | " & Meter (Completed, Total) & "  " &
            Paint (Pad (Image (Percent) & "%", 5), "1;38;5;212"));
         ANSI_Line
           ("  | generated    " & Image (Generated) & " / " & Image (Total));
         ANSI_Line
           ("  | queued       " & Image (Queued) & " / " & Image (Total));
         ANSI_Line
           ("  | indexed      " & Image (Completed) & " / " & Image (Total));
         ANSI_Line
           ("  | workers      " & Image (Workers_Ready) & " ready, " &
            Image (Workers_Done) & " epoch done, " & Image (Worker_Count) &
            " active");
         ANSI_Line
           ("  | throughput   " & Showcase_Support.Fixed_Image (Rate, 1) &
            " images/s, " & Showcase_Support.Fixed_Image
              ((if Elapsed <= 0.0 then 0.0
                else MiB / Long_Float (Elapsed)), 1) & " MiB/s");
         ANSI_Line
           ("  | flow         backoffs=" & Image (Producer_Backoffs) &
            "  source-gaps=" & Image (Source_Gaps), "1;38;5;141");
         ANSI_Line
           ("  | contention   queue=" & Image (Queue_Pressure) &
            "  index-guard=" & Image (Index_Retries) &
            "  registry=" & Image (Registry_Retries), "1;38;5;141");
         ANSI_Line
           ("  \" & Repeat (Horizontal, 67) & "/", "38;5;240");
         ANSI_Line ("");
         Show_Segment_Layout
           (Layout, Mapped_Length, Queued, Completed, Total, Workers_Ready,
            Workers_Done, Worker_Count, Queue_Pressure, Index_Retries,
            Registry_Retries);
         ANSI_Line ("");
         ANSI_Line
           ("  /--" & Paint (" workers ", "1;38;5;114") &
            Repeat (Horizontal, 54) & "\", "38;5;240");
         for Worker in 1 .. Maximum_Worker_Count loop
            if Worker <= Worker_Count then
               ANSI_Line
                 ("  | " & Paint
                    (Solid_Dot,
                     (if Per_Worker (Worker) = 0 then "38;5;240"
                      else "38;5;114")) &
                  " worker " & Pad (Image (Worker), 2) & "  " &
                  Meter
                    (Per_Worker (Worker),
                     Natural'Max
                       (1, (Total + Worker_Count - 1) / Worker_Count), 18) &
                  "  " & Paint
                    (Image (Per_Worker (Worker)) & " images", "38;5;245"));
            else
               ANSI_Line
                 ("  | " & Paint
                    ("o",
                     (if Per_Worker (Worker) = 0 then "38;5;238"
                      else "38;5;177")) & " worker " &
                  Pad (Image (Worker), 2) & "  " & Meter (0, 1, 18) &
                  "  " & Paint
                    ((if Per_Worker (Worker) = 0 then
                        "detached / available slot"
                      else
                        "drained + detached after " &
                        Image (Per_Worker (Worker)) & " images"),
                     "38;5;240"));
            end if;
         end loop;
         ANSI_Line
           ("  \" & Repeat (Horizontal, 67) & "/", "38;5;240");
         End_Frame;
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
      Expected_Entries : constant Natural :=
        Image_Count + (if Index_Rounds > 1 then 1 else 0);
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
      Queued         : Natural := 0;
      Sentinels      : Natural := 0;
      Completed      : Natural := 0;
      Queue_Pressure : Natural := 0;
      Producer_Backoffs : Natural := 0;
      Source_Gaps       : Natural := 0;
      Index_Retries  : Natural := 0;
      Registry_Retries : Natural := 0;
      Session_Images : Model.U64 := 0;
      Session_Dynamic_Worker_Images : Model.U64 := 0;
      Session_Queue_Pressure : Model.U64 := 0;
      Session_Producer_Backoffs : Model.U64 := 0;
      Session_Source_Gaps : Model.U64 := 0;
      Session_Index_Retries : Model.U64 := 0;
      Last_Render    : RT.Time;

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

      function Stop_Requested return Boolean is
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
            (if Index_Rounds > 1 then " (images + contention key)" else ""));
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
         if ANSI_Enabled
           and then Managed_Screen
           and then Env.Exists ("FLYOLOGY_SHOWCASE_SUMMARY_FILE")
         then
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

      if not ANSI_Enabled then
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

      Begin_Dashboard;
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
         begin
            while Completed < Image_Count
              or else Workers_Done < Active_Workers
            loop
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
                 and then Queued < Image_Count
               then
                  if Pending_Image = 0 then
                     Pending_Image := Queued + 1;
                     Model.Generate_Image
                       (Model.Image_Path (Corpus, Pending_Image), Width,
                        Height, Random_State);
                  end if;
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
                              Producer_Backoffs := Producer_Backoffs + 1;
                           end if;
                           Burst_Remaining := Burst_Remaining - 1;
                           if Burst_Remaining = 0
                             and then Queued < Image_Count
                           then
                              Source_Waiting := True;
                              Source_Gaps := Source_Gaps + 1;
                              Source_Resume := RT.Clock + RT.Milliseconds
                                (20 + (Queued * 29 + Batch * 11) mod 81);
                           end if;
                        when Job_Rings.Full | Job_Rings.Push_Contended =>
                           Generator_Paused := True;
                           Producer_Backoffs := Producer_Backoffs + 1;
                           Queue_Pressure := Queue_Pressure + 1;
                     end case;
                  end;
               elsif Queued = Image_Count
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
               if Generator_Paused
                 and then not Extra_Workers_Active
                 and then Maximum_Workers > Worker_Count
               then
                  Join_Workers (Maximum_Workers);
                  Extra_Workers_Active := True;
               elsif Extra_Workers_Active
                 and then not Generator_Paused
                 and then
                   (Queued = Image_Count
                    or else Queued - Recovery_Queued >= High_Water / 2)
               then
                  Retire_Workers (Worker_Count);
                  Extra_Workers_Active := False;
               end if;
               if RT.To_Duration (RT.Clock - Last_Render) >= 0.075 then
                  Show_Work
                    (Queued + (if Pending_Image = 0 then 0 else 1), Queued,
                     Completed, Image_Count, Positive (Batch), Workers_Ready,
                     Workers_Done, Positive (Active_Workers), Maximum_Workers,
                     Generator_Paused, Source_Waiting, Producer_Backoffs,
                     Source_Gaps, Queue_Pressure, Index_Retries,
                     Registry_Retries, Per_Worker, Width, Height, Passes,
                     Layout, Mapping_Size, Work_Started);
                  Last_Render := RT.Clock;
               end if;
               if RT.To_Duration (RT.Clock - Work_Started) > 900.0 then
                  raise Program_Error with "shared image index timed out";
               end if;
               delay 0.000_5;
            end loop;
         end;

         for Image_Id in 1 .. Image_Count loop
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
         if Image_Maps.Length (Index) /= Expected_Entries then
            raise Program_Error with
              "shared index contains unexpected entries";
         end if;

         Last_Batch_Elapsed := RT.To_Duration (RT.Clock - Work_Started);
         Session_Work_Elapsed :=
           Session_Work_Elapsed + Last_Batch_Elapsed;
         Session_Images := Session_Images + Model.U64 (Image_Count);
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
         Show_Work
           (Queued, Queued, Completed, Image_Count, Positive (Batch),
            Workers_Ready, Workers_Done, Positive (Active_Workers),
            Maximum_Workers, False, False, Producer_Backoffs, Source_Gaps,
            Queue_Pressure, Index_Retries, Registry_Retries, Per_Worker,
            Width, Height, Passes, Layout, Mapping_Size, Work_Started);

         exit when Stop_Requested
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
