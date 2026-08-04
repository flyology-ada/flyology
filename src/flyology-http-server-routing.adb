with Ada.Real_Time;
with Ada.Strings.Fixed;
with Flyology.IO;
with Flyology.IO.TLS;

package body Flyology.HTTP.Server.Routing is
   use type Ada.Real_Time.Time;

   package App renames Flyology.HTTP.Server.Applications;
   use type App.Authentication_Mode;
   use type App.Response_State;
   use type App.Upgrade_Mode;

   Max_Segments : constant := 64;

   type Segment_Array is
     array (Positive range 1 .. Max_Segments) of Unbounded_String;
   type Segment_List is record
      Values   : Segment_Array;
      Count    : Natural := 0;
      Trailing : Boolean := False;
   end record;

   function Hex_Value (Value : Character) return Natural is
     (if Value in '0' .. '9' then Character'Pos (Value) - Character'Pos ('0')
      elsif Value in 'a' .. 'f'
      then Character'Pos (Value) - Character'Pos ('a') + 10
      elsif Value in 'A' .. 'F'
      then Character'Pos (Value) - Character'Pos ('A') + 10
      else raise Route_Error with "invalid percent escape in HTTP path");

   function Valid_UTF8 (Value : String) return Boolean is
      Index : Natural := Value'First;

      function Byte (Offset : Natural) return Natural is
        (Character'Pos (Value (Index + Offset)));
      function Continuation (Offset : Natural) return Boolean is
        (Index + Offset <= Value'Last
         and then Byte (Offset) in 16#80# .. 16#BF#);
   begin
      while Index <= Value'Last loop
         if Byte (0) <= 16#7F# then
            Index := Index + 1;
         elsif Byte (0) in 16#C2# .. 16#DF# and then Continuation (1) then
            Index := Index + 2;
         elsif Byte (0) = 16#E0#
           and then Index + 2 <= Value'Last
           and then Byte (1) in 16#A0# .. 16#BF#
           and then Continuation (2)
         then
            Index := Index + 3;
         elsif Byte (0) in 16#E1# .. 16#EC# | 16#EE# .. 16#EF#
           and then Continuation (1) and then Continuation (2)
         then
            Index := Index + 3;
         elsif Byte (0) = 16#ED#
           and then Index + 2 <= Value'Last
           and then Byte (1) in 16#80# .. 16#9F#
           and then Continuation (2)
         then
            Index := Index + 3;
         elsif Byte (0) = 16#F0#
           and then Index + 3 <= Value'Last
           and then Byte (1) in 16#90# .. 16#BF#
           and then Continuation (2) and then Continuation (3)
         then
            Index := Index + 4;
         elsif Byte (0) in 16#F1# .. 16#F3#
           and then Continuation (1)
           and then Continuation (2)
           and then Continuation (3)
         then
            Index := Index + 4;
         elsif Byte (0) = 16#F4#
           and then Index + 3 <= Value'Last
           and then Byte (1) in 16#80# .. 16#8F#
           and then Continuation (2) and then Continuation (3)
         then
            Index := Index + 4;
         else
            return False;
         end if;
      end loop;
      return True;
   end Valid_UTF8;

   function Raw_Path (Target : String) return String is
      Query : Natural := Ada.Strings.Fixed.Index (Target, "?");
      Start : Natural := Target'First;
      Scheme : constant Natural := Ada.Strings.Fixed.Index (Target, "://");
   begin
      if Target = "*" then
         return "*";
      elsif Scheme /= 0 then
         Start := 0;
         for Index in Scheme + 3 .. Target'Last loop
            if Target (Index) = '/' then
               Start := Index;
               exit;
            elsif Target (Index) = '?' then
               return "/";
            end if;
         end loop;
         if Start = 0 then
            return "/";
         end if;
         Query := Ada.Strings.Fixed.Index (Target (Start .. Target'Last), "?");
      end if;
      return
        (if Query = 0 then Target (Start .. Target'Last)
         elsif Query = Start then "/"
         else Target (Start .. Query - 1));
   end Raw_Path;

   function Raw_Query_Suffix (Target : String) return String is
      Query : constant Natural := Ada.Strings.Fixed.Index (Target, "?");
   begin
      return
        (if Query = 0 then "" else Target (Query .. Target'Last));
   end Raw_Query_Suffix;

   function Decode_Path (Value : String) return String is
      Result : Unbounded_String;
      Index  : Natural := Value'First;
      Byte   : Natural;
      Item   : Character;
      Escaped : Boolean;
   begin
      if Value = "*" then
         return Value;
      elsif Value'Length = 0 or else Value (Value'First) /= '/' then
         raise Route_Error with "routed HTTP path is not origin-form";
      end if;
      while Index <= Value'Last loop
         Escaped := Value (Index) = '%';
         if Value (Index) = '%' then
            if Index + 2 > Value'Last then
               raise Route_Error with "truncated percent escape in HTTP path";
            end if;
            Byte := Hex_Value (Value (Index + 1)) * 16
              + Hex_Value (Value (Index + 2));
            Item := Character'Val (Byte);
            Index := Index + 3;
         else
            Item := Value (Index);
            Index := Index + 1;
         end if;
         if Item = Character'Val (0)
           or else Item = Character'Val (92)
           or else Character'Pos (Item) < 32
           or else Character'Pos (Item) = 127
         then
            raise Route_Error with "unsafe decoded byte in HTTP path";
         elsif Item = '/' and then Escaped
         then
            raise Route_Error with "encoded path separator is ambiguous";
         end if;
         Append (Result, Item);
      end loop;
      declare
         Decoded : constant String := To_String (Result);
      begin
         if Ada.Strings.Fixed.Index (Decoded, "//") /= 0 then
            raise Route_Error with "empty HTTP path segment is ambiguous";
         elsif not Valid_UTF8 (Decoded) then
            raise Route_Error with "HTTP path is not valid UTF-8";
         end if;
         return Decoded;
      end;
   end Decode_Path;

   procedure Split_Path (Value : String; Result : out Segment_List) is
      First : Natural := Value'First + 1;
      Slash : Natural;
   begin
      Result := (Values => (others => Null_Unbounded_String),
                 Count => 0, Trailing => False);
      if Value = "*" then
         Result.Count := 1;
         Result.Values (1) := To_Unbounded_String ("*");
         return;
      elsif Value = "/" then
         return;
      end if;
      Result.Trailing := Value (Value'Last) = '/';
      while First <= Value'Last loop
         Slash := Ada.Strings.Fixed.Index (Value (First .. Value'Last), "/");
         if Slash = First then
            if Slash = Value'Last then
               exit;
            end if;
            raise Route_Error with "empty HTTP path segment";
         end if;
         if Result.Count = Max_Segments then
            raise Route_Error with "too many HTTP path segments";
         end if;
         Result.Count := Result.Count + 1;
         Result.Values (Result.Count) := To_Unbounded_String
           (if Slash = 0 then Value (First .. Value'Last)
            else Value (First .. Slash - 1));
         exit when Slash = 0 or else Slash = Value'Last;
         First := Slash + 1;
      end loop;
   end Split_Path;

   function Parameter_Name (Value : String) return String is
     (if Value'Length >= 3
        and then Value (Value'First) = '{'
        and then Value (Value'Last) = '}'
      then Value (Value'First + 1 .. Value'Last - 1) else "");

   function Is_Remainder (Value : String) return Boolean is
     (Value'Length >= 4
      and then Value (Value'First .. Value'First + 1) = "{*"
      and then Value (Value'Last) = '}');

   function Remainder_Name (Value : String) return String is
     (if Is_Remainder (Value)
      then Value (Value'First + 2 .. Value'Last - 1) else "");

   function Valid_Parameter_Name (Value : String) return Boolean is
   begin
      if Value'Length = 0 then
         return False;
      end if;
      for Item of Value loop
         if Item not in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-'
         then
            return False;
         end if;
      end loop;
      return True;
   end Valid_Parameter_Name;

   procedure Validate_Method (Value : String) is
   begin
      if Value'Length = 0 then
         raise Route_Error with "empty HTTP route method";
      end if;
      for Item of Value loop
         if Item not in 'A' .. 'Z' | '0' .. '9' | '-' then
            raise Route_Error with "HTTP route method must be uppercase";
         end if;
      end loop;
   end Validate_Method;

   procedure Validate_Pattern
     (Pattern : String;
      Static_Only : Boolean := False)
   is
      Segments : Segment_List;
      Names    : Segment_Array := (others => Null_Unbounded_String);
      Count    : Natural := 0;
   begin
      if Pattern'Length = 0 or else Pattern (Pattern'First) /= '/'
        or else Ada.Strings.Fixed.Index (Pattern, "?") /= 0
        or else Ada.Strings.Fixed.Index (Pattern, "#") /= 0
        or else Ada.Strings.Fixed.Index (Pattern, "%") /= 0
        or else Ada.Strings.Fixed.Index
          (Pattern, String'(1 => Character'Val (92))) /= 0
      then
         raise Route_Error with "invalid HTTP route pattern";
      end if;
      Split_Path (Pattern, Segments);
      for Index in 1 .. Segments.Count loop
         declare
            Segment : constant String := To_String (Segments.Values (Index));
            Name    : constant String :=
              (if Is_Remainder (Segment) then Remainder_Name (Segment)
               else Parameter_Name (Segment));
         begin
            if Ada.Strings.Fixed.Index (Segment, "{") /= 0
              or else Ada.Strings.Fixed.Index (Segment, "}") /= 0
            then
               if Static_Only or else not Valid_Parameter_Name (Name) then
                  raise Route_Error with "invalid HTTP route parameter";
               elsif Is_Remainder (Segment) and then Index /= Segments.Count
               then
                  raise Route_Error with
                    "HTTP route remainder must be the final segment";
               end if;
               for Prior in 1 .. Count loop
                  if To_String (Names (Prior)) = Name then
                     raise Route_Error with "duplicate HTTP route parameter";
                  end if;
               end loop;
               Count := Count + 1;
               Names (Count) := To_Unbounded_String (Name);
            end if;
         end;
      end loop;
   end Validate_Pattern;

   function Specificity (Pattern : String) return Natural is
      Segments : Segment_List;
      Result   : Natural := 0;
   begin
      Split_Path (Pattern, Segments);
      for Index in 1 .. Segments.Count loop
         declare
            Segment : constant String := To_String (Segments.Values (Index));
         begin
            Result := Result
              + (if Is_Remainder (Segment) then 1
                 elsif Parameter_Name (Segment) /= "" then 10 else 100);
         end;
      end loop;
      return Result;
   end Specificity;

   function Compatible (Left, Right : String) return Boolean is
     (Parameter_Name (Left) /= "" or else Is_Remainder (Left)
      or else Parameter_Name (Right) /= "" or else Is_Remainder (Right)
      or else Left = Right);

   function Patterns_Overlap (Left, Right : String) return Boolean is
      L, R : Segment_List;
      Common : Natural;
   begin
      Split_Path (Left, L);
      Split_Path (Right, R);
      Common := Natural'Min (L.Count, R.Count);
      for Index in 1 .. Common loop
         exit when Is_Remainder (To_String (L.Values (Index)))
           or else Is_Remainder (To_String (R.Values (Index)));
         if not Compatible
           (To_String (L.Values (Index)), To_String (R.Values (Index)))
         then
            return False;
         end if;
      end loop;
      return L.Count = R.Count
        or else
          (L.Count > 0
           and then Is_Remainder (To_String (L.Values (L.Count))))
        or else
          (R.Count > 0
           and then Is_Remainder (To_String (R.Values (R.Count))));
   end Patterns_Overlap;

   procedure Check_Add
     (Item : Router; Method, Pattern : String)
   is
   begin
      Validate_Method (Method);
      Validate_Pattern (Pattern);
      if Item.Count = Item.Capacity then
         raise Route_Error with "HTTP router capacity exhausted";
      end if;
      for Index in 1 .. Item.Count loop
         if To_String (Item.Routes (Index).Method) = Method
           and then Patterns_Overlap
             (To_String (Item.Routes (Index).Pattern), Pattern)
           and then Specificity (To_String (Item.Routes (Index).Pattern)) =
             Specificity (Pattern)
         then
            raise Route_Error with "ambiguous HTTP route registration";
         end if;
      end loop;
   end Check_Add;

   function Route_Count (Item : Router) return Natural is (Item.Count);

   function Describe_Route
     (Item  : Router;
      Index : Positive) return Route_Description
   is
   begin
      if Index > Item.Count then
         raise Constraint_Error with "HTTP route introspection index invalid";
      end if;
      return
        (Method           => Item.Routes (Index).Method,
         Pattern          => Item.Routes (Index).Pattern,
         Name             => Item.Routes (Index).Name,
         Policy           => Item.Routes (Index).Policy,
         Middleware_Count => Item.Routes (Index).Middleware_Count);
   end Describe_Route;

   function Global_Middleware_Count (Item : Router) return Natural is
     (Item.Middleware_Count);

   function Describe_Global_Middleware
     (Item  : Router;
      Index : Positive) return Middleware_Description
   is
   begin
      if Index > Item.Middleware_Count then
         raise Constraint_Error with
           "HTTP global middleware introspection index invalid";
      end if;
      return
        (Name  => Item.Middleware (Index).Name,
         Stage => Item.Middleware (Index).Stage);
   end Describe_Global_Middleware;

   function Route_Middleware_Count
     (Item        : Router;
      Route_Index : Positive) return Natural
   is
   begin
      if Route_Index > Item.Count then
         raise Constraint_Error with "HTTP route introspection index invalid";
      end if;
      return Item.Routes (Route_Index).Middleware_Count;
   end Route_Middleware_Count;

   function Describe_Route_Middleware
     (Item             : Router;
      Route_Index      : Positive;
      Middleware_Index : Positive) return Middleware_Description
   is
   begin
      if Route_Index > Item.Count then
         raise Constraint_Error with "HTTP route introspection index invalid";
      elsif Middleware_Index >
        Item.Routes (Route_Index).Middleware_Count
      then
         raise Constraint_Error with
           "HTTP route middleware introspection index invalid";
      end if;
      return
        (Name  => Item.Routes (Route_Index).Middleware
                    (Middleware_Index).Name,
         Stage => Item.Routes (Route_Index).Middleware
                    (Middleware_Index).Stage);
   end Describe_Route_Middleware;

   procedure Add
     (Item    : in out Router;
      Method  : String;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy)
   is
      Effective_Name : constant String :=
        (if Name = "" then Method & " " & Pattern else Name);
   begin
      Check_Add (Item, Method, Pattern);
      if Policy.Max_Body > Max_Request_Body then
         raise Route_Error with "route body limit exceeds server maximum";
      end if;
      for Index in 1 .. Item.Count loop
         if To_String (Item.Routes (Index).Name) = Effective_Name then
            raise Route_Error with "duplicate HTTP route name";
         end if;
      end loop;
      Item.Count := Item.Count + 1;
      Item.Routes (Item.Count) :=
        (Method  => To_Unbounded_String (Method),
         Pattern => To_Unbounded_String (Pattern),
         Name    => To_Unbounded_String (Effective_Name),
         Handler => Handler,
         Policy  => Policy,
         Middleware =>
           (others =>
              (Component => null,
               Stage     => Request_Head,
               Name      => Null_Unbounded_String)),
         Middleware_Count => 0);
   end Add;

   procedure Add_Middleware
     (Item      : in out Router;
      Component : not null Middleware_Access;
      Stage     : Middleware_Stage := Request_Head;
      Name      : String := "")
   is
   begin
      if Item.Middleware_Count = Max_Global_Middleware then
         raise Route_Error with "global HTTP middleware capacity exhausted";
      end if;
      Item.Middleware_Count := Item.Middleware_Count + 1;
      Item.Middleware (Item.Middleware_Count) :=
        (Component => Component,
         Stage     => Stage,
         Name      => To_Unbounded_String (Name));
   end Add_Middleware;

   procedure Add_Route_Middleware
     (Item      : in out Router;
      Name      : String;
      Component : not null Middleware_Access;
      Stage     : Middleware_Stage := Request_Head;
      Middleware_Name : String := "")
   is
   begin
      for Index in 1 .. Item.Count loop
         if To_String (Item.Routes (Index).Name) = Name then
            if Item.Routes (Index).Middleware_Count = Max_Route_Middleware
            then
               raise Route_Error with
                 "route HTTP middleware capacity exhausted";
            end if;
            Item.Routes (Index).Middleware_Count :=
              Item.Routes (Index).Middleware_Count + 1;
            Item.Routes (Index).Middleware
              (Item.Routes (Index).Middleware_Count) :=
                (Component => Component,
                 Stage     => Stage,
                 Name      => To_Unbounded_String (Middleware_Name));
            return;
         end if;
      end loop;
      raise Route_Error with "unknown HTTP route name";
   end Add_Route_Middleware;

   procedure Get
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "GET", Pattern, Handler, Name, Policy);
   end Get;

   procedure Head
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "HEAD", Pattern, Handler, Name, Policy);
   end Head;

   procedure Post
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "POST", Pattern, Handler, Name, Policy);
   end Post;

   procedure Put
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "PUT", Pattern, Handler, Name, Policy);
   end Put;

   procedure Patch
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "PATCH", Pattern, Handler, Name, Policy);
   end Patch;

   procedure Delete
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "DELETE", Pattern, Handler, Name, Policy);
   end Delete;

   procedure Options
     (Item : in out Router; Pattern : String;
      Handler : not null Handler_Access; Name : String := "";
      Policy : Route_Policy := Default_Route_Policy) is
   begin
      Add (Item, "OPTIONS", Pattern, Handler, Name, Policy);
   end Options;

   function Join_Pattern (Prefix, Pattern : String) return String is
   begin
      if Prefix = "/" then
         return Pattern;
      elsif Pattern = "/" then
         return Prefix;
      elsif Prefix (Prefix'Last) = '/' then
         return Prefix (Prefix'First .. Prefix'Last - 1) & Pattern;
      else
         return Prefix & Pattern;
      end if;
   end Join_Pattern;

   procedure Mount
     (Item        : in out Router;
      Prefix      : String;
      Source      : Router;
      Name_Prefix : String := "")
   is
   begin
      Validate_Pattern (Prefix, Static_Only => True);
      if Source.Count > Item.Capacity - Item.Count then
         raise Route_Error with "HTTP router capacity exhausted by mount";
      end if;
      for Index in 1 .. Source.Count loop
         declare
            Mounted_Route : Route_Entry renames Source.Routes (Index);
            New_Index     : Positive;
         begin
            if Source.Middleware_Count + Mounted_Route.Middleware_Count >
              Max_Route_Middleware
            then
               raise Route_Error with
                 "mounted HTTP middleware capacity exhausted";
            end if;
            Add
              (Item,
               To_String (Mounted_Route.Method),
               Join_Pattern (Prefix, To_String (Mounted_Route.Pattern)),
               Mounted_Route.Handler,
               (if Name_Prefix = "" then To_String (Mounted_Route.Name)
               else Name_Prefix & To_String (Mounted_Route.Name)),
               Mounted_Route.Policy);
            New_Index := Item.Count;
            for Middleware_Index in 1 .. Source.Middleware_Count loop
               Item.Routes (New_Index).Middleware_Count :=
                 Item.Routes (New_Index).Middleware_Count + 1;
               Item.Routes (New_Index).Middleware
                 (Item.Routes (New_Index).Middleware_Count) :=
                   Source.Middleware (Middleware_Index);
            end loop;
            for Middleware_Index in 1 .. Mounted_Route.Middleware_Count loop
               Item.Routes (New_Index).Middleware_Count :=
                 Item.Routes (New_Index).Middleware_Count + 1;
               Item.Routes (New_Index).Middleware
                 (Item.Routes (New_Index).Middleware_Count) :=
                   Mounted_Route.Middleware (Middleware_Index);
            end loop;
         end;
      end loop;
   end Mount;

   function Match_Path
     (Pattern, Path : String;
      Ignore_Trailing : Boolean;
      Capture : Boolean;
      X : access App.Exchange := null) return Boolean
   is
      P, V : Segment_List;
      Last_Is_Remainder : Boolean;
      Normal_Count : Natural;
   begin
      Split_Path (Pattern, P);
      Split_Path (Path, V);
      Last_Is_Remainder := P.Count > 0
        and then Is_Remainder (To_String (P.Values (P.Count)));
      Normal_Count := (if Last_Is_Remainder then P.Count - 1 else P.Count);
      if V.Count < Normal_Count
        or else (not Last_Is_Remainder and then V.Count /= P.Count)
        or else (not Ignore_Trailing and then not Last_Is_Remainder
                 and then P.Trailing /= V.Trailing)
      then
         return False;
      end if;
      for Index in 1 .. Normal_Count loop
         declare
            Pattern_Segment : constant String := To_String (P.Values (Index));
            Value_Segment   : constant String := To_String (V.Values (Index));
            Name : constant String := Parameter_Name (Pattern_Segment);
         begin
            if Name = "" then
               if Pattern_Segment /= Value_Segment then
                  return False;
               end if;
            elsif Capture then
               App.Add_Parameter (X.all, Name, Value_Segment);
            end if;
         end;
      end loop;
      if Last_Is_Remainder and then Capture then
         declare
            Remainder : Unbounded_String;
         begin
            for Index in P.Count .. V.Count loop
               if Index > P.Count then
                  Append (Remainder, "/");
               end if;
               Append (Remainder, To_String (V.Values (Index)));
            end loop;
            if V.Trailing and then V.Count >= P.Count then
               Append (Remainder, "/");
            end if;
            App.Add_Parameter
              (X.all, Remainder_Name (To_String (P.Values (P.Count))),
               To_String (Remainder));
         end;
      end if;
      return True;
   end Match_Path;

   procedure Add_Allowed (Allowed : in out Unbounded_String; Method : String)
   is
      Existing : constant String := To_String (Allowed);
      Wrapped  : constant String := ", " & Existing & ", ";
   begin
      if Ada.Strings.Fixed.Index (Wrapped, ", " & Method & ", ") = 0 then
         if Length (Allowed) > 0 then
            Append (Allowed, ", ");
         end if;
         Append (Allowed, Method);
      end if;
   end Add_Allowed;

   procedure Admit_Body
     (Context : in out App_Context;
      X       : in out App.Exchange;
      Next    : in out Components.Next_Handler)
   is
      Accepted : Boolean;
   begin
      App.Apply_Body_Policy (X, Accepted);
      if Accepted then
         Next.Call (Context, X);
      end if;
   end Admit_Body;

   procedure Require_Authentication
     (Context : in out App_Context;
      X       : in out App.Exchange;
      Next    : in out Components.Next_Handler)
   is
   begin
      if X.Authentication = App.Required_Authentication
        and then not X.Has_Principal
      then
         X.Add_Header ("WWW-Authenticate", "Bearer");
         X.Problem
           (401, "authentication-required", "Authentication required");
      else
         Next.Call (Context, X);
      end if;
   end Require_Authentication;

   procedure Automatic_Response
     (Context : in out App_Context;
      X       : in out App.Exchange)
   is
      pragma Unreferenced (Context);
      Name : constant String := X.Route_Name;
   begin
      if Name = "flyology.bad_request" then
         X.Problem (400, "invalid-path", "Request path is malformed");
      elsif Name = "flyology.redirect" then
         X.Respond (308, "", "");
      elsif Name = "flyology.options" then
         X.No_Content;
      elsif Name in "flyology.method_not_allowed" |
        "flyology.cors_preflight"
      then
         X.Problem (405, "method-not-allowed", "Method is not allowed");
      else
         X.Problem (404, "not-found", "Route does not exist");
      end if;
   end Automatic_Response;

   procedure Dispatch
     (Item       : in out Router;
      Context    : in out App_Context;
      Connection : aliased in out Flyology.HTTP.Server.Connection;
      Value      : aliased in out Request;
      Peer       : Flyology.IO.Sockets.Endpoint;
      Token      : access Flyology.Cancellation.Token := null)
   is
      Target_Value : constant String := Target (Value);
      Raw          : constant String := Raw_Path (Target_Value);
      Invalid_Path : Boolean := False;

      function Decode_For_Dispatch return String is
      begin
         return (if Raw = "*" then "*" else Decode_Path (Raw));
      exception
         when Route_Error =>
            Invalid_Path := True;
            return "/";
      end Decode_For_Dispatch;

      Path_Value   : constant String := Decode_For_Dispatch;
      Request_Method : constant String := Method (Value);
      Selected       : Natural := 0;
      Fallback       : Natural := 0;
      Selected_Score : Natural := 0;
      Allowed        : Unbounded_String;
      Alternate      : Natural := 0;
      Preflight_Route : Natural := 0;
      X : aliased App.Exchange := App.Create
        (Value, Connection, Peer, Token,
         Request_Deadline (Connection));

      function Matches (Index : Positive; Ignore : Boolean := False)
        return Boolean
      is (Match_Path
            (To_String (Item.Routes (Index).Pattern), Path_Value,
             Ignore, Capture => False));

      procedure Consider (Index : Positive; Is_Fallback : Boolean := False) is
         Score : constant Natural :=
           Specificity (To_String (Item.Routes (Index).Pattern));
      begin
         if Is_Fallback then
            if Fallback = 0 or else Score >
              Specificity (To_String (Item.Routes (Fallback).Pattern))
            then
               Fallback := Index;
            end if;
         elsif Selected = 0 or else Score > Selected_Score then
            Selected := Index;
            Selected_Score := Score;
         elsif Score = Selected_Score then
            raise Route_Error with "ambiguous HTTP route match";
         end if;
      end Consider;

      procedure Run_Automatic
        (Name : String;
         CORS_Policy : Natural := 0)
      is
         Pipeline : aliased Components.Pipeline
           (Capacity => Max_Global_Middleware);
      begin
         X.Configure_Route
           (Name, Path_Value, App.Reject_Body, App.No_Authentication,
            CORS_Policy, 0, 0, App.No_Upgrade);
         X.Seal_Route;
         for Index in 1 .. Item.Middleware_Count loop
            if Item.Middleware (Index).Stage = Request_Head then
               Pipeline.Add (Item.Middleware (Index).Component);
            end if;
         end loop;
         for Index in 1 .. Item.Middleware_Count loop
            if Item.Middleware (Index).Stage = Application then
               Pipeline.Add (Item.Middleware (Index).Component);
            end if;
         end loop;
         Pipeline.Execute (Context, X, Automatic_Response'Access);
      end Run_Automatic;
   begin
      if Request_Method = "OPTIONS" and then Raw = "*" then
         Add_Allowed (Allowed, "OPTIONS");
         for Index in 1 .. Item.Count loop
            Add_Allowed (Allowed, To_String (Item.Routes (Index).Method));
            if To_String (Item.Routes (Index).Method) = "GET"
              and then Item.Routes (Index).Policy.Upgrade = No_Upgrade
            then
               Add_Allowed (Allowed, "HEAD");
            end if;
         end loop;
         if Length (Allowed) > 0 then
            X.Add_Header ("Allow", To_String (Allowed));
         end if;
         Run_Automatic ("flyology.options");
         return;
      end if;
      if Invalid_Path then
         Run_Automatic ("flyology.bad_request");
         return;
      end if;
      for Index in 1 .. Item.Count loop
         if Matches (Index, Item.Slashes = Ignore_Slashes) then
            declare
               Route_Method : constant String :=
                 To_String (Item.Routes (Index).Method);
            begin
               if Item.Routes (Index).Policy.CORS_Policy /= 0
                 and then
                   (Preflight_Route = 0
                    or else Specificity
                      (To_String (Item.Routes (Preflight_Route).Pattern)) <
                      Specificity (To_String (Item.Routes (Index).Pattern)))
               then
                  Preflight_Route := Index;
               end if;
               Add_Allowed (Allowed, Route_Method);
               if Route_Method = "GET"
                 and then Item.Routes (Index).Policy.Upgrade = No_Upgrade
               then
                  Add_Allowed (Allowed, "HEAD");
               end if;
               if Route_Method = Request_Method then
                  Consider (Index);
               elsif Request_Method = "HEAD" and then Route_Method = "GET"
                 and then Item.Routes (Index).Policy.Upgrade = No_Upgrade
               then
                  Consider (Index, Is_Fallback => True);
               end if;
            end;
         elsif Item.Slashes = Redirect_Slashes and then Matches (Index, True)
           and then (To_String (Item.Routes (Index).Method) = Request_Method
                     or else (Request_Method = "HEAD"
                              and then To_String
                                (Item.Routes (Index).Method) = "GET"
                              and then Item.Routes (Index).Policy.Upgrade =
                                No_Upgrade))
         then
            Alternate := Index;
         end if;
      end loop;
      if Selected = 0 then
         Selected := Fallback;
      end if;
      if Selected = 0 then
         if Alternate /= 0 then
            declare
               Location : constant String :=
                 (if Raw = "/" then Raw
                  elsif Raw (Raw'Last) = '/'
                  then Raw (Raw'First .. Raw'Last - 1)
                  else Raw & "/") & Raw_Query_Suffix (Target_Value);
            begin
               X.Add_Header ("Location", Location);
            end;
            --  Redirect responses also pass through global observation and
            --  security middleware; the Location header was staged above.
            Run_Automatic ("flyology.redirect");
         elsif Length (Allowed) > 0 then
            X.Add_Header ("Allow", To_String (Allowed));
            if Request_Method = "OPTIONS"
              and then X.Request_Header
                ("Access-Control-Request-Method") /= ""
              and then Preflight_Route /= 0
            then
               Run_Automatic
                 ("flyology.cors_preflight",
                  Item.Routes (Preflight_Route).Policy.CORS_Policy);
            else
               Run_Automatic ("flyology.method_not_allowed");
            end if;
         else
            Run_Automatic ("flyology.not_found");
         end if;
         return;
      end if;

      declare
         Route : constant Route_Entry := Item.Routes (Selected);
         Pipeline : aliased Components.Pipeline
           (Capacity =>
              Max_Global_Middleware + Max_Route_Middleware + 2);
      begin
         X.Configure_Route
           (To_String (Route.Name), Path_Value, Route.Policy.Body_Handling,
            Route.Policy.Authentication, Route.Policy.CORS_Policy,
            Route.Policy.Concurrency, Route.Policy.Rate_Per_Second,
            Route.Policy.Upgrade);
         if not Match_Path
           (To_String (Route.Pattern), Path_Value,
            Item.Slashes = Ignore_Slashes, Capture => True, X => X'Access)
         then
            raise Program_Error with "selected HTTP route no longer matches";
         end if;
         X.Seal_Route;
         if Route.Policy.Timeout >= 0.0 then
            declare
               Candidate : constant Ada.Real_Time.Time := Ada.Real_Time.Clock
                 + Ada.Real_Time.To_Time_Span (Route.Policy.Timeout);
            begin
               if Candidate < X.Deadline then
                  X.Narrow_Deadline (Candidate);
               end if;
            end;
         end if;
         begin
            Narrow_Body_Limit (Connection, Route.Policy.Max_Body);
         exception
            when Payload_Too_Large | Protocol_Error =>
               X.Problem (413, "body-too-large", "Request body is too large");
               return;
         end;

         for Index in 1 .. Item.Middleware_Count loop
            if Item.Middleware (Index).Stage = Request_Head then
               Pipeline.Add (Item.Middleware (Index).Component);
            end if;
         end loop;
         for Index in 1 .. Route.Middleware_Count loop
            if Route.Middleware (Index).Stage = Request_Head then
               Pipeline.Add (Route.Middleware (Index).Component);
            end if;
         end loop;
         Pipeline.Add (Require_Authentication'Access);
         Pipeline.Add (Admit_Body'Access);
         for Index in 1 .. Item.Middleware_Count loop
            if Item.Middleware (Index).Stage = Application then
               Pipeline.Add (Item.Middleware (Index).Component);
            end if;
         end loop;
         for Index in 1 .. Route.Middleware_Count loop
            if Route.Middleware (Index).Stage = Application then
               Pipeline.Add (Route.Middleware (Index).Component);
            end if;
         end loop;
         Pipeline.Execute (Context, X, Route.Handler);
         if X.Response = App.Not_Started then
            X.No_Content;
         elsif X.Response in App.Streaming_Response | App.Streaming_SSE |
           App.Upgraded | App.Failed
         then
            --  A lifecycle must finish before its borrowed exchange returns.
            --  Returning while framing is active makes another HTTP read
            --  unsafe, so contain the fault to this connection.
            X.Mark_Failed;
         end if;
      exception
         when Resource_Exhausted =>
            if not Response_Started (Connection) then
               X.Add_Header ("Retry-After", "1");
               X.Problem
                 (503, "ingress-budget-exhausted",
                  "Server ingress capacity is exhausted");
            else
               Connection.Request_Close := True;
            end if;
      end;
   exception
      when Route_Error =>
         if not Response_Started (Connection) then
            X.Problem (400, "invalid-path", "Request path is malformed");
         end if;
      when Payload_Too_Large =>
         if not Response_Started (Connection) then
            X.Problem (413, "body-too-large", "Request body is too large");
         else
            Connection.Request_Close := True;
         end if;
      when Expectation_Failed =>
         if not Response_Started (Connection) then
            X.Problem
              (417, "expectation-failed", "Request expectation failed");
         else
            Connection.Request_Close := True;
         end if;
      when Protocol_Error =>
         if not Response_Started (Connection) then
            X.Problem (400, "bad-request", "Request data is malformed");
         else
            Connection.Request_Close := True;
         end if;
   end Dispatch;

   procedure Serve
     (Item         : in out Router;
      Context      : in out App_Context;
      Connection   : aliased in out Flyology.HTTP.Server.Connection;
      Peer         : Flyology.IO.Sockets.Endpoint;
      Timeout      : Duration := 30.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests : Natural := 1_000;
      Token        : access Flyology.Cancellation.Token := null;
      Header_Timeout : Duration := -1.0)
   is
      Value  : aliased Request;
      Closed : Boolean;
      Count  : Natural := 0;
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Head_Started : Ada.Real_Time.Time := Started;
      Head_Budget  : Duration := Timeout;

      function Read_Timeout return Duration is
         Age_Left : Duration;
      begin
         if Max_Connection_Age < 0.0 then
            return Timeout;
         end if;
         Age_Left := Max_Connection_Age - Ada.Real_Time.To_Duration
           (Ada.Real_Time.Clock - Started);
         if Age_Left <= 0.0 then
            return 0.0;
         elsif Timeout < 0.0 then
            return Age_Left;
         else
            return Duration'Min (Timeout, Age_Left);
         end if;
      end Read_Timeout;

      function Head_Time_Left return Duration is
         Elapsed : constant Duration := Ada.Real_Time.To_Duration
           (Ada.Real_Time.Clock - Head_Started);
      begin
         if Head_Budget < 0.0 then
            return -1.0;
         elsif Elapsed >= Head_Budget then
            return 0.0;
         else
            return Head_Budget - Elapsed;
         end if;
      end Head_Time_Left;
   begin
      loop
         exit when Read_Timeout = 0.0;
         Head_Started := Ada.Real_Time.Clock;
         Head_Budget :=
           (if Header_Timeout < 0.0
            then Read_Timeout
            elsif Read_Timeout < 0.0
            then Header_Timeout
            else Duration'Min (Header_Timeout, Read_Timeout));
         begin
            Read_Request_Head
              (Connection, Value, Closed,
               Header_Timeout  => Head_Budget,
               Request_Timeout => Read_Timeout,
               Max_Body        => Max_Request_Body,
               Token           => Token);
         exception
            when Payload_Too_Large =>
               if not Response_Started (Connection)
                 and then Head_Time_Left /= 0.0
               then
                  Respond
                    (Connection, 413, "text/plain; charset=utf-8",
                     "request content is too large" & Character'Val (10),
                     Close => True, Timeout => Head_Time_Left, Token => Token);
               end if;
               return;
            when Expectation_Failed =>
               if not Response_Started (Connection)
                 and then Head_Time_Left /= 0.0
               then
                  Respond
                    (Connection, 417, "text/plain; charset=utf-8",
                     "request expectation failed" & Character'Val (10),
                     Close => True, Timeout => Head_Time_Left, Token => Token);
               end if;
               return;
            when Protocol_Error =>
               if not Response_Started (Connection)
                 and then Head_Time_Left /= 0.0
               then
                  Respond
                    (Connection, 400, "text/plain; charset=utf-8",
                     "bad request" & Character'Val (10), Close => True,
                     Timeout => Head_Time_Left, Token => Token);
               end if;
               return;
            when Flyology.IO.Timeout_Error |
                 Flyology.IO.Device_Error |
                 Flyology.IO.TLS.TLS_Error |
                 Flyology.IO.Sockets.Socket_Error =>
               return;
         end;
         exit when Closed;
         Count := Count + 1;
         if Max_Requests > 0 and then Count >= Max_Requests then
            Connection.Request_Close := True;
         end if;
         begin
            Dispatch (Item, Context, Connection, Value, Peer, Token);
         exception
            when Flyology.Cancellation.Operation_Cancelled |
                 Flyology.IO.Timeout_Error |
                 Flyology.IO.Device_Error |
                 Flyology.IO.TLS.TLS_Error |
                 Flyology.IO.Sockets.Socket_Error |
                 Resource_Exhausted =>
               return;
            when others =>
               if not Response_Started (Connection) then
                  begin
                     Respond
                       (Connection, 500, "text/plain; charset=utf-8",
                        "internal server error" & Character'Val (10),
                        Close => True, Timeout => Read_Timeout,
                        Token => Token);
                  exception
                     when others => null;
                  end;
               end if;
               return;
         end;
         exit when Should_Close (Connection);
      end loop;
   end Serve;

end Flyology.HTTP.Server.Routing;
