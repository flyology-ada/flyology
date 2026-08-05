package body Flyology.HTTP.Server.Middleware_Rate_Limits is
   use type Ada.Real_Time.Time;

   Max_Route_Length : constant := 128;
   Max_Key_Length   : constant := 64;
   Shard_Count      : constant Positive := Positive'Min (16, Capacity);
   Shard_Capacity   : constant Positive := Capacity / Shard_Count;

   type Bucket_Entry is record
      Used         : Boolean := False;
      Route        : String (1 .. Max_Route_Length) := (others => ' ');
      Route_Length : Natural := 0;
      Key          : String (1 .. Max_Key_Length) := (others => ' ');
      Key_Length   : Natural := 0;
      Tokens       : Duration := 0.0;
      Seen         : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
   end record;
   type Entry_Array is array (Positive range <>) of Bucket_Entry;

   protected type Limiter_Bucket is
      procedure Admit
        (Route   : String;
         Key     : String;
         Rate    : Positive;
         Now     : Ada.Real_Time.Time;
         Allowed : out Boolean);
   private
      Values : Entry_Array (1 .. Shard_Capacity);
   end Limiter_Bucket;

   protected body Limiter_Bucket is
      procedure Admit
        (Route   : String;
         Key     : String;
         Rate    : Positive;
         Now     : Ada.Real_Time.Time;
         Allowed : out Boolean)
      is
         Slot   : Natural := 0;
         Empty  : Natural := 0;
         Oldest : Positive := Values'First;
      begin
         Allowed := False;
         if Route'Length = 0 or else Route'Length > Max_Route_Length
           or else Key'Length = 0 or else Key'Length > Max_Key_Length
         then
            return;
         end if;
         for Index in Values'Range loop
            if Values (Index).Used
              and then Values (Index).Route_Length = Route'Length
              and then Values (Index).Key_Length = Key'Length
              and then Values (Index).Route (1 .. Route'Length) = Route
              and then Values (Index).Key (1 .. Key'Length) = Key
            then
               Slot := Index;
               exit;
            elsif not Values (Index).Used and then Empty = 0 then
               Empty := Index;
            elsif Values (Index).Used
              and then Values (Index).Seen < Values (Oldest).Seen
            then
               Oldest := Index;
            end if;
         end loop;
         if Slot = 0 then
            Slot := (if Empty > 0 then Empty else Oldest);
            Values (Slot).Used := True;
            Values (Slot).Route_Length := Route'Length;
            Values (Slot).Key_Length := Key'Length;
            Values (Slot).Route (1 .. Route'Length) := Route;
            Values (Slot).Key (1 .. Key'Length) := Key;
            Values (Slot).Tokens := Duration (Rate);
            Values (Slot).Seen := Now;
         else
            declare
               Elapsed : constant Duration :=
                 Duration'Max
                   (0.0, Ada.Real_Time.To_Duration
                      (Now - Values (Slot).Seen));
            begin
               if Elapsed >= 1.0 then
                  Values (Slot).Tokens := Duration (Rate);
               else
                  Values (Slot).Tokens := Duration'Min
                    (Duration (Rate),
                     Values (Slot).Tokens + Elapsed * Rate);
               end if;
               Values (Slot).Seen := Now;
            end;
         end if;
         if Values (Slot).Tokens >= 1.0 then
            Values (Slot).Tokens := Values (Slot).Tokens - 1.0;
            Allowed := True;
         end if;
      end Admit;
   end Limiter_Bucket;

   type Limiter_Array is
     array (Positive range 1 .. Shard_Count) of Limiter_Bucket;
   Limiters : Limiter_Array;

   function Shard (Route, Key : String) return Positive is
      type Hash_Value is mod 2 ** 32;
      Value : Hash_Value := 2_166_136_261;
   begin
      for Item of Route loop
         Value :=
           (Value xor Hash_Value (Character'Pos (Item))) * 16_777_619;
      end loop;
      for Item of Key loop
         Value :=
           (Value xor Hash_Value (Character'Pos (Item))) * 16_777_619;
      end loop;
      return Natural (Value mod Hash_Value (Shard_Count)) + 1;
   end Shard;

   procedure Count_Denial is
   begin
      if Metric_Output /= null then
         Metrics.Count (Metric_Output.all, Metrics.Rate_Limit_Denial);
      end if;
   exception
      when others => null;
   end Count_Denial;

   procedure Call
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange;
      Next    : in out Components.Next_Handler)
   is
      Rate    : constant Natural := X.Rate_Per_Second;
      Allowed : Boolean;
   begin
      if Rate = 0 then
         Next.Call (Context, X);
         return;
      end if;
      declare
         Route : constant String := X.Route_Name;
         Key   : constant String := Client_Key (X);
      begin
         Limiters (Shard (Route, Key)).Admit
           (Route, Key, Rate, Clock, Allowed);
      end;
      if not Allowed then
         Count_Denial;
         X.Add_Header ("Retry-After", "1");
         X.Problem (429, "rate-limit-exceeded", "Request rate is exceeded");
         return;
      end if;
      Next.Call (Context, X);
   end Call;

end Flyology.HTTP.Server.Middleware_Rate_Limits;
