package body Flyology.Connection_Policy
  with SPARK_Mode
is
   function Classify_Acquire
     (Generation_Matches : Boolean;
      Resources_Open     : Boolean;
      Closing            : Boolean;
      Active             : Boolean) return Acquire_Action
   is
     (if not Generation_Matches or else not Resources_Open or else Closing
      then Cancel_Lease
      elsif Active then Wait_For_Lease
      else Acquire_Lease);

   function Started_After_Register (Started : Natural) return Positive is
     (Started + 1);

   function Started_After_Release (Started : Positive) return Natural is
     (Started - 1);

   function Should_Wake_Next
     (Active    : Boolean;
      Closing   : Boolean;
      Started   : Natural;
      Signalled : Boolean) return Boolean
   is
     (not Active and then not Closing and then Started > 0
      and then not Signalled);

   function Close_Leader
     (Descriptor_Open : Boolean;
      Closing         : Boolean) return Boolean
   is
     (Descriptor_Open and then not Closing);

   function Close_Wake_Required
     (Leader  : Boolean;
      Started : Natural) return Boolean
   is
     (Leader and then Started > 0);

   function Classify_Close
     (Leader          : Boolean;
      Descriptor_Open : Boolean;
      Cleanup_Failed  : Boolean;
      Provider_Failed : Boolean) return Close_Report
   is
     (if not Leader
      then (if Descriptor_Open then Await_Leader else Close_Finished)
      elsif Cleanup_Failed then Raise_Cleanup_Failure
      elsif Provider_Failed then Raise_Provider_Error
      else Close_Finished);

   function Binding_Accepted
     (Bound   : Boolean;
      Matches : Boolean) return Boolean
   is
     (not Bound or else Matches);

   function Finish_Close_Allowed
     (Closing            : Boolean;
      Active             : Boolean;
      Started            : Natural;
      Generation_Matches : Boolean;
      Resources_Released : Boolean) return Boolean
   is
     (Closing and then not Active and then Started = 0
      and then Generation_Matches and then Resources_Released);

   function Is_Open
     (Descriptor_Open : Boolean;
      Closing         : Boolean) return Boolean
   is
     (Descriptor_Open and then not Closing);

   function Waiting_Operations
     (Started : Natural;
      Active  : Boolean) return Natural
   is
     (if Active then Started - 1 else Started);
end Flyology.Connection_Policy;
