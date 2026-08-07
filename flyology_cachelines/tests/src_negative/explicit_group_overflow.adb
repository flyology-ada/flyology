with Flyology_Cachelines;
with Flyology_Cachelines.Padded_Groups;
with Interfaces;

procedure Explicit_Group_Overflow is
   package Must_Not_Compile is new Flyology_Cachelines.Padded_Groups
     (Element_Type => Interfaces.Unsigned_8,
      Group_Length => Flyology_Cachelines.Destructive_Interference_Size + 1);
begin
   null;
end Explicit_Group_Overflow;
