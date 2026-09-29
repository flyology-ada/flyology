with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Strings.Fixed;
with Flyology;
with Flyology.Data_Structures;
with Flyology.Data_Structures.Byte_Strings;
with Flyology.Data_Structures.Regions;
with Flyology.Shared_Memory;
with Flyology.Shared_Memory.Segments;
with Flyology.Shared_Memory.Testing;
with Flyology.Shared_Memory.Unix_Sockets;
with Flyology.Shared_Memory.Unix_Sockets.Testing;
with Interfaces;
with Interfaces.C;
with System;

procedure Shared_Memory_Smoke is
   package DS renames Flyology.Data_Structures;
   package Regions renames DS.Regions;
   package Strings renames DS.Byte_Strings;
   package Shared renames Flyology.Shared_Memory;
   package Segments renames Shared.Segments;
   package Testing renames Shared.Testing;
   package Unix_Sockets renames Shared.Unix_Sockets;
   package Unix_Testing renames Shared.Unix_Sockets.Testing;
   package C renames Interfaces.C;

   use type Ada.Streams.Stream_Element_Array;
   use type DS.Region_Offset;
   use type Interfaces.Unsigned_32;
   use type C.int;
   use type C.long;
   use type Shared.Backing_Kind;
   use type Shared.Byte_Length;
   use type Shared.Namespace_Open_Result;
   use type Segments.Find_Or_Create_Result;
   use type Segments.Handle_State;
   use type Segments.Lookup_Result;
   use type Segments.Remove_Result;
   use type Segments.Replacement_Result;
   use type Segments.Segment_Open_Result;
   use type Unix_Sockets.Socket_Descriptor;

   Mapping_Length : constant Shared.Byte_Length := 1_048_576;
   Config         : constant Segments.Configuration :=
     (Schema               => 16#5348_4152_4544_0001#,
      Registry_Capacity    => 16,
      Maximum_Name_Length  => 64,
      Allocation_Alignment => 64);

   function Getpid return C.int;
   pragma Import (C, Getpid, "getpid");
   function Is_Linux return C.int;
   pragma Import (C, Is_Linux, "flyology_test_is_linux");

   function Socketpair (Left, Right : access C.int) return C.int;
   pragma Import (C, Socketpair, "flyology_test_shared_socketpair");
   function Spawn_Child
     (Program     : C.char_array;
      Socket      : C.int;
      Parent_Base : C.unsigned_long_long;
      Length      : C.unsigned_long_long;
      PID         : access C.int) return C.int;
   pragma Import (C, Spawn_Child, "flyology_test_spawn_shared_memory_child");
   function Poll_Child (PID : C.int) return C.int;
   pragma Import (C, Poll_Child, "flyology_test_poll_shared_memory_child");
   function Kill (PID, Signal : C.int) return C.int;
   pragma Import (C, Kill, "kill");
   function Close_Socket (Socket : C.int) return C.int;
   pragma Import (C, Close_Socket, "close");
   function Send_Two (Socket, First, Second : C.int) return C.int;
   pragma Import (C, Send_Two, "flyology_test_send_two_descriptors");
   function Send_Split (Socket, First, Second : C.int) return C.int;
   pragma Import (C, Send_Split, "flyology_test_send_split_descriptors");
   function Send_Many (Socket, Descriptor : C.int; Count : C.unsigned) return C.int;
   pragma Import (C, Send_Many, "flyology_test_send_many_descriptors");
   function Create_Read_Only (Length : C.unsigned_long_long; Descriptor : access C.int) return C.int;
   pragma Import (C, Create_Read_Only, "flyology_test_create_read_only_backing");
   function Send_Raw (Socket, Descriptor : C.int) return C.long;
   pragma Import (C, Send_Raw, "flyology_shm_send_fd_once");
   function Open_FD_Count return C.int;
   pragma Import (C, Open_FD_Count, "flyology_test_open_fd_count");
   function Contains_U64
     (Base : System.Address; Length : C.size_t; Value : Interfaces.Unsigned_64) return C.int;
   pragma Import (C, Contains_U64, "flyology_test_mapping_contains_u64");
   function Truncate (Descriptor : C.int; Length : C.long_long) return C.int;
   pragma Import (C, Truncate, "ftruncate");
   function Create_Unsized (Name : C.char_array; Descriptor : access C.int) return C.int;
   pragma Import (C, Create_Unsized, "flyology_test_create_unsized_shm");
   function Close_Unsized (Name : C.char_array; Descriptor : C.int) return C.int;
   pragma Import (C, Close_Unsized, "flyology_test_close_unsized_shm");
   function Unlink_Shared_Name (Name : C.char_array) return C.int;
   pragma Import (C, Unlink_Shared_Name, "flyology_test_unlink_shm");
   procedure Assert (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Assert;

   function Identifier return String
   is (Ada.Strings.Fixed.Trim (C.int'Image (Getpid), Ada.Strings.Both));

   function Wait_Child (PID : C.int) return C.int is
      Result : C.int;
   begin
      for Attempt in 1 .. 10_000 loop
         Result := Poll_Child (PID);
         if Result = 1 then
            return 0;
         elsif Result = -1 then
            return -1;
         end if;
         delay 0.001;
      end loop;
      Result := Kill (PID, 9);
      for Attempt in 1 .. 10_000 loop
         Result := Poll_Child (PID);
         exit when Result in -1 | 1;
         delay 0.001;
      end loop;
      return -1;
   end Wait_Child;

   function Size_Changes_Rejected (Descriptor : C.int; Length : Shared.Byte_Length) return Boolean is
      Grow_Result   : constant C.int := Truncate (Descriptor, C.long_long (Length + 1));
      Shrink_Result : constant C.int := Truncate (Descriptor, C.long_long (Length - 1));
   begin
      return Grow_Result /= 0 and then Shrink_Result /= 0;
   end Size_Changes_Rejected;

   procedure Create_Name
     (Segment : Segments.View;
      Name    : String;
      Length  : Shared.Byte_Length;
      Handle  : out Segments.Named_Handle;
      Claim   : out Segments.Creation_Claim)
   is
      Result  : Segments.Find_Or_Create_Result;
      Failure : Interfaces.Unsigned_32;
   begin
      loop
         Segments.Try_Find_Or_Create (Segment, Name, Length, Handle, Claim, Result, Failure);
         exit when Result /= Segments.Registry_Busy;
         delay 0.0;
      end loop;
      Assert (Result = Segments.Created, "named extent was not created");
      Assert (Failure = 0, "new extent reported a failure code");
   end Create_Name;

   procedure Check_Anonymous_And_Registry is
      Backing                                               : Shared.Backing_Object;
      Required                                              : Shared.Backing_Object;
      Odd_Length_Backing                                    : Shared.Backing_Object;
      Left, Right                                           : Shared.Mapping;
      Segment_Left, Segment_Right                           : Segments.View;
      Region_Left, Region_Right                             : Regions.View;
      Opened                                                : Segments.Segment_Open_Result;
      First, Second, Pending, Reused, Existing              : Segments.Named_Handle;
      First_Claim, Second_Claim, Pending_Claim, Reuse_Claim : Segments.Creation_Claim;
      First_Location, Other_Location                        : DS.Region_Offset;
      First_Length, Other_Length                            : Shared.Byte_Length;
      Result                                                : Segments.Find_Or_Create_Result;
      Lookup                                                : Segments.Lookup_Result;
      Removed                                               : Segments.Remove_Result;
      Failure                                               : Interfaces.Unsigned_32;
      String_Left, String_Right                             : Strings.View;
      Payload                                               : constant Ada.Streams.Stream_Element_Array :=
        (1 => 16#46#, 2 => 16#6C#, 3 => 16#79#);
      Observed                                              :
        Ada.Streams.Stream_Element_Array (Payload'Range);
      Props                                                 : Shared.Security_Properties;
      Noexec_Rejected                                       : Boolean := False;
      Odd_Length_Rejected                                   : Boolean := False;
   begin
      Shared.Create_Anonymous (Backing, Mapping_Length);
      Props := Shared.Properties (Backing);
      Assert (Props.Close_On_Exec, "anonymous descriptor lacks CLOEXEC");
      if Is_Linux = 1 then
         Assert (not Props.Owner_Only_Permissions, "Linux memfd mode bits were misreported as owner-only");
         Assert (Props.Size_Immutable, "Linux anonymous descriptor lacks immutable size seals");
         Assert
           (Size_Changes_Rejected (Testing.Descriptor (Backing), Mapping_Length),
            "sealed anonymous size accepted grow or shrink");
      else
         Assert (Props.Owner_Only_Permissions, "Darwin anonymous descriptor permissions are not owner-only");
      end if;

      --  Linux memfd retains arbitrary exact lengths. Darwin POSIX shared
      --  memory rounds non-page geometry, so exact-size validation must reject
      --  rather than silently expose a differently sized object. The image
      --  index showcase found this boundary with an 11,968-byte segment.
      begin
         Shared.Create_Anonymous (Odd_Length_Backing, 11_968);
      exception
         when Shared.Validation_Error =>
            Odd_Length_Rejected := True;
      end;
      if Is_Linux = 1 then
         Assert
           (Shared.Is_Open (Odd_Length_Backing) and then Shared.Length (Odd_Length_Backing) = 11_968,
            "Linux anonymous backing lost an arbitrary exact length");
         Shared.Close (Odd_Length_Backing);
      else
         Assert
           (Odd_Length_Rejected and then not Shared.Is_Open (Odd_Length_Backing),
            "Darwin accepted rounded anonymous shared-memory geometry");
      end if;
      if Props.No_Execute_Seal_Supported then
         Assert (Props.No_Execute_Seal, "supported anonymous no-execute seal was not applied");
      end if;
      if Props.No_Execute_Seal then
         Shared.Create_Anonymous (Required, Mapping_Length, Require_No_Execute_Seal => True);
         Assert (Shared.Properties (Required).No_Execute_Seal, "required no-execute seal was not reported");
         Shared.Close (Required);
      else
         begin
            Shared.Create_Anonymous (Required, Mapping_Length, Require_No_Execute_Seal => True);
         exception
            when Shared.Security_Error =>
               Noexec_Rejected := True;
         end;
         Assert (Noexec_Rejected, "unavailable required no-execute seal did not fail closed");
      end if;
      Assert (Shared.Kind (Backing) = Shared.Anonymous_Capability, "anonymous backing kind is wrong");
      Shared.Map (Left, Backing);
      Shared.Map (Right, Backing);
      Shared.Close (Backing);
      Assert (not Shared.Is_Open (Backing), "anonymous descriptor stayed open");

      Segments.Create_Or_Attach (Segment_Left, Left, Config, Opened);
      Assert (Opened = Segments.Initialized_New, "first anonymous mapping did not initialize segment");
      Segments.Create_Or_Attach (Segment_Right, Right, Config, Opened);
      Assert (Opened = Segments.Attached_Existing, "second anonymous mapping did not attach segment");
      Segments.Attach_Region (Segment_Left, Region_Left);
      Segments.Attach_Region (Segment_Right, Region_Right);

      --  These two strings have the same 32-bit FNV-1a hash. Exact byte
      --  comparison must keep their registry entries distinct.
      Create_Name (Segment_Left, "costarring", Strings.Required_Storage (32), First, First_Claim);
      Segments.Claimed_Extent (Segment_Left, First_Claim, First_Location, First_Length);
      Strings.Initialize (String_Left, Region_Left, First_Location, 32);
      Strings.Assign (String_Left, Payload);
      Segments.Publish (Segment_Left, First_Claim);

      Create_Name (Segment_Right, "liquid", Strings.Required_Storage (16), Second, Second_Claim);
      Segments.Claimed_Extent (Segment_Right, Second_Claim, Other_Location, Other_Length);
      Assert (Other_Location /= First_Location, "hash-colliding exact names aliased one extent");
      Segments.Publish (Segment_Right, Second_Claim);

      Segments.Try_Find_Or_Create
        (Segment_Right, "costarring", Strings.Required_Storage (32), Existing, Reuse_Claim, Result, Failure);
      Assert (Result = Segments.Attached_Existing, "duplicate exact name did not attach existing extent");
      Segments.Resolve (Segment_Right, Existing, Other_Location, Other_Length);
      Assert
        (Other_Location = First_Location and then Other_Length = First_Length,
         "duplicate exact name resolved different geometry");
      Strings.Attach (String_Right, Region_Right, Other_Location, 32);
      Strings.Read (String_Right, Observed);
      Assert (Observed = Payload, "second mapping observed wrong bytes");

      declare
         protected Summary is
            procedure Complete (Was_Creator, Passed : Boolean);
            function Creators return Natural;
            function Completed return Natural;
            function All_Passed return Boolean;
         private
            Creator_Count  : Natural := 0;
            Complete_Count : Natural := 0;
            Passed_All     : Boolean := True;
         end Summary;

         protected body Summary is
            procedure Complete (Was_Creator, Passed : Boolean) is
            begin
               Complete_Count := Complete_Count + 1;
               if Was_Creator then
                  Creator_Count := Creator_Count + 1;
               end if;
               Passed_All := Passed_All and Passed;
            end Complete;
            function Creators return Natural
            is (Creator_Count);
            function Completed return Natural
            is (Complete_Count);
            function All_Passed return Boolean
            is (Passed_All);
         end Summary;

         task type Racer is
            pragma Task_Info (Flyology.Native_Task);
         end Racer;

         task body Racer is
            Race_Handle  : Segments.Named_Handle;
            Race_Claim   : Segments.Creation_Claim;
            Race_Result  : Segments.Find_Or_Create_Result;
            Race_Failure : Interfaces.Unsigned_32;
            Creator      : Boolean := False;
         begin
            loop
               Segments.Try_Find_Or_Create
                 (Segment_Left, "native-race", 512, Race_Handle, Race_Claim, Race_Result, Race_Failure);
               case Race_Result is
                  when Segments.Created                                             =>
                     Creator := True;
                     Segments.Publish (Segment_Left, Race_Claim);
                     exit;

                  when Segments.Attached_Existing                                   =>
                     exit;

                  when Segments.Registry_Busy | Segments.Initialization_In_Progress =>
                     delay 0.0;

                  when others                                                       =>
                     raise Program_Error with "unexpected native registry race result";
               end case;
            end loop;
            Summary.Complete (Creator, Race_Failure = 0);
         exception
            when others =>
               Summary.Complete (Creator, False);
         end Racer;

      begin
         declare
            Racers : array (1 .. 16) of Racer;
         begin
            null;
         end;
         Assert
           (Summary.Creators = 1 and then Summary.Completed = 16 and then Summary.All_Passed,
            "native find-or-create race did not elect exactly one creator");
      end;

      Create_Name (Segment_Left, "pending", 256, Pending, Pending_Claim);
      Segments.Try_Find (Segment_Right, "pending", Existing, Lookup, Failure);
      Assert (Lookup = Segments.Initialization_In_Progress, "unpublished extent was exposed as ready");
      Segments.Publish_Failure (Segment_Left, Pending_Claim, 77);
      Segments.Try_Find (Segment_Right, "pending", Existing, Lookup, Failure);
      Assert
        (Lookup = Segments.Initialization_Failed and then Failure = 77,
         "published initialization failure was lost");
      Assert (Segments.Failure_Of (Segment_Right, Existing) = 77, "failed handle returned wrong code");
      Segments.Try_Remove (Segment_Right, "pending", Removed);
      Assert (Removed = Segments.Removed, "failed name was not removed");
      Assert
        (Segments.State_Of (Segment_Left, Pending) = Segments.Removed,
         "removed handle did not become inactive");

      Create_Name (Segment_Right, "reused", 128, Reused, Reuse_Claim);
      Segments.Claimed_Extent (Segment_Right, Reuse_Claim, Other_Location, Other_Length);
      Segments.Publish (Segment_Right, Reuse_Claim);
      Assert
        (Segments.State_Of (Segment_Left, Pending) = Segments.Stale,
         "extent reuse did not stale the old generation");
      Assert
        (Segments.State_Of (Segment_Left, Reused) = Segments.Ready, "reused extent did not publish ready");

      Strings.Detach (String_Right);
      Strings.Detach (String_Left);
      Regions.Detach (Region_Right);
      Regions.Detach (Region_Left);
      Segments.Detach (Segment_Right);
      Segments.Detach (Segment_Left);
      Shared.Unmap (Right);
      Shared.Unmap (Left);
   end Check_Anonymous_And_Registry;

   procedure Check_Named is
      Name                            : constant String := "/flyology-smoke-" & Identifier;
      Created, Opened                 : Shared.Backing_Object;
      Map_Created, Map_Opened         : Shared.Mapping;
      Segment_Created, Segment_Opened : Segments.View;
      Namespace_Result                : Shared.Namespace_Open_Result;
      Segment_Result                  : Segments.Segment_Open_Result;
      Mismatch_Rejected               : Boolean := False;
      Unsized_Name                    : constant String := Name & "-unsized";
      C_Unsized_Name                  : constant C.char_array := C.To_C (Unsized_Name);
      Unsized_FD                      : aliased C.int := -1;
      Original, Replacement           : Shared.Backing_Object;
      Replacement_Name                : constant String := Name & "-r";
      C_Replacement_Name              : constant C.char_array := C.To_C (Replacement_Name);
      Identity_Rejected               : Boolean := False;
   begin
      Shared.Create_Or_Open_Named (Created, Name, Mapping_Length, Namespace_Result);
      Assert (Namespace_Result = Shared.Created_New, "create-or-open did not report creation");
      Assert
        (Shared.Properties (Created).Close_On_Exec
         and then Shared.Properties (Created).Owner_Only_Permissions,
         "named object security properties are wrong");
      Shared.Map (Map_Created, Created);
      Segments.Create_Or_Attach (Segment_Created, Map_Created, Config, Segment_Result);
      Assert (Segment_Result = Segments.Initialized_New, "named segment did not initialize");
      Shared.Create_Or_Open_Named (Opened, Name, Mapping_Length, Namespace_Result);
      Assert (Namespace_Result = Shared.Opened_Existing, "named object did not open existing");
      Shared.Map (Map_Opened, Opened);
      Segments.Create_Or_Attach (Segment_Opened, Map_Opened, Config, Segment_Result);
      Assert (Segment_Result = Segments.Attached_Existing, "named segment opener did not attach");
      Segments.Detach (Segment_Opened);
      Shared.Unmap (Map_Opened);
      Shared.Close (Opened);

      begin
         Shared.Open_Named (Opened, Name, Mapping_Length / 2, Namespace_Result);
      exception
         when Shared.Validation_Error =>
            Mismatch_Rejected := True;
      end;
      Assert (Mismatch_Rejected, "named wrong-size open was accepted");

      Assert (Create_Unsized (C_Unsized_Name, Unsized_FD'Access) = 0, "unsized named object setup failed");
      Shared.Open_Named (Opened, Unsized_Name, Mapping_Length, Namespace_Result);
      Assert
        (Namespace_Result = Shared.Initialization_In_Progress and then not Shared.Is_Open (Opened),
         "opener did not report creator sizing in progress");
      Assert (Close_Unsized (C_Unsized_Name, Unsized_FD) = 0, "unsized named object cleanup failed");
      Unsized_FD := -1;

      Shared.Create_Named (Original, Replacement_Name, Mapping_Length);
      Assert (Unlink_Shared_Name (C_Replacement_Name) = 0, "named identity replacement setup failed");
      Shared.Create_Named (Replacement, Replacement_Name, Mapping_Length);
      if Is_Linux = 1 then
         begin
            Shared.Unlink (Original);
         exception
            when Shared.Validation_Error =>
               Identity_Rejected := True;
         end;
         Assert (Identity_Rejected, "stale named backing unlinked its namespace replacement");
      end if;
      Shared.Unlink (Replacement);
      Shared.Close (Replacement);
      Shared.Close (Original);
      declare
         Failure_Object : Shared.Backing_Object;
         Failed         : Boolean := False;
      begin
         begin
            Shared.Create_Named (Failure_Object, Name & "-f", Shared.Byte_Length (C.long_long'Last) + 1);
         exception
            when Constraint_Error =>
               Failed := True;
         end;
         if Shared.Is_Open (Failure_Object) then
            Shared.Unlink (Failure_Object);
            Shared.Close (Failure_Object);
         end if;
         Assert (Failed, "nonrepresentable named creation unexpectedly succeeded");
         Shared.Create_Named (Failure_Object, Name & "-f", Mapping_Length);
         Shared.Unlink (Failure_Object);
         Shared.Close (Failure_Object);
      end;

      Shared.Unlink (Created);
      Shared.Unlink (Created);
      Segments.Detach (Segment_Created);
      Shared.Unmap (Map_Created);
      Shared.Close (Created);
   exception
      when others =>
         if Shared.Is_Open (Replacement) then
            begin
               Shared.Unlink (Replacement);
            exception
               when others =>
                  null;
            end;
            Shared.Close (Replacement);
         end if;
         if Shared.Is_Open (Original) then
            Shared.Close (Original);
         end if;
         if Shared.Is_Open (Created) then
            begin
               Shared.Unlink (Created);
            exception
               when others =>
                  null;
            end;
         end if;
         if Unsized_FD >= 0 then
            declare
               Ignored : constant C.int := Close_Unsized (C_Unsized_Name, Unsized_FD);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         end if;
         raise;
   end Check_Named;

   procedure Check_File is
      Root                            : constant String :=
        Ada.Environment_Variables.Value ("FLYOLOGY_TEST_TEMP_ROOT", "/tmp");
      Path                            : constant String := Root & "/shared-memory-smoke.data";
      Created, Opened                 : Shared.Backing_Object;
      Map_Created, Map_Opened         : Shared.Mapping;
      Segment_Created, Segment_Opened : Segments.View;
      Segment_Result                  : Segments.Segment_Open_Result;
      Identity_Path                   : constant String := Path & ".identity";
      Failure_Path                    : constant String := Path & ".failed-create";
      Original, Replacement           : Shared.Backing_Object;
      Identity_Rejected               : Boolean := False;
   begin
      Shared.Create_File (Created, Path, Mapping_Length);
      Assert
        (Shared.Properties (Created).Close_On_Exec
         and then Shared.Properties (Created).No_Symlink_Follow
         and then Shared.Properties (Created).Owner_Only_Permissions,
         "file-backed object security properties are wrong");
      Shared.Map (Map_Created, Created);
      Segments.Create_Or_Attach (Segment_Created, Map_Created, Config, Segment_Result);
      Assert (Segment_Result = Segments.Initialized_New, "file-backed segment did not initialize");
      Shared.Flush (Map_Created);
      Shared.Flush (Created);
      Segments.Detach (Segment_Created);
      Shared.Unmap (Map_Created);
      Shared.Close (Created);

      Shared.Open_File (Opened, Path, Mapping_Length);
      Shared.Map (Map_Opened, Opened);
      Segments.Create_Or_Attach (Segment_Opened, Map_Opened, Config, Segment_Result);
      Assert (Segment_Result = Segments.Attached_Existing, "file-backed segment did not persist");
      Shared.Unlink (Opened);
      Segments.Detach (Segment_Opened);
      Shared.Unmap (Map_Opened);
      Shared.Close (Opened);

      Shared.Create_File (Original, Identity_Path, Mapping_Length);
      Ada.Directories.Delete_File (Identity_Path);
      Shared.Create_File (Replacement, Identity_Path, Mapping_Length);
      begin
         Shared.Unlink (Original);
      exception
         when Shared.Validation_Error =>
            Identity_Rejected := True;
      end;
      Assert (Identity_Rejected, "stale file backing unlinked its namespace replacement");
      Shared.Unlink (Replacement);
      Shared.Close (Replacement);
      Shared.Close (Original);
      declare
         Failure_Object : Shared.Backing_Object;
         Failed         : Boolean := False;
      begin
         begin
            Shared.Create_File (Failure_Object, Failure_Path, Shared.Byte_Length (C.long_long'Last) + 1);
         exception
            when Constraint_Error =>
               Failed := True;
         end;
         if Shared.Is_Open (Failure_Object) then
            Shared.Unlink (Failure_Object);
            Shared.Close (Failure_Object);
         end if;
         Assert (Failed, "nonrepresentable file creation unexpectedly succeeded");
         Shared.Create_File (Failure_Object, Failure_Path, Mapping_Length);
         Shared.Unlink (Failure_Object);
         Shared.Close (Failure_Object);
      end;
   exception
      when others =>
         if Shared.Is_Open (Replacement) then
            begin
               Shared.Unlink (Replacement);
            exception
               when others =>
                  null;
            end;
            Shared.Close (Replacement);
         end if;
         if Shared.Is_Open (Original) then
            Shared.Close (Original);
         end if;
         if Shared.Is_Open (Opened) then
            begin
               Shared.Unlink (Opened);
            exception
               when others =>
                  null;
            end;
         elsif Shared.Is_Open (Created) then
            begin
               Shared.Unlink (Created);
            exception
               when others =>
                  null;
            end;
         end if;
         raise;
   end Check_File;

   procedure Check_Registry_Corruption is
      Backing        : Shared.Backing_Object;
      Map            : Shared.Mapping;
      Segment        : Segments.View;
      Segment_Result : Segments.Segment_Open_Result;
      Handle         : Segments.Named_Handle;
      Claim          : Segments.Creation_Claim;
      Result         : Segments.Find_Or_Create_Result;
      Removed        : Segments.Remove_Result;
      Failure        : Interfaces.Unsigned_32;
      Rejected       : Boolean := False;
      Data_Start     : constant Shared.Byte_Length := Segments.Required_Registry_Storage (Config);
   begin
      Shared.Create_Anonymous (Backing, Mapping_Length);
      Shared.Map (Map, Backing);
      Segments.Create_Or_Attach (Segment, Map, Config, Segment_Result);
      Assert (Segment_Result = Segments.Initialized_New, "corruption-test segment did not initialize");
      Segments.Detach (Segment);
      Testing.Store_Release_U64 (Map, 56, Interfaces.Unsigned_64 (Data_Start + 1));
      begin
         Segments.Create_Or_Attach (Segment, Map, Config, Segment_Result);
      exception
         when Segments.Segment_Error =>
            Rejected := True;
      end;
      Assert (Rejected, "misaligned registry frontier was accepted");
      Shared.Unmap (Map);
      Shared.Close (Backing);

      Shared.Create_Anonymous (Backing, Mapping_Length);
      Shared.Map (Map, Backing);
      Segments.Create_Or_Attach (Segment, Map, Config, Segment_Result);
      Create_Name (Segment, "removed", 256, Handle, Claim);
      Segments.Publish (Segment, Claim);
      Segments.Try_Remove (Segment, "removed", Removed);
      Assert (Removed = Segments.Removed, "corruption slot was not removed");
      Testing.Store_Release_U64 (Map, 152, 1);
      Rejected := False;
      begin
         Segments.Try_Find_Or_Create (Segment, "reuse", 128, Handle, Claim, Result, Failure);
      exception
         when Segments.Segment_Error =>
            Rejected := True;
      end;
      Assert (Rejected, "corrupt removed extent was reused");
      Segments.Detach (Segment);
      Shared.Unmap (Map);
      Shared.Close (Backing);
   end Check_Registry_Corruption;

   procedure Check_Exhaustion is
      Small_Config   : constant Segments.Configuration :=
        (Schema               => 16#534D_414C_4C00_0001#,
         Registry_Capacity    => 1,
         Maximum_Name_Length  => 8,
         Allocation_Alignment => 64);
      Small_Length   : constant Shared.Byte_Length := 16_384;
      Backing        : Shared.Backing_Object;
      Map            : Shared.Mapping;
      Segment        : Segments.View;
      Segment_Result : Segments.Segment_Open_Result;
      Handle         : Segments.Named_Handle;
      Claim          : Segments.Creation_Claim;
      Result         : Segments.Find_Or_Create_Result;
      Failure        : Interfaces.Unsigned_32;
   begin
      Shared.Create_Anonymous (Backing, Small_Length);
      Shared.Map (Map, Backing);
      Segments.Create_Or_Attach (Segment, Map, Small_Config, Segment_Result);
      Assert (Segment_Result = Segments.Initialized_New, "small segment did not initialize");
      Segments.Try_Find_Or_Create (Segment, "large", Small_Length, Handle, Claim, Result, Failure);
      Assert (Result = Segments.Segment_Exhausted, "small segment did not report byte exhaustion");
      Segments.Try_Find_Or_Create (Segment, "one", 64, Handle, Claim, Result, Failure);
      Assert (Result = Segments.Created, "small segment did not create extent");
      Segments.Publish (Segment, Claim);
      Segments.Try_Find_Or_Create (Segment, "one", 32, Handle, Claim, Result, Failure);
      Assert (Result = Segments.Configuration_Mismatch, "duplicate name accepted a different extent length");
      Segments.Try_Find_Or_Create (Segment, "two", 8, Handle, Claim, Result, Failure);
      Assert (Result = Segments.Registry_Exhausted, "full registry did not report slot exhaustion");
      Segments.Detach (Segment);
      Shared.Unmap (Map);
      Shared.Close (Backing);
   end Check_Exhaustion;

   procedure Check_Replacement_Migration is
      Old_Length                                                   : constant Shared.Byte_Length := 16_384;
      New_Length                                                   : constant Shared.Byte_Length := 32_768;
      Registry_Guard_Offset                                        : constant Shared.Byte_Length := 64;
      Root                                                         : constant String :=
        Ada.Environment_Variables.Value ("FLYOLOGY_TEST_TEMP_ROOT", "/tmp");
      Path                                                         : constant String :=
        Root & "/shared-memory-migration-" & Identifier & ".data";
      Source_Backing, Target_Backing, Target_Opened, Equal_Backing : Shared.Backing_Object;
      Source_Map, Target_Map, Opened_Map, Equal_Map                : Shared.Mapping;
      Source_Segment, Replacement                                  : Segments.View;
      Source_Region, Target_Region                                 : Regions.View;
      Source_String, Target_String                                 : Strings.View;
      Segment_Result                                               : Segments.Segment_Open_Result;
      Migration_Result                                             : Segments.Replacement_Result;
      Handle, Pending, Reused, Large                               : Segments.Named_Handle;
      Claim, Pending_Claim, Reuse_Claim, Large_Claim               : Segments.Creation_Claim;
      Find_Result                                                  : Segments.Find_Or_Create_Result;
      Remove_Result                                                : Segments.Remove_Result;
      Failure                                                      : Interfaces.Unsigned_32;
      Location, Target_Location                                    : DS.Region_Offset;
      Extent, Target_Extent                                        : Shared.Byte_Length;
      Payload                                                      :
        constant Ada.Streams.Stream_Element_Array := (1 => 16#67#, 2 => 16#72#, 3 => 16#6F#, 4 => 16#77#);
      Child_Payload                                                :
        constant Ada.Streams.Stream_Element_Array := (1 => 16#65#, 2 => 16#78#, 3 => 16#65#, 4 => 16#63#);
      Observed                                                     :
        Ada.Streams.Stream_Element_Array (Payload'Range);
      Opened_Target_Rejected                                       : Boolean := False;
      Equal_Target_Rejected                                        : Boolean := False;
      Source_Base, Target_Base                                     : Interfaces.Unsigned_64;
      Left, Right                                                  : aliased C.int := -1;
      Child                                                        : aliased C.int := -1;
      Program                                                      : constant C.char_array :=
        C.To_C
          (Ada.Directories.Containing_Directory (Ada.Command_Line.Command_Name) & "/shared_memory_child");
      Ignored                                                      : C.int;
   begin
      Shared.Create_Anonymous (Source_Backing, Old_Length);
      Shared.Map (Source_Map, Source_Backing);
      Source_Base := Testing.Base_Value (Source_Map);
      Segments.Create_Or_Attach (Source_Segment, Source_Map, Config, Segment_Result);
      Assert (Segment_Result = Segments.Initialized_New, "replacement source did not initialize");
      Segments.Attach_Region (Source_Segment, Source_Region);
      Create_Name (Source_Segment, "replacement-handoff", Strings.Required_Storage (64), Handle, Claim);
      Segments.Claimed_Extent (Source_Segment, Claim, Location, Extent);
      Strings.Initialize (Source_String, Source_Region, Location, 64);
      Strings.Assign (Source_String, Payload);
      Segments.Publish (Source_Segment, Claim);
      Strings.Detach (Source_String);
      Regions.Detach (Source_Region);

      Segments.Try_Find_Or_Create
        (Source_Segment, "large", Old_Length, Large, Large_Claim, Find_Result, Failure);
      Assert
        (Find_Result = Segments.Segment_Exhausted,
         "replacement source did not exhaust its fixed byte extent");

      Shared.Create_Anonymous (Equal_Backing, Old_Length);
      Shared.Map (Equal_Map, Equal_Backing);
      begin
         Segments.Try_Prepare_Replacement
           (Source     => Source_Segment,
            Target     => Equal_Map,
            Config     => Config,
            Quiescence => Segments.Caller_Established_Quiescence,
            Result     => Migration_Result);
      exception
         when Constraint_Error =>
            Equal_Target_Rejected := True;
      end;
      Assert (Equal_Target_Rejected, "same-size mapping was accepted as a larger replacement");
      Shared.Unmap (Equal_Map);
      Shared.Close (Equal_Backing);

      Create_Name (Source_Segment, "pending", 64, Pending, Pending_Claim);
      Shared.Create_File (Target_Backing, Path, New_Length);
      Shared.Open_File (Target_Opened, Path, New_Length);
      Shared.Map (Opened_Map, Target_Opened);
      begin
         Segments.Try_Prepare_Replacement
           (Source     => Source_Segment,
            Target     => Opened_Map,
            Config     => Config,
            Quiescence => Segments.Caller_Established_Quiescence,
            Result     => Migration_Result);
      exception
         when Shared.Validation_Error =>
            Opened_Target_Rejected := True;
      end;
      Assert (Opened_Target_Rejected, "opened mapping received exclusive replacement authority");
      Shared.Unmap (Opened_Map);
      Shared.Close (Target_Opened);

      Shared.Map (Target_Map, Target_Backing);
      Target_Base := Testing.Base_Value (Target_Map);
      Testing.Store_Release_U32 (Source_Map, Registry_Guard_Offset, 1);
      Segments.Try_Prepare_Replacement
        (Source     => Source_Segment,
         Target     => Target_Map,
         Config     => Config,
         Quiescence => Segments.Caller_Established_Quiescence,
         Result     => Migration_Result);
      Assert
        (Migration_Result = Segments.Registry_Busy,
         "replacement copied while the source registry guard was owned");
      Testing.Store_Release_U32 (Source_Map, Registry_Guard_Offset, 0);

      Segments.Try_Prepare_Replacement
        (Source     => Source_Segment,
         Target     => Target_Map,
         Config     => Config,
         Quiescence => Segments.Caller_Established_Quiescence,
         Result     => Migration_Result);
      Assert
        (Migration_Result = Segments.Initialization_In_Progress,
         "replacement exposed an unpublished named extent");

      Segments.Publish_Failure (Source_Segment, Pending_Claim, 91);
      Segments.Try_Remove (Source_Segment, "pending", Remove_Result);
      Assert (Remove_Result = Segments.Removed, "replacement setup could not retire failed initialization");
      Segments.Try_Prepare_Replacement
        (Source     => Source_Segment,
         Target     => Target_Map,
         Config     => Config,
         Quiescence => Segments.Caller_Established_Quiescence,
         Result     => Migration_Result);
      Assert (Migration_Result = Segments.Replacement_Ready, "larger replacement was not published ready");
      Assert
        (not Segments.Is_Attached (Replacement),
         "replacement preparation implicitly attached a process-local view");
      Segments.Create_Or_Attach (Replacement, Target_Map, Config, Segment_Result);
      Assert
        (Segment_Result = Segments.Attached_Existing,
         "published replacement did not attach as an existing segment");
      Assert (Shared.Length (Target_Map) = New_Length, "replacement mapping lost its larger extent");

      Segments.Resolve (Replacement, Handle, Target_Location, Target_Extent);
      Assert
        (Target_Location = Location and then Target_Extent = Extent,
         "replacement changed a published offset or extent");
      Segments.Attach_Region (Replacement, Target_Region);
      Strings.Attach (Target_String, Target_Region, Target_Location, 64);
      Strings.Read (Target_String, Observed);
      Assert (Observed = Payload, "replacement lost stored payload bytes");
      Assert
        (Contains_U64 (Testing.Base (Target_Map), C.size_t (New_Length), Source_Base) = 0
         and then Contains_U64 (Testing.Base (Target_Map), C.size_t (New_Length), Target_Base) = 0,
         "replacement stored a process-local mapping address");
      Strings.Detach (Target_String);
      Regions.Detach (Target_Region);

      Assert (Socketpair (Left'Access, Right'Access) = 0, "replacement handoff socketpair failed");
      Assert
        (Spawn_Child
           (Program,
            Right,
            C.unsigned_long_long (Target_Base),
            C.unsigned_long_long (New_Length),
            Child'Access)
         = 0,
         "replacement handoff helper did not spawn");
      Ignored := Close_Socket (Right);
      Assert (Ignored = 0, "parent did not close replacement child socket endpoint");
      Right := -1;
      Unix_Sockets.Send (Unix_Sockets.Socket_Descriptor (Left), Target_Backing, Unix_Sockets.Borrow);
      Assert (Wait_Child (Child) = 0, "replacement handoff helper failed");
      Child := -1;
      Ignored := Close_Socket (Left);
      Assert (Ignored = 0, "parent did not close replacement handoff socket");
      Left := -1;

      Segments.Attach_Region (Replacement, Target_Region);
      Strings.Attach (Target_String, Target_Region, Target_Location, 64);
      Strings.Read (Target_String, Observed);
      Assert (Observed = Child_Payload, "exec'd helper did not mutate the replacement payload");
      Strings.Detach (Target_String);
      Regions.Detach (Target_Region);

      Segments.Try_Find_Or_Create (Replacement, "reused", 64, Reused, Reuse_Claim, Find_Result, Failure);
      Assert (Find_Result = Segments.Created, "replacement did not reuse a fitting removed reservation");
      Segments.Publish (Replacement, Reuse_Claim);
      Assert
        (Segments.State_Of (Replacement, Pending) = Segments.Stale
         and then Segments.State_Of (Source_Segment, Pending) = Segments.Removed,
         "replacement reuse did not advance only the cloned generation");

      Segments.Try_Find_Or_Create
        (Replacement, "large", Old_Length, Large, Large_Claim, Find_Result, Failure);
      Assert
        (Find_Result = Segments.Created, "larger replacement did not expose its additional allocation tail");
      Segments.Publish (Replacement, Large_Claim);
      Assert
        (Segments.State_Of (Replacement, Handle) = Segments.Ready
         and then Segments.State_Of (Source_Segment, Handle) = Segments.Ready,
         "replacement did not preserve the original generation-stamped handle");

      Shared.Unlink (Target_Backing);
      Shared.Close (Target_Backing);
      Assert (Shared.Is_Mapped (Target_Map), "closing replacement backing invalidated its mapping");
      Segments.Detach (Replacement);
      Shared.Unmap (Target_Map);
      Segments.Detach (Source_Segment);
      Shared.Unmap (Source_Map);
      Shared.Close (Source_Backing);
   exception
      when others =>
         if Child >= 0 then
            Ignored := Kill (Child, 9);
            Ignored := Wait_Child (Child);
         end if;
         if Left >= 0 then
            Ignored := Close_Socket (Left);
         end if;
         if Right >= 0 then
            Ignored := Close_Socket (Right);
         end if;
         if Shared.Is_Open (Target_Opened) then
            Shared.Close (Target_Opened);
         end if;
         if Shared.Is_Open (Target_Backing) then
            begin
               Shared.Unlink (Target_Backing);
            exception
               when others =>
                  null;
            end;
            Shared.Close (Target_Backing);
         end if;
         raise;
   end Check_Replacement_Migration;

   procedure Check_Handoff is
      Backing             : Shared.Backing_Object;
      Parent_Map          : Shared.Mapping;
      Segment             : Segments.View;
      Region              : Regions.View;
      Object              : Strings.View;
      Segment_Result      : Segments.Segment_Open_Result;
      Handle              : Segments.Named_Handle;
      Claim               : Segments.Creation_Claim;
      Location            : DS.Region_Offset;
      Extent              : Shared.Byte_Length;
      Left, Right         : aliased C.int := -1;
      Child               : aliased C.int := -1;
      Program             : constant C.char_array :=
        C.To_C
          (Ada.Directories.Containing_Directory (Ada.Command_Line.Command_Name) & "/shared_memory_child");
      Parent_Base         : Interfaces.Unsigned_64;
      Observed            : Ada.Streams.Stream_Element_Array (1 .. 3);
      Initial             : constant Ada.Streams.Stream_Element_Array :=
        (1 => 16#46#, 2 => 16#6C#, 3 => 16#79#);
      Expected            : constant Ada.Streams.Stream_Element_Array :=
        (1 => 16#49#, 2 => 16#50#, 3 => 16#43#);
      Received            : Shared.Backing_Object;
      Before, After       : C.int;
      Rejected            : Boolean := False;
      Wrong_Size_Rejected : Boolean := False;
      Immutable_Rejected  : Boolean := False;
      Wrong_Type_Rejected : Boolean := False;
      Read_Only_Rejected  : Boolean := False;
      Socket_Rejected     : Boolean := False;
      Ignored             : C.int;
   begin
      Shared.Create_Anonymous (Backing, Mapping_Length);
      Shared.Map (Parent_Map, Backing);
      Parent_Base := Testing.Base_Value (Parent_Map);
      Segments.Create_Or_Attach (Segment, Parent_Map, Config, Segment_Result);
      Assert (Segment_Result = Segments.Initialized_New, "handoff segment did not initialize");
      Segments.Attach_Region (Segment, Region);
      Create_Name (Segment, "handoff", Strings.Required_Storage (16), Handle, Claim);
      Segments.Claimed_Extent (Segment, Claim, Location, Extent);
      Strings.Initialize (Object, Region, Location, 16);
      Strings.Assign (Object, Initial);
      Segments.Publish (Segment, Claim);
      Assert
        (Contains_U64 (Testing.Base (Parent_Map), C.size_t (Mapping_Length), Parent_Base) = 0,
         "stored segment bytes leaked their native mapping base");

      Assert (Socketpair (Left'Access, Right'Access) = 0, "socketpair failed");
      Assert
        (Spawn_Child
           (Program,
            Right,
            C.unsigned_long_long (Parent_Base),
            C.unsigned_long_long (Mapping_Length),
            Child'Access)
         = 0,
         "shared-memory helper did not spawn");
      Ignored := Close_Socket (Right);
      Assert (Ignored = 0, "parent did not close child socket endpoint");
      Right := -1;
      Unix_Sockets.Send (Unix_Sockets.Socket_Descriptor (Left), Backing, Unix_Sockets.Borrow);
      --  sendmsg acceptance is not receiver acceptance. Keep Left connected
      --  until the exec'd child has received, validated, mapped, attached, and
      --  published its mutation. Closing it earlier races peer validation on
      --  Darwin, where getpeername can report EINVAL after peer shutdown.
      Assert (Wait_Child (Child) = 0, "shared-memory helper failed");
      Child := -1;
      Strings.Read (Object, Observed);
      Assert (Observed = Expected, "exec'd helper did not mutate the relocatable object");
      Ignored := Close_Socket (Left);
      Left := -1;
      Assert (Ignored = 0, "parent did not close handoff socket");

      Assert (Socketpair (Left'Access, Right'Access) = 0, "socketpair failed");
      Before := Open_FD_Count;
      Unix_Sockets.Send (Unix_Sockets.Socket_Descriptor (Left), Backing, Unix_Sockets.Borrow);
      begin
         Unix_Sockets.Receive (Unix_Sockets.Socket_Descriptor (Right), Mapping_Length / 2, Received);
      exception
         when Shared.Validation_Error =>
            Wrong_Size_Rejected := True;
      end;
      After := Open_FD_Count;
      Assert (Wrong_Size_Rejected, "wrong-size received descriptor was accepted");
      Assert (After = Before, "wrong-size receive leaked a descriptor");
      Ignored := Close_Socket (Left);
      Assert (Ignored = 0, "wrong-size sender socket close failed");
      Left := -1;
      Ignored := Close_Socket (Right);
      Assert (Ignored = 0, "wrong-size receiver socket close failed");
      Right := -1;

      Assert (Socketpair (Left'Access, Right'Access) = 0, "socketpair failed");
      Before := Open_FD_Count;
      Unix_Sockets.Send (Unix_Sockets.Socket_Descriptor (Left), Backing, Unix_Sockets.Borrow);
      begin
         Unix_Sockets.Receive
           (Unix_Sockets.Socket_Descriptor (Right), Mapping_Length, Received, Require_Immutable_Size => True);
      exception
         when Shared.Security_Error =>
            Immutable_Rejected := True;
      end;
      if Shared.Properties (Backing).Size_Immutable then
         Assert
           (Shared.Is_Open (Received)
            and then Shared.Properties (Received).Close_On_Exec
            and then Shared.Properties (Received).Size_Immutable,
            "immutable received descriptor validation failed");
         Shared.Close (Received);
      else
         Assert
           (Immutable_Rejected and then not Shared.Is_Open (Received),
            "unsealed received descriptor did not fail closed");
      end if;
      After := Open_FD_Count;
      Assert (After = Before, "immutable receive validation leaked an FD");
      Ignored := Close_Socket (Left);
      Assert (Ignored = 0, "immutable sender socket close failed");
      Left := -1;
      Ignored := Close_Socket (Right);
      Assert (Ignored = 0, "immutable receiver socket close failed");
      Right := -1;

      Assert (Socketpair (Left'Access, Right'Access) = 0, "socketpair failed");
      Before := Open_FD_Count;
      Assert (Send_Raw (Left, Left) = 1, "wrong-type ancillary test send failed");
      begin
         Unix_Sockets.Receive (Unix_Sockets.Socket_Descriptor (Right), Mapping_Length, Received);
      exception
         when Shared.Validation_Error =>
            Wrong_Type_Rejected := True;
      end;
      After := Open_FD_Count;
      Assert (Wrong_Type_Rejected, "socket descriptor type was accepted");
      Assert (After = Before, "wrong-type receive leaked a descriptor");
      Ignored := Close_Socket (Left);
      Assert (Ignored = 0, "wrong-type sender socket close failed");
      Left := -1;
      Ignored := Close_Socket (Right);
      Assert (Ignored = 0, "wrong-type receiver socket close failed");
      Right := -1;

      declare
         Read_Only : aliased C.int := -1;
      begin
         Assert
           (Create_Read_Only (C.unsigned_long_long (Mapping_Length), Read_Only'Access) = 0,
            "read-only ancillary backing setup failed");
         Assert (Socketpair (Left'Access, Right'Access) = 0, "socketpair failed");
         Before := Open_FD_Count;
         Assert (Send_Raw (Left, Read_Only) = 1, "read-only ancillary test send failed");
         begin
            Unix_Sockets.Receive (Unix_Sockets.Socket_Descriptor (Right), Mapping_Length, Received);
         exception
            when Shared.Validation_Error =>
               Read_Only_Rejected := True;
         end;
         After := Open_FD_Count;
         Assert (Read_Only_Rejected, "read-only received backing descriptor was accepted");
         Assert (After = Before, "read-only receive leaked a descriptor");
         Ignored := Close_Socket (Read_Only);
         Assert (Ignored = 0, "read-only backing close failed");
         Ignored := Close_Socket (Left);
         Assert (Ignored = 0, "read-only sender socket close failed");
         Left := -1;
         Ignored := Close_Socket (Right);
         Assert (Ignored = 0, "read-only receiver socket close failed");
         Right := -1;
      end;

      begin
         Unix_Sockets.Send
           (Unix_Sockets.Socket_Descriptor (Testing.Descriptor (Backing)), Backing, Unix_Sockets.Borrow);
      exception
         when Unix_Sockets.Protocol_Error =>
            Socket_Rejected := True;
      end;
      Assert (Socket_Rejected, "non-socket handoff endpoint was accepted");

      Assert (Socketpair (Left'Access, Right'Access) = 0, "socketpair failed");
      Before := Open_FD_Count;
      Assert
        (Send_Two (Left, Testing.Descriptor (Backing), Testing.Descriptor (Backing)) = 0,
         "malformed ancillary test send failed");
      begin
         Unix_Sockets.Receive (Unix_Sockets.Socket_Descriptor (Right), Mapping_Length, Received);
      exception
         when Unix_Sockets.Protocol_Error =>
            Rejected := True;
      end;
      After := Open_FD_Count;
      Assert (Rejected, "multiple received descriptors were accepted");
      Assert (After = Before, "malformed receive leaked descriptors");
      Ignored := Close_Socket (Left);
      Assert (Ignored = 0, "malformed sender socket close failed");
      Left := -1;
      Ignored := Close_Socket (Right);
      Assert (Ignored = 0, "malformed receiver socket close failed");
      Right := -1;

      Assert (Socketpair (Left'Access, Right'Access) = 0, "socketpair failed");
      Before := Open_FD_Count;
      declare
         Split_Result : constant C.int :=
           Send_Split (Left, Testing.Descriptor (Backing), Testing.Descriptor (Backing));
      begin
         Assert (Split_Result = 0 or else Split_Result = 1, "split ancillary test send failed");
         if Split_Result = 0 then
            Rejected := False;
            begin
               Unix_Sockets.Receive (Unix_Sockets.Socket_Descriptor (Right), Mapping_Length, Received);
            exception
               when Unix_Sockets.Protocol_Error =>
                  Rejected := True;
            end;
            After := Open_FD_Count;
            Assert (Rejected, "multiple SCM_RIGHTS headers were accepted");
            Assert (After = Before, "split ancillary receive leaked descriptors");
         end if;
      end;
      Ignored := Close_Socket (Left);
      Assert (Ignored = 0, "split ancillary sender close failed");
      Left := -1;
      Ignored := Close_Socket (Right);
      Assert (Ignored = 0, "split ancillary receiver close failed");
      Right := -1;

      Assert (Socketpair (Left'Access, Right'Access) = 0, "socketpair failed");
      Before := Open_FD_Count;
      Assert
        (Send_Many (Left, Testing.Descriptor (Backing), C.unsigned (64)) = 0,
         "many-descriptor ancillary test send failed");
      Rejected := False;
      begin
         Unix_Sockets.Receive (Unix_Sockets.Socket_Descriptor (Right), Mapping_Length, Received);
      exception
         when Unix_Sockets.Protocol_Error =>
            Rejected := True;
      end;
      After := Open_FD_Count;
      Assert (Rejected, "large descriptor set was accepted");
      Assert (After = Before, "large descriptor receive leaked descriptors");
      Ignored := Close_Socket (Left);
      Assert (Ignored = 0, "many-descriptor sender close failed");
      Left := -1;
      Ignored := Close_Socket (Right);
      Assert (Ignored = 0, "many-descriptor receiver close failed");
      Right := -1;

      Assert (Socketpair (Left'Access, Right'Access) = 0, "socketpair failed");
      Before := Open_FD_Count;
      Unix_Sockets.Send (Unix_Sockets.Socket_Descriptor (Left), Backing, Unix_Sockets.Borrow);
      Unix_Sockets.Send (Unix_Sockets.Socket_Descriptor (Left), Backing, Unix_Sockets.Borrow);
      Unix_Sockets.Receive (Unix_Sockets.Socket_Descriptor (Right), Mapping_Length, Received);
      Shared.Close (Received);
      Unix_Sockets.Receive (Unix_Sockets.Socket_Descriptor (Right), Mapping_Length, Received);
      Shared.Close (Received);
      After := Open_FD_Count;
      Assert (After = Before, "back-to-back one-byte handoff records leaked descriptors");
      Ignored := Close_Socket (Left);
      Assert (Ignored = 0, "back-to-back sender close failed");
      Left := -1;
      Ignored := Close_Socket (Right);
      Assert (Ignored = 0, "back-to-back receiver close failed");
      Right := -1;

      declare
         Send_Socket    : Unix_Sockets.Socket_Descriptor;
         Receive_Socket : Unix_Sockets.Socket_Descriptor;
         Sender         : Unix_Sockets.Handoff_Channel;
         Receiver       : Unix_Sockets.Handoff_Channel;
      begin
         Assert (Socketpair (Left'Access, Right'Access) = 0, "owned-channel socketpair failed");
         Send_Socket := Unix_Sockets.Socket_Descriptor (Left);
         Receive_Socket := Unix_Sockets.Socket_Descriptor (Right);
         Unix_Sockets.Adopt (Sender, Send_Socket);
         Unix_Sockets.Adopt (Receiver, Receive_Socket);
         Left := C.int (Send_Socket);
         Right := C.int (Receive_Socket);
         Assert (Left = -1 and then Right = -1, "owned-channel adoption did not consume socket descriptors");
         Unix_Sockets.Send (Sender, Backing, Unix_Sockets.Borrow);
         Unix_Sockets.Receive (Receiver, Mapping_Length, Received);
         Assert
           (Shared.Is_Open (Received) and then Shared.Properties (Received).Close_On_Exec,
            "owned channel did not receive validated backing");
         Shared.Close (Received);
         Unix_Sockets.Close (Sender);
         Unix_Sockets.Close (Sender);
         Unix_Sockets.Close (Receiver);
         Unix_Sockets.Close (Receiver);
         Assert
           (not Unix_Sockets.Is_Open (Sender) and then not Unix_Sockets.Is_Open (Receiver),
            "owned channel close was not idempotent");
      end;

      declare
         Receive_Socket    : Unix_Sockets.Socket_Descriptor;
         Receiver          : Unix_Sockets.Handoff_Channel;
         Busy_Observed     : Boolean := False;
         Busy_Rejected     : Boolean := False;
         Guard_Preserved   : Boolean := False;
         Receive_Succeeded : Boolean := False;
         Unblock_Status    : C.long := -1;

         task Blocking_Receiver
           with Priority => System.Priority'Last is
            entry Start;
            entry Await_Result (Succeeded : out Boolean);
         end Blocking_Receiver;

         task body Blocking_Receiver is
            Local_Item : Shared.Backing_Object;
            Outcome    : Boolean := False;
         begin
            accept Start;
            begin
               Unix_Sockets.Receive (Receiver, Mapping_Length, Local_Item);
               Outcome := Shared.Is_Open (Local_Item);
               Shared.Close (Local_Item);
            exception
               when others =>
                  if Shared.Is_Open (Local_Item) then
                     Shared.Close (Local_Item);
                  end if;
            end;
            accept Await_Result (Succeeded : out Boolean) do
               Succeeded := Outcome;
            end Await_Result;
         end Blocking_Receiver;
      begin
         Assert (Socketpair (Left'Access, Right'Access) = 0, "busy-channel socketpair failed");
         Receive_Socket := Unix_Sockets.Socket_Descriptor (Right);
         Unix_Sockets.Adopt (Receiver, Receive_Socket);
         Right := C.int (Receive_Socket);

         --  Wait until the native receiver has acquired the guard and blocked
         --  in recvmsg. The test-only query does not alter channel traffic.
         Blocking_Receiver.Start;
         for Attempt in 1 .. 10_000 loop
            Busy_Observed := Unix_Testing.Is_Busy (Receiver);
            exit when Busy_Observed;
            delay 0.0;
         end loop;

         if Busy_Observed then
            begin
               Unix_Sockets.Send (Receiver, Backing, Unix_Sockets.Borrow);
            exception
               when Unix_Sockets.Channel_Busy =>
                  Busy_Rejected := True;
            end;
            begin
               Unix_Sockets.Close (Receiver);
            exception
               when Unix_Sockets.Channel_Busy =>
                  Guard_Preserved := True;
            end;
            Unblock_Status := Send_Raw (Left, Testing.Descriptor (Backing));
         elsif Unix_Sockets.Is_Open (Receiver) then
            --  Ensure an unexpected setup failure cannot leave the task
            --  blocked while its enclosing scope waits for termination.
            Unix_Sockets.Close (Receiver);
         end if;

         Blocking_Receiver.Await_Result (Receive_Succeeded);
         if Unix_Sockets.Is_Open (Receiver) then
            Unix_Sockets.Close (Receiver);
         end if;
         Ignored := Close_Socket (Left);
         Left := -1;

         Assert (Busy_Observed, "receiver did not acquire channel guard");
         Assert (Busy_Rejected, "concurrent channel send was not rejected");
         Assert (Guard_Preserved, "rejected send released another operation's channel guard");
         Assert (Unblock_Status = 1, "busy-channel receive unblock failed");
         Assert (Receive_Succeeded, "busy-channel receive did not complete");
         Assert (Ignored = 0, "busy-channel peer close failed");
      end;

      declare
         Receive_Socket : Unix_Sockets.Socket_Descriptor;
         Receiver       : Unix_Sockets.Handoff_Channel;
      begin
         Before := Open_FD_Count;
         Assert (Socketpair (Left'Access, Right'Access) = 0, "validation-channel socketpair failed");
         Receive_Socket := Unix_Sockets.Socket_Descriptor (Right);
         Unix_Sockets.Adopt (Receiver, Receive_Socket);
         Right := C.int (Receive_Socket);
         Unix_Sockets.Send (Unix_Sockets.Socket_Descriptor (Left), Backing, Unix_Sockets.Borrow);
         Wrong_Size_Rejected := False;
         begin
            Unix_Sockets.Receive (Receiver, Mapping_Length / 2, Received);
         exception
            when Shared.Validation_Error =>
               Wrong_Size_Rejected := True;
         end;
         Assert
           (Wrong_Size_Rejected
            and then Unix_Sockets.Is_Poisoned (Receiver)
            and then not Unix_Sockets.Is_Open (Receiver),
            "owned channel did not fail closed after backing validation");
         Ignored := Close_Socket (Left);
         Assert (Ignored = 0, "validation-channel sender close failed");
         Left := -1;
         After := Open_FD_Count;
         Assert (After = Before, "validation failure leaked descriptors");
      end;

      declare
         Receive_Socket : Unix_Sockets.Socket_Descriptor;
         Receiver       : Unix_Sockets.Handoff_Channel;
      begin
         Before := Open_FD_Count;
         Assert (Socketpair (Left'Access, Right'Access) = 0, "poison-channel socketpair failed");
         Receive_Socket := Unix_Sockets.Socket_Descriptor (Right);
         Unix_Sockets.Adopt (Receiver, Receive_Socket);
         Right := C.int (Receive_Socket);
         Assert
           (Send_Many (Left, Testing.Descriptor (Backing), C.unsigned (64)) = 0,
            "poison-channel malformed send failed");
         Rejected := False;
         begin
            Unix_Sockets.Receive (Receiver, Mapping_Length, Received);
         exception
            when Unix_Sockets.Protocol_Error =>
               Rejected := True;
         end;
         Assert
           (Rejected
            and then Unix_Sockets.Is_Poisoned (Receiver)
            and then not Unix_Sockets.Is_Open (Receiver),
            "owned channel did not fail closed after malformed ancillary");
         Ignored := Close_Socket (Left);
         Assert (Ignored = 0, "poison-channel sender close failed");
         Left := -1;
         After := Open_FD_Count;
         Assert (After = Before, "poisoned channel leaked descriptors");
      end;

      declare
         Send_Socket : Unix_Sockets.Socket_Descriptor;
         Sender      : Unix_Sockets.Handoff_Channel;
         Failed      : Boolean := False;
      begin
         Before := Open_FD_Count;
         Assert (Socketpair (Left'Access, Right'Access) = 0, "broken-channel socketpair failed");
         Send_Socket := Unix_Sockets.Socket_Descriptor (Left);
         Unix_Sockets.Adopt (Sender, Send_Socket);
         Left := C.int (Send_Socket);
         Ignored := Close_Socket (Right);
         Assert (Ignored = 0, "broken-channel peer close failed");
         Right := -1;
         begin
            Unix_Sockets.Send (Sender, Backing, Unix_Sockets.Borrow);
         exception
            when Shared.Operating_System_Error =>
               Failed := True;
         end;
         Assert
           (Failed and then Unix_Sockets.Is_Poisoned (Sender),
            "broken channel did not suppress SIGPIPE and fail closed");
         After := Open_FD_Count;
         Assert (After = Before, "broken channel leaked descriptors");
      end;

      declare
         Receive_Socket : Unix_Sockets.Socket_Descriptor;
         Receiver       : Unix_Sockets.Handoff_Channel;
         Unsupported    : Boolean := False;
      begin
         Assert (Socketpair (Left'Access, Right'Access) = 0, "untrusted-channel socketpair failed");
         Receive_Socket := Unix_Sockets.Socket_Descriptor (Right);
         if Is_Linux = 1 then
            Assert
              (Shared.Properties (Backing).Size_Immutable,
               "Linux anonymous backing lacks immutable size seals");
            Unix_Sockets.Adopt (Receiver, Receive_Socket, Unix_Sockets.Untrusted_Peer);
            Right := C.int (Receive_Socket);
            Assert (Send_Raw (Left, Testing.Descriptor (Backing)) = 1, "untrusted-channel send failed");
            Unix_Sockets.Receive (Receiver, Mapping_Length, Received);
            Assert
              (Shared.Is_Open (Received) and then Shared.Properties (Received).Size_Immutable,
               "untrusted channel accepted insufficient backing security");
            Shared.Close (Received);
            Unix_Sockets.Close (Receiver);
         else
            begin
               Unix_Sockets.Adopt (Receiver, Receive_Socket, Unix_Sockets.Untrusted_Peer);
            exception
               when Shared.Security_Error =>
                  Unsupported := True;
            end;
            Assert
              (Unsupported and then Receive_Socket >= 0,
               "Darwin untrusted handoff did not fail closed before adoption");
            Ignored := Close_Socket (C.int (Receive_Socket));
            Assert (Ignored = 0, "untrusted receiver close failed");
            Right := -1;
         end if;
         Ignored := Close_Socket (Left);
         Assert (Ignored = 0, "untrusted sender close failed");
         Left := -1;
      end;

      Strings.Detach (Object);
      Regions.Detach (Region);
      Segments.Detach (Segment);
      Shared.Unmap (Parent_Map);
      Shared.Close (Backing);
   exception
      when others =>
         if Left >= 0 then
            Ignored := Close_Socket (Left);
         end if;
         if Right >= 0 then
            Ignored := Close_Socket (Right);
         end if;
         raise;
   end Check_Handoff;

begin
   Check_Anonymous_And_Registry;
   Check_Named;
   Check_File;
   Check_Exhaustion;
   Check_Replacement_Migration;
   Check_Registry_Corruption;
   Check_Handoff;
end Shared_Memory_Smoke;
