with Flyology.HTTP.Server.Applications;

private package Flyology.HTTP.Route_Parameter_Policy
  with SPARK_Mode => On
is

   Max_Parameters : constant Positive :=
     Flyology.HTTP.Server.Applications.Max_Path_Parameters;

   subtype Parameter_Count is Natural range 0 .. Max_Parameters;
   subtype Parameter_Index is Parameter_Count range 1 .. Max_Parameters;

   type Capacity_Transition is record
      Accepted   : Boolean;
      Next_Count : Parameter_Count;
   end record;

   --  Return the only capacity transition used before Validate_Pattern adds
   --  a name. A full array retains its count and rejects the addition.
   function Advance
     (Current : Parameter_Count) return Capacity_Transition
   with
     Global         => null,
     Contract_Cases =>
       (Current = Max_Parameters =>
          not Advance'Result.Accepted
          and then Advance'Result.Next_Count = Current,
        Current < Max_Parameters =>
          Advance'Result.Accepted
          and then Advance'Result.Next_Count = Current + 1);

end Flyology.HTTP.Route_Parameter_Policy;
