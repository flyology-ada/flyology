with Ada.Strings;
with Ada.Strings.Fixed;

package body Flyology.HTTP.Server.Middleware_CORS is

   package App renames Flyology.HTTP.Server.Applications;

   function Decimal (Value : Duration) return String is
   begin
      return Ada.Strings.Fixed.Trim
        (Long_Long_Integer'Image (Long_Long_Integer (Value)),
         Ada.Strings.Both);
   end Decimal;

   procedure Add_Origin
     (X      : in out App.Exchange;
      Policy : CORS.Policy;
      Origin : String)
   is
   begin
      X.Add_Header
        ("Access-Control-Allow-Origin",
         (if CORS.Wildcard (Policy) then "*" else Origin));
      if not CORS.Wildcard (Policy) then
         X.Add_Header ("Vary", "Origin");
      end if;
      if CORS.Credentials (Policy) then
         X.Add_Header ("Access-Control-Allow-Credentials", "true");
      end if;
   end Add_Origin;

   procedure Call
     (Context : in out App_Context;
      X       : in out App.Exchange;
      Next    : in out Components.Next_Handler)
   is
      Slot   : constant Natural := X.CORS_Policy;
      Origin : constant String := X.Request_Header ("Origin");
   begin
      if Slot = 0 or else Origin = "" then
         Next.Call (Context, X);
         return;
      end if;
      declare
         Policy : constant access constant CORS.Policy := Resolve (Slot);
         Requested_Method : constant String :=
           X.Request_Header ("Access-Control-Request-Method");
         Requested_Headers : constant String :=
           X.Request_Header ("Access-Control-Request-Headers");
         Preflight : constant Boolean :=
           X.Request_Method = "OPTIONS" and then Requested_Method /= "";
      begin
         if Policy = null or else not CORS.Origin_Allowed (Policy.all, Origin)
         then
            if Preflight then
               X.Problem (403, "cors-origin-denied", "CORS origin denied");
            else
               Next.Call (Context, X);
            end if;
            return;
         end if;

         if Preflight then
            if not CORS.Method_Allowed (Policy.all, Requested_Method)
              or else not CORS.Headers_Allowed
                (Policy.all, Requested_Headers)
            then
               X.Problem
                 (403, "cors-preflight-denied", "CORS preflight denied");
               return;
            end if;
            Add_Origin (X, Policy.all, Origin);
            X.Add_Header ("Vary", "Access-Control-Request-Method");
            if Requested_Headers /= "" then
               X.Add_Header ("Vary", "Access-Control-Request-Headers");
            end if;
            X.Add_Header
              ("Access-Control-Allow-Methods", CORS.Methods (Policy.all));
            if CORS.Headers (Policy.all) /= "" then
               X.Add_Header
                 ("Access-Control-Allow-Headers", CORS.Headers (Policy.all));
            end if;
            if CORS.Preflight_Max_Age (Policy.all) >= 0.0 then
               X.Add_Header
                 ("Access-Control-Max-Age",
                  Decimal (CORS.Preflight_Max_Age (Policy.all)));
            end if;
            X.No_Content;
            return;
         end if;

         if not CORS.Method_Allowed (Policy.all, X.Request_Method) then
            Next.Call (Context, X);
            return;
         end if;
         Add_Origin (X, Policy.all, Origin);
         if CORS.Exposed (Policy.all) /= "" then
            X.Add_Header
              ("Access-Control-Expose-Headers", CORS.Exposed (Policy.all));
         end if;
         Next.Call (Context, X);
      end;
   end Call;

end Flyology.HTTP.Server.Middleware_CORS;
