package body Flyology.HTTP.Decoded_Path_Policy
  with SPARK_Mode => On
is

   function Classify (Value : String) return Path_Disposition is
     (if
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
                    or else Value (Index + 2) = '/'))))
      then Reject_Dot_Segment
      else Accept_Path);

end Flyology.HTTP.Decoded_Path_Policy;
