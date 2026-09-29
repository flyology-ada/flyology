--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Flyology_Bench.Internal_Probes;

package body Flyology_Bench.Host_Control is
   function Pin_Current_Thread (CPU : Natural) return Placement_Strength is
   begin
      case Internal_Probes.Place_Current_Thread (CPU) is
         when Internal_Probes.Advisory_Placement =>
            return Advisory;

         when Internal_Probes.Strict_Placement   =>
            return Strict;

         when Internal_Probes.Placement_Refused  =>
            raise Program_Error with "host rejected benchmark thread placement";
      end case;
   end Pin_Current_Thread;
end Flyology_Bench.Host_Control;
