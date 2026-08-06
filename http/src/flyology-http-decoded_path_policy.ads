--  Internal, proved policy for decoded HTTP path dot segments.
private package Flyology.HTTP.Decoded_Path_Policy
  with SPARK_Mode => On
is

   type Path_Disposition is (Accept_Path, Reject_Dot_Segment);

   --  Reject exactly when a slash-delimited segment is "." or "..".
   function Classify (Value : String) return Path_Disposition
   with
     Global => null,
     Post   =>
       (Classify'Result = Reject_Dot_Segment) =
         (for some Index in Value'Range =>
            (Index = Value'First or else Value (Index - 1) = '/')
            and then Value (Index) = '.'
            and then
              ((Index = Value'Last or else Value (Index + 1) = '/')
               or else
                 (Index < Value'Last
                  and then Value (Index + 1) = '.'
                  and then
                    (Index + 1 = Value'Last
                     or else Value (Index + 2) = '/'))));

end Flyology.HTTP.Decoded_Path_Policy;
