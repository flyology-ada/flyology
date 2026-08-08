--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Interfaces.C;

package body Flyology_Bench.Host_Control is
   function Native_Pin
     (CPU : Interfaces.C.unsigned) return Interfaces.C.int;
   pragma Import (C, Native_Pin, "flyology_bench_pin_current_thread");

   function Pin_Current_Thread (CPU : Natural) return Placement_Strength is
      Status : constant Interfaces.C.int :=
        Native_Pin (Interfaces.C.unsigned (CPU));
   begin
      case Status is
         when 1 => return Advisory;
         when 2 => return Strict;
         when others =>
            raise Program_Error with "host rejected benchmark thread placement";
      end case;
   end Pin_Current_Thread;
end Flyology_Bench.Host_Control;
