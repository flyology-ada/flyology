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

   --  The largest number of distinct core classes this crate distinguishes.
   --  Current hybrid parts report two; the margin covers a third without
   --  making the table a host-dependent size.
   Max_Core_Classes : constant := 8;

   subtype Core_Class_Count is Natural range 0 .. Max_Core_Classes;
   subtype Core_Class_Index is Core_Class_Count range 1 .. Max_Core_Classes;

   --  What ordered the core classes, and therefore how much the order means.
   --
   --  Host_Reported: the kernel's own per-CPU capacity values separated the
   --  classes.  Capacity is the scheduler's measure of relative CPU
   --  performance, normalized to 1024 for the most capable CPU, and it
   --  accounts for both microarchitecture and clock.  Architectures selecting
   --  the generic topology code publish it; x86-64 does not.
   --
   --  Inferred: no capacity value separated the classes, so they are ordered
   --  by descending L1 data-cache capacity.  That holds on current hybrid
   --  parts, where the higher-performing core has the larger L1 data cache,
   --  and it carries no meaning on a host whose classes differ some other
   --  way.  This is the crate's inference, not a fact the host states.
   --
   --  Unordered: fewer than two classes exist, or nothing separated them, so
   --  the order carries no information.
   type Class_Ordering is (Host_Reported, Inferred, Unordered);

   --  One core class: an L1 data-cache geometry and the CPUs reporting it.
   --
   --  Cores counts physical cores and CPUs counts logical ones.  They differ
   --  under SMT, where sibling CPUs share one L1 data cache: a 24-core host
   --  with two threads per core reports 24 cores and 48 CPUs in one class.
   --  Capacity is the kernel's capacity value, or zero when the host
   --  publishes none.
   type Core_Class_Parameters (Available : Boolean := False) is record
      case Available is
         when True =>
            Line_Size  : Positive;
            Total_Size : Positive;
            Cores      : Positive;
            CPUs       : Positive;
            Capacity   : Natural;
         when False =>
            null;
      end case;
   end record;

   type Core_Class_Table is array (Core_Class_Index) of Core_Class_Parameters;

   --  The distinct core classes the host's CPUs report.
   --
   --  CPUs are grouped by capacity and L1 data-cache geometry together, so
   --  two core types that share a geometry stay separate when the host gives
   --  them different capacities.  Count is zero when sysfs describes no
   --  usable CPU, and also when the host reports more distinct classes than
   --  the table holds, so a caller degrades instead of reading a truncated
   --  table.
   type Core_Classes is record
      Count    : Core_Class_Count := 0;
      Ordering : Class_Ordering   := Unordered;
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
