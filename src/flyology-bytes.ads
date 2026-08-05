with Ada.Streams;
private with Ada.Containers.Vectors;

--  Provides an owned, growable sequence of octets for binary application
--  data. Stream_Element_Array remains the contiguous I/O boundary; this type
--  supplies value semantics when the final length is not known in advance.
package Flyology.Bytes is

   use type Ada.Streams.Stream_Element;

   --  Owned byte sequence with automatic storage management and value
   --  semantics. Its representation and indices are intentionally hidden.
   type Unbounded_Bytes is private;

   --  Empty byte sequence.
   Empty : constant Unbounded_Bytes;

   --  Copy a contiguous stream-element array into owned storage.
   --  @param Data Source bytes
   --  @return Independently owned byte sequence
   function To_Unbounded_Bytes
     (Data : Ada.Streams.Stream_Element_Array) return Unbounded_Bytes;

   --  Copy a byte string into owned storage using a one-to-one mapping from
   --  Character positions 0 .. 255. This is not a character encoding.
   --  @param Data Source byte string
   --  @return Independently owned byte sequence
   function From_Byte_String (Data : String) return Unbounded_Bytes;

   --  Return a contiguous copy with lower bound 1, or 1 .. 0 when empty.
   --  @param Data Owned byte sequence
   --  @return Contiguous stream elements
   function To_Array
     (Data : Unbounded_Bytes) return Ada.Streams.Stream_Element_Array;

   --  Convert bytes one-to-one to Character positions 0 .. 255. This helper
   --  is intended for byte-oriented protocol parsers and already validated
   --  UTF-8 text; it does not decode Unicode.
   --  @param Data Owned byte sequence
   --  @return Byte string with the same octets
   function To_Byte_String (Data : Unbounded_Bytes) return String;

   --  Return the number of retained bytes.
   --  @param Data Owned byte sequence
   --  @return Payload length
   function Length (Data : Unbounded_Bytes) return Natural;

   --  Return one retained byte by its one-based position.
   --  @param Data Owned byte sequence
   --  @param Index One-based byte position
   --  @return Byte at Index
   function Element
     (Data  : Unbounded_Bytes;
      Index : Positive) return Ada.Streams.Stream_Element;

   --  Append contiguous bytes, growing owned storage as required.
   --  @param Data Destination sequence
   --  @param Value Bytes to append
   procedure Append
     (Data  : in out Unbounded_Bytes;
      Value : Ada.Streams.Stream_Element_Array);

   --  Append one byte, growing owned storage as required.
   --  @param Data Destination sequence
   --  @param Value Byte to append
   procedure Append
     (Data  : in out Unbounded_Bytes;
      Value : Ada.Streams.Stream_Element);

   --  Ensure capacity for at least Capacity bytes without changing Length.
   --  @param Data Destination sequence
   --  @param Capacity Requested retained capacity
   procedure Reserve_Capacity
     (Data     : in out Unbounded_Bytes;
      Capacity : Natural);

   --  Append a one-to-one byte string. This is not a character encoding.
   --  @param Data Destination sequence
   --  @param Value Byte string to append
   procedure Append_Byte_String
     (Data  : in out Unbounded_Bytes;
      Value : String);

   --  Transfer owned storage without copying and leave Source empty.
   --  @param Target Destination sequence, whose prior storage is released
   --  @param Source Sequence whose storage is transferred
   procedure Move
     (Target : in out Unbounded_Bytes;
      Source : in out Unbounded_Bytes);

   --  Release all retained elements and backing capacity.
   --  @param Data Sequence to clear
   procedure Clear (Data : in out Unbounded_Bytes);

private
   package Storage is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => Ada.Streams.Stream_Element);

   type Unbounded_Bytes is record
      Value : Storage.Vector;
   end record;

   Empty : constant Unbounded_Bytes := (Value => Storage.Empty_Vector);

end Flyology.Bytes;
