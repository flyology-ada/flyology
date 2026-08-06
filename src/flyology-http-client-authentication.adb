with Ada.Characters.Handling;
with Flyology.HTTP.Headers;

package body Flyology.HTTP.Client.Authentication is

   function Base64 (Value : String) return String is
      Alphabet : constant String :=
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      Result : String (1 .. 4 * ((Value'Length + 2) / 3));
      Input  : Natural := Value'First;
      Output : Natural := Result'First;
   begin
      while Input <= Value'Last loop
         declare
            Remaining : constant Natural := Value'Last - Input + 1;
            A : constant Natural := Character'Pos (Value (Input));
            B : constant Natural :=
              (if Remaining >= 2
               then Character'Pos (Value (Input + 1)) else 0);
            C : constant Natural :=
              (if Remaining >= 3
               then Character'Pos (Value (Input + 2)) else 0);
         begin
            Result (Output) := Alphabet (A / 4 + 1);
            Result (Output + 1) :=
              Alphabet ((A mod 4) * 16 + B / 16 + 1);
            Result (Output + 2) :=
              (if Remaining >= 2
               then Alphabet ((B mod 16) * 4 + C / 64 + 1) else '=');
            Result (Output + 3) :=
              (if Remaining >= 3 then Alphabet (C mod 64 + 1) else '=');
            Input := Input + 3;
            Output := Output + 4;
         end;
      end loop;
      return Result;
   end Base64;

   procedure Replace (Item : in out Request; Value : String) is
      Filtered : Flyology.HTTP.Headers.List
        (Capacity  => Item.Fields.Capacity,
         Max_Bytes => Item.Fields.Max_Bytes);
   begin
      for Index in 1 .. Flyology.HTTP.Headers.Count (Item.Fields) loop
         declare
            Name : constant String :=
              Flyology.HTTP.Headers.Name (Item.Fields, Index);
         begin
            if Ada.Characters.Handling.To_Lower (Name) /= "authorization" then
               Flyology.HTTP.Headers.Add
                 (Filtered, Name,
                  Flyology.HTTP.Headers.Value (Item.Fields, Index));
            end if;
         end;
      end loop;
      if Value'Length > 0 then
         Flyology.HTTP.Headers.Add (Filtered, "Authorization", Value);
      end if;
      Item.Fields := Filtered;
   end Replace;

   procedure Clear (Item : in out Request) is
   begin
      Replace (Item, "");
   end Clear;

   procedure Set_Bearer (Item : in out Request; Token : String) is
      Padding : Boolean := False;
   begin
      if Token'Length = 0 then
         raise Constraint_Error with "empty Bearer token";
      elsif Token'Length > Item.Fields.Max_Bytes then
         raise Flyology.HTTP.Headers.Headers_Too_Large;
      end if;
      for Value of Token loop
         if Value = '=' then
            Padding := True;
         elsif Padding
           or else not
             (Value in 'a' .. 'z'
                or else Value in 'A' .. 'Z'
                or else Value in '0' .. '9'
                or else Value in '-' | '.' | '_' | '~' | '+' | '/')
         then
            raise Constraint_Error with "invalid Bearer token";
         end if;
      end loop;
      Replace (Item, "Bearer " & Token);
   end Set_Bearer;

   procedure Set_Basic
     (Item : in out Request; User_Id : String; Password : String) is
   begin
      if (for some Value of User_Id =>
            Value = ':' or else Character'Pos (Value) < 32
              or else Character'Pos (Value) = 127)
        or else
          (for some Value of Password =>
             Character'Pos (Value) < 32
               or else Character'Pos (Value) = 127)
      then
         raise Constraint_Error with "invalid Basic credentials";
      elsif User_Id'Length >= Item.Fields.Max_Bytes
        or else Password'Length >
          Item.Fields.Max_Bytes - User_Id'Length - 1
      then
         raise Flyology.HTTP.Headers.Headers_Too_Large;
      end if;
      Replace (Item, "Basic " & Base64 (User_Id & ":" & Password));
   end Set_Basic;

end Flyology.HTTP.Client.Authentication;
