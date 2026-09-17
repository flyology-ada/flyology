with Ada.Containers.Vectors;
with Ada.Real_Time;

--  Internal bounded history of admitted restart times. Storage is reserved
--  from the configured Burst_Attempts policy before admission opens.

package Flyology.Supervision_Windows is
   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;
   package Time_Vectors is new Ada.Containers.Vectors (Positive, Ada.Real_Time.Time);

   type History is record
      Times    : Time_Vectors.Vector;
      Capacity : Natural := 0;
      First    : Positive := 1;
      Count    : Natural := 0;
   end record;

   procedure Initialize (Item : in out History; Limit : Positive);
   procedure Reset (Item : in out History);

   function Has_Capacity
     (Item : History; Now : Ada.Real_Time.Time; Window : Ada.Real_Time.Time_Span; Limit : Positive)
      return Boolean
   with Pre => Limit <= Item.Capacity and then Window > Ada.Real_Time.Time_Span_Zero;

   procedure Record_Attempt (Item : in out History; Now : Ada.Real_Time.Time);
end Flyology.Supervision_Windows;
