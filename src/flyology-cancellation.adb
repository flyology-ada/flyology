package body Flyology.Cancellation is

   use type Interfaces.C.int;

#if FLYOLOGY_WORKER_POOL_TEST_HOOKS then
   function Test_Cancellation_Failure return Interfaces.C.int
   with Import, Convention => C, External_Name => "flyology_test_worker_native_executor_cancellation_failure";
#end if;

   protected body Token is
      procedure Request is
      begin
         if not Is_Requested then
            --  Avoid creating an OS descriptor for task-only cancellation.
            --  Wait_Source observes Is_Requested under this same lock; an
            --  already borrowed descriptor remains persistent and is woken.
            --  Publish the terminal state first so a wake failure cannot
            --  prevent polling or protected-entry waiters from observing it.
            Is_Requested := True;
            if Wake_Sources.Descriptor (Wake) >= 0 then
#if FLYOLOGY_WORKER_POOL_TEST_HOOKS then
               if Test_Cancellation_Failure /= 0 then
                  raise Program_Error with "injected cancellation wake signaling failure";
               end if;
#end if;
               Wake_Sources.Signal (Wake);
            end if;
         end if;
      end Request;

      entry Await_Request when Is_Requested is
      begin
         null;
      end Await_Request;

      function Requested return Boolean
      is (Is_Requested);

      procedure Wait_Source (FD : out Interfaces.C.int; Already_Requested : out Boolean) is
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
