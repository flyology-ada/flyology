package body Flyology.HTTP.Expect_Policy
  with SPARK_Mode => On
is

   function Classify
     (Version         : HTTP_Version;
      Field_Count     : Natural;
      Value_Supported : Boolean) return Expectation_Action is
     (if Version = HTTP_1_0 or else Field_Count = 0 then Ignore
      elsif Field_Count = 1 and then Value_Supported then Proceed
      else Reject);

end Flyology.HTTP.Expect_Policy;
