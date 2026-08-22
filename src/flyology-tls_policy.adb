package body Flyology.TLS_Policy
  with SPARK_Mode
is
   function Classify_Acquire
     (Generation_Matches : Boolean; Closing : Boolean; Descriptor_Open : Boolean) return Acquire_Action
   is (if not Generation_Matches
       then Reject_Replaced
       elsif Closing
       then Reject_Closing
       elsif not Descriptor_Open
       then Reject_Closed
       else Acquire_Operation);

   function Classify_Take
     (Socket_Open        : Boolean;
      Connection_Retains : Boolean;
      Client_Side        : Boolean;
      Server_Name_Given  : Boolean;
      Provider_Available : Boolean) return Take_Action
   is (if not Socket_Open
       then Reject_Closed_Socket
       elsif Connection_Retains
       then Reject_Retained_Socket
       elsif Client_Side and then not Server_Name_Given
       then Reject_Missing_Server_Name
       elsif not Client_Side and then Server_Name_Given
       then Reject_Unexpected_Server_Name
       elsif not Provider_Available
       then Reject_Unavailable_Provider
       else Transfer_Ownership);

   function Close_Leader (Descriptor_Open : Boolean; Closing : Boolean) return Boolean
   is (Descriptor_Open and then not Closing);

   function Finish_Close_Allowed
     (Closing : Boolean; Active : Boolean; Generation_Matches : Boolean) return Boolean
   is (Closing and then not Active and then Generation_Matches);

   function Is_Open (Descriptor_Open : Boolean; Closing : Boolean) return Boolean
   is (Descriptor_Open and then not Closing);

   function Invalid_Progress_Sentinel (First : Offset; Last : Offset) return Sentinel_Choice is
   begin
      if First > Offset'First then
         return (Available => True, Value => First - 1);
      elsif Last < Offset'Last then
         return (Available => True, Value => Last + 1);
      else
         return (Available => False, Value => Offset'First);
      end if;
   end Invalid_Progress_Sentinel;

   function Complete_Progress_Valid (First : Offset; Last : Offset; Reported : Offset) return Boolean
   is (Reported >= First and then Reported <= Last);

   function Progress_Preserved (Before : Offset; After : Offset) return Boolean
   is (After = Before);

   function Next_Offset (Position : Offset) return Offset
   is (Position + 1);
end Flyology.TLS_Policy;
