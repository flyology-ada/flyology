--  Provides cache-line-aware storage policy and host cache information.
--
--  The compile-time spacing policy is independent of runtime cache queries.
--  Storage wrappers use Destructive_Interference_Size; query functions report
--  host information when the operating system makes it available.

package Flyology_Cachelines is

   --  Spacing in storage elements used to prevent false sharing.
   --
   --  This deliberately exceeds
   --  the physical line size on targets whose spatial prefetchers fetch
   --  adjacent lines together.  The architecture policy is adapted from
   --  crossbeam-utils' CachePadded type; README.md records the rationale and
   --  upstream architecture references.
   Destructive_Interference_Size : constant Positive := 128;

   --  Result of a platform cache query.
   --
   --  @field Available True when the host supplied a value.
   --  @field Value The queried size or capacity in bytes.
   type Cache_Query_Result (Available : Boolean := False) is record
      case Available is
         when True =>
            Value : Natural;

         when False =>
            null;
      end case;
   end record;

   --  A cache query result with no host value.
   Unavailable : constant Cache_Query_Result := (Available => False);

   --  The largest number of core classes this crate distinguishes.
   Max_Core_Classes : constant := 8;

   --  One class of cores that report a single cache geometry.
   --
   --  A host whose cores are all alike has one class.  A host that combines
   --  core types has one class per type, ordered so that Fastest_Core_Class
   --  is the class the host ranks highest.  Consult Core_Class_Ordering
   --  before relying on that rank: it reports whether the host stated the
   --  order or the crate inferred it.
   type Core_Class is range 1 .. Max_Core_Classes;

   --  The class every unqualified cache query describes.
   Fastest_Core_Class : constant Core_Class := 1;

   --  How much the order of the core classes is worth.
   --
   --  @enum Host_Reported The host published a performance rank and the
   --    classes follow it.  macOS performance levels and the Linux per-CPU
   --    capacity values are such ranks.
   --  @enum Inferred The host published no rank, so the classes are ordered
   --    by descending L1 data-cache capacity.  That holds on current hybrid
   --    parts, where the higher-performing core has the larger L1 data cache,
   --    and carries no meaning on a host whose classes differ some other way.
   --  @enum Unordered Fewer than two classes exist, or nothing distinguished
   --    them, so the order carries no information.
   type Class_Ordering is (Host_Reported, Inferred, Unordered);

   --  Return the physical cache-line size reported by the host OS.
   --
   --  This is not reported per core class.  macOS publishes no per-class line
   --  size, and the core types of current heterogeneous parts share one line
   --  size.
   --  @return The detected size in bytes, or Unavailable.
   function Hardware_Cache_Line_Size return Cache_Query_Result;

   --  Return the number of core classes the host distinguishes.
   --  @return The detected class count, or Unavailable.
   function Core_Class_Count return Cache_Query_Result;

   --  Return what ordered the core classes.
   --  @return The ordering basis, which is Unordered when the order means
   --    nothing.
   function Core_Class_Ordering return Class_Ordering;

   --  Return the number of physical cores in a core class.
   --  @param Class The core class to describe.
   --  @return The detected core count, or Unavailable.
   function Core_Class_Cores (Class : Core_Class := Fastest_Core_Class) return Cache_Query_Result;

   --  Return the number of logical CPUs in a core class.
   --
   --  This exceeds the core count on a host with simultaneous multithreading,
   --  where sibling CPUs share one core's L1 data cache.
   --  @param Class The core class to describe.
   --  @return The detected CPU count, or Unavailable.
   function Core_Class_CPUs (Class : Core_Class := Fastest_Core_Class) return Cache_Query_Result;

   --  Return the L1 data-cache capacity in bytes for a core class.
   --
   --  A host whose cores are not identical has no single L1 data-cache
   --  capacity, so the result describes one class rather than every core.
   --  The default describes the class the host ranks highest: on Apple
   --  silicon that is a performance core, whose L1 data cache is larger than
   --  an efficiency core's.
   --  @param Class The core class to describe.
   --  @return The detected capacity in bytes, or Unavailable.
   function L1_Data_Cache_Size (Class : Core_Class := Fastest_Core_Class) return Cache_Query_Result;

   --  Return the number of destructive-interference-sized slots in L1.
   --  These are spacing-policy slots, not physical cache lines.  The count
   --  divides L1_Data_Cache_Size and describes the same core class.
   --  @param Class The core class to describe.
   --  @return The derived slot count, or Unavailable.
   function L1_Data_Cache_Slots (Class : Core_Class := Fastest_Core_Class) return Cache_Query_Result;

   --  Return the L2 cache capacity in bytes for a core class.
   --
   --  L2 is shared between cores on many designs, so this capacity is not
   --  available to one core alone.  Read L2_Sharing_Cores before sizing a
   --  per-core working set against it.
   --  @param Class The core class to describe.
   --  @return The detected capacity in bytes, or Unavailable.
   function L2_Cache_Size (Class : Core_Class := Fastest_Core_Class) return Cache_Query_Result;

   --  Return how many cores share one L2 cache in a core class.
   --
   --  One means each core has its own L2.  A larger count means the capacity
   --  L2_Cache_Size reports is divided among that many cores.
   --  @param Class The core class to describe.
   --  @return The detected core count, or Unavailable.
   function L2_Sharing_Cores (Class : Core_Class := Fastest_Core_Class) return Cache_Query_Result;

   --  Explicitly choose a fallback for an unavailable query result.
   --  @param Result The cache query result to inspect.
   --  @param Fallback The value to return when Result is unavailable.
   --  @return Result.Value when available, otherwise Fallback.
   function Value_Or (Result : Cache_Query_Result; Fallback : Natural) return Natural;

end Flyology_Cachelines;
