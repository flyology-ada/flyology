with Ada.Characters.Handling;

package body Flyology.HTTP.Headers is
   use Ada.Strings.Unbounded;

   function Is_Token_Character (Value : Character) return Boolean is
     (Value in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
        | '!' | '#' | '$' | '%' | '&' | ''' | '*' | '+' | '-' | '.'
        | '^' | '_' | '`' | '|' | '~');

   procedure Add (Item : in out List; Name : String; Value : String) is
      Added : constant Natural := Name'Length + Value'Length;
   begin
      if Name = ""
        or else (for some Character_Value of Name =>
                   not Is_Token_Character (Character_Value))
      then
         raise Constraint_Error with "invalid HTTP field name";
      end if;
      if (for some Character_Value of Value =>
            Character_Value = Character'Val (0)
              or else Character_Value = Character'Val (10)
              or else Character_Value = Character'Val (13)
              or else Character'Pos (Character_Value) = 127
              or else
                (Character'Pos (Character_Value) < 32
                 and then Character_Value /= Character'Val (9)))
      then
         raise Constraint_Error with "invalid HTTP field value";
      end if;
      if Item.Last = Item.Capacity
        or else Added > Item.Max_Bytes - Item.Used_Bytes
      then
         raise Headers_Too_Large;
      end if;
      Item.Last := Item.Last + 1;
      Item.Fields (Item.Last) :=
        (Name_Value => To_Unbounded_String (Name),
         Data_Value => To_Unbounded_String (Value));
      Item.Used_Bytes := Item.Used_Bytes + Added;
   end Add;

   procedure Clear (Item : in out List) is
   begin
      for Index in 1 .. Item.Last loop
         Item.Fields (Index) :=
           (Name_Value => Null_Unbounded_String,
            Data_Value => Null_Unbounded_String);
      end loop;
      Item.Last := 0;
      Item.Used_Bytes := 0;
   end Clear;

   function Count (Item : List) return Natural is (Item.Last);

   function Name (Item : List; Index : Positive) return String is
   begin
      if Index > Item.Last then
         raise Constraint_Error with "HTTP field index is out of range";
      end if;
      return To_String (Item.Fields (Index).Name_Value);
   end Name;

   function Value (Item : List; Index : Positive) return String is
   begin
      if Index > Item.Last then
         raise Constraint_Error with "HTTP field index is out of range";
      end if;
      return To_String (Item.Fields (Index).Data_Value);
   end Value;

   function Same_Name
     (Left : Unbounded_String; Right : String) return Boolean
   is
     (Ada.Characters.Handling.To_Lower (To_String (Left)) =
        Ada.Characters.Handling.To_Lower (Right));

   function Count (Item : List; Name : String) return Natural is
      Result : Natural := 0;
   begin
      for Index in 1 .. Item.Last loop
         if Same_Name (Item.Fields (Index).Name_Value, Name) then
            Result := Result + 1;
         end if;
      end loop;
      return Result;
   end Count;

   function Value
     (Item : List; Name : String; Occurrence : Positive := 1) return String
   is
      Seen : Natural := 0;
   begin
      for Index in 1 .. Item.Last loop
         if Same_Name (Item.Fields (Index).Name_Value, Name) then
            Seen := Seen + 1;
            if Seen = Occurrence then
               return To_String (Item.Fields (Index).Data_Value);
            end if;
         end if;
      end loop;
      return "";
   end Value;

end Flyology.HTTP.Headers;
