package body Flyology.File_Timeout_Policy
  with SPARK_Mode
is
   function Classify (Timeout : Duration) return Read_Disposition
   is (if Timeout > 0.0 then Read_Within_Deadline else Read_Immediately);

end Flyology.File_Timeout_Policy;
