with Prepared_Admission_Lifetime_Support;

--  This program must not compile. Held would outlive the Family named by the
--  observation operation's Owner access discriminant.

procedure Operation_Outlives_Family is
   package Support renames Prepared_Admission_Lifetime_Support;
   package Prepared renames Support.Prepared;

   type Operation_Reference is access all Prepared.Observation_Operation;
   Held : Operation_Reference;
begin
   declare
      Item : aliased Support.Families.Family;
   begin
      Held :=
        new Prepared.Observation_Operation
              (Support.Global_Set'Access, Item'Access);
   end;
end Operation_Outlives_Family;
