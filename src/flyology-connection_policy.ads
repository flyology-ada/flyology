--  Internal, proved state decisions for connection admission and lease
--  serialization. Resource ownership and wake-source operations remain in the
--  protected controller that consumes these decisions.
private package Flyology.Connection_Policy
  with Preelaborate,
       SPARK_Mode
is
   type Acquire_Action is
     (Cancel_Lease, Wait_For_Lease, Acquire_Lease);

   function Classify_Acquire
     (Generation_Matches : Boolean;
      Resources_Open     : Boolean;
      Closing            : Boolean;
      Active             : Boolean) return Acquire_Action
   with Post =>
     (if not Generation_Matches or else not Resources_Open or else Closing
      then Classify_Acquire'Result = Cancel_Lease
      elsif Active then Classify_Acquire'Result = Wait_For_Lease
      else Classify_Acquire'Result = Acquire_Lease);

   function Started_After_Register (Started : Natural) return Positive
   with Pre  => Started < Natural'Last,
        Post => Started_After_Register'Result = Started + 1;

   function Started_After_Release (Started : Positive) return Natural
   with Post => Started_After_Release'Result = Started - 1;

   function Should_Wake_Next
     (Active    : Boolean;
      Closing   : Boolean;
      Started   : Natural;
      Signalled : Boolean) return Boolean
   with Post =>
     Should_Wake_Next'Result =
       (not Active and then not Closing and then Started > 0
        and then not Signalled);

   function Close_Leader
     (Descriptor_Open : Boolean;
      Closing         : Boolean) return Boolean
   with Post =>
     Close_Leader'Result = (Descriptor_Open and then not Closing);

   function Close_Wake_Required
     (Leader  : Boolean;
      Started : Natural) return Boolean
   with Post => Close_Wake_Required'Result = (Leader and then Started > 0);

   function Finish_Close_Allowed
     (Closing            : Boolean;
      Active             : Boolean;
      Started            : Natural;
      Generation_Matches : Boolean;
      Resources_Released : Boolean) return Boolean
   with Post =>
     Finish_Close_Allowed'Result =
       (Closing and then not Active and then Started = 0
        and then Generation_Matches and then Resources_Released);

   function Is_Open
     (Descriptor_Open : Boolean;
      Closing         : Boolean) return Boolean
   with Post => Is_Open'Result = (Descriptor_Open and then not Closing);

   function Waiting_Operations
     (Started : Natural;
      Active  : Boolean) return Natural
   with Pre  => not Active or else Started > 0,
        Post => Waiting_Operations'Result =
          (if Active then Started - 1 else Started);
end Flyology.Connection_Policy;
