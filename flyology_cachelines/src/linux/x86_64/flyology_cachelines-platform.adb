with Flyology_Cachelines.Linux;
with Interfaces;
with System.Machine_Code;

package body Flyology_Cachelines.Platform is

   use type Interfaces.Unsigned_32;

   type CPUID_Result is record
      EAX : Interfaces.Unsigned_32;
      EBX : Interfaces.Unsigned_32;
      ECX : Interfaces.Unsigned_32;
      EDX : Interfaces.Unsigned_32;
   end record;

   procedure CPUID
     (Leaf    : Interfaces.Unsigned_32;
      Subleaf : Interfaces.Unsigned_32;
      Result  : out CPUID_Result)
   is
      use System.Machine_Code;
   begin
      Asm
        (Template => "cpuid",
         Outputs  =>
           (Interfaces.Unsigned_32'Asm_Output ("=a", Result.EAX),
            Interfaces.Unsigned_32'Asm_Output ("=b", Result.EBX),
            Interfaces.Unsigned_32'Asm_Output ("=c", Result.ECX),
            Interfaces.Unsigned_32'Asm_Output ("=d", Result.EDX)),
         Inputs   =>
           (Interfaces.Unsigned_32'Asm_Input ("a", Leaf),
            Interfaces.Unsigned_32'Asm_Input ("c", Subleaf)),
         Clobber  => "cc",
         Volatile => True);
   end CPUID;

   function Detect_Intel return Flyology_Cachelines.Linux.Cache_Parameters is
      Info : CPUID_Result;
   begin
      CPUID (0, 0, Info);
      if Info.EAX < 4 then
         return Flyology_Cachelines.Linux.No_Cache_Parameters;
      end if;

      for Index in Interfaces.Unsigned_32 range 0 .. 31 loop
         CPUID (4, Index, Info);
         declare
            Cache_Type  : constant Interfaces.Unsigned_32 :=
              Info.EAX and 16#1F#;
            Cache_Level : constant Interfaces.Unsigned_32 :=
              Interfaces.Shift_Right (Info.EAX, 5) and 16#07#;
         begin
            exit when Cache_Type = 0;
            if Cache_Type = 1 and then Cache_Level = 1 then
               declare
                  Line_Size : constant Positive :=
                    Positive (Natural (Info.EBX and 16#0FFF#) + 1);
                  Partitions : constant Positive :=
                    Positive
                      (Natural
                         (Interfaces.Shift_Right (Info.EBX, 12)
                          and 16#03FF#)
                       + 1);
                  Associativity : constant Positive :=
                    Positive
                      (Natural
                         (Interfaces.Shift_Right (Info.EBX, 22)
                          and 16#03FF#)
                       + 1);
                  Sets : constant Positive := Positive (Natural (Info.ECX) + 1);
               begin
                  return
                    (Available  => True,
                     Line_Size  => Line_Size,
                     Total_Size =>
                       Line_Size * Partitions * Associativity * Sets);
               end;
            end if;
         end;
      end loop;

      return Flyology_Cachelines.Linux.No_Cache_Parameters;
   end Detect_Intel;

   function Detect_AMD return Flyology_Cachelines.Linux.Cache_Parameters is
      Info : CPUID_Result;
   begin
      CPUID (16#8000_0000#, 0, Info);
      if Info.EAX < 16#8000_0005# then
         return Flyology_Cachelines.Linux.No_Cache_Parameters;
      end if;

      CPUID (16#8000_0005#, 0, Info);
      declare
         Line_Size : constant Natural := Natural (Info.ECX and 16#00FF#);
         Size_KiB  : constant Natural :=
           Natural (Interfaces.Shift_Right (Info.ECX, 16) and 16#00FF#);
      begin
         return
           (if Line_Size > 0 and then Size_KiB > 0
            then
              (Available  => True,
               Line_Size  => Line_Size,
               Total_Size => Size_KiB * 1_024)
            else Flyology_Cachelines.Linux.No_Cache_Parameters);
      end;
   end Detect_AMD;

   function Detect_From_CPUID return Flyology_Cachelines.Linux.Cache_Parameters is
      Vendor : CPUID_Result;
   begin
      CPUID (0, 0, Vendor);
      if Vendor.EBX = 16#756E_6547#
        and then Vendor.EDX = 16#4965_6E69#
        and then Vendor.ECX = 16#6C65_746E#
      then
         return Detect_Intel;
      else
         return Detect_AMD;
      end if;
   exception
      --  Malformed or unexpectedly large CPUID fields are a failed query,
      --  not an exception in the public cache-query API.
      when others =>
         return Flyology_Cachelines.Linux.No_Cache_Parameters;
   end Detect_From_CPUID;

   function Detect return Flyology_Cachelines.Linux.Cache_Parameters is
      Result : Flyology_Cachelines.Linux.Cache_Parameters := Detect_From_CPUID;
   begin
      if not Result.Available then
         Result := Flyology_Cachelines.Linux.Detect_From_Sysconf;
      end if;
      if not Result.Available then
         Result := Flyology_Cachelines.Linux.Detect_From_Sysfs;
      end if;
      return Result;
   exception
      when others =>
         return Flyology_Cachelines.Linux.No_Cache_Parameters;
   end Detect;

   Detected_Cache : constant Flyology_Cachelines.Linux.Cache_Parameters := Detect;

   function Hardware_Cache_Line_Size return Cache_Query_Result is
     (if Detected_Cache.Available
      then (Available => True, Value => Detected_Cache.Line_Size)
      else Unavailable);

   function L1_Data_Cache_Size return Cache_Query_Result is
     (if Detected_Cache.Available
      then (Available => True, Value => Detected_Cache.Total_Size)
      else Unavailable);

end Flyology_Cachelines.Platform;
