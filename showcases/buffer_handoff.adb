with Ada.Command_Line;
with Ada.Long_Float_Text_IO;
with Ada.Real_Time;
with Ada.Streams;
with Ada.Text_IO;
with Flyology;
with Flyology.Buffers;
with Flyology.Buffers.Channels;
with Flyology.Bytes;
with Flyology.Channels.Bounded;
with Flyology.Execution_Groups;
with Flyology.Execution_Groups.Topology;

procedure Buffer_Handoff is
   package CLI renames Ada.Command_Line;
   package RT renames Ada.Real_Time;

   package Value_Channels is new
     Flyology.Channels.Bounded (Flyology.Bytes.Unbounded_Bytes, Flyology.Bytes.Empty);
   package Buffer_Channels renames Flyology.Buffers.Channels;
   package Groups renames Flyology.Execution_Groups;
   package Topology renames Flyology.Execution_Groups.Topology;

   use type RT.Time;
   use type Groups.Group_Id;

   Queue_Capacity : constant Positive := 64;
   type Size_Array is array (Positive range <>) of Positive;
   Sizes          : constant Size_Array := (64, 512, 4_096, 16_384, 65_536);

   function Iterations_For (Size : Positive) return Positive is
      Target_Bytes : constant Positive := 64 * 1_024 * 1_024;
      Candidate    : constant Positive := Target_Bytes / Size;
   begin
      return Positive'Max (1_000, Positive'Min (100_000, Candidate));
   end Iterations_For;

   protected type Run_Control is
      procedure Ready;
      entry Await_Ready;
      procedure Open;
      entry Start;
      procedure Finished;
      procedure Fail;
      entry Await_Finished (Succeeded : out Boolean);
   private
      Ready_Count    : Natural := 0;
      Finished_Count : Natural := 0;
      Is_Open        : Boolean := False;
      Is_Valid       : Boolean := True;
   end Run_Control;

   protected body Run_Control is
      procedure Ready is
      begin
         Ready_Count := Ready_Count + 1;
      end Ready;

      entry Await_Ready when Ready_Count = 2 is
      begin
         null;
      end Await_Ready;

      procedure Open is
      begin
         Is_Open := True;
      end Open;

      entry Start when Is_Open is
      begin
         null;
      end Start;

      procedure Finished is
      begin
         Finished_Count := Finished_Count + 1;
      end Finished;

      procedure Fail is
      begin
         Is_Valid := False;
      end Fail;

      entry Await_Finished (Succeeded : out Boolean) when Finished_Count = 2 is
      begin
         Succeeded := Is_Valid;
      end Await_Finished;
   end Run_Control;

   procedure Report
     (Representation : String;
      Placement      : String;
      Producer_Group : Topology.Shard_Id;
      Consumer_Group : Topology.Shard_Id;
      Size           : Positive;
      Iterations     : Positive;
      Elapsed        : Duration)
   is
      MiB_Per_Second : constant Long_Float :=
        Long_Float (Size) * Long_Float (Iterations) / Long_Float (Elapsed) / Long_Float (1_024 * 1_024);
   begin
      Ada.Text_IO.Put
        (Representation
         & ","
         & Placement
         & ","
         & Producer_Group'Image
         & ","
         & Consumer_Group'Image
         & ","
         & Size'Image
         & ","
         & Iterations'Image
         & ",");
      Ada.Long_Float_Text_IO.Put (Long_Float (Elapsed), Fore => 1, Aft => 6, Exp => 0);
      Ada.Text_IO.Put (",");
      Ada.Long_Float_Text_IO.Put (MiB_Per_Second, Fore => 1, Aft => 2, Exp => 0);
      Ada.Text_IO.New_Line;
   end Report;

   procedure Run_Value
     (Size           : Positive;
      Iterations     : Positive;
      Producer_Group : Topology.Shard_Id;
      Consumer_Group : Topology.Shard_Id;
      Placement      : String)
   is
      Queue            : Value_Channels.Channel (Queue_Capacity);
      Control          : Run_Control;
      Source           :
        constant Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Size)) :=
          (others => 42);
      Started, Stopped : RT.Time;
      Succeeded        : Boolean;

      task type Producer_Task (Assigned_Group : Topology.Shard_Id) is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Producer_Task;

      task type Consumer_Task (Assigned_Group : Topology.Shard_Id) is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Consumer_Task;

      task body Producer_Task is
         Ready_Reported : Boolean := False;
      begin
         Topology.Cross_To_Shard (Assigned_Group);
         if Groups.Current /= Assigned_Group then
            raise Program_Error with "producer entered the wrong group";
         end if;
         Control.Ready;
         Ready_Reported := True;
         Control.Start;
         for Index in 1 .. Iterations loop
            declare
               Value : constant Flyology.Bytes.Unbounded_Bytes := Flyology.Bytes.To_Unbounded_Bytes (Source);
            begin
               Queue.Send (Value);
            end;
         end loop;
         Queue.Close;
         Control.Finished;
      exception
         when others =>
            Control.Fail;
            if not Ready_Reported then
               Control.Ready;
            end if;
            Queue.Close;
            Control.Finished;
      end Producer_Task;

      task body Consumer_Task is
         Value          : Flyology.Bytes.Unbounded_Bytes;
         Count          : Natural := 0;
         Ready_Reported : Boolean := False;
      begin
         Topology.Cross_To_Shard (Assigned_Group);
         if Groups.Current /= Assigned_Group then
            raise Program_Error with "consumer entered the wrong group";
         end if;
         Control.Ready;
         Ready_Reported := True;
         Control.Start;
         loop
            begin
               Queue.Receive (Value);
            exception
               when Value_Channels.Channel_Closed =>
                  exit;
            end;
            Count := Count + 1;
         end loop;
         if Count /= Iterations then
            Control.Fail;
         end if;
         Control.Finished;
      exception
         when others =>
            Control.Fail;
            if not Ready_Reported then
               Control.Ready;
            end if;
            Control.Finished;
      end Consumer_Task;

      Producer : Producer_Task (Producer_Group);
      Consumer : Consumer_Task (Consumer_Group);
      pragma Unreferenced (Producer, Consumer);
   begin
      Control.Await_Ready;
      Started := RT.Clock;
      Control.Open;
      Control.Await_Finished (Succeeded);
      Stopped := RT.Clock;
      if not Succeeded then
         raise Program_Error with "value handoff benchmark failed";
      end if;
      Report
        ("value-copy",
         Placement,
         Producer_Group,
         Consumer_Group,
         Size,
         Iterations,
         RT.To_Duration (Stopped - Started));
   end Run_Value;

   procedure Run_Buffer
     (Size           : Positive;
      Iterations     : Positive;
      Producer_Group : Topology.Shard_Id;
      Consumer_Group : Topology.Shard_Id;
      Placement      : String)
   is
      Storage          : aliased Flyology.Buffers.Pool (Block_Size => Size, Capacity => Queue_Capacity + 2);
      Queue            : Buffer_Channels.Channel (Storage'Access, Capacity => Queue_Capacity);
      Control          : Run_Control;
      Source           :
        constant Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Size)) :=
          (others => 42);
      Started, Stopped : RT.Time;
      Succeeded        : Boolean;

      task type Producer_Task (Assigned_Group : Topology.Shard_Id) is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Producer_Task;

      task type Consumer_Task (Assigned_Group : Topology.Shard_Id) is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Consumer_Task;

      task body Producer_Task is
         Value          : Flyology.Buffers.Unique_Buffer (Storage'Access);
         Ready_Reported : Boolean := False;
      begin
         Topology.Cross_To_Shard (Assigned_Group);
         if Groups.Current /= Assigned_Group then
            raise Program_Error with "producer entered the wrong group";
         end if;
         Control.Ready;
         Ready_Reported := True;
         Control.Start;
         for Index in 1 .. Iterations loop
            Flyology.Buffers.Acquire (Value);
            Flyology.Buffers.Copy_From (Value, Source);
            Queue.Send_Move (Value);
         end loop;
         Queue.Close;
         Control.Finished;
      exception
         when others =>
            Control.Fail;
            if not Ready_Reported then
               Control.Ready;
            end if;
            Queue.Close;
            Control.Finished;
      end Producer_Task;

      task body Consumer_Task is
         Value          : Flyology.Buffers.Unique_Buffer (Storage'Access);
         Count          : Natural := 0;
         Ready_Reported : Boolean := False;
      begin
         Topology.Cross_To_Shard (Assigned_Group);
         if Groups.Current /= Assigned_Group then
            raise Program_Error with "consumer entered the wrong group";
         end if;
         Control.Ready;
         Ready_Reported := True;
         Control.Start;
         loop
            begin
               Queue.Receive_Move (Value);
            exception
               when Buffer_Channels.Channel_Closed =>
                  exit;
            end;
            Count := Count + 1;
            Flyology.Buffers.Release (Value);
         end loop;
         if Count /= Iterations then
            Control.Fail;
         end if;
         Control.Finished;
      exception
         when others =>
            Control.Fail;
            if not Ready_Reported then
               Control.Ready;
            end if;
            Control.Finished;
      end Consumer_Task;

      Producer : Producer_Task (Producer_Group);
      Consumer : Consumer_Task (Consumer_Group);
      pragma Unreferenced (Producer, Consumer);
   begin
      Control.Await_Ready;
      Started := RT.Clock;
      Control.Open;
      Control.Await_Finished (Succeeded);
      Stopped := RT.Clock;
      if not Succeeded then
         raise Program_Error with "buffer handoff benchmark failed";
      end if;
      Report
        ("unique-buffer",
         Placement,
         Producer_Group,
         Consumer_Group,
         Size,
         Iterations,
         RT.To_Duration (Stopped - Started));
   end Run_Buffer;

   Placement      : constant String := (if CLI.Argument_Count = 0 then "same" else CLI.Argument (1));
   Producer_Group : constant Topology.Shard_Id := 0;
   Consumer_Group : constant Topology.Shard_Id :=
     (if Placement = "same"
      then 0
      elsif Placement = "cross"
      then 1
      else raise Program_Error with "placement must be same or cross");

begin
   Ada.Text_IO.Put_Line
     ("representation,topology,producer_group,consumer_group,bytes," & "iterations,seconds,mib_per_second");
   for Size of Sizes loop
      declare
         Iterations : constant Positive := Iterations_For (Size);
      begin
         Run_Value (Size, Iterations, Producer_Group, Consumer_Group, "shared-" & Placement);
         Run_Buffer (Size, Iterations, Producer_Group, Consumer_Group, "shared-" & Placement);
      end;
   end loop;
end Buffer_Handoff;
