private package Flyology_Cachelines.Linux is

   type Cache_Parameters (Available : Boolean := False) is record
      case Available is
         when True =>
            Line_Size  : Positive;
            Total_Size : Positive;
         when False =>
            null;
      end case;
   end record;

   No_Cache_Parameters : constant Cache_Parameters := (Available => False);

   function Detect_From_Sysconf return Cache_Parameters;

   function Detect_From_Sysfs return Cache_Parameters;

   subtype Class_Count is Natural range 0 .. Max_Core_Classes;

   --  One core class: an L1 data-cache geometry and the CPUs reporting it.
   --
   --  Cores counts physical cores and CPUs counts logical ones.  They differ
   --  under SMT, where sibling CPUs share one L1 data cache: a 24-core host
   --  with two threads per core reports 24 cores and 48 CPUs in one class.
   --  Capacity is the kernel's capacity value, or zero when the host
   --  publishes none.  L2_Size is the level 2 capacity and L2_CPUs the number
   --  of logical CPUs sharing it, both zero when sysfs describes no level 2.
   type Core_Class_Parameters (Available : Boolean := False) is record
      case Available is
         when True =>
            Line_Size  : Positive;
            Total_Size : Positive;
            Cores      : Positive;
            CPUs       : Positive;
            Capacity   : Natural;
            L2_Size    : Natural;
            L2_CPUs    : Natural;
         when False =>
            null;
      end case;
   end record;

   type Core_Class_Table is array (Core_Class) of Core_Class_Parameters;

   --  The distinct core classes the host's CPUs report.
   --
   --  CPUs are grouped by capacity and L1 data-cache geometry together, so
   --  two core types that share a geometry stay separate when the host gives
   --  them different capacities.
   --
   --  Ordering says what separated the classes, and so how much their order
   --  is worth.  Host_Reported means the kernel's per-CPU capacity values
   --  ordered them: capacity is the scheduler's measure of relative CPU
   --  performance, normalized to 1024 for the most capable CPU, published
   --  under cpuN/cpu_capacity by architectures selecting the generic topology
   --  code.  x86-64 does not publish it, so its hybrid parts fall to
   --  Inferred, which orders by descending L1 data-cache capacity.
   --
   --  Count is zero when sysfs describes no usable CPU, and also when the
   --  host reports more distinct classes than the table holds, so a caller
   --  degrades instead of reading a truncated table.
   type Core_Classes is record
      Count    : Class_Count    := 0;
      Ordering : Class_Ordering := Unordered;
      Classes  : Core_Class_Table;
   end record;

   No_Core_Classes : constant Core_Classes :=
     (Count    => 0,
      Ordering => Unordered,
      Classes  => (others => (Available => False)));

   --  Location of the kernel's CPU descriptions.  Detection always reads this
   --  tree; the parameter below exists so tests can present a topology the
   --  test host does not have.
   Default_CPU_Root : constant String := "/sys/devices/system/cpu/";

   function Detect_Core_Classes
     (Root : String := Default_CPU_Root) return Core_Classes;

end Flyology_Cachelines.Linux;
