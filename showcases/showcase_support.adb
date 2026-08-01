with System;
with System.Storage_Elements;

package body Showcase_Support is

   function Current_Thread return System.Address;
   pragma Import (C, Current_Thread, "pthread_self");

   function Thread_Image return String is
     (System.Storage_Elements.Integer_Address'Image
        (System.Storage_Elements.To_Integer (Current_Thread)));

end Showcase_Support;
