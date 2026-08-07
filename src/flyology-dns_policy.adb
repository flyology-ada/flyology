package body Flyology.DNS_Policy
  with SPARK_Mode => On
is

   function Selected_Endpoint
     (Attempt : Positive; Rotation : Rotation_Offset; Count : Positive)
      return Natural
   is
   begin
      return (Attempt - 1 + Rotation) mod Count;
   end Selected_Endpoint;

   function Receive_Window
     (Attempt_Remaining : Duration;
      Overall_Remaining : Duration;
      Infinite          : Boolean) return Duration
   is
   begin
      if Infinite then
         return Duration'Max (0.0, Attempt_Remaining);
      end if;
      return Duration'Max
        (0.0, Duration'Min (Attempt_Remaining, Overall_Remaining));
   end Receive_Window;

   function Receive_Window_Expired
     (Attempt_Remaining : Duration;
      Overall_Remaining : Duration;
      Infinite          : Boolean) return Boolean
   is
   begin
      return Receive_Window (Attempt_Remaining, Overall_Remaining, Infinite)
        <= 0.0;
   end Receive_Window_Expired;

   function Label_Byte_Is_Usable (Value : Natural) return Boolean is
   begin
      return Value /= Label_Separator;
   end Label_Byte_Is_Usable;

   function Classify_Exhausted
     (Malformed        : Boolean;
      Server_Failed    : Boolean;
      Transport_Failed : Boolean) return Exhausted_Outcome
   is
   begin
      if Malformed then
         return Report_Malformed;
      elsif Server_Failed then
         return Report_Server_Failure;
      elsif Transport_Failed then
         return Report_Transport_Failure;
      end if;
      return Report_Deadline;
   end Classify_Exhausted;

end Flyology.DNS_Policy;
