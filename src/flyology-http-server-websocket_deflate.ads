with Ada.Streams;
with Flyology.Bytes;

--  Bounded raw-DEFLATE support for RFC 7692 WebSocket messages. The server
--  negotiates no context takeover, so each invocation is an independent
--  stream and no codec state survives between messages.
private package Flyology.HTTP.Server.WebSocket_Deflate is

   Invalid_Data : exception;
   Output_Too_Large : exception;

   --  Inflate one RFC 7692 message payload. Reserve_Output is called before
   --  each bounded growth step so the owning connection can account for the
   --  temporary decompressed representation before allocating it.
   procedure Inflate
     (Input          : Flyology.Bytes.Unbounded_Bytes;
      Output         : out Flyology.Bytes.Unbounded_Bytes;
      Maximum        : Natural;
      Reserve_Output : access procedure (Bytes : Natural) := null);

   --  Encode one message as raw DEFLATE with a bounded 32 KiB LZ77 window and
   --  fixed Huffman codes, followed by the RFC 7692 sync-flush prefix. The
   --  encoder is deterministic and carries no state between messages.
   procedure Deflate
     (Input  : Ada.Streams.Stream_Element_Array;
      Output : out Flyology.Bytes.Unbounded_Bytes);

   procedure Deflate
     (Input  : Flyology.Bytes.Unbounded_Bytes;
      Output : out Flyology.Bytes.Unbounded_Bytes);

end Flyology.HTTP.Server.WebSocket_Deflate;
