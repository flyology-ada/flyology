package body Flyology.IO.TLS.Testing is

   function Operation_Active (Item : Connection) return Boolean is
     (Item.Controller.Operation_Is_Active);

   function Queued_Operations (Item : Connection) return Natural is
     (Item.Controller.Queued_Acquisitions);

   function Close_In_Progress (Item : Connection) return Boolean is
     (Item.Controller.Close_Is_In_Progress);

   function Generation (Item : Connection) return Interfaces.Unsigned_64 is
     (Interfaces.Unsigned_64 (Item.Controller.Generation_State));

   procedure Attempt_Stale_Acquisition
     (Item         : in out Connection;
      Snapshot     : Interfaces.Unsigned_64;
      Was_Replaced : out Boolean)
   is
      FD           : Descriptor;
      Actual       : Descriptor_Generation;
      Close_Source : Descriptor;
      Result       : Acquire_Result;
   begin
      Item.Controller.Acquire
        (Descriptor_Generation (Snapshot),
         FD,
         Actual,
         Close_Source,
         Result);
      Was_Replaced := Result = Replaced;
      if Result = Acquired then
         Item.Controller.Release (Actual);
      end if;
   end Attempt_Stale_Acquisition;

end Flyology.IO.TLS.Testing;
