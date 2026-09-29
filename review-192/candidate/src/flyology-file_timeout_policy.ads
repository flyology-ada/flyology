--  Internal, proved classification of a positional file read's relative
--  deadline.
--
--  Example: `Disposition := Classify (Timeout);`

private package Flyology.File_Timeout_Policy
  with Preelaborate, SPARK_Mode
is

   --  How a timed positional read dispatches. Read_Immediately runs one
   --  untimed positional read and lets its outcome win; Read_Within_Deadline
   --  runs the read under an armed relative deadline.
   type Read_Disposition is (Read_Immediately, Read_Within_Deadline);

   --  A positional read has no readiness wait to abandon, so a zero Timeout is
   --  the library-wide immediate attempt rather than an immediate failure, and
   --  a negative Timeout is the same untimed read without a deadline. Only a
   --  positive Timeout arms one.
   function Classify (Timeout : Duration) return Read_Disposition
   with
     Inline,
     Contract_Cases =>
       (Timeout > 0.0 => Classify'Result = Read_Within_Deadline,
        Timeout = 0.0 => Classify'Result = Read_Immediately,
        Timeout < 0.0 => Classify'Result = Read_Immediately);

end Flyology.File_Timeout_Policy;
