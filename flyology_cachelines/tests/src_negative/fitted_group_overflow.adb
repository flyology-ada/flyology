with Flyology_Cachelines;
with Flyology_Cachelines.Fitted_Groups;
with Interfaces;

procedure Fitted_Group_Overflow is
   type Oversized_Element is
     array (1 .. Flyology_Cachelines.Destructive_Interference_Size + 1) of Interfaces.Unsigned_8;
   package Must_Not_Compile is new Flyology_Cachelines.Fitted_Groups (Oversized_Element);
begin
   null;
end Fitted_Group_Overflow;
