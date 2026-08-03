private package Flyology.DNS_Test_Observations is

   --  Clear all test-only receive-wait observations.
   procedure Reset;

   --  Record one receive wait and whether its UDP socket was already closed.
   procedure Record_Receive_Wait (After_Close : Boolean);

   --  Return the number of receive waits attempted after UDP closure.
   function Post_Close_Receive_Waits return Natural;

end Flyology.DNS_Test_Observations;
