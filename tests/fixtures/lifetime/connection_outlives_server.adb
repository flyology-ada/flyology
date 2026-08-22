with Flyology.IO.Connections;

--  This program must not compile. The connection is allocated from a
--  library-level collection while it names a Server declared in an inner
--  block, so it would outlive the admission controller it borrows. Ada
--  rejects the access discriminant instead of leaving the rule to prose.
--  scripts/test.sh compiles this fixture and fails if the compiler accepts
--  it.

procedure Connection_Outlives_Server is
   package Connections renames Flyology.IO.Connections;

   type Connection_Reference is access all Connections.Connection;

   Held : Connection_Reference;
begin
   declare
      Manager : aliased Connections.Server (Capacity => 1);
   begin
      Held := new Connections.Connection (Manager'Access);
   end;
   Connections.Close (Held.all);
end Connection_Outlives_Server;
