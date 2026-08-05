with Ada.Streams;
with Flyology.IO.Files;

--  Supplies positional file-range request bodies. A source borrows an open
--  descriptor, never changes its file position, and never closes it.
package Flyology.HTTP.Client.Request_Bodies.Files is

   --  Borrow Count bytes beginning at Offset. File must remain open through
   --  Execute. The range must fit File_Offset; invalid ranges are rejected
   --  when Execute queries Declared_Length. Reaching end-of-file early causes
   --  the client's known-length source validation to raise Request_Body_Error.
   type Range_Source
     (File   : not null access Flyology.IO.Files.File_Descriptor;
      Offset : Flyology.IO.Files.File_Offset;
      Count  : Body_Size)
   is limited new Request_Body_Source with private;

   --  Rewind a file range for an explicit later Execute call. The descriptor
   --  remains borrowed and the HTTP client never rewinds automatically.
   --  @param Item Source whose next read returns to Offset
   procedure Rewind (Item : in out Range_Source);

   --  @exclude
   --  @param Item File range to inspect
   --  @return Exact configured range length
   overriding function Declared_Length
     (Item : Range_Source) return Body_Length;

   --  @exclude
   --  @param Item File range to advance
   --  @param Data Client staging array
   --  @param Last Last produced byte
   --  @param Finished Whether the range or file is exhausted
   --  @param Timeout Remaining exchange timeout
   --  @param Token Exchange cancellation token
   overriding procedure Read
     (Item     : in out Range_Source;
      Data     : out Ada.Streams.Stream_Element_Array;
      Last     : out Ada.Streams.Stream_Element_Offset;
      Finished : out Boolean;
      Timeout  : Duration;
      Token    : access Flyology.Cancellation.Token);

private
   type Range_Source
     (File   : not null access Flyology.IO.Files.File_Descriptor;
      Offset : Flyology.IO.Files.File_Offset;
      Count  : Body_Size)
   is limited new Request_Body_Source with record
      Position : Body_Size := 0;
   end record;

end Flyology.HTTP.Client.Request_Bodies.Files;
