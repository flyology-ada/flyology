with Ada.Streams;
with Flyology.Buffers.Channels;

--  Adapts a bounded unique-buffer channel into a generated HTTP request body.
--  Producers retain ordinary channel backpressure and close the channel to
--  finish an unknown-length body.
package Flyology.HTTP.Client.Request_Bodies.Channels is

   --  Consume buffers from Input. Pool must be Input's owner. The source holds
   --  at most one received buffer between Read calls and releases each buffer
   --  after copying its payload into the HTTP transport's bounded staging
   --  array. Pool and Input must outlive the source and Execute.
   type Channel_Source
     (Pool  : not null access Flyology.Buffers.Pool;
      Input : not null access Flyology.Buffers.Channels.Channel)
   is limited new Request_Body_Source with private;

   --  Set the framing length before Execute. Unknown_Length, the default,
   --  sends HTTP/1.1 chunked coding until Input closes and drains. A known
   --  length makes the client consume exactly that many bytes and validate an
   --  early channel close. The length cannot change after reading starts.
   --  @param Item Channel source to configure
   --  @param Length Known total byte count or Unknown_Length
   --  @exception Program_Error Reading has already started
   procedure Set_Declared_Length
     (Item : in out Channel_Source; Length : Body_Length);

   --  @exclude
   --  @param Item Channel source to inspect
   --  @return Configured known or unknown length
   overriding function Declared_Length
     (Item : Channel_Source) return Body_Length;

   --  @exclude
   --  @param Item Channel source to advance
   --  @param Data Client staging array
   --  @param Last Last produced byte
   --  @param Finished Whether the channel is closed and drained
   --  @param Timeout Remaining exchange timeout
   --  @param Token Exchange cancellation token
   overriding procedure Read
     (Item     : in out Channel_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token);

private
   type Channel_Source
     (Pool  : not null access Flyology.Buffers.Pool;
      Input : not null access Flyology.Buffers.Channels.Channel)
   is limited new Request_Body_Source with record
      Current  : Flyology.Buffers.Unique_Buffer (Pool);
      Position : Natural := 0;
      Framing  : Body_Length := Unknown_Length;
      Started  : Boolean := False;
      Ended    : Boolean := False;
   end record;

end Flyology.HTTP.Client.Request_Bodies.Channels;
