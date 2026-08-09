package body Flyology.TLS_Test_Hooks
  with SPARK_Mode => On,
       Refined_State =>
         (Barrier_State => (Armed_Flags, Reached_Flags, Released_Flags))
is
   subtype Barrier_Index is Integer range 0 .. Barrier_Count - 1;

   type Barrier_Flags is array (Barrier_Index) of Boolean
     with Atomic_Components;

   Armed_Flags : Barrier_Flags := (others => False)
     with Async_Readers, Async_Writers;
   Reached_Flags : Barrier_Flags := (others => False)
     with Async_Readers, Async_Writers;
   Released_Flags : Barrier_Flags := (others => False)
     with Async_Readers, Async_Writers;

   function Valid_Point (Point : Integer) return Boolean is
     (Point >= 0 and then Point < Barrier_Count);

   procedure Reset is
   begin
      for Point in Barrier_Index loop
         Armed_Flags (Point) := False;
         Reached_Flags (Point) := False;
         Released_Flags (Point) := True;
      end loop;
   end Reset;

   procedure Arm (Point : Integer) is
   begin
      if not Valid_Point (Point) then
         return;
      end if;
      Reached_Flags (Point) := False;
      Released_Flags (Point) := False;
      Armed_Flags (Point) := True;
   end Arm;

   procedure Arrive (Point : Integer; Did_Arrive : out Boolean) is
   begin
      if not Valid_Point (Point) then
         Did_Arrive := False;
         return;
      end if;

      declare
         Is_Armed : constant Boolean := Armed_Flags (Point);
      begin
         if not Is_Armed then
            Did_Arrive := False;
            return;
         end if;
      end;

      Reached_Flags (Point) := True;
      Did_Arrive := True;
   end Arrive;

   function Reached (Point : Integer) return Boolean is
   begin
      if not Valid_Point (Point) then
         return False;
      end if;

      declare
         Has_Reached : constant Boolean := Reached_Flags (Point);
      begin
         return Has_Reached;
      end;
   end Reached;

   function Released (Point : Integer) return Boolean is
   begin
      if not Valid_Point (Point) then
         return True;
      end if;

      declare
         Is_Released : constant Boolean := Released_Flags (Point);
      begin
         return Is_Released;
      end;
   end Released;

   procedure Release (Point : Integer) is
   begin
      if not Valid_Point (Point) then
         return;
      end if;
      Released_Flags (Point) := True;
      Armed_Flags (Point) := False;
   end Release;
end Flyology.TLS_Test_Hooks;
