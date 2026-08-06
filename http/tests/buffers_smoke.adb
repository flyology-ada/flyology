with Ada.Directories;
with Ada.Streams;
with Flyology;
with Flyology.Buffers;
with Flyology.Buffers.Channels;
with Flyology.Bytes;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.WebSocket_Handlers;
with Flyology.IO.Files;
with Flyology.IO.Sockets;
with Interfaces;
with System;

procedure Buffers_Smoke is
   package Buffers renames Flyology.Buffers;
   package Channels renames Flyology.Buffers.Channels;
   package Files renames Flyology.IO.Files;
   package HTTP renames Flyology.HTTP.Server;
   package Sockets renames Flyology.IO.Sockets;
   package WebSockets renames Flyology.HTTP.Server.WebSocket_Handlers;

   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Buffers.Pool_Snapshot;
   use type Channels.Transfer_Metadata;
   use type Channels.Try_Receive_Result;
   use type Channels.Try_Send_Result;
   use type Files.File_Descriptor;
   use type Interfaces.Unsigned_64;
   use type System.Address;

   procedure Assert (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Assert;

   procedure Check_Payload
     (Item     : Buffers.Unique_Buffer;
      Expected : Ada.Streams.Stream_Element_Array)
   is
      procedure Check (Data : Ada.Streams.Stream_Element_Array) is
      begin
         Assert (Data'Length = Expected'Length, "buffer length mismatch");
         for Offset in 0 .. Expected'Length - 1 loop
            Assert
              (Data (Data'First + Ada.Streams.Stream_Element_Offset (Offset)) =
                 Expected
                   (Expected'First
                    + Ada.Streams.Stream_Element_Offset (Offset)),
               "buffer payload mismatch");
         end loop;
      end Check;
   begin
      Buffers.With_Readable_Data (Item, Check'Access);
   end Check_Payload;

   procedure Run_Ownership is
      Storage : aliased Buffers.Pool (Block_Size => 16, Capacity => 3);
      Left    : Buffers.Unique_Buffer (Storage'Access);
      Right   : Buffers.Unique_Buffer (Storage'Access);
      Spare   : Buffers.Unique_Buffer (Storage'Access);
      Extra   : Buffers.Unique_Buffer (Storage'Access);
      Before  : System.Address := System.Null_Address;
      After   : System.Address := System.Null_Address;
      Acquired : Boolean;

      procedure Remember_Before
        (Data : Ada.Streams.Stream_Element_Array) is
      begin
         Before := Data'Address;
      end Remember_Before;

      procedure Remember_After
        (Data : Ada.Streams.Stream_Element_Array) is
      begin
         After := Data'Address;
      end Remember_After;
   begin
      Assert
        (Buffers.Current (Storage) =
           (Available => 3, Outstanding => 0),
         "new pool accounting is wrong");
      Buffers.Acquire (Left);
      Buffers.Copy_From (Left, [11, 22, 33, 44]);
      Buffers.Set_Tag (Left, 91);
      Buffers.With_Readable_Data (Left, Remember_Before'Access);
      Buffers.Move (Left, Right);
      Assert
        (not Buffers.Has_Buffer (Left) and then Buffers.Has_Buffer (Right),
         "move did not transfer ownership");
      Assert (Buffers.Tag (Right) = 91, "move lost the buffer tag");
      Buffers.With_Readable_Data (Right, Remember_After'Access);
      Assert (Before = After, "move changed the payload address");
      Check_Payload (Right, [11, 22, 33, 44]);

      Buffers.Acquire (Left);
      Buffers.Acquire (Spare);
      Buffers.Try_Acquire (Extra, Acquired);
      Assert (not Acquired, "exhausted pool acquired another slot");
      Buffers.Release (Left);
      Buffers.Release (Right);
      Buffers.Release (Spare);
      Assert
        (Buffers.Current (Storage) =
           (Available => 3, Outstanding => 0),
         "release did not restore pool accounting");
   end Run_Ownership;

   procedure Run_Pool_Exhaustion is
      Storage : aliased Buffers.Pool (Block_Size => 8, Capacity => 1);
      Held    : Buffers.Unique_Buffer (Storage'Access);
      Waiting : Buffers.Unique_Buffer (Storage'Access);
      Acquired : Boolean;
      Timed_Out : Boolean := False;
   begin
      Buffers.Acquire (Held);
      Buffers.Try_Acquire (Waiting, Acquired);
      Assert (not Acquired, "exhausted pool acquired a second slot");
      begin
         Buffers.Acquire_For (Waiting, 0.0);
      exception
         when Buffers.Timeout_Error => Timed_Out := True;
      end;
      Assert (Timed_Out, "zero-time pool acquisition did not time out");
      Assert (not Buffers.Has_Buffer (Waiting), "timeout attached a slot");
      Buffers.Release (Held);
   end Run_Pool_Exhaustion;

   procedure Run_Channel_Semantics is
      Storage : aliased Buffers.Pool (Block_Size => 16, Capacity => 3);
      Queue   : Channels.Channel (Storage'Access, Capacity => 1);
      First   : Buffers.Unique_Buffer (Storage'Access);
      Second  : Buffers.Unique_Buffer (Storage'Access);
      Target  : Buffers.Unique_Buffer (Storage'Access);
      Send_Result    : Channels.Try_Send_Result;
      Receive_Result : Channels.Try_Receive_Result;
      Metadata       : Channels.Transfer_Metadata;
      Timed_Out      : Boolean := False;
   begin
      Buffers.Acquire (First);
      Buffers.Copy_From (First, [1, 2, 3]);
      Buffers.Set_Tag (First, 7);
      Queue.Send_Move (First, Metadata => 13);
      Assert (not Buffers.Has_Buffer (First), "send retained ownership");

      Buffers.Acquire (Second);
      Buffers.Copy_From (Second, [4, 5]);
      Queue.Try_Send_Move (Second, Send_Result);
      Assert
        (Send_Result = Channels.Channel_Full
         and then Buffers.Has_Buffer (Second),
         "full channel did not preserve sender ownership");
      begin
         Queue.Timed_Send_Move (Second, 0.0);
      exception
         when Channels.Timeout_Error => Timed_Out := True;
      end;
      Assert
        (Timed_Out and then Buffers.Has_Buffer (Second),
         "timed send did not preserve ownership");

      Queue.Receive_Move (Target, Metadata);
      Assert (Buffers.Tag (Target) = 7, "channel lost FIFO metadata");
      Assert (Metadata = 13, "channel lost transfer metadata");
      Check_Payload (Target, [1, 2, 3]);
      Buffers.Release (Target);

      Queue.Send_Move (Second);
      Queue.Receive_Move (Target, Metadata);
      Assert
        (Metadata = Channels.No_Metadata,
         "default channel metadata did not round trip");
      Buffers.Release (Target);
      Buffers.Acquire (Second);

      Queue.Close;
      Queue.Try_Send_Move (Second, Send_Result);
      Assert
        (Send_Result = Channels.Send_Closed
         and then Buffers.Has_Buffer (Second),
         "closed channel consumed a sender buffer");
      Queue.Try_Receive_Move (Target, Receive_Result);
      Assert
        (Receive_Result = Channels.Receive_Closed
         and then not Buffers.Has_Buffer (Target),
         "drained channel returned a phantom buffer");
      Buffers.Release (Second);
      Queue.Await_Drained;
   end Run_Channel_Semantics;

   procedure Run_Concurrent_Handoff is
      Iterations : constant Positive := 2_000;
      Storage : aliased Buffers.Pool (Block_Size => 8, Capacity => 8);
      Queue   : Channels.Channel (Storage'Access, Capacity => 4);
      protected Completion is
         procedure Producer_Finished (Succeeded : Boolean);
         procedure Consumer_Finished
           (Succeeded : Boolean; Count : Natural);
         entry Await_Result (Succeeded : out Boolean; Count : out Natural);
      private
         Producer_Done : Boolean := False;
         Consumer_Done : Boolean := False;
         Producer_OK   : Boolean := False;
         Consumer_OK   : Boolean := False;
         Final_Count   : Natural := 0;
      end Completion;

      protected body Completion is
         procedure Producer_Finished (Succeeded : Boolean) is
         begin
            Producer_OK := Succeeded;
            Producer_Done := True;
         end Producer_Finished;

         procedure Consumer_Finished
           (Succeeded : Boolean; Count : Natural) is
         begin
            Consumer_OK := Succeeded;
            Final_Count := Count;
            Consumer_Done := True;
         end Consumer_Finished;

         entry Await_Result (Succeeded : out Boolean; Count : out Natural)
           when Producer_Done and then Consumer_Done
         is
         begin
            Succeeded := Producer_OK and then Consumer_OK;
            Count := Final_Count;
         end Await_Result;
      end Completion;

      task Producer is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Producer;

      task Consumer is
         pragma Task_Info (Flyology.Lightweight_Task);
      end Consumer;

      task body Producer is
         Item : Buffers.Unique_Buffer (Storage'Access);
      begin
         for Index in 1 .. Iterations loop
            Buffers.Acquire (Item);
            Buffers.Copy_From
              (Item, [1 => Ada.Streams.Stream_Element (Index mod 251)]);
            Buffers.Set_Tag (Item, Interfaces.Unsigned_64 (Index));
            Queue.Send_Move (Item);
         end loop;
         Queue.Close;
         Completion.Producer_Finished (True);
      exception
         when others =>
            Queue.Close;
            Completion.Producer_Finished (False);
      end Producer;

      task body Consumer is
         Item : Buffers.Unique_Buffer (Storage'Access);
         Count : Natural := 0;
         Valid : Boolean := True;
      begin
         loop
            begin
               Queue.Receive_Move (Item);
            exception
               when Channels.Channel_Closed => exit;
            end;
            Count := Count + 1;
            if Buffers.Tag (Item) /= Interfaces.Unsigned_64 (Count) then
               Valid := False;
            end if;
            Buffers.Release (Item);
         end loop;
         Completion.Consumer_Finished (Valid, Count);
      exception
         when others => Completion.Consumer_Finished (False, Count);
      end Consumer;
      Succeeded : Boolean;
      Count     : Natural;
   begin
      Completion.Await_Result (Succeeded, Count);
      Assert (Succeeded, "concurrent buffer handoff failed");
      Assert (Count = Iterations, "concurrent buffer handoff lost values");
   end Run_Concurrent_Handoff;

   procedure Run_Abort_Safety is
      Storage : aliased Buffers.Pool (Block_Size => 8, Capacity => 2);
      Queue   : Channels.Channel (Storage'Access, Capacity => 1);
      Seed    : Buffers.Unique_Buffer (Storage'Access);
      Target  : Buffers.Unique_Buffer (Storage'Access);

      protected Gate is
         procedure Ready;
         entry Await_Ready;
      private
         Is_Ready : Boolean := False;
      end Gate;

      protected body Gate is
         procedure Ready is
         begin
            Is_Ready := True;
         end Ready;

         entry Await_Ready when Is_Ready is
         begin
            null;
         end Await_Ready;
      end Gate;

      task Blocked_Sender is
         pragma Task_Info (Flyology.Lightweight_Task);
         entry Start;
      end Blocked_Sender;

      task body Blocked_Sender is
         Item : Buffers.Unique_Buffer (Storage'Access);
      begin
         accept Start;
         Buffers.Acquire (Item);
         Buffers.Copy_From (Item, [5, 6]);
         Gate.Ready;
         Queue.Send_Move (Item);
      end Blocked_Sender;
   begin
      Buffers.Acquire (Seed);
      Buffers.Copy_From (Seed, [1]);
      Queue.Send_Move (Seed);
      Blocked_Sender.Start;
      Gate.Await_Ready;
      for Attempt in 1 .. 1_000 loop
         exit when Queue.Current.Waiting_Senders = 1;
         delay 0.001;
      end loop;
      Assert
        (Queue.Current.Waiting_Senders = 1,
         "sender did not block at the full buffer channel");
      abort Blocked_Sender;
      while not Blocked_Sender'Terminated loop
         delay 0.001;
      end loop;
      Queue.Receive_Move (Target);
      Buffers.Release (Target);
      Queue.Close;
      Assert
        (Buffers.Current (Storage) =
           (Available => 2, Outstanding => 0),
         "aborted buffer send leaked or duplicated a slot");
   end Run_Abort_Safety;

   procedure Run_WebSocket_Outbox is
      Storage : aliased Buffers.Pool (Block_Size => 16, Capacity => 2);
      First   : Buffers.Unique_Buffer (Storage'Access);
      Second  : Buffers.Unique_Buffer (Storage'Access);
      Accepted : Boolean;
      Timed_Out : Boolean;
      Legacy_Rejected : Boolean := False;
   begin
      Buffers.Acquire (First);
      Buffers.Copy_From (First, [1, 2, 3, 4]);
      declare
         Session : WebSockets.Session
           (Capacity    => 1,
            Byte_Limit  => 16,
            Budget      => null,
            Buffer_Pool => Storage'Access);

         task Closer is
            entry Start;
         end Closer;

         task body Closer is
         begin
            accept Start;
            delay 0.02;
            WebSockets.Close (Session);
         end Closer;
      begin
         begin
            WebSockets.Try_Publish
              (Session,
               (Kind => HTTP.Binary_Frame,
                Data => Flyology.Bytes.To_Unbounded_Bytes ([1])),
               Accepted);
         exception
            when Program_Error => Legacy_Rejected := True;
         end;
         Assert
           (Legacy_Rejected,
            "configured WebSocket session accepted value publishing");
         WebSockets.Try_Publish_Move
           (Session, HTTP.Binary_Frame, First, Accepted);
         Assert
           (Accepted and then not Buffers.Has_Buffer (First),
            "WebSocket outbox did not accept moved payload");
         Buffers.Acquire (Second);
         Buffers.Copy_From (Second, [5, 6]);
         Buffers.Set_Tag (Second, 777);
         WebSockets.Try_Publish_Move
           (Session, HTTP.Binary_Frame, Second, Accepted);
         Assert
           (not Accepted and then Buffers.Has_Buffer (Second),
            "full WebSocket outbox consumed a payload");
         Assert
           (Buffers.Tag (Second) = 777,
            "rejected WebSocket publish changed the application tag");
         Closer.Start;
         WebSockets.Publish_Move_For
           (Session, HTTP.Binary_Frame, Second, Accepted,
            Timeout => -1.0, Timed_Out => Timed_Out);
         Assert
           (not Accepted and then not Timed_Out,
            "WebSocket close was reported as a timeout");
         Assert
           (Buffers.Has_Buffer (Second) and then Buffers.Tag (Second) = 777,
            "closed WebSocket publish changed buffer ownership or tag");
      end;
      Buffers.Release (Second);
      Assert
        (Buffers.Current (Storage) =
           (Available => 2, Outstanding => 0),
         "WebSocket outbox finalization did not release moved payload");
   end Run_WebSocket_Outbox;

   procedure Run_IO is
      Storage : aliased Buffers.Pool (Block_Size => 16, Capacity => 2);
      Outgoing : Buffers.Unique_Buffer (Storage'Access);
      Incoming : Buffers.Unique_Buffer (Storage'Access);
      Left, Right : Sockets.Socket_Type;
      Received : Natural;
      Written  : Natural;
      File     : Files.File_Descriptor := Files.Invalid_File;
      Path     : constant String := "/tmp/flyology-buffer-smoke.bin";
   begin
      Buffers.Acquire (Outgoing);
      Buffers.Acquire (Incoming);
      Buffers.Copy_From (Outgoing, [9, 8, 7, 6]);
      Sockets.Create_Socket_Pair (Left, Right);
      Sockets.Send_All (Left, Outgoing);
      Sockets.Receive (Right, Incoming, Received, Timeout => 2.0);
      Assert (Received = 4, "buffer socket receive length is wrong");
      Check_Payload (Incoming, [9, 8, 7, 6]);
      Sockets.Close_Socket (Left);
      Sockets.Close_Socket (Right);

      File := Files.Open
        (Path, Mode => Files.Write_Only, Create => True, Truncate => True);
      Files.Write_At (File, 0, Outgoing, Written);
      Assert (Written = 4, "buffer file write length is wrong");
      Files.Close (File);
      File := Files.Open (Path, Mode => Files.Read_Only);
      Files.Read_At (File, 0, Incoming, Received);
      Files.Close (File);
      Assert (Received = 4, "buffer file read length is wrong");
      Check_Payload (Incoming, [9, 8, 7, 6]);
      Ada.Directories.Delete_File (Path);
   exception
      when others =>
         if File /= Files.Invalid_File then
            Files.Close (File);
         end if;
         if Sockets.Is_Open (Left) then
            Sockets.Close_Socket (Left);
         end if;
         if Sockets.Is_Open (Right) then
            Sockets.Close_Socket (Right);
         end if;
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
         raise;
   end Run_IO;

begin
   Run_Ownership;
   Run_Pool_Exhaustion;
   Run_Channel_Semantics;
   Run_Concurrent_Handoff;
   Run_Abort_Safety;
   Run_WebSocket_Outbox;
   Run_IO;
end Buffers_Smoke;
