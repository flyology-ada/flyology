with Ada.Real_Time;
with Flyology.Cancellation;
with Flyology.HTTP.Server.Applications;
with Flyology.Task_Scopes;

--  Connects structured task scopes to an HTTP request without lending the
--  Exchange or connection to child tasks.
--  @formal Input_Type Immutable child-operation input
--  @formal Result_Type Child-operation result
--  @formal Execute Child operation implementation
generic
   type Input_Type is private;
   type Result_Type is private;
   with procedure Execute
     (Input    : Input_Type;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Result   : out Result_Type);
package Flyology.HTTP.Server.Request_Tasks is

   --  General structured operation implementation used by this adapter.
   package Operations is new
     Flyology.Task_Scopes (Input_Type, Result_Type, Execute);

   --  Inherit the Exchange cancellation identity and current absolute
   --  deadline. Subsequent Exchange narrowing does not retroactively update a
   --  configured scope, so configure it after request middleware completes.
   --  The scope links parent cancellation downward into a private child token;
   --  sibling failure never requests the parent request token.
   --  Item must be declared with Parent => X.Cancellation so Ada enforces the
   --  request-token borrow.
   --  @param Item Request task scope
   --  @param X Borrowed request exchange
   --  @param Cancel_Siblings_On_Failure Whether one failure cancels siblings
   procedure Configure
     (Item : in out Operations.Scope;
      X    : Applications.Exchange;
      Cancel_Siblings_On_Failure : Boolean := True);

end Flyology.HTTP.Server.Request_Tasks;
