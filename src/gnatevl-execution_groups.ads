with System.Multiprocessors;

package Gnatevl.Execution_Groups with Preelaborate is

   type Group_Id is range 0 .. 255;
   subtype Shared_Group_Id is Group_Id range 0 .. 127;
   subtype Dedicated_Group_Id is Group_Id range 128 .. Group_Id'Last;

   Default_Group : constant Shared_Group_Id := 0;

   Group_Error     : exception;
   Migration_Error : exception;

   function For_CPU
     (CPU : System.Multiprocessors.CPU_Range) return Shared_Group_Id
   with Pre => Integer (CPU) <= Integer (Shared_Group_Id'Last),
        Post => Integer (For_CPU'Result) = Integer (CPU);

   function Current return Group_Id;

   function Create_Dedicated return Dedicated_Group_Id;

   function Is_Dedicated (Group : Group_Id) return Boolean;

   --  Migrate the calling evented task at this safe point. The procedure
   --  returns on Group's event-loop pthread. Stock Native_Thread tasks cannot
   --  migrate because their stacks and lifecycle are owned by pthread/GNARL.
   procedure Migrate (Group : Group_Id);

end Gnatevl.Execution_Groups;
