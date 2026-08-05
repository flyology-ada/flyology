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
      Admission_Wait_Armed);

   --  Return the number of operations queued for Item's exclusive lease.
   --  This child is a smoke-test source and is not part of libFlyology.
   function Waiting_Operations (Item : Connection) return Natural;

   function Operation_Active (Item : Connection) return Boolean;

   function Close_Requested (Item : Connection) return Boolean;

   procedure Reset_Barriers;

   procedure Arm (Point : Barrier_Point);

   procedure Wait_Reached (Point : Barrier_Point);

   procedure Release (Point : Barrier_Point);

end Flyology.IO.Connections.Testing;
