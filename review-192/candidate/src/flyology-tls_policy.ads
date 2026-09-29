--  Internal, proved state and buffer-progress decisions for the TLS
--  controller. Provider calls, readiness waits, and resource destruction stay
--  in the non-SPARK orchestration package that consumes these decisions.
with Ada.Streams;

private package Flyology.TLS_Policy
  with Preelaborate, SPARK_Mode
is
   use type Ada.Streams.Stream_Element_Offset;

   subtype Offset is Ada.Streams.Stream_Element_Offset;

   type Acquire_Action is (Acquire_Operation, Reject_Closing, Reject_Closed, Reject_Replaced);

   --  Admission decision for a socket handed to a TLS connection. Every
   --  rejection is decided before the transfer touches provider or connection
   --  state, so a refused transfer leaves the caller's socket untouched.
   type Take_Action is
     (Transfer_Ownership,
      Reject_Closed_Socket,
      Reject_Retained_Socket,
      Reject_Missing_Server_Name,
      Reject_Unexpected_Server_Name,
      Reject_Unavailable_Provider);

   function Classify_Take
     (Socket_Open        : Boolean;
      Connection_Retains : Boolean;
      Client_Side        : Boolean;
      Server_Name_Given  : Boolean;
      Provider_Available : Boolean) return Take_Action
   with
     Post =>
       (if not Socket_Open
        then Classify_Take'Result = Reject_Closed_Socket
        elsif Connection_Retains
        then Classify_Take'Result = Reject_Retained_Socket
        elsif Client_Side and then not Server_Name_Given
        then Classify_Take'Result = Reject_Missing_Server_Name
        elsif not Client_Side and then Server_Name_Given
        then Classify_Take'Result = Reject_Unexpected_Server_Name
        elsif not Provider_Available
        then Classify_Take'Result = Reject_Unavailable_Provider
        else Classify_Take'Result = Transfer_Ownership)
       --  A transfer starts only from a socket that owns a descriptor and a
       --  connection that retains none, which is what makes the transfer's
       --  socket move unable to fail.
       and then (if Classify_Take'Result = Transfer_Ownership
                 then Socket_Open and then not Connection_Retains);

   function Classify_Acquire
     (Generation_Matches : Boolean; Closing : Boolean; Descriptor_Open : Boolean) return Acquire_Action
   with
     Post =>
       (if not Generation_Matches
        then Classify_Acquire'Result = Reject_Replaced
        elsif Closing
        then Classify_Acquire'Result = Reject_Closing
        elsif not Descriptor_Open
        then Classify_Acquire'Result = Reject_Closed
        else Classify_Acquire'Result = Acquire_Operation);

   function Close_Leader (Descriptor_Open : Boolean; Closing : Boolean) return Boolean
   with Post => Close_Leader'Result = (Descriptor_Open and then not Closing);

   function Finish_Close_Allowed
     (Closing : Boolean; Active : Boolean; Generation_Matches : Boolean) return Boolean
   with Post => Finish_Close_Allowed'Result = (Closing and then not Active and then Generation_Matches);

   function Is_Open (Descriptor_Open : Boolean; Closing : Boolean) return Boolean
   with Post => Is_Open'Result = (Descriptor_Open and then not Closing);

   type Sentinel_Choice is record
      Available : Boolean := False;
      Value     : Offset := Offset'First;
   end record;

   function Invalid_Progress_Sentinel (First : Offset; Last : Offset) return Sentinel_Choice
   with
     Pre  => First <= Last,
     Post =>
       Invalid_Progress_Sentinel'Result.Available = (First > Offset'First or else Last < Offset'Last)
       and then (if Invalid_Progress_Sentinel'Result.Available
                 then
                   Invalid_Progress_Sentinel'Result.Value < First
                   or else Invalid_Progress_Sentinel'Result.Value > Last);

   function Complete_Progress_Valid (First : Offset; Last : Offset; Reported : Offset) return Boolean
   with
     Pre  => First <= Last,
     Post => Complete_Progress_Valid'Result = (Reported >= First and then Reported <= Last);

   function Progress_Preserved (Before : Offset; After : Offset) return Boolean
   with Post => Progress_Preserved'Result = (After = Before);

   function Next_Offset (Position : Offset) return Offset
   with Pre => Position < Offset'Last, Post => Next_Offset'Result = Position + 1;
end Flyology.TLS_Policy;
