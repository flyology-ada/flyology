with Ada.Characters.Handling;
with Ada.Strings.Fixed;

package body Flyology.HTTP is
   use Ada.Strings.Unbounded;

   function Is_Token_Character (Value : Character) return Boolean is
     (Value in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
        | '!' | '#' | '$' | '%' | '&' | ''' | '*' | '+' | '-' | '.'
        | '^' | '_' | '`' | '|' | '~');

   function To_Method (Value : String) return Method is
   begin
      if Value'Length not in 1 .. 64
        or else (for some Item of Value => not Is_Token_Character (Item))
      then
         raise Constraint_Error with "invalid HTTP method";
      end if;
      return (Value => To_Unbounded_String (Value));
   end To_Method;

   function Image (Value : Method) return String is
     (To_String (Value.Value));

   function Is_Safe (Value : Method) return Boolean is
      Text : constant String := Image (Value);
   begin
      return Text in "GET" | "HEAD" | "OPTIONS" | "TRACE";
   end Is_Safe;

   function Is_Idempotent (Value : Method) return Boolean is
      Text : constant String := Image (Value);
   begin
      return Is_Safe (Value) or else Text in "PUT" | "DELETE";
   end Is_Idempotent;

   function Decimal_Port (Value : String) return Port_Number is
      Result : Natural := 0;
   begin
      if Value = "" then
         raise Constraint_Error with "empty HTTP origin port";
      end if;
      for Item of Value loop
         if Item not in '0' .. '9'
           or else Result > (Natural (Port_Number'Last) -
                             (Character'Pos (Item) - Character'Pos ('0'))) / 10
         then
            raise Constraint_Error with "invalid HTTP origin port";
         end if;
         Result := Result * 10 + Character'Pos (Item) - Character'Pos ('0');
      end loop;
      if Result = 0 then
         raise Constraint_Error with "HTTP origin port is zero";
      end if;
      return Port_Number (Result);
   end Decimal_Port;

   function Parse_Origin (Value : String) return Origin is
      use Ada.Characters.Handling;
      use Ada.Strings.Fixed;
      Side       : Origin_Scheme;
      Default    : Port_Number;
      First      : Positive;
      Last       : Natural := Value'Last;
      Host_First : Positive;
      Host_Last  : Natural;
      Port_First : Natural := 0;
   begin
      if Value'Length >= 7
        and then To_Lower (Value (Value'First .. Value'First + 6)) = "http://"
      then
         Side := Plain_HTTP;
         Default := 80;
         First := Value'First + 7;
      elsif Value'Length >= 8
        and then To_Lower (Value (Value'First .. Value'First + 7)) = "https://"
      then
         Side := Secure_HTTPS;
         Default := 443;
         First := Value'First + 8;
      else
         raise Constraint_Error with
           "HTTP origin requires http:// or https://";
      end if;

      if First > Last then
         raise Constraint_Error with "HTTP origin has no host";
      end if;
      if Value (Last) = '/' then
         Last := Last - 1;
      end if;
      if First > Last
        or else Index (Value (First .. Last), "/") /= 0
        or else Index (Value (First .. Last), "?") /= 0
        or else Index (Value (First .. Last), "#") /= 0
        or else Index (Value (First .. Last), "@") /= 0
      then
         raise Constraint_Error with
           "HTTP origin contains non-origin components";
      end if;

      if Value (First) = '[' then
         declare
            Closing : constant Natural := Index (Value (First .. Last), "]");
         begin
            if Closing = 0 or else Closing = First + 1 then
               raise Constraint_Error with
                 "invalid bracketed HTTP origin host";
            end if;
            Host_First := First + 1;
            Host_Last := Closing - 1;
            if Index (Value (Host_First .. Host_Last), ":") = 0 then
               raise Constraint_Error with
                 "bracketed HTTP origin host is not IPv6";
            end if;
            if Closing < Last then
               if Value (Closing + 1) /= ':' then
                  raise Constraint_Error with
                    "invalid text after IPv6 origin host";
               end if;
               Port_First := Closing + 2;
            end if;
         end;
      else
         declare
            Colon : constant Natural := Index
              (Value (First .. Last), ":", Going => Ada.Strings.Backward);
         begin
            Host_First := First;
            if Colon = 0 then
               Host_Last := Last;
            else
               Host_Last := Colon - 1;
               Port_First := Colon + 1;
               if Index (Value (Host_First .. Host_Last), ":") /= 0 then
                  raise Constraint_Error with
                    "IPv6 HTTP origin hosts require brackets";
               end if;
            end if;
         end;
      end if;

      if Host_Last < Host_First
        or else Host_Last - Host_First + 1 > 253
        or else (for some Item of Value (Host_First .. Host_Last) =>
                   Character'Pos (Item) < 33
                     or else Character'Pos (Item) > 126
                     or else Item in '[' | ']'
                     or else Item = Character'Val (16#5C#))
      then
         raise Constraint_Error with "invalid HTTP origin host";
      end if;

      return
        (Scheme_Value => Side,
         Host_Value   => To_Unbounded_String
           (To_Lower (Value (Host_First .. Host_Last))),
         Port_Value   =>
           (if Port_First = 0 then Default
            else Decimal_Port (Value (Port_First .. Last))));
   end Parse_Origin;

   function Scheme (Value : Origin) return Origin_Scheme is
     (Value.Scheme_Value);

   function Host (Value : Origin) return String is
     (To_String (Value.Host_Value));

   function Port (Value : Origin) return Port_Number is
     (Value.Port_Value);

   function Image (Value : Origin) return String is
      Prefix : constant String :=
        (if Value.Scheme_Value = Plain_HTTP then "http://" else "https://");
      Name : constant String := Host (Value);
      Bracketed : constant String :=
        (if Ada.Strings.Fixed.Index (Name, ":") = 0
         then Name else "[" & Name & "]");
      Default : constant Boolean :=
        (Value.Scheme_Value = Plain_HTTP and then Value.Port_Value = 80)
        or else
        (Value.Scheme_Value = Secure_HTTPS and then Value.Port_Value = 443);
      Port_Text : constant String := Port_Number'Image (Value.Port_Value);
   begin
      return Prefix & Bracketed &
        (if Default then ""
         else ":" & Port_Text (Port_Text'First + 1 .. Port_Text'Last));
   end Image;

   function Image (Value : Protocol) return String is
     (if Value = HTTP_1_1_Protocol then "HTTP/1.1" else "HTTP/unknown");

end Flyology.HTTP;
