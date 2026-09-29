--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Interfaces.C;

package body Flyology_Debug is
   use type Interfaces.C.int;

   function Native_Clock (Value : access Interfaces.Unsigned_64) return Interfaces.C.int;
   pragma Import (C, Native_Clock, "flyology_debug_clock_now");

   function Clock return Timestamp is
      Value : aliased Interfaces.Unsigned_64;
   begin
      if Native_Clock (Value'Access) /= 0 then
         raise Program_Error with "platform monotonic clock read failed";
      end if;
      return Timestamp (Value);
   end Clock;

   function First_Producer (Producer_Count : Positive) return Positive is
      pragma Unreferenced (Producer_Count);
   begin
      return 1;
   end First_Producer;
end Flyology_Debug;
