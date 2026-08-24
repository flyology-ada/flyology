with Flyology.Buffers.Domains;

--  This program must not compile. Held would outlive the domain named by the
--  owned buffer's access discriminant.

procedure Buffer_Outlives_Domain is
   package Domains renames Flyology.Buffers.Domains;

   type Buffer_Reference is access all Domains.Owned_Buffer;

   Held : Buffer_Reference;
begin
   declare
      Configuration : constant Domains.Pool_Configuration_Array :=
        [1 => (Block_Size => 8, Capacity => 1)];
      Domain        : aliased Domains.Buffer_Domain := Domains.Create (Configuration);
   begin
      Held := new Domains.Owned_Buffer (Domain'Access);
   end;
   Domains.Release (Held.all);
end Buffer_Outlives_Domain;
