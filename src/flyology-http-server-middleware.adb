package body Flyology.HTTP.Server.Middleware is
   use type Ada.Task_Identification.Task_Id;

   procedure Add
     (Item      : in out Pipeline;
      Component : not null Middleware_Access)
   is
   begin
      if Item.Count = Item.Capacity then
         raise Constraint_Error with "HTTP middleware pipeline is full";
      end if;
      Item.Count := Item.Count + 1;
      Item.Components (Item.Count) := Component;
   end Add;

   procedure Dispatch
     (Item     : not null Pipeline_Access;
      Position : Positive;
      Context  : in out App_Context;
      X        : in out App.Exchange;
      Terminal : not null Handler_Access)
   is
   begin
      if Position > Item.Count then
         Terminal.all (Context, X);
      else
         declare
            Next : Next_Handler :=
              (Owner      => Item,
               Position   => Position + 1,
               Terminal   => Terminal,
               Owner_Task => Ada.Task_Identification.Current_Task,
               Was_Called => False);
         begin
            Item.Components (Position).all (Context, X, Next);
         end;
      end if;
   end Dispatch;

   procedure Execute
     (Item     : aliased in out Pipeline;
      Context  : in out App_Context;
      X        : in out App.Exchange;
      Terminal : not null Handler_Access)
   is
   begin
      Dispatch (Item'Unchecked_Access, 1, Context, X, Terminal);
   end Execute;

   procedure Call
     (Item    : in out Next_Handler;
      Context : in out App_Context;
      X       : in out App.Exchange)
   is
   begin
      if Ada.Task_Identification.Current_Task /= Item.Owner_Task then
         raise Program_Error with
           "HTTP middleware continuation called by non-owner task";
      elsif Item.Was_Called then
         raise Program_Error with "HTTP middleware continuation called twice";
      elsif Item.Owner = null or else Item.Terminal = null then
         raise Program_Error with "invalid HTTP middleware continuation";
      end if;
      Item.Was_Called := True;
      Dispatch (Item.Owner, Item.Position, Context, X, Item.Terminal);
   end Call;

   function Invoked (Item : Next_Handler) return Boolean is
     (Item.Was_Called);

   procedure No_Error_Log
     (Kind  : Failure_Kind;
      Error : Ada.Exceptions.Exception_Occurrence;
      X     : in out App.Exchange)
   is
      pragma Unreferenced (Kind, Error, X);
   begin
      null;
   end No_Error_Log;

   procedure No_Error_Map
     (Context : in out App_Context;
      X       : in out App.Exchange;
      Error   : Ada.Exceptions.Exception_Occurrence;
      Handled : in out Boolean)
   is
      pragma Unreferenced (Context, X, Error, Handled);
   begin
      null;
   end No_Error_Map;

end Flyology.HTTP.Server.Middleware;
