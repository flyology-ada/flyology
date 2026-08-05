with Ada.Streams;
with Flyology.Buffers;
with Flyology.Bytes;

--  Supplies bounded-memory request body sources for the HTTP client. Each
--  source borrows its payload for the duration of Execute; the caller retains
--  ownership and must not mutate or release it until Execute returns.
package Flyology.HTTP.Client.Request_Bodies is

   --  Borrow a stream-element array without retaining a second complete body.
   --  Data must outlive the source and every Execute call using it.
   type Array_Source
     (Data : not null access constant Ada.Streams.Stream_Element_Array)
   is limited new Request_Body_Source with private;

   --  Rewind an array source for an explicit later Execute call. The HTTP
   --  client never invokes this automatically.
   --  @param Item Source whose cursor returns to its first byte
   procedure Rewind (Item : in out Array_Source);

   --  Borrow a byte string using the same one-character-to-one-octet mapping
   --  as Set_Body. This adapter does not perform character encoding.
   type Byte_String_Source
     (Data : not null access constant String)
   is limited new Request_Body_Source with private;

   --  Rewind a byte-string source for an explicit later Execute call.
   --  @param Item Source whose cursor returns to its first byte
   procedure Rewind (Item : in out Byte_String_Source);

   --  Borrow owned Flyology bytes without constructing another complete
   --  request body. Data must remain unchanged through Execute.
   type Bytes_Source
     (Data : not null access constant Flyology.Bytes.Unbounded_Bytes)
   is limited new Request_Body_Source with private;

   --  Rewind an owned-bytes source for an explicit later Execute call.
   --  @param Item Source whose cursor returns to its first byte
   procedure Rewind (Item : in out Bytes_Source);

   --  Borrow the readable payload of one acquired unique buffer. The source
   --  never transfers or releases the buffer's ownership token.
   type Buffer_Source
     (Data : not null access constant Flyology.Buffers.Unique_Buffer)
   is limited new Request_Body_Source with private;

   --  Rewind a unique-buffer source for an explicit later Execute call.
   --  @param Item Source whose cursor returns to its first byte
   procedure Rewind (Item : in out Buffer_Source);

   --  @exclude
   --  @param Item Array source to inspect
   --  @return Exact array length
   overriding function Declared_Length
     (Item : Array_Source) return Body_Length;
   --  @exclude
   --  @param Item Array source to advance
   --  @param Data Client staging array
   --  @param Last Last produced byte
   --  @param Finished Whether the array is exhausted
   --  @param Timeout Remaining exchange timeout
   --  @param Token Exchange cancellation token
   overriding procedure Read
     (Item     : in out Array_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token);

   --  @exclude
   --  @param Item Byte-string source to inspect
   --  @return Exact byte-string length
   overriding function Declared_Length
     (Item : Byte_String_Source) return Body_Length;
   --  @exclude
   --  @param Item Byte-string source to advance
   --  @param Data Client staging array
   --  @param Last Last produced byte
   --  @param Finished Whether the byte string is exhausted
   --  @param Timeout Remaining exchange timeout
   --  @param Token Exchange cancellation token
   overriding procedure Read
     (Item     : in out Byte_String_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token);

   --  @exclude
   --  @param Item Owned-bytes source to inspect
   --  @return Exact retained byte length
   overriding function Declared_Length
     (Item : Bytes_Source) return Body_Length;
   --  @exclude
   --  @param Item Owned-bytes source to advance
   --  @param Data Client staging array
   --  @param Last Last produced byte
   --  @param Finished Whether the owned bytes are exhausted
   --  @param Timeout Remaining exchange timeout
   --  @param Token Exchange cancellation token
   overriding procedure Read
     (Item     : in out Bytes_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token);

   --  @exclude
   --  @param Item Unique-buffer source to inspect
   --  @return Exact readable buffer length
   overriding function Declared_Length
     (Item : Buffer_Source) return Body_Length;
   --  @exclude
   --  @param Item Unique-buffer source to advance
   --  @param Data Client staging array
   --  @param Last Last produced byte
   --  @param Finished Whether the buffer is exhausted
   --  @param Timeout Remaining exchange timeout
   --  @param Token Exchange cancellation token
   overriding procedure Read
     (Item     : in out Buffer_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token);

private
   type Array_Source
     (Data : not null access constant Ada.Streams.Stream_Element_Array)
   is limited new Request_Body_Source with record
      Position : Natural := 0;
   end record;

   type Byte_String_Source
     (Data : not null access constant String)
   is limited new Request_Body_Source with record
      Position : Natural := 0;
   end record;

   type Bytes_Source
     (Data : not null access constant Flyology.Bytes.Unbounded_Bytes)
   is limited new Request_Body_Source with record
      Position : Natural := 0;
   end record;

   type Buffer_Source
     (Data : not null access constant Flyology.Buffers.Unique_Buffer)
   is limited new Request_Body_Source with record
      Position : Natural := 0;
   end record;

end Flyology.HTTP.Client.Request_Bodies;
