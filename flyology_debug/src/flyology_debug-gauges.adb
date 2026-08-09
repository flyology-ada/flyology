--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

package body Flyology_Debug.Gauges is
   protected type Gauge_Slot is
      procedure Set_State
        (Timestamp : Flyology_Debug.Timestamp; Value : Gauge_Value_Type);
      procedure Read_State (Result : out Gauge_Record);
      procedure Clear_State;
   private
      Current : Gauge_Record;
   end Gauge_Slot;

   protected body Gauge_Slot is
      procedure Set_State
        (Timestamp : Flyology_Debug.Timestamp; Value : Gauge_Value_Type)
      is
      begin
         Current :=
           (Is_Set => True, Timestamp => Timestamp, Value => Value);
      end Set_State;

      procedure Read_State (Result : out Gauge_Record) is
      begin
         Result := Current;
      end Read_State;

      procedure Clear_State is
      begin
         Current.Is_Set := False;
      end Clear_State;
   end Gauge_Slot;

   type Slot_Array is array (Gauge_Kind) of Gauge_Slot;

   Slots : Slot_Array;

   procedure Set (Gauge : Gauge_Kind; Value : Gauge_Value_Type) is
   begin
      Slots (Gauge).Set_State (Now, Value);
   end Set;

   procedure Read (Result : out Snapshot) is
   begin
      for Gauge in Gauge_Kind loop
         Slots (Gauge).Read_State (Result.Values (Gauge));
      end loop;
   end Read;

   procedure Clear is
   begin
      for Gauge in Gauge_Kind loop
         Slots (Gauge).Clear_State;
      end loop;
   end Clear;

   function Is_Set
     (Result : Snapshot; Gauge : Gauge_Kind) return Boolean
   is (Result.Values (Gauge).Is_Set);

   function Value_Of
     (Result : Snapshot; Gauge : Gauge_Kind) return Gauge_Value_Type
   is
   begin
      if not Result.Values (Gauge).Is_Set then
         raise Constraint_Error with "gauge is not set in snapshot";
      end if;
      return Result.Values (Gauge).Value;
   end Value_Of;

   function Timestamp_Of
     (Result : Snapshot; Gauge : Gauge_Kind) return Timestamp
   is
   begin
      if not Result.Values (Gauge).Is_Set then
         raise Constraint_Error with "gauge is not set in snapshot";
      end if;
      return Result.Values (Gauge).Timestamp;
   end Timestamp_Of;
end Flyology_Debug.Gauges;
