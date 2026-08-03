with Ada.Characters.Handling;
with Ada.Strings;
with Ada.Strings.Fixed;

package body Flyology.HTTP.Server.Requests is
   function Hex_Value (Value : Character) return Natural is
   begin
      if Value in '0' .. '9' then
         return Character'Pos (Value) - Character'Pos ('0');
      elsif Value in 'a' .. 'f' then
         return Character'Pos (Value) - Character'Pos ('a') + 10;
      elsif Value in 'A' .. 'F' then
         return Character'Pos (Value) - Character'Pos ('A') + 10;
      end if;
      raise Flyology.HTTP.Protocol_Error with "invalid percent escape";
   end Hex_Value;

   function Decode_Query (Value : String) return String is
      Result : Unbounded_String;
      Index  : Natural := Value'First;
   begin
      while Index <= Value'Last loop
         if Value (Index) = '%' then
            if Index > Value'Last - 2 then
               raise Flyology.HTTP.Protocol_Error with
                 "truncated query percent escape";
            end if;
            Append
              (Result,
               Character'Val
                 (16 * Hex_Value (Value (Index + 1))
                  + Hex_Value (Value (Index + 2))));
            Index := Index + 3;
         elsif Value (Index) = '+' then
            Append (Result, ' ');
            Index := Index + 1;
         else
            Append (Result, Value (Index));
            Index := Index + 1;
         end if;
      end loop;
      return To_String (Result);
   end Decode_Query;

   procedure Find_Query
     (X          : Applications.Exchange;
      Name       : String;
      Occurrence : Positive;
      Found      : out Boolean;
      Value      : out Unbounded_String)
   is
      Target : constant String := X.Request_Target;
      Mark   : constant Natural := Ada.Strings.Fixed.Index (Target, "?");
      First  : Natural;
      Last   : Natural;
      Seen   : Natural := 0;
   begin
      Found := False;
      Value := Null_Unbounded_String;
      if Mark = 0 or else Mark = Target'Last then
         return;
      end if;
      First := Mark + 1;
      while First <= Target'Last loop
         Last := Ada.Strings.Fixed.Index (Target (First .. Target'Last), "&");
         if Last = 0 then
            Last := Target'Last + 1;
         end if;
         declare
            Pair  : constant String := Target (First .. Last - 1);
            Equal : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
            Key   : constant String := Decode_Query
              (if Equal = 0 then Pair else Pair (Pair'First .. Equal - 1));
         begin
            if Key = Name then
               Seen := Seen + 1;
               if Seen = Occurrence then
                  Value := To_Unbounded_String
                    (if Equal = 0 then ""
                     else Decode_Query (Pair (Equal + 1 .. Pair'Last)));
                  Found := True;
                  return;
               end if;
            end if;
         end;
         First := Last + 1;
      end loop;
   end Find_Query;

   function Query
     (X          : Applications.Exchange;
      Name       : String;
      Occurrence : Positive := 1) return String
   is
      Found : Boolean;
      Value : Unbounded_String;
   begin
      Find_Query (X, Name, Occurrence, Found, Value);
      return (if Found then To_String (Value) else "");
   end Query;

   function Has_Query
     (X          : Applications.Exchange;
      Name       : String;
      Occurrence : Positive := 1) return Boolean
   is
      Found : Boolean;
      Value : Unbounded_String;
   begin
      Find_Query (X, Name, Occurrence, Found, Value);
      return Found;
   end Has_Query;

   function Cookie (X : Applications.Exchange; Name : String) return String is
      Field : constant String := X.Request_Header ("Cookie");
      First : Natural := Field'First;
      Last  : Natural;
      Count : Natural := 0;
   begin
      if Field'Length > 4_096 then
         raise Flyology.HTTP.Protocol_Error with "cookie field is too large";
      end if;
      while First <= Field'Last loop
         Last := Ada.Strings.Fixed.Index (Field (First .. Field'Last), ";");
         if Last = 0 then
            Last := Field'Last + 1;
         end if;
         Count := Count + 1;
         if Count > 64 then
            raise Flyology.HTTP.Protocol_Error with "too many cookies";
         end if;
         declare
            Pair  : constant String := Ada.Strings.Fixed.Trim
              (Field (First .. Last - 1), Ada.Strings.Both);
            Equal : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
         begin
            if Equal > 0
              and then Pair (Pair'First .. Equal - 1) = Name
            then
               return Pair (Equal + 1 .. Pair'Last);
            end if;
         end;
         First := Last + 1;
      end loop;
      return "";
   end Cookie;

   function Media_Type (X : Applications.Exchange) return String is
      Field : constant String := X.Request_Header ("Content-Type");
      Mark  : constant Natural := Ada.Strings.Fixed.Index (Field, ";");
   begin
      return Ada.Characters.Handling.To_Lower
        (Ada.Strings.Fixed.Trim
           ((if Mark = 0 then Field else Field (Field'First .. Mark - 1)),
            Ada.Strings.Both));
   end Media_Type;

   function Content_Type_Parameter
     (X    : Applications.Exchange;
      Name : String) return String
   is
      Field : constant String := X.Request_Header ("Content-Type");
      First : Natural := Ada.Strings.Fixed.Index (Field, ";");
   begin
      while First > 0 and then First < Field'Last loop
         First := First + 1;
         declare
            Last : Natural := Ada.Strings.Fixed.Index
              (Field (First .. Field'Last), ";");
         begin
            if Last = 0 then
               Last := Field'Last + 1;
            end if;
            declare
               Part : constant String := Ada.Strings.Fixed.Trim
                 (Field (First .. Last - 1), Ada.Strings.Both);
               Equal : constant Natural := Ada.Strings.Fixed.Index (Part, "=");
            begin
               if Equal > 0
                 and then Ada.Characters.Handling.To_Lower
                   (Ada.Strings.Fixed.Trim
                      (Part (Part'First .. Equal - 1), Ada.Strings.Both)) =
                   Ada.Characters.Handling.To_Lower (Name)
               then
                  declare
                     Raw : constant String := Ada.Strings.Fixed.Trim
                       (Part (Equal + 1 .. Part'Last), Ada.Strings.Both);
                  begin
                     if Raw'Length >= 2
                       and then Raw (Raw'First) = '"'
                       and then Raw (Raw'Last) = '"'
                     then
                        return Raw (Raw'First + 1 .. Raw'Last - 1);
                     end if;
                     return Raw;
                  end;
               end if;
            end;
            First := (if Last > Field'Last then 0 else Last);
         end;
      end loop;
      return "";
   end Content_Type_Parameter;

   function Authority (X : Applications.Exchange) return String is
      Host : constant String := X.Request_Header ("Host");
      Target : constant String := X.Request_Target;
      Scheme_End : Natural := 0;
   begin
      if Host /= "" then
         return Host;
      elsif Target'Length >= 7
        and then Ada.Characters.Handling.To_Lower
          (Target (Target'First .. Target'First + 6)) = "http://"
      then
         Scheme_End := Target'First + 6;
      elsif Target'Length >= 8
        and then Ada.Characters.Handling.To_Lower
          (Target (Target'First .. Target'First + 7)) = "https://"
      then
         Scheme_End := Target'First + 7;
      else
         return "";
      end if;
      declare
         First : constant Natural := Scheme_End + 1;
         Last  : Natural := Target'Last;
      begin
         for Index in First .. Target'Last loop
            if Target (Index) in '/' | '?' then
               Last := Index - 1;
               exit;
            end if;
         end loop;
         return (if Last < First then "" else Target (First .. Last));
      end;
   end Authority;

end Flyology.HTTP.Server.Requests;
