with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings;
with Ada.Strings.Fixed;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Byte_Strings;
with Flyology.Data_Structures.Regions;
with Flyology.Shared_Memory;
with Flyology.Shared_Memory.Segments;
with Flyology.Shared_Memory.Unix_Sockets;
with Interfaces;
with Interfaces.C;
with Shared_Image_Index_Support;

procedure Shared_Image_Index_Worker is
   package CLI renames Ada.Command_Line;
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

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Ada.Streams.Stream_Element_Offset;
   use type Image_Maps.Put_Result;
   use type Job_Rings.Pop_Result;
   use type Result_Rings.Push_Result;
   use type Segments.Find_Or_Create_Result;
   use type Segments.Lookup_Result;
   use type Segments.Segment_Open_Result;

   Segment_Config : constant Segments.Configuration :=
     (Schema               => 16#5348_4F57_494D_4701#,
      Registry_Capacity    => 8,
      Maximum_Name_Length  => 64,
      Allocation_Alignment => 64);

   function Close_Descriptor (Descriptor : C.int) return C.int;
   pragma Import (C, Close_Descriptor, "close");

   function Image (Value : Integer) return String is
     (Ada.Strings.Fixed.Trim (Integer'Image (Value), Ada.Strings.Both));

   function To_Bytes (Value : String) return Ada.Streams.Stream_Element_Array
   is
      Result : Ada.Streams.Stream_Element_Array (1 .. Value'Length);
   begin
      for Index in Value'Range loop
         Result
           (Ada.Streams.Stream_Element_Offset (Index - Value'First + 1)) :=
             Ada.Streams.Stream_Element (Character'Pos (Value (Index)));
      end loop;
      return Result;
   end To_Bytes;

   procedure Resolve_Name
     (Segment  : Segments.View;
      Name     : String;
      Location : out DS.Region_Offset;
      Extent   : out DS.Byte_Count)
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
              "cannot resolve segment extent " & Name & ": " & Outcome'Image;
         end if;
         delay 0.0;
      end loop;
      Segments.Resolve (Segment, Handle, Location, Extent);
   end Resolve_Name;

   procedure Push_Result
     (Ring    : in out Result_Rings.View;
      Value   : Model.Image_Result;
      Retries : in out Natural)
   is
      Outcome : Result_Rings.Push_Result;
   begin
      loop
         Result_Rings.Try_Push (Ring, Value, Outcome);
         exit when Outcome = Result_Rings.Pushed;
         Retries := Retries + 1;
         delay 0.0;
      end loop;
   end Push_Result;

   Corpus         : constant String := CLI.Argument (2);
   Worker_Id      : constant Positive := Positive'Value (CLI.Argument (3));
   Mapping_Size   : constant DS.Byte_Count :=
     DS.Byte_Count'Value (CLI.Argument (4));
   Index_Capacity : constant Positive := Positive'Value (CLI.Argument (5));
   Width          : constant Positive := Positive'Value (CLI.Argument (6));
   Height         : constant Positive := Positive'Value (CLI.Argument (7));
   Passes         : constant Positive := Positive'Value (CLI.Argument (8));
   Index_Rounds   : constant Positive := Positive'Value (CLI.Argument (9));
   Socket         : Unix.Socket_Descriptor := 3;
   Backing        : Shared.Backing_Object;
   Map            : Shared.Mapping;
   Segment        : Segments.View;
   Region         : Regions.View;
   Segment_State  : Segments.Segment_Open_Result;
   Jobs           : Job_Rings.View;
   Results        : Result_Rings.View;
   Index          : Image_Maps.View;
   Gate           : Strings.View;
   Race_Object    : Strings.View;
   Location       : DS.Region_Offset;
   Resolved_Length : DS.Byte_Count;
   Gate_Length    : Natural;
   Queue_Retries  : Natural := 0;
   Index_Retries  : Natural := 0;
   Registry_Retries : Natural := 0;
   Images_Done    : Natural := 0;
   Batch_Images_Done : Natural := 0;
   Current_Batch  : Model.U64 := 0;
   Retire         : Boolean := False;
   Admitted       : Boolean := False;
   Event          : Model.Image_Result;

   procedure Read_Gate
     (Batch        : out Model.U64;
      Worker_Limit : out Natural)
   is
      Data  : Ada.Streams.Stream_Element_Array (1 .. 16);
      Limit : Model.U64 := 0;
   begin
      Strings.Read (Gate, Data);
      Batch := 0;
      for Byte_Index in 0 .. 7 loop
         Batch := Batch or Interfaces.Shift_Left
           (Model.U64
              (Data
                 (Data'First + Ada.Streams.Stream_Element_Offset
                    (Byte_Index))),
            Byte_Index * 8);
         Limit := Limit or Interfaces.Shift_Left
           (Model.U64
              (Data
                 (Data'First + Ada.Streams.Stream_Element_Offset
                    (Byte_Index + 8))),
            Byte_Index * 8);
      end loop;
      if Limit > Model.U64 (Positive'Last) then
         raise Constraint_Error with "gate worker limit is not representable";
      end if;
      Worker_Limit := Natural (Limit);
   end Read_Gate;
begin
   if CLI.Argument_Count /= 9 or else CLI.Argument (1) /= "worker" then
      raise Constraint_Error with "worker argument contract mismatch";
   end if;

   --  fd 3 is the only endpoint intentionally inherited across exec.  Receive
   --  validates the connected Unix socket, ancillary framing, exact backing
   --  length, descriptor type, and CLOEXEC before returning one owned object.
   Unix.Receive (Socket, Mapping_Size, Backing);
   declare
      Ignored : constant C.int := Close_Descriptor (C.int (Socket));
      pragma Unreferenced (Ignored);
   begin
      Socket := Unix.Socket_Descriptor (-1);
   end;
   Shared.Map (Map, Backing);
   Shared.Close (Backing);
   Segments.Create_Or_Attach
     (Segment, Map, Segment_Config, Segment_State);
   if Segment_State /= Segments.Attached_Existing then
      raise Program_Error with "worker could not attach ready segment";
   end if;
   Segments.Attach_Region (Segment, Region);

   Resolve_Name
     (Segment, Model.Job_Ring_Name, Location, Resolved_Length);
   Job_Rings.Attach (Jobs, Region, Location, Model.Job_Ring_Capacity);
   Resolve_Name
     (Segment, Model.Result_Ring_Name, Location, Resolved_Length);
   Result_Rings.Attach
     (Results, Region, Location, Model.Result_Ring_Capacity);
   Resolve_Name
     (Segment, Model.Index_Name, Location, Resolved_Length);
   Image_Maps.Attach (Index, Region, Location, Index_Capacity);
   Resolve_Name
     (Segment, Model.Gate_Name, Location, Resolved_Length);
   begin
      Strings.Attach (Gate, Region, Location, Model.Gate_Capacity);
   exception
      when Error : others =>
         raise Program_Error with
           "worker " & Image (Worker_Id) & " could not attach " &
           Model.Gate_Name & " at offset" &
           DS.Region_Offset'Image (Location) & " length" &
           DS.Byte_Count'Image (Resolved_Length) & ": " &
           Ada.Exceptions.Exception_Message (Error);
   end;

   Event :=
     (Batch_Id       => 0,
      Image_Id        => 0,
      Content_Hash    => 0,
      Red_Total       => 0,
      Green_Total     => 0,
      Blue_Total      => 0,
      Pixel_Count     => 0,
      Worker_Id       => Model.U32 (Worker_Id),
      Index_Retries   => 0,
      Queue_Retries   => 0,
      Flags           => Model.Worker_Attached);
   Push_Result (Results, Event, Queue_Retries);

   loop
      begin
         Gate_Length := Strings.Length (Gate);
         exit when Gate_Length > 0;
      exception
         when DS.Busy_Error => null;
      end;
      delay 0.001;
   end loop;

   declare
      Handle  : Segments.Named_Handle;
      Claim   : Segments.Creation_Claim;
      Outcome : Segments.Find_Or_Create_Result;
      Failure : Interfaces.Unsigned_32;
      Extent  : DS.Byte_Count;
      Won     : Boolean := False;
   begin
      loop
         Segments.Try_Find_Or_Create
           (Segment, Model.Race_Name,
            Strings.Required_Storage (Model.Race_Capacity),
            Handle, Claim, Outcome, Failure);
         case Outcome is
            when Segments.Created =>
               Segments.Claimed_Extent
                 (Segment, Claim, Location, Extent);
               Strings.Initialize
                 (Race_Object, Region, Location, Model.Race_Capacity);
               Strings.Assign
                 (Race_Object, To_Bytes ("created by worker " &
                  Image (Worker_Id)));
               Segments.Publish (Segment, Claim);
               Won := True;
               exit;
            when Segments.Attached_Existing =>
               Segments.Resolve (Segment, Handle, Location, Extent);
               begin
                  Strings.Attach
                    (Race_Object, Region, Location, Model.Race_Capacity);
               exception
                  when Error : others =>
                     raise Program_Error with
                       "worker " & Image (Worker_Id) & " could not attach " &
                       Model.Race_Name & " at offset" &
                       DS.Region_Offset'Image (Location) & " length" &
                       DS.Byte_Count'Image (Extent) & ": " &
                       Ada.Exceptions.Exception_Message (Error);
               end;
               exit;
            when Segments.Registry_Busy |
              Segments.Initialization_In_Progress =>
               Registry_Retries := Registry_Retries + 1;
               delay 0.0;
            when others =>
               raise Program_Error with
                 "worker registry race failed: " & Outcome'Image;
         end case;
      end loop;
      Event :=
        (Batch_Id => 0,
         Image_Id => 0,
         Content_Hash => 0,
         Red_Total => 0,
         Green_Total => 0,
         Blue_Total => 0,
         Pixel_Count => 0,
         Worker_Id => Model.U32 (Worker_Id),
         Index_Retries => Model.U32 (Registry_Retries),
         Queue_Retries => 0,
         Flags => Model.Worker_Race_Done or
           (if Won then Model.Worker_Won_Race else 0));
      Push_Result (Results, Event, Queue_Retries);
   end;

   --  A dynamically spawned worker attaches and completes the registry race
   --  while the old membership limit is still published.  It may enter the
   --  job ring only after the coordinator has observed both acknowledgments
   --  and raises the limit to include its worker ID.
   loop
      declare
         Gate_Batch : Model.U64;
         Gate_Limit : Natural;
      begin
         Read_Gate (Gate_Batch, Gate_Limit);
         if Gate_Batch /= 0 and then Worker_Id <= Gate_Limit then
            Admitted := True;
         end if;
      exception
         when DS.Busy_Error | Constraint_Error => null;
      end;
      exit when Admitted;
      delay 0.001;
   end loop;

   loop
      declare
         Job         : Model.Image_Job;
         Pop_Outcome : Job_Rings.Pop_Result;
         Local       : Model.Image_Result;
         Local_Queue_Retries : Natural := 0;
         Local_Index_Retries : Natural := 0;
      begin
         loop
            --  Membership is sampled immediately before dequeue.  A lowering
            --  of the limit can race this sample, so retirement may drain at
            --  most the one job admitted by that race.  Every claimed job is
            --  fully analyzed and published before this check is reached
            --  again and the worker acknowledges departure.
            declare
               Gate_Batch : Model.U64;
               Gate_Limit : Natural;
            begin
               Read_Gate (Gate_Batch, Gate_Limit);
               if Gate_Batch = 0 then
                  raise Constraint_Error with "gate has no epoch identity";
               end if;
               Retire := Worker_Id > Gate_Limit;
            exception
               when DS.Busy_Error | Constraint_Error => null;
            end;
            exit when Retire;
            Job_Rings.Try_Pop (Jobs, Job, Pop_Outcome);
            exit when Pop_Outcome = Job_Rings.Popped;
            Queue_Retries := Queue_Retries + 1;
            Local_Queue_Retries := Local_Queue_Retries + 1;
            delay 0.0;
         end loop;
         exit when Retire;
         if Job.Image_Id = 0 then
            exit when Job.Batch_Id = 0;
            if Current_Batch /= 0 and then Job.Batch_Id /= Current_Batch then
               raise Program_Error with "worker received mismatched epoch end";
            end if;
            Event :=
              (Batch_Id       => Job.Batch_Id,
               Image_Id       => 0,
               Content_Hash   => 0,
               Red_Total      => 0,
               Green_Total    => 0,
               Blue_Total     => 0,
               Pixel_Count    => Model.U64 (Batch_Images_Done),
               Worker_Id      => Model.U32 (Worker_Id),
               Index_Retries  => 0,
               Queue_Retries  => 0,
               Flags          => Model.Worker_Batch_Done);
            Push_Result (Results, Event, Queue_Retries);
            Current_Batch := 0;
            Batch_Images_Done := 0;
            loop
               declare
                  Next_Batch  : Model.U64;
                  Next_Limit  : Natural;
               begin
                  Read_Gate (Next_Batch, Next_Limit);
                  if Next_Batch /= Job.Batch_Id
                    or else Worker_Id > Next_Limit
                  then
                     Retire := Worker_Id > Next_Limit;
                     exit;
                  end if;
               exception
                  when DS.Busy_Error | Constraint_Error => null;
               end;
               delay 0.001;
            end loop;
         else
            if Job.Batch_Id = 0 then
               raise Program_Error with "image job has no epoch identity";
            elsif Current_Batch = 0 then
               Current_Batch := Job.Batch_Id;
            elsif Job.Batch_Id /= Current_Batch then
               raise Program_Error with "worker observed overlapping epochs";
            end if;
            Model.Analyze_Image
              (Model.Image_Path (Corpus, Positive (Job.Image_Id)),
               Width, Height, Passes, Worker_Id, Local);
            Local.Batch_Id := Job.Batch_Id;
            Local.Image_Id := Job.Image_Id;
            Local.Queue_Retries := Model.U32 (Local_Queue_Retries);
            for Round in 1 .. Index_Rounds loop
               loop
                  Local.Index_Retries := Model.U32 (Local_Index_Retries);
                  begin
                     declare
                        Put_Outcome : Image_Maps.Put_Result;
                     begin
                        Image_Maps.Put
                          (Index,
                           (if Round = Index_Rounds then Job.Image_Id else 0),
                           Local, Put_Outcome);
                        if Put_Outcome = Image_Maps.Table_Full then
                           raise Program_Error with
                             "shared image index is full";
                        end if;
                        exit;
                     end;
                  exception
                     when DS.Busy_Error =>
                        Local_Index_Retries := Local_Index_Retries + 1;
                        delay 0.0;
                  end;
               end loop;
            end loop;
            Index_Retries := Index_Retries + Local_Index_Retries;
            Push_Result (Results, Local, Queue_Retries);
            Images_Done := Images_Done + 1;
            Batch_Images_Done := Batch_Images_Done + 1;
         end if;
      end;
      exit when Retire;
   end loop;

   Event :=
     (Batch_Id      => 0,
      Image_Id      => 0,
      Content_Hash  => 0,
      Red_Total     => 0,
      Green_Total   => 0,
      Blue_Total    => 0,
      Worker_Id     => Model.U32 (Worker_Id),
      Index_Retries => Model.U32 (Index_Retries),
      Queue_Retries => Model.U32 (Queue_Retries),
      Flags         => Model.Worker_Finished,
      Pixel_Count   => Model.U64 (Images_Done));
   Push_Result (Results, Event, Queue_Retries);

   Strings.Detach (Race_Object);
   Strings.Detach (Gate);
   Image_Maps.Detach (Index);
   Result_Rings.Detach (Results);
   Job_Rings.Detach (Jobs);
   Regions.Detach (Region);
   Segments.Detach (Segment);
   Shared.Unmap (Map);
end Shared_Image_Index_Worker;
