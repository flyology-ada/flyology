private package Flyology.HTTP.Expect_Policy
  with SPARK_Mode => On
is

   type Expectation_Action is (Ignore, Proceed, Reject);

   --  Classify the complete HTTP version, field-count, and supported-value
   --  decision consumed by the request parser.
   function Classify
     (Version         : HTTP_Version;
      Field_Count     : Natural;
      Value_Supported : Boolean) return Expectation_Action
   with
     Global         => null,
     Contract_Cases =>
       (Version = HTTP_1_0 or else Field_Count = 0 =>
          Classify'Result = Ignore,
        Version = HTTP_1_1
          and then Field_Count = 1
          and then Value_Supported =>
            Classify'Result = Proceed,
        Version = HTTP_1_1
          and then Field_Count > 0
          and then (Field_Count /= 1 or else not Value_Supported) =>
            Classify'Result = Reject);

end Flyology.HTTP.Expect_Policy;
