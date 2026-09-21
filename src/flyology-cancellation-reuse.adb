package body Flyology.Cancellation.Reuse is
   procedure Reset (Item : in out Token) is
   begin
      Flyology.Wake_Sources.Release (Item.Wake);
      Item.State.Reset_For_Reuse;
   end Reset;
end Flyology.Cancellation.Reuse;
