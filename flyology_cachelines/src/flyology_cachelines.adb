with Flyology_Cachelines.Platform;

package body Flyology_Cachelines is

   --  The host is inspected on first use rather than during elaboration.
   --
   --  Describing every core class means reading one description per CPU on
   --  Linux, which costs tens of milliseconds on a host with many CPUs.  A
   --  program that links this crate and never asks about the host should not
   --  pay that at startup, so the inspection is deferred until a query needs
   --  it and its result is then reused.  Cache geometry is stable for the
   --  life of a process, so one inspection stays correct.
   --
   --  Two tasks racing on the first query is safe without a lock.  Detect
   --  reads only the operating system's stable description of the machine, so
   --  both compute the same value and both store the same bytes; a race can
   --  duplicate the work but cannot produce a value neither task computed.
   --  Ready is atomic and is set after Detected is written, so a task that
   --  observes it set also observes the completed record.
   Detected : Platform.Host_Facts;
   Ready    : Boolean := False with Atomic;

   function Facts return Platform.Host_Facts is
   begin
      if not Ready then
         Detected := Platform.Detect;
         Ready := True;
      end if;

      return Detected;
   end Facts;

   --  A zero field is a value the host did not supply.
   function Reported (Value : Natural) return Cache_Query_Result is
     (if Value = 0 then Unavailable else (Available => True, Value => Value));

   --  Facts for a class the host actually described.  Asking about a class
   --  beyond the reported count is a question the host did not answer, not an
   --  error.
   function Facts_For (Class : Core_Class) return Platform.Class_Facts is
      Host : constant Platform.Host_Facts := Facts;
   begin
      return
        (if Natural (Class) <= Host.Count
         then Host.Classes (Class)
         else (others => 0));
   end Facts_For;

   function Hardware_Cache_Line_Size return Cache_Query_Result is
     (Reported (Facts.Line_Size));

   function Core_Class_Count return Cache_Query_Result is
     (Reported (Facts.Count));

   function Core_Class_Ordering return Class_Ordering is
     (Facts.Ordering);

   function Core_Class_Cores
     (Class : Core_Class := Fastest_Core_Class) return Cache_Query_Result is
     (Reported (Facts_For (Class).Cores));

   function Core_Class_CPUs
     (Class : Core_Class := Fastest_Core_Class) return Cache_Query_Result is
     (Reported (Facts_For (Class).CPUs));

   function L1_Data_Cache_Size
     (Class : Core_Class := Fastest_Core_Class) return Cache_Query_Result is
     (Reported (Facts_For (Class).Total_Size));

   function L2_Cache_Size
     (Class : Core_Class := Fastest_Core_Class) return Cache_Query_Result is
     (Reported (Facts_For (Class).L2_Size));

   function L2_Sharing_Cores
     (Class : Core_Class := Fastest_Core_Class) return Cache_Query_Result is
     (Reported (Facts_For (Class).L2_Sharing_Cores));

   function L1_Data_Cache_Slots
     (Class : Core_Class := Fastest_Core_Class) return Cache_Query_Result
   is
      Size : constant Cache_Query_Result := L1_Data_Cache_Size (Class);
   begin
      return
        (if Size.Available
         then
           (Available => True,
            Value     => Size.Value / Destructive_Interference_Size)
         else Unavailable);
   end L1_Data_Cache_Slots;

   function Value_Or
     (Result   : Cache_Query_Result;
      Fallback : Natural) return Natural is
     (if Result.Available then Result.Value else Fallback);

end Flyology_Cachelines;
