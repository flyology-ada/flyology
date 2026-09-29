package body Flyology_Cachelines.Platform is

   --  No supported host interface, so nothing is reported.
   function Detect return Host_Facts is
      Nothing : Host_Facts;
   begin
      return Nothing;
   end Detect;

end Flyology_Cachelines.Platform;
