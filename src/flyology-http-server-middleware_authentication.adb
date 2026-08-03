with Ada.Strings.Fixed;

package body Flyology.HTTP.Server.Middleware_Authentication is
   package App renames Flyology.HTTP.Server.Applications;
   use type App.Authentication_Mode;

   function Authorization (X : App.Exchange) return String is
     (X.Request_Header ("Authorization"));

   procedure Reject (X : in out App.Exchange) is
   begin
      X.Add_Header ("WWW-Authenticate", Challenge);
      X.Problem (401, "authentication-required", "Authentication required");
   end Reject;

   procedure Call
     (Context : in out App_Context;
      X       : in out App.Exchange;
      Next    : in out Components.Next_Handler)
   is
      Field : constant String := Authorization (X);
   begin
      if X.Authentication = App.No_Authentication then
         Next.Call (Context, X);
         return;
      elsif Field = "" then
         if X.Authentication = App.Required_Authentication then
            Reject (X);
         else
            Next.Call (Context, X);
         end if;
         return;
      end if;

      declare
         Separator : constant Natural := Ada.Strings.Fixed.Index (Field, " ");
         Accepted  : Boolean := False;
         Identity  : Ada.Strings.Unbounded.Unbounded_String;
      begin
         if Separator = 0
           or else Separator = Field'First
           or else Separator = Field'Last
         then
            Reject (X);
            return;
         end if;
         Authenticate
           (Field (Field'First .. Separator - 1),
            Field (Separator + 1 .. Field'Last), Accepted, Identity);
         if not Accepted
           or else Ada.Strings.Unbounded.Length (Identity) = 0
         then
            Reject (X);
            return;
         end if;
         X.Set_Principal (Ada.Strings.Unbounded.To_String (Identity));
         Next.Call (Context, X);
      end;
   end Call;

end Flyology.HTTP.Server.Middleware_Authentication;
