with Ada.Strings;
with Ada.Strings.Fixed;

package body Flyology.HTTP.Server.Responses is
   procedure Validate_Name (Name : String) is
   begin
      if Name = "" then
         raise Program_Error with "empty HTTP field or cookie name";
      end if;
      for Item of Name loop
         if Item not in 'a' .. 'z'
           and then Item not in 'A' .. 'Z'
           and then Item not in '0' .. '9'
           and then Item not in '!' | '#' | '$' | '%' | '&' | ''' | '*'
             | '+' | '-' | '.' | '^' | '_' | '`' | '|' | '~'
         then
            raise Program_Error with "invalid HTTP field or cookie name";
         end if;
      end loop;
   end Validate_Name;

   procedure Validate_Value (Value : String; Cookie : Boolean := False) is
   begin
      for Item of Value loop
         if Character'Pos (Item) < 32 or else Character'Pos (Item) = 127
           or else (Cookie and then Item in ';' | ',')
         then
            raise Program_Error with "invalid HTTP field or cookie value";
         end if;
      end loop;
   end Validate_Value;

   procedure Set_Cookie
     (X       : in out Applications.Exchange;
      Name    : String;
      Value   : String;
      Options : Cookie_Options := (others => <>))
   is
      Field : Unbounded_String := To_Unbounded_String (Name & "=" & Value);
   begin
      Validate_Name (Name);
      Validate_Value (Value, Cookie => True);
      if Options.SameSite = SameSite_None and then not Options.Secure then
         raise Program_Error with "SameSite=None cookie requires Secure";
      end if;
      if Length (Options.Path) > 0 then
         Validate_Value (To_String (Options.Path));
         Append (Field, "; Path=" & To_String (Options.Path));
      end if;
      if Length (Options.Domain) > 0 then
         Validate_Value (To_String (Options.Domain));
         Append (Field, "; Domain=" & To_String (Options.Domain));
      end if;
      if Options.Has_Max_Age then
         Append
           (Field, "; Max-Age=" & Ada.Strings.Fixed.Trim
              (Integer'Image (Options.Max_Age), Ada.Strings.Both));
      end if;
      if Length (Options.Expires) > 0 then
         Validate_Value (To_String (Options.Expires));
         Append (Field, "; Expires=" & To_String (Options.Expires));
      end if;
      if Options.Secure then
         Append (Field, "; Secure");
      end if;
      if Options.HTTP_Only then
         Append (Field, "; HttpOnly");
      end if;
      case Options.SameSite is
         when SameSite_Unspecified => null;
         when SameSite_Lax => Append (Field, "; SameSite=Lax");
         when SameSite_Strict => Append (Field, "; SameSite=Strict");
         when SameSite_None => Append (Field, "; SameSite=None");
      end case;
      X.Add_Header ("Set-Cookie", To_String (Field));
   end Set_Cookie;

   procedure Initialize
     (Item         : in out Builder;
      Status       : Positive;
      Content_Type : String := "")
   is
   begin
      Item.Status_Value := Status;
      Item.Content_Type_Value := To_Unbounded_String (Content_Type);
      Item.Header_Block := Null_Unbounded_String;
      Item.Payload_Value := Null_Unbounded_String;
   end Initialize;

   procedure Add_Header
     (Item  : in out Builder;
      Name  : String;
      Value : String)
   is
   begin
      Validate_Name (Name);
      Validate_Value (Value);
      Append
        (Item.Header_Block,
         Name & Character'Val (0) & Value & Character'Val (0));
   end Add_Header;

   procedure Set_Payload (Item : in out Builder; Value : String) is
   begin
      Item.Payload_Value := To_Unbounded_String (Value);
   end Set_Payload;

   procedure Send
     (Item  : Builder;
      X     : in out Applications.Exchange;
      Close : Boolean := False)
   is
      Block : constant String := To_String (Item.Header_Block);
      First : Natural := Block'First;
      Mark  : Natural;
   begin
      while First <= Block'Last loop
         Mark := Ada.Strings.Fixed.Index
           (Block (First .. Block'Last), String'(1 => Character'Val (0)));
         declare
            Name : constant String := Block (First .. Mark - 1);
            Value_First : constant Natural := Mark + 1;
            Value_End : constant Natural := Ada.Strings.Fixed.Index
              (Block (Value_First .. Block'Last),
               String'(1 => Character'Val (0)));
         begin
            X.Add_Header (Name, Block (Value_First .. Value_End - 1));
            First := Value_End + 1;
         end;
      end loop;
      X.Respond
        (Item.Status_Value,
         To_String (Item.Content_Type_Value),
         To_String (Item.Payload_Value), Close);
   end Send;

end Flyology.HTTP.Server.Responses;
