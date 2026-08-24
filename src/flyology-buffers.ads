with Ada.Finalization;
with Ada.Streams;
with Interfaces;

--  Supplies fixed-storage byte buffers with explicit single-owner transfer.
--  A buffer payload is mutable only through its current Unique_Buffer owner.
--  Moving a buffer transfers a slot token and never copies payload bytes.
--  Pool acquisition and accounting are task-safe. One task must exclusively
--  own each Unique_Buffer handle and every payload borrow through that handle.

package Flyology.Buffers is
   use type Ada.Streams.Stream_Element_Offset;

   --  Raised by a timed pool acquisition whose deadline expires first.
   Timeout_Error : exception;

   --  Fixed-block storage pool. Pool must outlive every buffer obtained from
   --  it; an access discriminant enforces that relationship for ordinary Ada
   --  objects. Storage is allocated once during initialization and never
   --  grows. Finalizing a Pool with an outstanding buffer or channel token
   --  raises Program_Error rather than invalidating live ownership.
   type Pool
     (Block_Size : Positive;
      --  Payload capacity of each buffer
      Capacity   : Positive)  --  Number of independently ownable buffers
   is limited new Ada.Finalization.Limited_Controlled with private;

   --  Snapshot of one pool's ownership accounting.
   --  @field Available Slots available for acquisition
   --  @field Outstanding Slots held by buffers or channels
   type Pool_Snapshot is record
      Available   : Natural;
      Outstanding : Natural;
   end record;

   --  Exclusive handle for one pool slot. The type is limited so assignment
   --  cannot duplicate ownership. Finalization returns an acquired slot.
   type Unique_Buffer
     (Owner : not null access Pool)  --  Storage pool that must outlive handle
   is limited new Ada.Finalization.Limited_Controlled with private;

   --  Wait until a pool slot is available and attach it to vacant Item. The
   --  protected entry suspends a lightweight caller cooperatively and blocks
   --  only a native caller's tasking thread.
   --  @param Item Vacant buffer that receives sole ownership
   --  @exception Program_Error Item already owns a slot
   procedure Acquire (Item : in out Unique_Buffer)
   with Pre => not Has_Buffer (Item), Post => Has_Buffer (Item) and then Length (Item) = 0;

   --  Attempt to acquire without waiting.
   --  @param Item Vacant buffer that receives ownership on success
   --  @param Acquired True only when a slot was attached
   --  @exception Program_Error Item already owns a slot
   procedure Try_Acquire (Item : in out Unique_Buffer; Acquired : out Boolean)
   with Pre => not Has_Buffer (Item), Post => Acquired = Has_Buffer (Item);

   --  Acquire within one relative deadline. Negative Timeout waits without a
   --  deadline; zero is an immediate attempt.
   --  @param Item Vacant buffer that receives ownership on success
   --  @param Timeout Maximum monotonic wait in seconds
   --  @exception Timeout_Error No slot becomes available before the deadline
   --  @exception Program_Error Item already owns a slot
   procedure Acquire_For (Item : in out Unique_Buffer; Timeout : Duration)
   with Pre => not Has_Buffer (Item), Post => Has_Buffer (Item) and then Length (Item) = 0;

   --  Return Item's slot to its pool and leave Item vacant. A slot completing
   --  its final nonwrapping generation is permanently retired instead of
   --  becoming available again. Releasing a vacant buffer is harmless.
   --  @param Item Buffer whose ownership is relinquished
   procedure Release (Item : in out Unique_Buffer)
   with Post => not Has_Buffer (Item);

   --  Transfer ownership without copying payload bytes. Source and Target
   --  must belong to the same pool.
   --  @param Source Acquired buffer whose ownership transfers
   --  @param Target Vacant buffer that receives the slot
   --  @exception Program_Error The handles belong to different pools, Source
   --     is vacant, or Target already owns a slot
   procedure Move (Source : in out Unique_Buffer; Target : in out Unique_Buffer)
   with
     Pre  => Has_Buffer (Source) and then not Has_Buffer (Target),
     Post => not Has_Buffer (Source) and then Has_Buffer (Target);

   --  Report whether Item currently owns a pool slot.
   --  @param Item Buffer to inspect
   --  @return True only while Item owns storage
   function Has_Buffer (Item : Unique_Buffer) return Boolean;

   --  Return the initialized payload length. A vacant buffer has length zero.
   --  @param Item Buffer to inspect
   --  @return Number of readable payload bytes
   function Length (Item : Unique_Buffer) return Natural;

   --  Return the fixed payload capacity supplied by Item's pool.
   --  @param Item Buffer to inspect
   --  @return Maximum writable payload bytes
   function Buffer_Capacity (Item : Unique_Buffer) return Positive;

   --  Associate an application scalar with Item. The tag follows ownership
   --  transfer but is not part of the payload.
   --  @param Item Acquired buffer to update
   --  @param Value Application-defined scalar
   --  @exception Program_Error Item is vacant
   procedure Set_Tag (Item : in out Unique_Buffer; Value : Interfaces.Unsigned_64)
   with Pre => Has_Buffer (Item);

   --  Return Item's application tag, or zero for a vacant buffer.
   --  @param Item Buffer to inspect
   --  @return Application-defined scalar
   function Tag (Item : Unique_Buffer) return Interfaces.Unsigned_64;

   --  Borrow Item's initialized payload for the duration of Process. Empty
   --  payloads are passed as a null array. Process executes synchronously and
   --  any exception it raises propagates. It must not retain an address into
   --  Data after it returns.
   --  @param Item Acquired buffer to inspect
   --  @param Process Synchronous payload consumer
   --  @exception Program_Error Item is vacant
   procedure With_Readable_Data
     (Item : Unique_Buffer; Process : not null access procedure (Data : Ada.Streams.Stream_Element_Array))
   with Pre => Has_Buffer (Item);

   --  Borrow Item's full writable block for the duration of Process. Length
   --  initially contains the current readable length and is committed only
   --  when Process returns normally with a value no greater than capacity.
   --  An exception leaves the prior readable length unchanged, although
   --  payload bytes already mutated by Process remain changed. Process must
   --  not retain an address into Data after it returns.
   --  @param Item Acquired buffer to modify
   --  @param Process Synchronous payload producer
   --  @exception Program_Error Item is vacant
   --  @exception Constraint_Error Process returns Length greater than capacity
   procedure With_Writable_Data
     (Item    : in out Unique_Buffer;
      Process :
        not null access procedure (Data : in out Ada.Streams.Stream_Element_Array; Length : in out Natural))
   with Pre => Has_Buffer (Item);

   --  Copy Data into Item and set its readable length. This convenience
   --  operation is for boundaries that do not yet produce directly into a
   --  borrowed block.
   --  @param Item Acquired destination buffer
   --  @param Data Source bytes
   --  @exception Program_Error Item is vacant
   --  @exception Constraint_Error Data is larger than Item's capacity
   procedure Copy_From (Item : in out Unique_Buffer; Data : Ada.Streams.Stream_Element_Array)
   with
     Pre  => Has_Buffer (Item) and then Data'Length <= Buffer_Capacity (Item),
     Post => Length (Item) = Data'Length;

   --  Read the pool's coherent availability counters. This task-safe snapshot
   --  does not wait for all outstanding owners to drain.
   --  @param Item Pool to inspect
   --  @return Current slot accounting
   function Current (Item : Pool) return Pool_Snapshot;

private
   subtype Generation is Interfaces.Unsigned_64;
   No_Generation : constant Generation := 0;
   No_Slot       : constant Natural := 0;

   type Slot_Array is array (Positive range <>) of Natural;
   type Generation_Array is array (Positive range <>) of Generation;
   type Boolean_Array is array (Positive range <>) of Boolean;

   protected type Pool_State (Slot_Count : Positive) is
      procedure Allocate (Slot : out Natural; Version : out Generation);
      entry Acquire (Slot : out Natural; Version : out Generation);
      procedure Try_Acquire (Slot : out Natural; Version : out Generation; Acquired : out Boolean);
      procedure Release (Slot : Positive; Version : Generation);
      function Current return Pool_Snapshot;
   private
      Free_Slots  : Slot_Array (1 .. Slot_Count) := (others => No_Slot);
      Versions    : Generation_Array (1 .. Slot_Count) := (others => No_Generation);
      In_Use      : Boolean_Array (1 .. Slot_Count) := (others => False);
      Free_Count  : Natural := 0;
      Next_Unused : Natural := 1;
      Used_Count  : Natural := 0;
   end Pool_State;

   subtype Storage_Offset is Ada.Streams.Stream_Element_Offset;
   type Storage_Access is access Ada.Streams.Stream_Element_Array;
   type Pool
     (Block_Size : Positive;
      Capacity   : Positive)
   is limited new Ada.Finalization.Limited_Controlled with record
      State : Pool_State (Capacity);
      Data  : Storage_Access;
   end record;

   --  @exclude
   --  @param Item Pool being initialized
   overriding
   procedure Initialize (Item : in out Pool);
   --  @exclude
   --  @param Item Pool being finalized
   overriding
   procedure Finalize (Item : in out Pool);

   type Buffer_Token is record
      Slot             : Natural := No_Slot;
      Version          : Generation := No_Generation;
      Length           : Natural := 0;
      Tag              : Interfaces.Unsigned_64 := 0;
      Channel_Metadata : Interfaces.Unsigned_64 := 0;
   end record;

   No_Token : constant Buffer_Token := (others => <>);

   type Unique_Buffer (Owner : not null access Pool) is limited new Ada.Finalization.Limited_Controlled
   with record
      Token : Buffer_Token := No_Token;
   end record;

   --  @exclude
   --  @param Item Buffer to compare
   --  @param Token Ownership token to compare
   --  @return True when Item contains Token
   function Owns (Item : Unique_Buffer; Token : Buffer_Token) return Boolean;
   --  @exclude
   --  @param Item Buffer relinquishing its token
   --  @param Token Detached ownership token
   procedure Detach (Item : in out Unique_Buffer; Token : out Buffer_Token);
   --  @exclude
   --  @param Item Vacant buffer receiving ownership
   --  @param Token Ownership token consumed on success
   procedure Attach (Item : in out Unique_Buffer; Token : in out Buffer_Token);
   --  @exclude
   --  @param Owner Pool receiving its slot
   --  @param Token Ownership token cleared on release
   procedure Release_Token (Owner : not null access Pool; Token : in out Buffer_Token);

   --  @exclude
   --  @param Item Buffer being finalized
   overriding
   procedure Finalize (Item : in out Unique_Buffer);

end Flyology.Buffers;
