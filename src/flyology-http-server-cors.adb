with Ada.Characters.Handling;
with Ada.Strings;
with Ada.Strings.Fixed;

package body Flyology.HTTP.Server.CORS is
   procedure Validate_Value (Value : String) is
   begin
      for Item of Value loop
         if Character'Pos (Item) < 32 or else Character'Pos (Item) = 127 then
            raise Program_Error with "invalid CORS policy value";
         end if;
      end loop;
   end Validate_Value;

   function Create
     (Allowed_Origins   : String;
      Allowed_Methods   : String;
      Allowed_Headers   : String := "";
      Exposed_Headers   : String := "";
      Allow_Credentials : Boolean := False;
      Max_Age           : Duration := -1.0) return Policy
   is
   begin
      if Allowed_Origins = "" or else Allowed_Methods = "" then
         raise Program_Error with "CORS origins and methods are required";
      elsif Allowed_Origins = "*" and then Allow_Credentials then
         raise Program_Error with
           "CORS wildcard origin cannot allow credentials";
      end if;
      Validate_Value (Allowed_Origins);
      Validate_Value (Allowed_Methods);
      Validate_Value (Allowed_Headers);
      Validate_Value (Exposed_Headers);
      return
        (To_Unbounded_String (Allowed_Origins),
         To_Unbounded_String (Allowed_Methods),
         To_Unbounded_String (Allowed_Headers),
         To_Unbounded_String (Exposed_Headers),
         Allow_Credentials,
         Max_Age);
   end Create;

   function Exact_Word (List, Word : String) return Boolean is
      First : Positive := List'First;
      Last  : Natural;
   begin
      if List = "" then
         return False;
      end if;
      loop
         Last := Ada.Strings.Fixed.Index (List (First .. List'Last), " ");
         if Last = 0 then
            return List (First .. List'Last) = Word;
         elsif List (First .. Last - 1) = Word then
            return True;
         end if;
         First := Last + 1;
         while First <= List'Last and then List (First) = ' ' loop
            First := First + 1;
         end loop;
         exit when First > List'Last;
      end loop;
      return False;
   end Exact_Word;

   function Origin_Allowed (Item : Policy; Origin : String) return Boolean is
      Values : constant String := To_String (Item.Origins_Value);
   begin
      return Values = "*" or else Exact_Word (Values, Origin);
   end Origin_Allowed;

   function List_Has
     (List, Value : String;
      Case_Sensitive : Boolean) return Boolean
   is
      First : Positive := List'First;
      Last  : Natural;
   begin
      if List = "" or else Value = "" then
         return False;
      end if;
      loop
         Last := Ada.Strings.Fixed.Index (List (First .. List'Last), ",");
         declare
            Finish : constant Natural :=
              (if Last = 0 then List'Last else Last - 1);
            Candidate : constant String := Ada.Strings.Fixed.Trim
              (List (First .. Finish), Ada.Strings.Both);
         begin
            if (Case_Sensitive and then Candidate = Value)
              or else
                (not Case_Sensitive
                 and then Ada.Characters.Handling.To_Lower (Candidate) =
                   Ada.Characters.Handling.To_Lower (Value))
            then
               return True;
            end if;
         end;
         exit when Last = 0;
         First := Last + 1;
      end loop;
      return False;
   end List_Has;

   function Method_Allowed (Item : Policy; Method : String) return Boolean is
     (List_Has (To_String (Item.Methods_Value), Method, True));

   function Headers_Allowed (Item : Policy; Headers : String) return Boolean is
      First : Positive := Headers'First;
      Last  : Natural;
   begin
      if Headers = "" then
         return True;
      end if;
      loop
         Last := Ada.Strings.Fixed.Index
           (Headers (First .. Headers'Last), ",");
         declare
            Finish : constant Natural :=
              (if Last = 0 then Headers'Last else Last - 1);
            Candidate : constant String := Ada.Strings.Fixed.Trim
              (Headers (First .. Finish), Ada.Strings.Both);
         begin
            if not List_Has
              (To_String (Item.Headers_Value), Candidate, False)
            then
               return False;
            end if;
         end;
         exit when Last = 0;
         First := Last + 1;
      end loop;
      return True;
   end Headers_Allowed;

   function Methods (Item : Policy) return String is
     (To_String (Item.Methods_Value));

   function Headers (Item : Policy) return String is
     (To_String (Item.Headers_Value));

   function Exposed (Item : Policy) return String is
     (To_String (Item.Exposed_Value));

   function Credentials (Item : Policy) return Boolean is
     (Item.Credentials_Value);

   function Wildcard (Item : Policy) return Boolean is
     (To_String (Item.Origins_Value) = "*");

   function Preflight_Max_Age (Item : Policy) return Duration is
     (Item.Max_Age_Value);

end Flyology.HTTP.Server.CORS;
