package body Flyology.Cancellation is

   use type Interfaces.C.int;

   protected body Token is
      procedure Request is
      begin
         if not Is_Requested then
            --  Avoid creating an OS descriptor for task-only cancellation.
            --  Wait_Source observes Is_Requested under this same lock; an
            --  already borrowed descriptor remains persistent and is woken.
            if Wake_Sources.Descriptor (Wake) >= 0 then
               Wake_Sources.Signal (Wake);
            end if;
            Is_Requested := True;
         end if;
      end Request;

      entry Await_Request when Is_Requested is
      begin
         null;
      end Await_Request;

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
