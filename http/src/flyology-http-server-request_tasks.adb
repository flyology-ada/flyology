package body Flyology.HTTP.Server.Request_Tasks is

   procedure Configure
     (Item : in out Operations.Scope;
      X    : Applications.Exchange;
      Cancel_Siblings_On_Failure : Boolean := True) is
   begin
      Operations.Configure
        (Item, X.Deadline, Cancel_Siblings_On_Failure);
   end Configure;

end Flyology.HTTP.Server.Request_Tasks;
