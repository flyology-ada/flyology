package body Flyology.Supervision_Windows is
   use type Ada.Containers.Count_Type;

   function Advance (Item : History; Position : Positive; Steps : Natural) return Positive is
   begin
      if Steps <= Item.Capacity - Position then
         return Position + Steps;
      else
         return Steps - (Item.Capacity - Position);
      end if;
   end Advance;

   procedure Initialize (Item : in out History; Limit : Positive) is
   begin
      Item.Times.Clear;
      Item.Times.Reserve_Capacity (Ada.Containers.Count_Type (Limit));
      Item.Capacity := Limit;
      Item.First := 1;
      Item.Count := 0;
   end Initialize;

   procedure Reset (Item : in out History) is
   begin
      Item.First := 1;
      Item.Count := 0;
   end Reset;

   function Has_Capacity
     (Item : History; Now : Ada.Real_Time.Time; Window : Ada.Real_Time.Time_Span; Limit : Positive)
      return Boolean is
   begin
      return
        Item.Count < Limit
        or else Now - Item.Times.Element (Advance (Item, Item.First, Item.Count - Limit)) >= Window;
   end Has_Capacity;

   procedure Record_Attempt (Item : in out History; Now : Ada.Real_Time.Time) is
   begin
      if Item.Count = Item.Capacity then
         Item.Times.Replace_Element (Item.First, Now);
         Item.First := Advance (Item, Item.First, 1);
      else
         if Item.Times.Length = Ada.Containers.Count_Type (Item.Count) then
            Item.Times.Append (Now);
         else
            Item.Times.Replace_Element (Item.Count + 1, Now);
         end if;
         Item.Count := Item.Count + 1;
      end if;
   end Record_Attempt;
end Flyology.Supervision_Windows;
