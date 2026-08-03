with Ada.Exceptions;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Streams;
with Ada.Text_IO;
with GNAT.Sockets;
with Flyology;
with Flyology.Cancellation;
with Flyology.Fairness;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.IO.TLS.OpenSSL;
with Flyology.IO.TLS.Testing;
with Interfaces.C;
with TLS_Test_Provider;

procedure TLS_Smoke is
   package TLS renames Flyology.IO.TLS;
   package TLS_Testing renames Flyology.IO.TLS.Testing;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package Sockets renames GNAT.Sockets;

   use Ada.Streams;
   use type Interfaces.C.int;
   use type Interfaces.C.unsigned;
   use type Sockets.Socket_Type;

   Certificate : constant String :=
     "tests/fixtures/tls/server-cert.pem";
   Private_Key : constant String :=
     "tests/fixtures/tls/server-key.pem";
   Library_Directory : constant String :=
     (if Ada.Environment_Variables.Exists ("FLYOLOGY_TEST_OPENSSL_DIR")
      then Ada.Environment_Variables.Value ("FLYOLOGY_TEST_OPENSSL_DIR")
      else "");
   Mismatch_Directory : constant String :=
     (if Ada.Environment_Variables.Exists
           ("FLYOLOGY_TEST_OPENSSL_MISMATCH_DIR")
      then Ada.Environment_Variables.Value
        ("FLYOLOGY_TEST_OPENSSL_MISMATCH_DIR")
      else "");

   function Set_Abortive_Close (FD : Interfaces.C.int) return Interfaces.C.int;
   pragma Import
     (C, Set_Abortive_Close, "flyology_test_set_abortive_close");

   function Live_OpenSSL_Modules return Interfaces.C.unsigned;
   pragma Import
     (C, Live_OpenSSL_Modules, "flyology_tls_openssl_live_modules");

   Client_Backend : OpenSSL.OpenSSL_Provider;
   Server_Backend : OpenSSL.OpenSSL_Provider;

   protected type Outcome is
      procedure Report (Passed : Boolean);
      entry Wait;
      function Passed return Boolean;
   private
      Count : Natural := 0;
      OK    : Boolean := True;
   end Outcome;

   protected body Outcome is
      procedure Report (Passed : Boolean) is
      begin
         Count := Count + 1;
         OK := OK and Passed;
      end Report;

      entry Wait when Count = 2 is
      begin
         null;
      end Wait;

      function Passed return Boolean is (OK);
   end Outcome;

   procedure Run_Exchange (Model : Flyology.Execution_Model) is
      Client_Socket : Sockets.Socket_Type;
      Server_Socket : Sockets.Socket_Type;
      Client        : TLS.Connection;
      Server        : TLS.Connection;
      Result        : Outcome;
      Payload       : Stream_Element_Array (1 .. 262_144);
      Reply         : constant Stream_Element_Array := [16#FA#, 1, 2, 3];
   begin
      for Index in Payload'Range loop
         Payload (Index) := Stream_Element (Index mod 251);
      end loop;
      Sockets.Create_Socket_Pair (Client_Socket, Server_Socket);
      TLS.Take
        (Client_Backend, Client_Socket, TLS.Client, "localhost", Client);
      TLS.Take (Server_Backend, Server_Socket, TLS.Server, "", Server);
      pragma Assert (Client_Socket = Sockets.No_Socket);
      pragma Assert (Server_Socket = Sockets.No_Socket);

      declare
         task Client_Task is
            pragma Task_Info (Model);
         end Client_Task;

         task Server_Task is
            pragma Task_Info (Model);
         end Server_Task;

         task body Client_Task is
            Received : Stream_Element_Array (Reply'Range);
            EOF_Data : Stream_Element_Array (7 .. 7);
            EOF_Last : Stream_Element_Offset;
            Passed   : Boolean := False;
         begin
            TLS.Handshake (Client, Timeout => 5.0);
            TLS.Send_All (Client, Payload, Timeout => 5.0);
            TLS.Receive_Exactly (Client, Received, Timeout => 5.0);
            Passed := Received = Reply;
            TLS.Shutdown (Client, Timeout => 5.0);
            TLS.Receive (Client, EOF_Data, EOF_Last, Timeout => 0.0);
            Passed := Passed and EOF_Last = EOF_Data'First - 1;
            Result.Report (Passed);
         exception
            when Error : others =>
               Ada.Text_IO.Put_Line
                 (Ada.Exceptions.Exception_Information (Error));
               Result.Report (False);
         end Client_Task;

         task body Server_Task is
            Received : Stream_Element_Array (Payload'Range);
            Passed   : Boolean := False;
         begin
            TLS.Handshake (Server, Timeout => 5.0);
            TLS.Receive_Exactly (Server, Received, Timeout => 5.0);
            Passed := Received = Payload;
            TLS.Send_All (Server, Reply, Timeout => 5.0);
            TLS.Shutdown (Server, Timeout => 5.0);
            Result.Report (Passed);
         exception
            when Error : others =>
               Ada.Text_IO.Put_Line
                 (Ada.Exceptions.Exception_Information (Error));
               Result.Report (False);
         end Server_Task;
      begin
         Result.Wait;
      end;

      pragma Assert (Result.Passed);
      TLS.Close (Client);
      TLS.Close (Server);
   end Run_Exchange;

   procedure Run_Timeout (Model : Flyology.Execution_Model) is
      Client_Socket : Sockets.Socket_Type;
      Silent_Peer   : Sockets.Socket_Type;
      Client        : TLS.Connection;
      Result        : Outcome;
   begin
      Sockets.Create_Socket_Pair (Client_Socket, Silent_Peer);
      TLS.Take
        (Client_Backend, Client_Socket, TLS.Client, "localhost", Client);
      declare
         task Timer is
            pragma Task_Info (Model);
         end Timer;

         task Reporter is
            pragma Task_Info (Flyology.Native_Task);
         end Reporter;

         task body Timer is
            Timed_Out : Boolean := False;
         begin
            begin
               TLS.Handshake (Client, Timeout => 0.050);
            exception
               when Flyology.IO.Timeout_Error =>
                  Timed_Out := True;
            end;
            Result.Report (Timed_Out);
         exception
            when others =>
               Result.Report (False);
         end Timer;

         task body Reporter is
         begin
            Result.Report (True);
         end Reporter;
      begin
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
      TLS.Close (Client);
      Sockets.Close_Socket (Silent_Peer);
   end Run_Timeout;

   procedure Run_Cancellation (Model : Flyology.Execution_Model) is
      Client_Socket : Sockets.Socket_Type;
      Silent_Peer   : Sockets.Socket_Type;
      Client        : TLS.Connection;
      Token         : aliased Flyology.Cancellation.Token;

      protected Progress is
         procedure Started;
         procedure Finished (Passed : Boolean);
         entry Wait_Started;
         entry Wait_Finished;
         function Passed return Boolean;
      private
         Has_Started  : Boolean := False;
         Has_Finished : Boolean := False;
         Is_OK        : Boolean := False;
      end Progress;

      protected body Progress is
         procedure Started is
         begin
            Has_Started := True;
         end Started;
         procedure Finished (Passed : Boolean) is
         begin
            Is_OK := Passed;
            Has_Finished := True;
         end Finished;
         entry Wait_Started when Has_Started is
         begin
            null;
         end Wait_Started;
         entry Wait_Finished when Has_Finished is
         begin
            null;
         end Wait_Finished;
         function Passed return Boolean is (Is_OK);
      end Progress;
   begin
      Sockets.Create_Socket_Pair (Client_Socket, Silent_Peer);
      TLS.Take
        (Client_Backend, Client_Socket, TLS.Client, "localhost", Client);
      declare
         task Waiter is
            pragma Task_Info (Model);
         end Waiter;

         task body Waiter is
            Cancelled : Boolean := False;
         begin
            Progress.Started;
            begin
               TLS.Handshake (Client, Token => Token'Access);
            exception
               when TLS.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Progress.Finished (Cancelled);
         exception
            when others =>
               Progress.Finished (False);
         end Waiter;
      begin
         Progress.Wait_Started;
         delay 0.050;
         Token.Request;
         Progress.Wait_Finished;
      end;
      pragma Assert (Progress.Passed);
      TLS.Close (Client);
      Sockets.Close_Socket (Silent_Peer);
   end Run_Cancellation;

   procedure Run_Peer_Failure (Model : Flyology.Execution_Model) is
      Client_Socket : Sockets.Socket_Type;
      Server_Socket : Sockets.Socket_Type;
      Client        : TLS.Connection;
      Server        : TLS.Connection;
      Result        : Outcome;
   begin
      Sockets.Create_Socket_Pair (Client_Socket, Server_Socket);
      pragma Assert
        (Set_Abortive_Close
           (Interfaces.C.int
              (Flyology.IO.Sockets.Native_Descriptor (Server_Socket))) = 0);
      TLS.Take
        (Client_Backend, Client_Socket, TLS.Client, "localhost", Client);
      TLS.Take (Server_Backend, Server_Socket, TLS.Server, "", Server);
      declare
         task Client_Task is
            pragma Task_Info (Model);
         end Client_Task;
         task Server_Task is
            pragma Task_Info (Model);
         end Server_Task;

         task body Client_Task is
            Data   : Stream_Element_Array (1 .. 1);
            Last   : Stream_Element_Offset;
            Failed : Boolean := False;
         begin
            TLS.Handshake (Client, Timeout => 5.0);
            begin
               TLS.Receive (Client, Data, Last, Timeout => 5.0);
            exception
               when TLS.TLS_Error =>
                  Failed := True;
            end;
            Result.Report (Failed);
         exception
            when others =>
               Result.Report (False);
         end Client_Task;

         task body Server_Task is
         begin
            TLS.Handshake (Server, Timeout => 5.0);
            TLS.Close (Server);
            Result.Report (True);
         exception
            when others =>
               Result.Report (False);
         end Server_Task;
      begin
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
      TLS.Close (Client);
   end Run_Peer_Failure;

   procedure Run_Hostname_Rejection is
      Client_Socket : Sockets.Socket_Type;
      Server_Socket : Sockets.Socket_Type;
      Client        : TLS.Connection;
      Server        : TLS.Connection;
      Result        : Outcome;
   begin
      Sockets.Create_Socket_Pair (Client_Socket, Server_Socket);
      TLS.Take
        (Client_Backend, Client_Socket, TLS.Client, "not-localhost", Client);
      TLS.Take (Server_Backend, Server_Socket, TLS.Server, "", Server);
      declare
         task Client_Task is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Client_Task;
         task Server_Task is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Server_Task;

         task body Client_Task is
            Rejected : Boolean := False;
         begin
            begin
               TLS.Handshake (Client, Timeout => 5.0);
            exception
               when TLS.TLS_Error =>
                  Rejected := True;
            end;
            Result.Report (Rejected);
         exception
            when others =>
               Result.Report (False);
         end Client_Task;

         task body Server_Task is
         begin
            begin
               TLS.Handshake (Server, Timeout => 5.0);
            exception
               when TLS.TLS_Error =>
                  null;
            end;
            Result.Report (True);
         exception
            when others =>
               Result.Report (False);
         end Server_Task;
      begin
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
      TLS.Close (Client);
      TLS.Close (Server);
   end Run_Hostname_Rejection;

   procedure Run_Provider_Selection is
      Backend : TLS_Test_Provider.Provider;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Item    : TLS.Connection;
      Input   : constant Stream_Element_Array := [1, 2, 3];
      Output  : Stream_Element_Array (1 .. 3);
      Ready   : constant Stream_Element_Array := [1];
      Sent    : Stream_Element_Offset;
      Wants   : Natural;
      Partial : Natural;
   begin
      TLS_Test_Provider.Reset_Telemetry;
      Sockets.Create_Socket_Pair (Socket, Peer);
      TLS.Take (Backend, Socket, TLS.Server, "", Item);
      pragma Assert (Socket = Sockets.No_Socket);
      Sockets.Send_Socket (Peer, Ready, Sent);
      pragma Assert (Sent = Ready'Last);
      TLS.Handshake (Item, Timeout => 1.0);
      TLS.Send_All (Item, Input, Timeout => 1.0);
      TLS.Receive_Exactly (Item, Output, Timeout => 1.0);
      pragma Assert (Output = [42, 42, 42]);
      TLS.Shutdown (Item, Timeout => 1.0);
      TLS_Test_Provider.Get_Telemetry (Wants, Partial);
      pragma Assert (Wants = 4);
      pragma Assert (Partial >= 2);
      TLS.Close (Item);
      Sockets.Close_Socket (Peer);
   end Run_Provider_Selection;

   procedure Run_Provider_Result_Validation is
   begin
      for Behavior in
        TLS_Test_Provider.Invalid_Lower .. TLS_Test_Provider.Invalid_Upper
      loop
         declare
            Backend : TLS_Test_Provider.Provider;
            Socket  : Sockets.Socket_Type;
            Peer    : Sockets.Socket_Type;
            Item    : TLS.Connection;
            Buffer  : Stream_Element_Array (3 .. 3);
            Last    : Stream_Element_Offset;
            Ready   : constant Stream_Element_Array := [1];
            Sent    : Stream_Element_Offset;
            Failed  : Boolean := False;
         begin
            TLS_Test_Provider.Set_Receive_Behavior (Backend, Behavior);
            Sockets.Create_Socket_Pair (Socket, Peer);
            TLS.Take (Backend, Socket, TLS.Server, "", Item);
            Sockets.Send_Socket (Peer, Ready, Sent);
            begin
               TLS.Receive (Item, Buffer, Last, Timeout => 1.0);
            exception
               when TLS.TLS_Error =>
                  Failed := True;
            end;
            pragma Assert (Failed);
            TLS.Close (Item);
            Sockets.Close_Socket (Peer);
         end;
      end loop;

      declare
         Backend : TLS_Test_Provider.Provider;
         Socket  : Sockets.Socket_Type;
         Peer    : Sockets.Socket_Type;
         Item    : TLS.Connection;
         Buffer  : Stream_Element_Array (7 .. 7);
         Last    : Stream_Element_Offset;
         Ready   : constant Stream_Element_Array := [1];
         Sent    : Stream_Element_Offset;
      begin
         TLS_Test_Provider.Set_Receive_Behavior
           (Backend, TLS_Test_Provider.Orderly_EOF);
         Sockets.Create_Socket_Pair (Socket, Peer);
         TLS.Take (Backend, Socket, TLS.Server, "", Item);
         Sockets.Send_Socket (Peer, Ready, Sent);
         TLS.Receive (Item, Buffer, Last, Timeout => 1.0);
         pragma Assert (Last = Buffer'First - 1);
         TLS.Close (Item);
         Sockets.Close_Socket (Peer);
      end;
   end Run_Provider_Result_Validation;

   procedure Run_Close_Finalization_Fault is
      Backend : TLS_Test_Provider.Provider;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Item    : TLS.Connection;
      Failed  : Boolean := False;
   begin
      TLS_Test_Provider.Set_Finalize_Failure (Backend);
      Sockets.Create_Socket_Pair (Socket, Peer);
      TLS.Take (Backend, Socket, TLS.Server, "", Item);
      begin
         TLS.Close (Item);
      exception
         when TLS.TLS_Error =>
            Failed := True;
      end;
      pragma Assert (Failed);
      pragma Assert (not TLS.Is_Open (Item));
      TLS.Close (Item);
      Sockets.Close_Socket (Peer);
   end Run_Close_Finalization_Fault;

   procedure Run_Loader_Error is
      Baseline : constant Interfaces.C.unsigned := Live_OpenSSL_Modules;
   begin
      for Attempt in 1 .. 16 loop
         declare
            Backend : OpenSSL.OpenSSL_Provider;
            Failed  : Boolean := False;
         begin
            begin
               OpenSSL.Initialize_Client
                 (Backend,
                  Library_Directory =>
                    "/flyology-test-path-that-does-not-contain-openssl");
            exception
               when TLS.TLS_Error =>
                  Failed := True;
            end;
            pragma Assert (Failed);
            pragma Assert (not OpenSSL.Is_Available (Backend));
            pragma Assert (Live_OpenSSL_Modules = Baseline);
         end;
      end loop;

      declare
         Backend : OpenSSL.OpenSSL_Provider;
         Failed  : Boolean := False;
      begin
         begin
            OpenSSL.Initialize_Client
              (Backend,
               CA_File           => "/flyology-test-missing-ca.pem",
               Library_Directory => Library_Directory);
         exception
            when TLS.TLS_Error =>
               Failed := True;
         end;
         pragma Assert (Failed);
         pragma Assert (Live_OpenSSL_Modules = Baseline);
      end;

      if Mismatch_Directory'Length > 0 then
         declare
            Backend : OpenSSL.OpenSSL_Provider;
            Rejected : Boolean := False;
         begin
            begin
               OpenSSL.Initialize_Client
                 (Backend, Library_Directory => Mismatch_Directory);
            exception
               when Error : TLS.TLS_Error =>
                  Rejected := Ada.Strings.Fixed.Index
                    (Ada.Exceptions.Exception_Message (Error), "matched") > 0;
            end;
            pragma Assert (Rejected);
            pragma Assert (Live_OpenSSL_Modules = Baseline);
         end;
      end if;

      declare
         Backend : OpenSSL.OpenSSL_Provider;
         Rejected : Boolean := False;
      begin
         begin
            OpenSSL.Initialize_Client
              (Backend, CA_File => "bad" & Character'Val (0) & "path");
         exception
            when Program_Error =>
               Rejected := True;
         end;
         pragma Assert (Rejected);
         pragma Assert (Live_OpenSSL_Modules = Baseline);
      end;
   end Run_Loader_Error;

   procedure Run_Pre_Cancelled (Model : Flyology.Execution_Model) is
      Socket : Sockets.Socket_Type;
      Peer   : Sockets.Socket_Type;
      Item   : TLS.Connection;
      Token  : aliased Flyology.Cancellation.Token;
      Result : Outcome;
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      TLS.Take (Client_Backend, Socket, TLS.Client, "localhost", Item);
      Token.Request;
      declare
         task Caller is
            pragma Task_Info (Model);
         end Caller;
         task Reporter is
            pragma Task_Info (Flyology.Native_Task);
         end Reporter;

         task body Caller is
            Cancelled : Boolean := False;
         begin
            begin
               TLS.Handshake (Item, Timeout => 0.0, Token => Token'Access);
            exception
               when TLS.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Result.Report (Cancelled);
         exception
            when others =>
               Result.Report (False);
         end Caller;

         task body Reporter is
         begin
            Result.Report (True);
         end Reporter;
      begin
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
      TLS.Close (Item);
      Sockets.Close_Socket (Peer);
   end Run_Pre_Cancelled;

   procedure Run_Queued_Control
     (Model         : Flyology.Execution_Model;
      Cancel_Queued : Boolean)
   is
      Socket       : Sockets.Socket_Type;
      Peer         : Sockets.Socket_Type;
      Item         : TLS.Connection;
      Holder_Token : aliased Flyology.Cancellation.Token;
      Queued_Token : aliased Flyology.Cancellation.Token;

      protected Progress is
         procedure Holder_Started;
         procedure Holder_Finished (Passed : Boolean);
         procedure Release_Queued;
         entry Start_Queued;
         procedure Queued_Started;
         procedure Queued_Finished (Passed : Boolean);
         entry Wait_Holder_Started;
         entry Wait_Queued_Started;
         entry Wait_Queued_Finished;
         entry Wait_Holder_Finished;
         function Passed return Boolean;
      private
         Holder_In   : Boolean := False;
         Holder_Done : Boolean := False;
         Queued_Go   : Boolean := False;
         Queued_In   : Boolean := False;
         Queued_Done : Boolean := False;
         OK          : Boolean := True;
      end Progress;

      protected body Progress is
         procedure Holder_Started is
         begin
            Holder_In := True;
         end Holder_Started;
         procedure Holder_Finished (Passed : Boolean) is
         begin
            OK := OK and Passed;
            Holder_Done := True;
         end Holder_Finished;
         procedure Release_Queued is
         begin
            Queued_Go := True;
         end Release_Queued;
         entry Start_Queued when Queued_Go is
         begin
            null;
         end Start_Queued;
         procedure Queued_Started is
         begin
            Queued_In := True;
         end Queued_Started;
         procedure Queued_Finished (Passed : Boolean) is
         begin
            OK := OK and Passed;
            Queued_Done := True;
         end Queued_Finished;
         entry Wait_Holder_Started when Holder_In is
         begin
            null;
         end Wait_Holder_Started;
         entry Wait_Queued_Started when Queued_In is
         begin
            null;
         end Wait_Queued_Started;
         entry Wait_Queued_Finished when Queued_Done is
         begin
            null;
         end Wait_Queued_Finished;
         entry Wait_Holder_Finished when Holder_Done is
         begin
            null;
         end Wait_Holder_Finished;
         function Passed return Boolean is (OK);
      end Progress;
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      TLS.Take (Client_Backend, Socket, TLS.Client, "localhost", Item);
      declare
         task Holder is
            pragma Task_Info (Model);
         end Holder;
         task Queued is
            pragma Task_Info (Model);
         end Queued;

         task body Holder is
            Cancelled : Boolean := False;
         begin
            Progress.Holder_Started;
            begin
               TLS.Handshake (Item, Token => Holder_Token'Access);
            exception
               when TLS.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Progress.Holder_Finished (Cancelled);
         exception
            when others =>
               Progress.Holder_Finished (False);
         end Holder;

         task body Queued is
            Expected : Boolean := False;
         begin
            Progress.Start_Queued;
            Progress.Queued_Started;
            begin
               TLS.Handshake
                 (Item,
                  Timeout => (if Cancel_Queued then Flyology.IO.Infinite
                              else 0.050),
                  Token   => Queued_Token'Access);
            exception
               when TLS.Operation_Cancelled =>
                  Expected := Cancel_Queued;
               when Flyology.IO.Timeout_Error =>
                  Expected := not Cancel_Queued;
            end;
            Progress.Queued_Finished (Expected);
         exception
            when others =>
               Progress.Queued_Finished (False);
         end Queued;
      begin
         Progress.Wait_Holder_Started;
         delay 0.050;
         Progress.Release_Queued;
         Progress.Wait_Queued_Started;
         if Cancel_Queued then
            delay 0.030;
            Queued_Token.Request;
         end if;
         Progress.Wait_Queued_Finished;
         Holder_Token.Request;
         Progress.Wait_Holder_Finished;
      end;
      pragma Assert (Progress.Passed);
      TLS.Close (Item);
      Sockets.Close_Socket (Peer);
   end Run_Queued_Control;

   procedure Run_Concurrent_Close (Model : Flyology.Execution_Model) is
      Socket : Sockets.Socket_Type;
      Peer   : Sockets.Socket_Type;
      Item   : TLS.Connection;

      protected Progress is
         procedure Started;
         procedure Finished (Passed : Boolean);
         entry Wait_Started;
         entry Wait_Finished;
         function Passed return Boolean;
      private
         Has_Started  : Boolean := False;
         Has_Finished : Boolean := False;
         Is_OK        : Boolean := False;
      end Progress;

      protected body Progress is
         procedure Started is
         begin
            Has_Started := True;
         end Started;
         procedure Finished (Passed : Boolean) is
         begin
            Is_OK := Passed;
            Has_Finished := True;
         end Finished;
         entry Wait_Started when Has_Started is
         begin
            null;
         end Wait_Started;
         entry Wait_Finished when Has_Finished is
         begin
            null;
         end Wait_Finished;
         function Passed return Boolean is (Is_OK);
      end Progress;
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      TLS.Take (Client_Backend, Socket, TLS.Client, "localhost", Item);
      declare
         task Waiter is
            pragma Task_Info (Model);
         end Waiter;

         task body Waiter is
            Cancelled : Boolean := False;
         begin
            Progress.Started;
            begin
               TLS.Handshake (Item);
            exception
               when TLS.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Progress.Finished (Cancelled);
         exception
            when others =>
               Progress.Finished (False);
         end Waiter;
      begin
         Progress.Wait_Started;
         delay 0.050;
         TLS.Close (Item);
         Progress.Wait_Finished;
      end;
      pragma Assert (Progress.Passed);
      pragma Assert (not TLS.Is_Open (Item));
      Sockets.Close_Socket (Peer);
   end Run_Concurrent_Close;

   procedure Run_Queued_Close (Model : Flyology.Execution_Model) is
      Backend        : TLS_Test_Provider.Provider;
      Socket         : Sockets.Socket_Type;
      Peer           : Sockets.Socket_Type;
      Item           : TLS.Connection;
      Already_Closed : Boolean := False;

      protected Progress is
         procedure Release_Queued;
         entry Start_Queued;
         procedure Queued_Started;
         entry Wait_Queued_Started;
         procedure Finished (Passed : Boolean);
         entry Wait_Finished;
         function Passed return Boolean;
      private
         Queued_Go : Boolean := False;
         Queued_In : Boolean := False;
         Done      : Natural := 0;
         Is_OK     : Boolean := True;
      end Progress;

      protected body Progress is
         procedure Release_Queued is
         begin
            Queued_Go := True;
         end Release_Queued;
         entry Start_Queued when Queued_Go is
         begin
            null;
         end Start_Queued;
         procedure Queued_Started is
         begin
            Queued_In := True;
         end Queued_Started;
         entry Wait_Queued_Started when Queued_In is
         begin
            null;
         end Wait_Queued_Started;
         procedure Finished (Passed : Boolean) is
         begin
            Is_OK := Is_OK and Passed;
            Done := Done + 1;
         end Finished;
         entry Wait_Finished when Done = 3 is
         begin
            null;
         end Wait_Finished;
         function Passed return Boolean is (Is_OK);
      end Progress;
   begin
      TLS_Test_Provider.Set_Block_Handshake (Backend);
      Sockets.Create_Socket_Pair (Socket, Peer);
      TLS.Take (Backend, Socket, TLS.Client, "localhost", Item);
      declare
         task Active_Operation is
            pragma Task_Info (Model);
         end Active_Operation;
         task Queued_Operation is
            pragma Task_Info (Model);
         end Queued_Operation;
         task Closer is
            pragma Task_Info (Model);
         end Closer;

         task body Active_Operation is
            Cancelled : Boolean := False;
         begin
            begin
               TLS.Handshake (Item);
            exception
               when TLS.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Progress.Finished (Cancelled);
         exception
            when others =>
               Progress.Finished (False);
         end Active_Operation;

         task body Queued_Operation is
            Cancelled : Boolean := False;
         begin
            Progress.Start_Queued;
            Progress.Queued_Started;
            begin
               TLS.Handshake (Item);
            exception
               when TLS.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Progress.Finished (Cancelled);
         exception
            when others =>
               Progress.Finished (False);
         end Queued_Operation;

         task body Closer is
            Closed : Boolean := False;
         begin
            TLS_Test_Provider.Wait_Handshake_Blocked;
            Progress.Release_Queued;
            Progress.Wait_Queued_Started;
            delay 0.010;
            TLS.Close (Item);
            Closed := not TLS.Is_Open (Item);
            Progress.Finished (Closed);
         exception
            when others =>
               Progress.Finished (False);
         end Closer;
      begin
         while TLS.Is_Open (Item) loop
            Flyology.Fairness.Yield_Now;
         end loop;
         TLS_Test_Provider.Release_Handshake;
         Progress.Wait_Finished;
      end;
      pragma Assert (Progress.Passed);
      pragma Assert (not TLS.Is_Open (Item));
      begin
         TLS.Handshake (Item, Timeout => 0.0);
      exception
         when Program_Error =>
            Already_Closed := True;
      end;
      pragma Assert (Already_Closed);
      Sockets.Close_Socket (Peer);
   end Run_Queued_Close;

   procedure Run_Aborted_Close (Model : Flyology.Execution_Model) is
      Backend    : TLS_Test_Provider.Provider;
      Socket     : Sockets.Socket_Type;
      Peer       : Sockets.Socket_Type;
      Replacement : Sockets.Socket_Type;
      New_Peer    : Sockets.Socket_Type;
      Item        : TLS.Connection;

      protected Progress is
         procedure Active_Finished (Passed : Boolean);
         function Passed return Boolean;
      private
         Active_Done : Boolean := False;
         Active_OK   : Boolean := False;
      end Progress;

      protected body Progress is
         procedure Active_Finished (Passed : Boolean) is
         begin
            Active_OK := Passed;
            Active_Done := True;
         end Active_Finished;
         function Passed return Boolean is (Active_Done and Active_OK);
      end Progress;
   begin
      TLS_Test_Provider.Set_Block_Handshake (Backend);
      Sockets.Create_Socket_Pair (Socket, Peer);
      TLS.Take (Backend, Socket, TLS.Client, "localhost", Item);
      declare
         task Active_Operation is
            pragma Task_Info (Model);
         end Active_Operation;
         task Closer is
            pragma Task_Info (Model);
         end Closer;

         task body Active_Operation is
            Cancelled : Boolean := False;
         begin
            begin
               TLS.Handshake (Item);
            exception
               when TLS.Operation_Cancelled =>
                  Cancelled := True;
            end;
            Progress.Active_Finished (Cancelled);
         exception
            when others =>
               Progress.Active_Finished (False);
         end Active_Operation;

         task body Closer is
         begin
            TLS_Test_Provider.Wait_Handshake_Blocked;
            TLS.Close (Item);
         end Closer;
      begin
         TLS_Test_Provider.Wait_Handshake_Blocked;
         while TLS.Is_Open (Item) loop
            Flyology.Fairness.Yield_Now;
         end loop;
         abort Closer;
         TLS_Test_Provider.Release_Handshake;
      end;

      pragma Assert (Progress.Passed);
      pragma Assert (not TLS.Is_Open (Item));

      --  A completed abort-deferred close leaves the controller reusable.
      Sockets.Create_Socket_Pair (Replacement, New_Peer);
      TLS.Take (Backend, Replacement, TLS.Client, "localhost", Item);
      TLS.Close (Item);
      Sockets.Close_Socket (Peer);
      Sockets.Close_Socket (New_Peer);
   end Run_Aborted_Close;

   procedure Run_Aborted_Operation (Model : Flyology.Execution_Model) is
      Backend : TLS_Test_Provider.Provider;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Item    : TLS.Connection;
   begin
      TLS_Test_Provider.Set_Block_Handshake (Backend);
      Sockets.Create_Socket_Pair (Socket, Peer);
      TLS.Take (Backend, Socket, TLS.Client, "localhost", Item);
      declare
         task Worker is
            pragma Task_Info (Model);
         end Worker;

         task body Worker is
         begin
            TLS.Handshake (Item);
         end Worker;
      begin
         TLS_Test_Provider.Wait_Handshake_Blocked;
         abort Worker;
      end;

      TLS.Close (Item);
      Sockets.Close_Socket (Peer);
   end Run_Aborted_Operation;

   procedure Run_Empty_Closed_Validation is
      Item     : TLS.Connection;
      Empty    : Stream_Element_Array (1 .. 0);
      Last     : Stream_Element_Offset;
      Rejected : Natural := 0;
   begin
      begin
         TLS.Receive (Item, Empty, Last);
      exception
         when Program_Error =>
            Rejected := Rejected + 1;
      end;
      begin
         TLS.Receive_Exactly (Item, Empty);
      exception
         when Program_Error =>
            Rejected := Rejected + 1;
      end;
      begin
         TLS.Send_All (Item, Empty);
      exception
         when Program_Error =>
            Rejected := Rejected + 1;
      end;
      pragma Assert (Rejected = 3);
   end Run_Empty_Closed_Validation;

   procedure Run_Empty_Control (Model : Flyology.Execution_Model) is
      Backend : TLS_Test_Provider.Provider;
      Socket  : Sockets.Socket_Type;
      Peer    : Sockets.Socket_Type;
      Item    : TLS.Connection;
      Token   : aliased Flyology.Cancellation.Token;

      protected Progress is
         procedure Empty_Finished (Passed : Boolean);
         procedure Holder_Finished (Passed : Boolean);
         entry Wait_Empty;
         entry Wait_All;
         function Passed return Boolean;
      private
         Empty_Done  : Boolean := False;
         Holder_Done : Boolean := False;
         Is_OK       : Boolean := True;
      end Progress;

      protected body Progress is
         procedure Empty_Finished (Passed : Boolean) is
         begin
            Is_OK := Is_OK and Passed;
            Empty_Done := True;
         end Empty_Finished;

         procedure Holder_Finished (Passed : Boolean) is
         begin
            Is_OK := Is_OK and Passed;
            Holder_Done := True;
         end Holder_Finished;

         entry Wait_Empty when Empty_Done is
         begin
            null;
         end Wait_Empty;

         entry Wait_All when Empty_Done and Holder_Done is
         begin
            null;
         end Wait_All;

         function Passed return Boolean is (Is_OK);
      end Progress;
   begin
      TLS_Test_Provider.Set_Block_Handshake (Backend);
      Sockets.Create_Socket_Pair (Socket, Peer);
      TLS.Take (Backend, Socket, TLS.Client, "localhost", Item);
      Token.Request;
      declare
         task Holder is
            pragma Task_Info (Model);
         end Holder;

         task Empty_Caller is
            pragma Task_Info (Model);
         end Empty_Caller;

         task body Holder is
         begin
            TLS.Handshake (Item, Timeout => 1.0);
            Progress.Holder_Finished (True);
         exception
            when others =>
               Progress.Holder_Finished (False);
         end Holder;

         task body Empty_Caller is
            Empty     : Stream_Element_Array (1 .. 0);
            Last      : Stream_Element_Offset;
            Cancelled : Natural := 0;
            Timed_Out : Natural := 0;
         begin
            begin
               TLS.Receive (Item, Empty, Last, Token => Token'Access);
            exception
               when TLS.Operation_Cancelled =>
                  Cancelled := Cancelled + 1;
            end;
            begin
               TLS.Receive_Exactly (Item, Empty, Token => Token'Access);
            exception
               when TLS.Operation_Cancelled =>
                  Cancelled := Cancelled + 1;
            end;
            begin
               TLS.Send_All (Item, Empty, Token => Token'Access);
            exception
               when TLS.Operation_Cancelled =>
                  Cancelled := Cancelled + 1;
            end;

            TLS_Test_Provider.Wait_Handshake_Blocked;
            begin
               TLS.Receive (Item, Empty, Last, Timeout => 0.0);
            exception
               when Flyology.IO.Timeout_Error =>
                  Timed_Out := Timed_Out + 1;
            end;
            begin
               TLS.Receive_Exactly (Item, Empty, Timeout => 0.0);
            exception
               when Flyology.IO.Timeout_Error =>
                  Timed_Out := Timed_Out + 1;
            end;
            begin
               TLS.Send_All (Item, Empty, Timeout => 0.0);
            exception
               when Flyology.IO.Timeout_Error =>
                  Timed_Out := Timed_Out + 1;
            end;
            Progress.Empty_Finished
              (Cancelled = 3 and then Timed_Out = 3);
         exception
            when others =>
               Progress.Empty_Finished (False);
         end Empty_Caller;
      begin
         Progress.Wait_Empty;
         TLS_Test_Provider.Release_Handshake;
         Progress.Wait_All;
      end;
      pragma Assert (Progress.Passed);
      TLS.Close (Item);
      Sockets.Close_Socket (Peer);
   end Run_Empty_Control;

   procedure Run_Generation_Reuse is
      Backend      : TLS_Test_Provider.Provider;
      Socket       : Sockets.Socket_Type;
      Peer         : Sockets.Socket_Type;
      Replacement  : Sockets.Socket_Type;
      New_Peer     : Sockets.Socket_Type;
      Item         : TLS.Connection;
      Snapshot     : Interfaces.Unsigned_64;
      Was_Replaced : Boolean := False;
   begin
      Sockets.Create_Socket_Pair (Socket, Peer);
      TLS.Take (Backend, Socket, TLS.Client, "localhost", Item);
      Snapshot := TLS_Testing.Generation (Item);
      TLS.Close (Item);

      Sockets.Create_Socket_Pair (Replacement, New_Peer);
      TLS.Take (Backend, Replacement, TLS.Client, "localhost", Item);
      TLS_Testing.Attempt_Stale_Acquisition
        (Item, Snapshot, Was_Replaced);
      pragma Assert (Was_Replaced);
      TLS.Close (Item);
      Sockets.Close_Socket (Peer);
      Sockets.Close_Socket (New_Peer);
   end Run_Generation_Reuse;

   procedure Run_Provider_Lifetime is
      Client_Socket : Sockets.Socket_Type;
      Server_Socket : Sockets.Socket_Type;
      Client        : TLS.Connection;
      Server        : TLS.Connection;
      Result        : Outcome;
   begin
      Sockets.Create_Socket_Pair (Client_Socket, Server_Socket);
      declare
         Short_Lived : OpenSSL.OpenSSL_Provider;
      begin
         OpenSSL.Initialize_Client
           (Short_Lived,
            CA_File           => Certificate,
            Library_Directory => Library_Directory);
         TLS.Take
           (Short_Lived, Client_Socket, TLS.Client, "localhost", Client);
      end;
      TLS.Take (Server_Backend, Server_Socket, TLS.Server, "", Server);

      declare
         task Client_Task is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Client_Task;
         task Server_Task is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Server_Task;

         task body Client_Task is
         begin
            TLS.Handshake (Client, Timeout => 5.0);
            TLS.Shutdown (Client, Timeout => 5.0);
            Result.Report (True);
         exception
            when others =>
               Result.Report (False);
         end Client_Task;

         task body Server_Task is
         begin
            TLS.Handshake (Server, Timeout => 5.0);
            TLS.Shutdown (Server, Timeout => 5.0);
            Result.Report (True);
         exception
            when others =>
               Result.Report (False);
         end Server_Task;
      begin
         Result.Wait;
      end;
      pragma Assert (Result.Passed);
      TLS.Close (Client);
      TLS.Close (Server);
   end Run_Provider_Lifetime;

begin
   OpenSSL.Initialize_Client
     (Client_Backend,
      CA_File           => Certificate,
      Library_Directory => Library_Directory);
   OpenSSL.Initialize_Server
     (Server_Backend,
      Certificate,
      Private_Key,
      Library_Directory => Library_Directory);
   pragma Assert (OpenSSL.Version (Client_Backend)'Length > 0);

   Run_Exchange (Flyology.Lightweight_Task);
   Run_Exchange (Flyology.Native_Task);
   Run_Timeout (Flyology.Lightweight_Task);
   Run_Timeout (Flyology.Native_Task);
   Run_Cancellation (Flyology.Lightweight_Task);
   Run_Cancellation (Flyology.Native_Task);
   Run_Peer_Failure (Flyology.Lightweight_Task);
   Run_Peer_Failure (Flyology.Native_Task);
   Run_Hostname_Rejection;
   Run_Provider_Selection;
   Run_Provider_Result_Validation;
   Run_Empty_Closed_Validation;
   Run_Empty_Control (Flyology.Lightweight_Task);
   Run_Empty_Control (Flyology.Native_Task);
   Run_Generation_Reuse;
   Run_Close_Finalization_Fault;
   Run_Loader_Error;
   Run_Provider_Lifetime;
   Run_Pre_Cancelled (Flyology.Lightweight_Task);
   Run_Pre_Cancelled (Flyology.Native_Task);
   Run_Queued_Control (Flyology.Lightweight_Task, Cancel_Queued => False);
   Run_Queued_Control (Flyology.Native_Task, Cancel_Queued => False);
   Run_Queued_Control (Flyology.Lightweight_Task, Cancel_Queued => True);
   Run_Queued_Control (Flyology.Native_Task, Cancel_Queued => True);
   Run_Concurrent_Close (Flyology.Lightweight_Task);
   Run_Concurrent_Close (Flyology.Native_Task);
   Run_Queued_Close (Flyology.Lightweight_Task);
   Run_Queued_Close (Flyology.Native_Task);
   Run_Aborted_Operation (Flyology.Lightweight_Task);
   Run_Aborted_Operation (Flyology.Native_Task);
   Run_Aborted_Close (Flyology.Lightweight_Task);
   Run_Aborted_Close (Flyology.Native_Task);
end TLS_Smoke;
