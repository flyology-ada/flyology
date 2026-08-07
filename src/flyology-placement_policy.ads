private package Flyology.Placement_Policy
  with Preelaborate, SPARK_Mode => On
is

   --  Ada reserves this CPU aspect value as Not_A_Specific_CPU. It designates
   --  no processor, so a lightweight task carrying it draws an automatic
   --  placement ticket instead of naming a shared execution group.
   Reserved_CPU : constant := 0;

   --  Highest shared execution group a CPU aspect can name.
   Last_Shared_Group : constant := 127;

   --  CPU aspect values that name a shared execution group. The reserved
   --  value is excluded, so no CPU aspect names the first shared group.
   subtype Group_Selector is
     Natural range Reserved_CPU + 1 .. Last_Shared_Group;

   --  Return the shared execution group named by a CPU aspect value.
   function Group_For_CPU (CPU : Group_Selector) return Natural
   with
     Global => null,
     Post   =>
       Group_For_CPU'Result = CPU
       and then Group_For_CPU'Result /= Reserved_CPU;

end Flyology.Placement_Policy;
