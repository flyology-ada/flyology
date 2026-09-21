with Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Flyology.Buffers;
with Flyology.Buffers.Channels;
with Flyology.Channel_Buckets;
with Flyology.Channels.Bounded;
with Flyology.Operations;
with Interfaces;

procedure Flyology.Channel_Bucket_Smoke is
   package Plain is new Flyology.Channels.Bounded (Integer, 0);
   package Buffer_Channels renames Flyology.Buffers.Channels;

   type Plain_Access is access all Plain.Channel;
   type Plain_Array is array (Positive range <>) of Plain_Access;
   type Buffer_Array is
     array (Positive range <>) of Buffer_Channels.Channel_Access;
   type Bucket_Counts is
     array (Flyology.Channel_Buckets.Bucket_Index) of Natural;

   procedure Free is new
     Ada.Unchecked_Deallocation (Plain.Channel, Plain_Access);
   procedure Free is new
     Ada.Unchecked_Deallocation
       (Buffer_Channels.Channel,
        Buffer_Channels.Channel_Access);

   Storage       :
     aliased Flyology.Buffers.Pool (Block_Size => 8, Capacity => 4);
   Plain_Items   : Plain_Array (1 .. 128);
   Buffer_Items  : Buffer_Array (1 .. 128);
   Plain_Counts  : Bucket_Counts := (others => 0);
   Buffer_Counts : Bucket_Counts := (others => 0);

   use type Interfaces.Unsigned_64;

   function Occupied (Counts : Bucket_Counts) return Natural is
      Result : Natural := 0;
   begin
      for Count of Counts loop
         if Count /= 0 then
            Result := Result + 1;
         end if;
      end loop;
      return Result;
   end Occupied;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Check;

   function Different_Plain_Bucket return Positive is
      First : constant Flyology.Channel_Buckets.Bucket_Index :=
        Flyology.Channel_Buckets.Bucket
          (Plain_Items (1).all'Address, Plain.Channel'Alignment);
   begin
      for Index in 2 .. Plain_Items'Last loop
         if Flyology.Channel_Buckets.Bucket
              (Plain_Items (Index).all'Address, Plain.Channel'Alignment)
           /= First
         then
            return Index;
         end if;
      end loop;
      raise Program_Error with "plain channel buckets did not vary";
   end Different_Plain_Bucket;

   function Different_Buffer_Bucket return Positive is
      First : constant Flyology.Channel_Buckets.Bucket_Index :=
        Flyology.Channel_Buckets.Bucket
          (Buffer_Items (1).all'Address, Buffer_Channels.Channel'Alignment);
   begin
      for Index in 2 .. Buffer_Items'Last loop
         if Flyology.Channel_Buckets.Bucket
              (Buffer_Items (Index).all'Address,
               Buffer_Channels.Channel'Alignment)
           /= First
         then
            return Index;
         end if;
      end loop;
      raise Program_Error with "buffer channel buckets did not vary";
   end Different_Buffer_Bucket;

begin
   for Index in Plain_Items'Range loop
      Plain_Items (Index) := new Plain.Channel (1);
      Buffer_Items (Index) :=
        new Buffer_Channels.Channel (Storage'Unchecked_Access, 1);
      Plain_Counts
        (Flyology.Channel_Buckets.Bucket
           (Plain_Items (Index).all'Address, Plain.Channel'Alignment)) :=
        Plain_Counts
          (Flyology.Channel_Buckets.Bucket
             (Plain_Items (Index).all'Address, Plain.Channel'Alignment))
        + 1;
      Buffer_Counts
        (Flyology.Channel_Buckets.Bucket
           (Buffer_Items (Index).all'Address,
            Buffer_Channels.Channel'Alignment)) :=
        Buffer_Counts
          (Flyology.Channel_Buckets.Bucket
             (Buffer_Items (Index).all'Address,
              Buffer_Channels.Channel'Alignment))
        + 1;
   end loop;

   Check
     (Occupied (Plain_Counts) >= 16,
      "plain channel subscription buckets collapsed");
   Check
     (Occupied (Buffer_Counts) >= 16,
      "buffer channel subscription buckets collapsed");

   --  A transition on a different bucket must leave the pending receive on
   --  channel 1 untouched; a transition on channel 1 must still wake it.
   declare
      Other : constant Positive := Different_Plain_Bucket;
      Set   : aliased Flyology.Operations.Completion_Set (1);
      Get   : Plain.Receive_Operation :=
        Plain.Receive (Set'Access, Plain_Items (1), 1.0);
      Value : Integer;
   begin
      Plain.Send (Plain_Items (Other).all, 21);
      Check
        (Flyology.Operations.Is_Active (Get),
         "unrelated plain channel woke a receive");
      Plain.Send (Plain_Items (1).all, 22);
      Flyology.Operations.Wait_All (Set);
      Plain.Finish (Get, Value);
      Check (Value = 22, "plain channel subscription missed its value");
   end;

   declare
      Other    : constant Positive := Different_Buffer_Bucket;
      Set      : aliased Flyology.Operations.Completion_Set (1);
      Get      : Buffer_Channels.Receive_Operation :=
        Buffer_Channels.Receive_Move (Set'Access, Buffer_Items (1), 1.0);
      Outgoing : Flyology.Buffers.Unique_Buffer (Storage'Access);
      Incoming : Flyology.Buffers.Unique_Buffer (Storage'Access);
   begin
      Flyology.Buffers.Acquire (Outgoing);
      Flyology.Buffers.Set_Tag (Outgoing, 21);
      Buffer_Channels.Send_Move (Buffer_Items (Other).all, Outgoing);
      Check
        (Flyology.Operations.Is_Active (Get),
         "unrelated buffer channel woke a receive");
      Buffer_Channels.Receive_Move (Buffer_Items (Other).all, Incoming);
      Flyology.Buffers.Release (Incoming);
      Flyology.Buffers.Acquire (Outgoing);
      Flyology.Buffers.Set_Tag (Outgoing, 22);
      Buffer_Channels.Send_Move (Buffer_Items (1).all, Outgoing);
      Flyology.Operations.Wait_All (Set);
      Buffer_Channels.Finish (Get, Incoming);
      Check
        (Flyology.Buffers.Tag (Incoming) = 22,
         "buffer channel subscription missed its token");
      Flyology.Buffers.Release (Incoming);
   end;

   for Index in Plain_Items'Range loop
      Free (Plain_Items (Index));
      Free (Buffer_Items (Index));
   end loop;
   Ada.Text_IO.Put_Line
     ("channel bucket smoke passed: plain="
      & Natural'Image (Occupied (Plain_Counts))
      & ", buffers="
      & Natural'Image (Occupied (Buffer_Counts)));
end Flyology.Channel_Bucket_Smoke;
