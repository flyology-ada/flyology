with Interfaces.C;

package body Gnatevl.Execution_Groups is
   package C renames Interfaces.C;

   use type C.int;

   function Runtime_Current_Group return C.int;
   pragma Import
     (C, Runtime_Current_Group, "gnatevl_runtime_current_group");

   function Runtime_Create_Dedicated_Group return C.int;
   pragma Import
     (C,
      Runtime_Create_Dedicated_Group,
      "gnatevl_runtime_create_dedicated_group");

   function Runtime_Is_Dedicated_Group (Group : C.int) return C.int;
   pragma Import
     (C, Runtime_Is_Dedicated_Group, "gnatevl_runtime_is_dedicated_group");

   function Runtime_Migrate (Group : C.int) return C.int;
   pragma Import (C, Runtime_Migrate, "gnatevl_runtime_migrate");

   function For_CPU
     (CPU : System.Multiprocessors.CPU_Range) return Shared_Group_Id
   is
     (Shared_Group_Id (CPU));

   function Current return Group_Id is
      Result : constant C.int := Runtime_Current_Group;
   begin
      if Result < C.int (Group_Id'First)
        or else Result > C.int (Group_Id'Last)
      then
         raise Group_Error with "calling task is not evented";
      end if;
      return Group_Id (Result);
   end Current;

   function Create_Dedicated return Dedicated_Group_Id is
      Result : constant C.int := Runtime_Create_Dedicated_Group;
   begin
      if Result < C.int (Dedicated_Group_Id'First)
        or else Result > C.int (Dedicated_Group_Id'Last)
      then
         raise Group_Error with "cannot create a dedicated execution group";
      end if;
      return Dedicated_Group_Id (Result);
   end Create_Dedicated;

   function Is_Dedicated (Group : Group_Id) return Boolean is
     (Runtime_Is_Dedicated_Group (C.int (Group)) /= 0);

   procedure Migrate (Group : Group_Id) is
   begin
      if Runtime_Migrate (C.int (Group)) /= 0 then
         raise Migration_Error with
           "task cannot migrate to execution group" & Group'Image;
      end if;
   end Migrate;

end Gnatevl.Execution_Groups;
