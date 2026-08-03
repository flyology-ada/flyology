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

   function Generate return String is
      Value : Natural;
   begin
      Generator.Take (Value);
      return "fly-" & Ada.Strings.Fixed.Trim
        (Natural'Image (Value), Ada.Strings.Both);
   end Generate;

   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler)
   is
      Inbound : constant String := X.Request_Header (Header_Name);
      Value   : constant String :=
        (if Trust_Inbound and then Valid (Inbound)
         then Inbound else Generate);
   begin
      X.Set_Request_ID (Value);
      X.Add_Header (Header_Name, Value);
      Next.Call (Context, X);
   end Call;

end Flyology.HTTP.Server.Middleware_Request_IDs;
