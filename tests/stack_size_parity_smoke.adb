with Ada.Streams;
with GNAT.Sockets;
with Gnatevl;
with Gnatevl.IO.Sockets;

procedure Stack_Size_Parity_Smoke is
   use Ada.Streams;

   Tasks_Per_Lane : constant := 32;
   Task_Count     : constant := Tasks_Per_Lane * 2;
   Small_Stack    : constant := 16 * 1_024;
   One_Byte       : constant Stream_Element_Array := [1 => 42];

   type Socket_Array is
     array (Positive range <>) of GNAT.Sockets.Socket_Type;
   Servers : Socket_Array (1 .. Task_Count);
   Peers   : Socket_Array (1 .. Task_Count);

   protected State is
      procedure Started;
      procedure Finished (Index : Positive; Passed : Boolean);
      entry Wait_Started;
      entry Wait_Finished;
      function Passed return Boolean;
      function First_Failure return Natural;
   private
      Started_Count  : Natural := 0;
      Finished_Count : Natural := 0;
      All_OK         : Boolean := True;
      Failed_Index   : Natural := 0;
   end State;

   protected body State is
      procedure Started is
      begin
         Started_Count := Started_Count + 1;
      end Started;

      procedure Finished (Index : Positive; Passed : Boolean) is
      begin
         Finished_Count := Finished_Count + 1;
         All_OK := All_OK and Passed;
         if not Passed and then Failed_Index = 0 then
            Failed_Index := Index;
         end if;
      end Finished;

      entry Wait_Started when Started_Count = Task_Count is
      begin
         null;
      end Wait_Started;

      entry Wait_Finished when Finished_Count = Task_Count is
      begin
         null;
      end Wait_Finished;

      function Passed return Boolean is (All_OK);
      function First_Failure return Natural is (Failed_Index);
   end State;

begin
   for Index in Servers'Range loop
      GNAT.Sockets.Create_Socket_Pair (Servers (Index), Peers (Index));
   end loop;

   declare
      task type Worker
        (Index : Positive;
         Model : Gnatevl.Execution_Model)
      is
         pragma Task_Info (Model);
         pragma Storage_Size (Small_Stack);
      end Worker;

      task body Worker is
         Incoming : Stream_Element_Array (One_Byte'Range);
         Success  : Boolean := False;
      begin
         State.Started;
         Gnatevl.IO.Sockets.Receive_Exactly
           (Servers (Index), Incoming, Timeout => 5.0);
         Success := Incoming = One_Byte;
         State.Finished (Index, Success);
      exception
         when others =>
            State.Finished (Index, False);
      end Worker;

      type Worker_Access is access Worker;
      type Worker_Array is array (Positive range <>) of Worker_Access;
      Workers : Worker_Array (1 .. Task_Count);
      pragma Unreferenced (Workers);
   begin
      for Index in 1 .. Tasks_Per_Lane loop
         Workers (Index) :=
           new Worker (Index, Gnatevl.Event_Loop_Task);
      end loop;
      for Index in Tasks_Per_Lane + 1 .. Task_Count loop
         Workers (Index) :=
           new Worker (Index, Gnatevl.Native_Thread);
      end loop;

      select
         State.Wait_Started;
      or
         delay 5.0;
         raise Program_Error with "16 KiB task failed before its body";
      end select;

      for Index in Peers'Range loop
         Gnatevl.IO.Sockets.Send_All (Peers (Index), One_Byte, Timeout => 5.0);
      end loop;

      select
         State.Wait_Finished;
      or
         delay 5.0;
         raise Program_Error with "16 KiB task failed to complete";
      end select;

      pragma Assert
        (State.Passed,
         "16 KiB task failed, index=" & State.First_Failure'Image);
   end;

   for Index in Peers'Range loop
      GNAT.Sockets.Close_Socket (Servers (Index));
      GNAT.Sockets.Close_Socket (Peers (Index));
   end loop;
end Stack_Size_Parity_Smoke;
