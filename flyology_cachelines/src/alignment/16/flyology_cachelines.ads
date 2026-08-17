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
   Destructive_Interference_Size : constant Positive := 16;

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

   --  Return the physical cache-line size reported by the host OS.
   --  @return The detected size in bytes, or Unavailable.
   function Hardware_Cache_Line_Size return Cache_Query_Result;

   --  Return the L1 data-cache capacity in bytes.
   --
   --  A host whose cores are not identical has no single L1 data-cache
   --  capacity, so the result describes one core type.  macOS reports the
   --  highest-performing core type: an Apple silicon host reports its
   --  performance-core capacity, not the smaller efficiency-core capacity.
   --  Linux reports the cache that its own query mechanism describes, which
   --  is normally the cache of CPU 0.
   --  @return The detected capacity in bytes, or Unavailable.
   function L1_Data_Cache_Size return Cache_Query_Result;

   --  Return the number of destructive-interference-sized slots in L1.
   --  These are spacing-policy slots, not physical cache lines.  The count
   --  divides L1_Data_Cache_Size and therefore describes the same core type.
   --  @return The derived slot count, or Unavailable.
   function L1_Data_Cache_Slots return Cache_Query_Result;

   --  Explicitly choose a fallback for an unavailable query result.
   --  @param Result The cache query result to inspect.
   --  @param Fallback The value to return when Result is unavailable.
   --  @return Result.Value when available, otherwise Fallback.
   function Value_Or
     (Result   : Cache_Query_Result;
      Fallback : Natural) return Natural;

end Flyology_Cachelines;
