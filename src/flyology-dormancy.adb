with Interfaces.C;
with Flyology.Time_Math;

package body Flyology.Dormancy is
   package C renames Interfaces.C;

   use type C.int;
   use type C.long_long;

   Nanoseconds_Per_Second : constant := 1_000_000_000;
   Maximum_Wait : constant Duration :=
     Duration
       (C.long_long'Last / C.long_long (Nanoseconds_Per_Second));

   function Runtime_Set_Current_Dormancy
     (Value                    : C.int;
      Minimum_Wait_Nanoseconds : C.long_long) return C.int;
   pragma Import
     (C,
      Runtime_Set_Current_Dormancy,
      "flyology_runtime_set_current_dormancy");

   function Runtime_Current_Dormancy return C.int;
   pragma Import
     (C, Runtime_Current_Dormancy, "flyology_runtime_current_dormancy");

   function Runtime_Cold_Advice_Supported return C.int;
   pragma Import
     (C,
      Runtime_Cold_Advice_Supported,
      "flyology_runtime_cold_advice_supported");

   function Runtime_Pageout_Advice_Supported return C.int;
   pragma Import
     (C,
      Runtime_Pageout_Advice_Supported,
      "flyology_runtime_pageout_advice_supported");

   procedure Set_Policy
     (Value        : Policy;
      Minimum_Wait : Duration := 1.0)
   is
      Result : C.int;
   begin
      if Minimum_Wait < 0.0 or else Minimum_Wait > Maximum_Wait then
         raise Dormancy_Error with "invalid dormant-stack minimum wait";
      end if;
      Result := Runtime_Set_Current_Dormancy
        (C.int (Policy'Pos (Value)),
         Flyology.Time_Math.To_Nanoseconds (Minimum_Wait));
      if Result /= 0 and then Value /= Prompt then
         raise Dormancy_Error with
           "non-prompt dormancy requires a lightweight task";
      end if;
   end Set_Policy;

   function Current_Policy return Policy is
      Result : constant C.int := Runtime_Current_Dormancy;
   begin
      return
        (case Result is
            when 1 => Reclaimable,
            when 2 => Page_Out,
            when others => Prompt);
   end Current_Policy;

   function Cold_Advice_Supported return Boolean is
     (Runtime_Cold_Advice_Supported /= 0);

   function Pageout_Advice_Supported return Boolean is
     (Runtime_Pageout_Advice_Supported /= 0);

end Flyology.Dormancy;
