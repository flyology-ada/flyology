package Flyology.IO.Connections.Testing is

   type Barrier_Point is
     (After_Registration,
      After_Acquisition,
      Send_Chunk_Boundary,
      Active_Operation_Park,
      Queued_Operation_Park,
      Receive_Chunk_Boundary,
      Stale_Operation_Registration,
      TLS_Session_Installed,
      Admission_Acquired,
      Admission_Wait_Armed,
      Take_Admission_Acquired,
      Accept_Adopted,
      Take_Adopted,
      Raw_Accept_Returned,
      Accept_Socket_Owned,
      Before_HTTP_Client_DNS,
      Before_HTTP_Client_Connect,
      Close_Leadership_Taken,
      Managed_Connect_Connected,
      Managed_Connect_Child_Started,
      Managed_Connect_Child_Detached,
      Raw_Scoped_Connect_Armed,
      Deferred_Close_Published,
      Cleanup_Dispatch_Entered,
      Wake_Preparation_Claimed);

   --  Return the number of operations queued for Item's exclusive lease.
   --  This child is a smoke-test source and is not part of libFlyology.
   function Waiting_Operations (Item : Connection) return Natural;

   function Operation_Active (Item : Connection) return Boolean;

   function Close_Requested (Item : Connection) return Boolean;

   procedure Reset_Barriers;

   procedure Arm (Point : Barrier_Point);

   procedure Wait_Reached (Point : Barrier_Point);

   procedure Release (Point : Barrier_Point);

   procedure Fail_Next_Release_Wake;

   --  Fail the first attempt to drain a capacity wake after permit transfer.
   --  The gate must preserve the accepted permit and retry on finalization.
   procedure Fail_Next_Drain_Wake;

   --  Fail the first connection-controller wake write after its protected
   --  state transition. The caller's cleanup guard must retry outside it.
   procedure Fail_Next_Controller_Wake;

   --  Restrict each connection receive to at most Maximum bytes and reset the
   --  observed receive-call count. Zero removes the test-only restriction.
   procedure Set_Receive_Cap (Maximum : Natural);

   --  Return connection receive calls since Set_Receive_Cap.
   function Receive_Calls return Natural;

end Flyology.IO.Connections.Testing;
