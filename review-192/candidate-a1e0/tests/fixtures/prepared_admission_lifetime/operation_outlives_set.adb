with Flyology.Operations;
with Prepared_Admission_Lifetime_Support;

--  This program must not compile. Held would outlive the Completion_Set named
--  by the observation operation's Set access discriminant.

procedure Operation_Outlives_Set is
   package Support renames Prepared_Admission_Lifetime_Support;
   package Prepared renames Support.Prepared;

   type Operation_Reference is access all Prepared.Observation_Operation;
   Held : Operation_Reference;
begin
   declare
      Set : aliased Flyology.Operations.Completion_Set (1);
   begin
      Held :=
        new Prepared.Observation_Operation
              (Set'Access, Support.Global_Family'Access);
   end;
end Operation_Outlives_Set;
