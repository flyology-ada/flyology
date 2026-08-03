with Ada.Strings;
with Ada.Strings.Fixed;

package body Flyology.HTTP.Server.Middleware_Request_IDs is

   protected Generator is
      procedure Take (Value : out Natural);
   private
      Counter : Natural := 0;
   end Generator;

   protected body Generator is
      procedure Take (Value : out Natural) is
      begin
         if Counter = Natural'Last then
            Counter := 1;
         else
            Counter := Counter + 1;
         end if;
         Value := Counter;
      end Take;
   end Generator;

   function Valid (Value : String) return Boolean is
   begin
      if Value'Length = 0 or else Value'Length > 128 then
         return False;
      end if;
      for Item of Value loop
         if Item not in 'a' .. 'z'
           and then Item not in 'A' .. 'Z'
           and then Item not in '0' .. '9'
           and then Item not in '-' | '.' | '_'
         then
            return False;
         end if;
      end loop;
      return True;
   end Valid;

   function Generate_Default return String is
      Value : Natural;
   begin
      Generator.Take (Value);
      return "fly-" & Ada.Strings.Fixed.Trim
        (Natural'Image (Value), Ada.Strings.Both);
   end Generate_Default;

   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler)
   is
      Inbound : constant String := X.Request_Header (Header_Name);
      Generated : Ada.Strings.Unbounded.Unbounded_String;
   begin
      if Trust_Inbound and then Valid (Inbound) then
         Generated := Ada.Strings.Unbounded.To_Unbounded_String (Inbound);
      elsif Generate = null then
         Generated := Ada.Strings.Unbounded.To_Unbounded_String
           (Generate_Default);
      else
         --  X is a read-only borrow for the duration of this call. A custom
         --  generator must not retain it or return attacker-controlled bytes
         --  without its own normalization policy.
         Generate (Context, X, Generated);
         if not Valid (Ada.Strings.Unbounded.To_String (Generated)) then
            raise Constraint_Error with
              "request ID generator returned an invalid value";
         end if;
      end if;

      declare
         Value : constant String :=
           Ada.Strings.Unbounded.To_String (Generated);
      begin
         --  Validation precedes both mutations, so a bad custom value cannot
         --  enter exchange state, response headers, logs, or metrics.
         X.Set_Request_ID (Value);
         X.Add_Header (Header_Name, Value);
      end;
      Next.Call (Context, X);
   end Call;

end Flyology.HTTP.Server.Middleware_Request_IDs;
