with System.Tasking;

package System.Flyology.Task_Attribute_ABI is
   function Load (T : System.Tasking.Task_Id; Index : Integer) return System.Address;
   --  Load one task-attribute component through the representation selected
   --  for the active compiler release.

   function Is_Null (T : System.Tasking.Task_Id; Index : Integer) return Boolean;
   --  Test one task-attribute component against its representation's null
   --  value without weakening the component's atomic access.

   procedure Store (T : System.Tasking.Task_Id; Index : Integer; Value : System.Address);
   --  Store one address through the task-attribute component representation
   --  selected for the active compiler release.

   --  Preserve the original direct ATCB component accesses after introducing
   --  this representation boundary; these wrappers contain no policy.
   pragma Inline_Always (Load, Is_Null, Store);
end System.Flyology.Task_Attribute_ABI;
