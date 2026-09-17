with Ada.Containers.Vectors;
with Ada.Real_Time;

--  Internal bounded history of admitted restart times. Storage is reserved
--  from the configured Burst_Attempts policy before admission opens.
--  @exclude
package Flyology.Supervision_Windows is
   use type Ada.Real_Time.Time;
   use type Ada.Real_Time.Time_Span;
   --  @exclude
   package Time_Vectors is new Ada.Containers.Vectors (Positive, Ada.Real_Time.Time);

   --  @exclude
   --  @field Times Reserved timestamp storage
   --  @field Capacity Configured maximum retained attempts
   --  @field First Oldest retained timestamp index
   --  @field Count Number of retained timestamps
   type History is record
      Times    : Time_Vectors.Vector;
      Capacity : Natural := 0;
      First    : Positive := 1;
      Count    : Natural := 0;
   end record;

   --  @exclude
   --  @param Item History to reserve
   --  @param Limit Configured burst capacity
   procedure Initialize (Item : in out History; Limit : Positive);
   --  @exclude
   --  @param Item History to clear for reuse
   procedure Reset (Item : in out History);

   --  @exclude
   --  @param Item History of admitted attempts
   --  @param Now Time of proposed attempt
   --  @param Window Sliding recovery interval
   --  @param Limit Configured burst capacity
   --  @return Whether another attempt fits in the interval
   function Has_Capacity
     (Item : History; Now : Ada.Real_Time.Time; Window : Ada.Real_Time.Time_Span; Limit : Positive)
      return Boolean
   with Pre => Limit <= Item.Capacity and then Window > Ada.Real_Time.Time_Span_Zero;

   --  @exclude
   --  @param Item History to update
   --  @param Now Time of admitted attempt
   procedure Record_Attempt (Item : in out History; Now : Ada.Real_Time.Time);
end Flyology.Supervision_Windows;
