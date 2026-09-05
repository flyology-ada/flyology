with Flyology_Cachelines.Fitted_Groups;
with Flyology_Cachelines.Padded_Groups;
with Interfaces;

procedure Group_Guard_Compatibility is
   package Explicit_Groups is new
     Flyology_Cachelines.Padded_Groups (Element_Type => Interfaces.Unsigned_32, Group_Length => 4);
   package Automatic_Groups is new Flyology_Cachelines.Fitted_Groups (Interfaces.Unsigned_32);
   pragma Unreferenced (Explicit_Groups, Automatic_Groups);
begin
   null;
end Group_Guard_Compatibility;
