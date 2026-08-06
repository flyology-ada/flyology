package body Flyology.IO.TLS.Testing is

   function Generation
     (Item : in out Connection) return Interfaces.Unsigned_64
   is
      State    : Acquire_Result;
      Snapshot : Descriptor_Generation;
   begin
      Item.Controller.Snapshot_Acquisition (State, Snapshot);
      return Interfaces.Unsigned_64 (Snapshot);
   end Generation;

   procedure Attempt_Stale_Acquisition
     (Item         : in out Connection;
      Snapshot     : Interfaces.Unsigned_64;
      Was_Replaced : out Boolean)
   is
      FD           : Descriptor;
      Actual       : aliased Descriptor_Generation;
      Armed        : aliased Boolean := False;
      Close_Source : Descriptor;
      Result       : Acquire_Result;
   begin
      Item.Controller.Acquire
        (Descriptor_Generation (Snapshot),
         FD,
         Actual'Access,
         Armed'Access,
         Close_Source,
         Result);
      Was_Replaced := Result = Replaced;
      if Armed then
         Item.Controller.Release (Actual);
      end if;
   end Attempt_Stale_Acquisition;

end Flyology.IO.TLS.Testing;
