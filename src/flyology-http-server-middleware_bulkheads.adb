with Ada.Finalization;

package body Flyology.HTTP.Server.Middleware_Bulkheads is

   Max_Route_Length : constant := 128;

   type Route_Entry is record
      Used   : Boolean := False;
      Name   : String (1 .. Max_Route_Length) := (others => ' ');
      Length : Natural := 0;
      Active : Natural := 0;
   end record;
   type Route_Array is array (Positive range <>) of Route_Entry;

   protected type Manager is
      procedure Acquire
        (Route   : String;
         Limit   : Natural;
         Slot    : out Natural;
         Granted : out Boolean);
      procedure Release (Slot : Natural);
   private
      Global_Active : Natural := 0;
      Routes        : Route_Array (1 .. Route_Capacity);
   end Manager;

   protected body Manager is
      procedure Acquire
        (Route   : String;
         Limit   : Natural;
         Slot    : out Natural;
         Granted : out Boolean)
      is
         Empty : Natural := 0;
      begin
         Slot := 0;
         Granted := False;
         if Global_Limit > 0 and then Global_Active >= Global_Limit then
            return;
         end if;
         if Limit > 0 then
            if Route'Length = 0 or else Route'Length > Max_Route_Length then
               return;
            end if;
            for Index in Routes'Range loop
               if Routes (Index).Used
                 and then Routes (Index).Length = Route'Length
                 and then Routes (Index).Name (1 .. Route'Length) = Route
               then
                  Slot := Index;
                  exit;
               elsif not Routes (Index).Used and then Empty = 0 then
                  Empty := Index;
               end if;
            end loop;
            if Slot = 0 then
               if Empty = 0 then
                  return;
               end if;
               Slot := Empty;
               Routes (Slot).Used := True;
               Routes (Slot).Length := Route'Length;
               Routes (Slot).Name (1 .. Route'Length) := Route;
            end if;
            if Routes (Slot).Active >= Limit then
               return;
            end if;
            Routes (Slot).Active := Routes (Slot).Active + 1;
         end if;
         Global_Active := Global_Active + 1;
         Granted := True;
      end Acquire;

      procedure Release (Slot : Natural) is
      begin
         if Global_Active = 0 then
            raise Program_Error with "HTTP bulkhead permit underflow";
         end if;
         Global_Active := Global_Active - 1;
         if Slot > 0 then
            if Slot not in Routes'Range or else Routes (Slot).Active = 0 then
               raise Program_Error with "HTTP route permit underflow";
            end if;
            Routes (Slot).Active := Routes (Slot).Active - 1;
         end if;
      end Release;
   end Manager;

   State : aliased Manager;

   type Guard is new Ada.Finalization.Limited_Controlled with record
      Slot : Natural := 0;
      Held : Boolean := False;
   end record;

   overriding procedure Finalize (Item : in out Guard) is
   begin
      if Item.Held then
         State.Release (Item.Slot);
         Item.Held := False;
      end if;
   end Finalize;

   procedure Activate (Item : in out Guard; Slot : Natural) is
   begin
      Item.Slot := Slot;
      Item.Held := True;
   end Activate;

   procedure Count_Denial is
   begin
      if Metric_Output /= null then
         Metrics.Count (Metric_Output.all, Metrics.Bulkhead_Denial);
      end if;
   exception
      when others => null;
   end Count_Denial;

   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler)
   is
      Permit  : Guard;
      Granted : Boolean;
   begin
      State.Acquire
        (X.Route_Name, X.Concurrency_Limit, Permit.Slot, Granted);
      if not Granted then
         Count_Denial;
         X.Add_Header ("Retry-After", "1");
         X.Problem (503, "bulkhead-full", "Request concurrency is full");
         return;
      end if;
      Activate (Permit, Permit.Slot);
      Next.Call (Context, X);
   end Call;

end Flyology.HTTP.Server.Middleware_Bulkheads;
