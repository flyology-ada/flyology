with Ada.Strings.Unbounded;

--  Stores validated HTTP fields in insertion order without combining repeated
--  lines. The fixed field capacity and byte limit bound all retained storage.
package Flyology.HTTP.Headers is

   --  Default maximum number of physical fields retained by a list.
   Default_Capacity  : constant Positive := 64;
   --  Default maximum combined field-name and field-value bytes.
   Default_Max_Bytes : constant Positive := 16 * 1_024;

   --  Supported physical field-count bound.
   subtype Header_Capacity is Positive range 1 .. 256;
   --  Supported retained name/value byte bound.
   subtype Header_Byte_Limit is Positive range 1 .. 1_048_576;

   --  Raised when a list cannot retain another field within its configured
   --  field-count or byte bound.
   Headers_Too_Large : exception;

   --  Ordered bounded collection of HTTP field lines.
   --  @field Capacity Maximum physical field count
   --  @field Max_Bytes Maximum combined name and value bytes
   type List
     (Capacity  : Header_Capacity := Default_Capacity;
      Max_Bytes : Header_Byte_Limit := Default_Max_Bytes) is private;

   --  Append one physical field line. Names and values are validated against
   --  HTTP token and field-value syntax; repeated names remain separate.
   --  @param Item Collection to change
   --  @param Name Case-insensitive field name whose spelling is preserved
   --  @param Value Field value without surrounding line whitespace
   --  @exception Constraint_Error Name or Value is invalid
   --  @exception Headers_Too_Large A configured bound would be exceeded
   procedure Add (Item : in out List; Name : String; Value : String);

   --  Remove every field line.
   --  @param Item Collection to clear
   procedure Clear (Item : in out List);

   --  Return the number of physical fields.
   --  @param Item Collection to inspect
   --  @return Field count
   function Count (Item : List) return Natural;

   --  Return one field name by insertion index.
   --  @param Item Collection to inspect
   --  @param Index One-based physical field index
   --  @return Preserved field name
   function Name (Item : List; Index : Positive) return String;

   --  Return one field value by insertion index.
   --  @param Item Collection to inspect
   --  @param Index One-based physical field index
   --  @return Preserved field value
   function Value (Item : List; Index : Positive) return String;

   --  Count physical occurrences of a case-insensitive field name.
   --  @param Item Collection to inspect
   --  @param Name Field name
   --  @return Matching physical field count
   function Count (Item : List; Name : String) return Natural;

   --  Return one occurrence of a case-insensitive field. An empty string is
   --  returned when the occurrence is absent; use Count to distinguish that
   --  from a present empty value.
   --  @param Item Collection to inspect
   --  @param Name Field name
   --  @param Occurrence One-based matching occurrence
   --  @return Matching value or an empty string
   function Value
     (Item : List; Name : String; Occurrence : Positive := 1) return String;

private
   type Field is record
      Name_Value : Ada.Strings.Unbounded.Unbounded_String;
      Data_Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;
   type Field_Array is array (Positive range <>) of Field;

   type List
     (Capacity  : Header_Capacity := Default_Capacity;
      Max_Bytes : Header_Byte_Limit := Default_Max_Bytes) is record
         Fields     : Field_Array (1 .. Capacity);
         Last       : Natural := 0;
         Used_Bytes : Natural := 0;
   end record;

end Flyology.HTTP.Headers;
