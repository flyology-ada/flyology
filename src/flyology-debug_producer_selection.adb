--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology.Execution_Groups;
with Interfaces;
with Interfaces.C;

package body Flyology.Debug_Producer_Selection is
   use type Interfaces.Unsigned_64;
   use type Interfaces.C.int;

   function Runtime_Current_Group return Interfaces.C.int;
   pragma Import
     (C, Runtime_Current_Group, "flyology_runtime_current_group");

   function Native_Thread_Key return Interfaces.Unsigned_64;
   pragma Import
     (C, Native_Thread_Key, "flyology_debug_native_thread_key");

   function Choose (Producer_Count : Positive) return Positive is
      Group : Interfaces.C.int;
   begin
      if Producer_Count = 1 then
         return 1;
      end if;

      Group := Runtime_Current_Group;
      if Group in
        Interfaces.C.int (Flyology.Execution_Groups.Group_Id'First) ..
        Interfaces.C.int (Flyology.Execution_Groups.Group_Id'Last)
      then
         return
           Natural (Group) mod Producer_Count + 1;
      elsif Group /= -1 then
         raise Flyology.Execution_Groups.Group_Error with
           "invalid current execution group from Flyology runtime";
      end if;

      return Positive
        (Native_Thread_Key mod Interfaces.Unsigned_64 (Producer_Count) + 1);
   end Choose;
end Flyology.Debug_Producer_Selection;
