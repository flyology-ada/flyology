package body Flyology.Cancellation is

   use type Interfaces.C.int;

   protected body Token is
      procedure Request is
      begin
         if not Is_Requested then
            Wake_Sources.Signal (Wake);
            Is_Requested := True;
         end if;
      end Request;

      function Requested return Boolean is (Is_Requested);

      procedure Wait_Source
        (FD : out Interfaces.C.int; Already_Requested : out Boolean)
      is
      begin
         Already_Requested := Is_Requested;
         if Is_Requested then
            FD := -1;
         else
            Wake_Sources.Ensure (Wake);
            FD := Wake_Sources.Descriptor (Wake);
         end if;
      end Wait_Source;
   end Token;

end Flyology.Cancellation;
