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
   package C renames Interfaces.C;

   use type Ada.Streams.Stream_Element_Array;
   use type DS.Region_Offset;
   use type Interfaces.Unsigned_32;
   use type C.int;
   use type Shared.Backing_Kind;
   use type Shared.Byte_Length;
   use type Shared.Namespace_Open_Result;
   use type Segments.Find_Or_Create_Result;
   use type Segments.Handle_State;
   use type Segments.Lookup_Result;
   use type Segments.Remove_Result;
   use type Segments.Segment_Open_Result;

   Mapping_Length : constant Shared.Byte_Length := 1_048_576;
   Config : constant Segments.Configuration :=
     (Schema               => 16#5348_4152_4544_0001#,
      Registry_Capacity    => 16,
      Maximum_Name_Length  => 64,
      Allocation_Alignment => 64);

   function Getpid return C.int;
   pragma Import (C, Getpid, "getpid");
   function Is_Linux return C.int;
   pragma Import (C, Is_Linux, "flyology_test_is_linux");

   function Socketpair
     (Left, Right : access C.int) return C.int;
   pragma Import (C, Socketpair, "flyology_test_shared_socketpair");
   function Spawn_Child
     (Program     : C.char_array;
      Socket      : C.int;
      Parent_Base : C.unsigned_long_long;
      Length      : C.unsigned_long_long;
      PID         : access C.int) return C.int;
   pragma Import
     (C, Spawn_Child, "flyology_test_spawn_shared_memory_child");
   function Wait_Child (PID : C.int) return C.int;
   pragma Import
     (C, Wait_Child, "flyology_test_wait_shared_memory_child");
   function Close_Socket (Socket : C.int) return C.int;
   pragma Import
     (C, Close_Socket, "flyology_test_close_shared_socket");
   function Send_Two
     (Socket, First, Second : C.int) return C.int;
   pragma Import
     (C, Send_Two, "flyology_test_send_two_descriptors");
   function Send_Raw (Socket, Descriptor : C.int) return C.int;
   pragma Import (C, Send_Raw, "flyology_shm_send_fd");
   function Open_FD_Count return C.int;
   pragma Import (C, Open_FD_Count, "flyology_test_open_fd_count");
   function Contains_U64
     (Base   : System.Address;
      Length : C.size_t;
      Value  : Interfaces.Unsigned_64) return C.int;
   pragma Import
     (C, Contains_U64, "flyology_test_mapping_contains_u64");
   function Size_Changes_Rejected
     (Descriptor : C.int; Length : C.unsigned_long_long) return C.int;
   pragma Import
     (C, Size_Changes_Rejected, "flyology_test_size_changes_rejected");
   function Create_Unsized
     (Name : C.char_array; Descriptor : access C.int) return C.int;
   pragma Import
     (C, Create_Unsized, "flyology_test_create_unsized_shm");
   function Close_Unsized
     (Name : C.char_array; Descriptor : C.int) return C.int;
   pragma Import
     (C, Close_Unsized, "flyology_test_close_unsized_shm");

   procedure Assert (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         raise Program_Error with Message;
      end if;
   end Assert;

   function Identifier return String is
     (Ada.Strings.Fixed.Trim (C.int'Image (Getpid), Ada.Strings.Both));

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
         Segments.Try_Find_Or_Create
           (Segment, Name, Length, Handle, Claim, Result, Failure);
         exit when Result /= Segments.Registry_Busy;
         delay 0.0;
      end loop;
      Assert (Result = Segments.Created, "named extent was not created");
      Assert (Failure = 0, "new extent reported a failure code");
   end Create_Name;

   procedure Check_Anonymous_And_Registry is
      Backing : Shared.Backing_Object;
      Required : Shared.Backing_Object;
      Left, Right : Shared.Mapping;
      Segment_Left, Segment_Right : Segments.View;
      Region_Left, Region_Right : Regions.View;
      Opened : Segments.Segment_Open_Result;
      First, Second, Pending, Reused, Existing : Segments.Named_Handle;
      First_Claim, Second_Claim, Pending_Claim, Reuse_Claim :
        Segments.Creation_Claim;
      First_Location, Other_Location : DS.Region_Offset;
      First_Length, Other_Length : Shared.Byte_Length;
      Result : Segments.Find_Or_Create_Result;
      Lookup : Segments.Lookup_Result;
      Removed : Segments.Remove_Result;
      Failure : Interfaces.Unsigned_32;
      String_Left, String_Right : Strings.View;
      Payload : constant Ada.Streams.Stream_Element_Array :=
        (1 => 16#46#, 2 => 16#6C#, 3 => 16#79#);
      Observed : Ada.Streams.Stream_Element_Array (Payload'Range);
      Props : Shared.Security_Properties;
      Noexec_Rejected : Boolean := False;
   begin
      Shared.Create_Anonymous (Backing, Mapping_Length);
      Props := Shared.Properties (Backing);
      Assert (Props.Close_On_Exec, "anonymous descriptor lacks CLOEXEC");
      if Is_Linux = 1 then
         Assert
           (not Props.Owner_Only_Permissions,
            "Linux memfd mode bits were misreported as owner-only");
         Assert
           (Props.Size_Immutable,
            "Linux anonymous descriptor lacks immutable size seals");
         Assert
           (Size_Changes_Rejected
              (Testing.Descriptor (Backing),
               C.unsigned_long_long (Mapping_Length)) = 1,
            "sealed anonymous size accepted grow or shrink");
      else
         Assert
           (Props.Owner_Only_Permissions,
            "Darwin anonymous descriptor permissions are not owner-only");
      end if;
      if Props.No_Execute_Seal_Supported then
         Assert
           (Props.No_Execute_Seal,
            "supported anonymous no-execute seal was not applied");
      end if;
      if Props.No_Execute_Seal then
         Shared.Create_Anonymous
           (Required, Mapping_Length,
            Require_No_Execute_Seal => True);
         Assert
           (Shared.Properties (Required).No_Execute_Seal,
            "required no-execute seal was not reported");
         Shared.Close (Required);
      else
         begin
            Shared.Create_Anonymous
              (Required, Mapping_Length,
               Require_No_Execute_Seal => True);
         exception
            when Shared.Security_Error =>
               Noexec_Rejected := True;
         end;
         Assert
           (Noexec_Rejected,
            "unavailable required no-execute seal did not fail closed");
      end if;
      Assert
        (Shared.Kind (Backing) = Shared.Anonymous_Capability,
         "anonymous backing kind is wrong");
      Shared.Map (Left, Backing);
      Shared.Map (Right, Backing);
      Shared.Close (Backing);
      Assert
        (not Shared.Is_Open (Backing),
         "anonymous descriptor stayed open");

      Segments.Create_Or_Attach (Segment_Left, Left, Config, Opened);
      Assert
        (Opened = Segments.Initialized_New,
         "first anonymous mapping did not initialize segment");
      Segments.Create_Or_Attach (Segment_Right, Right, Config, Opened);
      Assert
        (Opened = Segments.Attached_Existing,
         "second anonymous mapping did not attach segment");
      Segments.Attach_Region (Segment_Left, Region_Left);
      Segments.Attach_Region (Segment_Right, Region_Right);

      --  These two strings have the same 32-bit FNV-1a hash. Exact byte
      --  comparison must keep their registry entries distinct.
      Create_Name
        (Segment_Left, "costarring", Strings.Required_Storage (32),
         First, First_Claim);
      Segments.Claimed_Extent
        (Segment_Left, First_Claim, First_Location, First_Length);
      Strings.Initialize (String_Left, Region_Left, First_Location, 32);
      Strings.Assign (String_Left, Payload);
      Segments.Publish (Segment_Left, First_Claim);

      Create_Name
        (Segment_Right, "liquid", Strings.Required_Storage (16),
         Second, Second_Claim);
      Segments.Claimed_Extent
        (Segment_Right, Second_Claim, Other_Location, Other_Length);
      Assert
        (Other_Location /= First_Location,
         "hash-colliding exact names aliased one extent");
      Segments.Publish (Segment_Right, Second_Claim);

      Segments.Try_Find_Or_Create
        (Segment_Right, "costarring", Strings.Required_Storage (32),
         Existing, Reuse_Claim, Result, Failure);
      Assert
        (Result = Segments.Attached_Existing,
         "duplicate exact name did not attach existing extent");
      Segments.Resolve
        (Segment_Right, Existing, Other_Location, Other_Length);
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
            Creator_Count : Natural := 0;
            Complete_Count : Natural := 0;
            Passed_All : Boolean := True;
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
            function Creators return Natural is (Creator_Count);
            function Completed return Natural is (Complete_Count);
            function All_Passed return Boolean is (Passed_All);
         end Summary;

         task type Racer is
            pragma Task_Info (Flyology.Native_Task);
         end Racer;

         task body Racer is
            Race_Handle : Segments.Named_Handle;
            Race_Claim : Segments.Creation_Claim;
            Race_Result : Segments.Find_Or_Create_Result;
            Race_Failure : Interfaces.Unsigned_32;
            Creator : Boolean := False;
         begin
            loop
               Segments.Try_Find_Or_Create
                 (Segment_Left, "native-race", 512, Race_Handle, Race_Claim,
                  Race_Result, Race_Failure);
               case Race_Result is
                  when Segments.Created =>
                     Creator := True;
                     Segments.Publish (Segment_Left, Race_Claim);
                     exit;
                  when Segments.Attached_Existing =>
                     exit;
                  when Segments.Registry_Busy |
                       Segments.Initialization_In_Progress =>
                     delay 0.0;
                  when others =>
                     raise Program_Error with
                       "unexpected native registry race result";
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
           (Summary.Creators = 1 and then Summary.Completed = 16
            and then Summary.All_Passed,
            "native find-or-create race did not elect exactly one creator");
      end;

      Create_Name (Segment_Left, "pending", 256, Pending, Pending_Claim);
      Segments.Try_Find
        (Segment_Right, "pending", Existing, Lookup, Failure);
      Assert
        (Lookup = Segments.Initialization_In_Progress,
         "unpublished extent was exposed as ready");
      Segments.Publish_Failure (Segment_Left, Pending_Claim, 77);
      Segments.Try_Find
        (Segment_Right, "pending", Existing, Lookup, Failure);
      Assert
        (Lookup = Segments.Initialization_Failed and then Failure = 77,
         "published initialization failure was lost");
      Assert
        (Segments.Failure_Of (Segment_Right, Existing) = 77,
         "failed handle returned wrong code");
      Segments.Try_Remove (Segment_Right, "pending", Removed);
      Assert (Removed = Segments.Removed, "failed name was not removed");
      Assert
        (Segments.State_Of (Segment_Left, Pending) = Segments.Removed,
         "removed handle did not become inactive");

      Create_Name (Segment_Right, "reused", 128, Reused, Reuse_Claim);
      Segments.Claimed_Extent
        (Segment_Right, Reuse_Claim, Other_Location, Other_Length);
      Segments.Publish (Segment_Right, Reuse_Claim);
      Assert
        (Segments.State_Of (Segment_Left, Pending) = Segments.Stale,
         "extent reuse did not stale the old generation");
      Assert
        (Segments.State_Of (Segment_Left, Reused) = Segments.Ready,
         "reused extent did not publish ready");

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
      Name : constant String := "/flyology-smoke-" & Identifier;
      Created, Opened : Shared.Backing_Object;
      Map_Created, Map_Opened : Shared.Mapping;
      Segment_Created, Segment_Opened : Segments.View;
      Namespace_Result : Shared.Namespace_Open_Result;
      Segment_Result : Segments.Segment_Open_Result;
      Mismatch_Rejected : Boolean := False;
      Unsized_Name : constant String := Name & "-unsized";
      C_Unsized_Name : constant C.char_array := C.To_C (Unsized_Name);
      Unsized_FD : aliased C.int := -1;
   begin
      Shared.Create_Or_Open_Named
        (Created, Name, Mapping_Length, Namespace_Result);
      Assert
        (Namespace_Result = Shared.Created_New,
         "create-or-open did not report creation");
      Assert
        (Shared.Properties (Created).Close_On_Exec
         and then Shared.Properties (Created).Owner_Only_Permissions,
         "named object security properties are wrong");
      Shared.Map (Map_Created, Created);
      Segments.Create_Or_Attach
        (Segment_Created, Map_Created, Config, Segment_Result);
      Assert
        (Segment_Result = Segments.Initialized_New,
         "named segment did not initialize");
      Shared.Create_Or_Open_Named
        (Opened, Name, Mapping_Length, Namespace_Result);
      Assert
        (Namespace_Result = Shared.Opened_Existing,
         "named object did not open existing");
      Shared.Map (Map_Opened, Opened);
      Segments.Create_Or_Attach
        (Segment_Opened, Map_Opened, Config, Segment_Result);
      Assert
        (Segment_Result = Segments.Attached_Existing,
         "named segment opener did not attach");
      Segments.Detach (Segment_Opened);
      Shared.Unmap (Map_Opened);
      Shared.Close (Opened);

      begin
         Shared.Open_Named
           (Opened, Name, Mapping_Length / 2, Namespace_Result);
      exception
         when Shared.Validation_Error =>
            Mismatch_Rejected := True;
      end;
      Assert (Mismatch_Rejected, "named wrong-size open was accepted");

      Assert
        (Create_Unsized (C_Unsized_Name, Unsized_FD'Access) = 0,
         "unsized named object setup failed");
      Shared.Open_Named
        (Opened, Unsized_Name, Mapping_Length, Namespace_Result);
      Assert
        (Namespace_Result = Shared.Initialization_In_Progress
         and then not Shared.Is_Open (Opened),
         "opener did not report creator sizing in progress");
      Assert
        (Close_Unsized (C_Unsized_Name, Unsized_FD) = 0,
         "unsized named object cleanup failed");
      Unsized_FD := -1;
      Shared.Unlink (Created);
      Shared.Unlink (Created);
      Segments.Detach (Segment_Created);
      Shared.Unmap (Map_Created);
      Shared.Close (Created);
   exception
      when others =>
         if Shared.Is_Open (Created) then
            begin
               Shared.Unlink (Created);
            exception
               when others => null;
            end;
         end if;
         if Unsized_FD >= 0 then
            declare
               Ignored : constant C.int :=
                 Close_Unsized (C_Unsized_Name, Unsized_FD);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         end if;
         raise;
   end Check_Named;

   procedure Check_File is
      Root : constant String :=
        Ada.Environment_Variables.Value
          ("FLYOLOGY_TEST_TEMP_ROOT", "/tmp");
      Path : constant String := Root & "/shared-memory-smoke.data";
      Created, Opened : Shared.Backing_Object;
      Map_Created, Map_Opened : Shared.Mapping;
      Segment_Created, Segment_Opened : Segments.View;
      Segment_Result : Segments.Segment_Open_Result;
   begin
      Shared.Create_File (Created, Path, Mapping_Length);
      Assert
        (Shared.Properties (Created).Close_On_Exec
         and then Shared.Properties (Created).No_Symlink_Follow
         and then Shared.Properties (Created).Owner_Only_Permissions,
         "file-backed object security properties are wrong");
      Shared.Map (Map_Created, Created);
      Segments.Create_Or_Attach
        (Segment_Created, Map_Created, Config, Segment_Result);
      Assert
        (Segment_Result = Segments.Initialized_New,
         "file-backed segment did not initialize");
      Shared.Flush (Map_Created);
      Shared.Flush (Created);
      Segments.Detach (Segment_Created);
      Shared.Unmap (Map_Created);
      Shared.Close (Created);

      Shared.Open_File (Opened, Path, Mapping_Length);
      Shared.Map (Map_Opened, Opened);
      Segments.Create_Or_Attach
        (Segment_Opened, Map_Opened, Config, Segment_Result);
      Assert
        (Segment_Result = Segments.Attached_Existing,
         "file-backed segment did not persist");
      Shared.Unlink (Opened);
      Segments.Detach (Segment_Opened);
      Shared.Unmap (Map_Opened);
      Shared.Close (Opened);
   exception
      when others =>
         if Shared.Is_Open (Opened) then
            begin
               Shared.Unlink (Opened);
            exception
               when others => null;
            end;
         elsif Shared.Is_Open (Created) then
            begin
               Shared.Unlink (Created);
            exception
               when others => null;
            end;
         end if;
         raise;
   end Check_File;

   procedure Check_Exhaustion is
      Small_Config : constant Segments.Configuration :=
        (Schema               => 16#534D_414C_4C00_0001#,
         Registry_Capacity    => 1,
         Maximum_Name_Length  => 8,
         Allocation_Alignment => 64);
      Small_Length : constant Shared.Byte_Length := 16_384;
      Backing : Shared.Backing_Object;
      Map : Shared.Mapping;
      Segment : Segments.View;
      Segment_Result : Segments.Segment_Open_Result;
      Handle : Segments.Named_Handle;
      Claim : Segments.Creation_Claim;
      Result : Segments.Find_Or_Create_Result;
      Failure : Interfaces.Unsigned_32;
   begin
      Shared.Create_Anonymous (Backing, Small_Length);
      Shared.Map (Map, Backing);
      Segments.Create_Or_Attach
        (Segment, Map, Small_Config, Segment_Result);
      Assert
        (Segment_Result = Segments.Initialized_New,
         "small segment did not initialize");
      Segments.Try_Find_Or_Create
        (Segment, "large", Small_Length, Handle, Claim, Result, Failure);
      Assert
        (Result = Segments.Segment_Exhausted,
         "small segment did not report byte exhaustion");
      Segments.Try_Find_Or_Create
        (Segment, "one", 64, Handle, Claim, Result, Failure);
      Assert
        (Result = Segments.Created,
         "small segment did not create extent");
      Segments.Publish (Segment, Claim);
      Segments.Try_Find_Or_Create
        (Segment, "one", 32, Handle, Claim, Result, Failure);
      Assert
        (Result = Segments.Configuration_Mismatch,
         "duplicate name accepted a different extent length");
      Segments.Try_Find_Or_Create
        (Segment, "two", 8, Handle, Claim, Result, Failure);
      Assert
        (Result = Segments.Registry_Exhausted,
         "full registry did not report slot exhaustion");
      Segments.Detach (Segment);
      Shared.Unmap (Map);
      Shared.Close (Backing);
   end Check_Exhaustion;

   procedure Check_Handoff is
      Backing : Shared.Backing_Object;
      Parent_Map : Shared.Mapping;
      Segment : Segments.View;
      Region : Regions.View;
      Object : Strings.View;
      Segment_Result : Segments.Segment_Open_Result;
      Handle : Segments.Named_Handle;
      Claim : Segments.Creation_Claim;
      Location : DS.Region_Offset;
      Extent : Shared.Byte_Length;
      Left, Right : aliased C.int := -1;
      Child : aliased C.int := -1;
      Program : constant C.char_array := C.To_C
        (Ada.Directories.Containing_Directory
           (Ada.Command_Line.Command_Name) & "/shared_memory_child");
      Parent_Base : Interfaces.Unsigned_64;
      Observed : Ada.Streams.Stream_Element_Array (1 .. 3);
      Initial : constant Ada.Streams.Stream_Element_Array :=
        (1 => 16#46#, 2 => 16#6C#, 3 => 16#79#);
      Expected : constant Ada.Streams.Stream_Element_Array :=
        (1 => 16#49#, 2 => 16#50#, 3 => 16#43#);
      Received : Shared.Backing_Object;
      Before, After : C.int;
      Rejected : Boolean := False;
      Wrong_Size_Rejected : Boolean := False;
      Immutable_Rejected : Boolean := False;
      Wrong_Type_Rejected : Boolean := False;
      Ignored : C.int;
   begin
      Shared.Create_Anonymous (Backing, Mapping_Length);
      Shared.Map (Parent_Map, Backing);
      Parent_Base := Testing.Base_Value (Parent_Map);
      Segments.Create_Or_Attach
        (Segment, Parent_Map, Config, Segment_Result);
      Assert
        (Segment_Result = Segments.Initialized_New,
         "handoff segment did not initialize");
      Segments.Attach_Region (Segment, Region);
      Create_Name
        (Segment, "handoff", Strings.Required_Storage (16), Handle, Claim);
      Segments.Claimed_Extent (Segment, Claim, Location, Extent);
      Strings.Initialize (Object, Region, Location, 16);
      Strings.Assign (Object, Initial);
      Segments.Publish (Segment, Claim);
      Assert
        (Contains_U64
           (Testing.Base (Parent_Map), C.size_t (Mapping_Length),
            Parent_Base) = 0,
         "stored segment bytes leaked their native mapping base");

      Assert (Socketpair (Left'Access, Right'Access) = 0, "socketpair failed");
      Assert
        (Spawn_Child
           (Program, Right, C.unsigned_long_long (Parent_Base),
            C.unsigned_long_long (Mapping_Length), Child'Access) = 0,
         "shared-memory helper did not spawn");
      Ignored := Close_Socket (Right);
      Assert (Ignored = 0, "parent did not close child socket endpoint");
      Right := -1;
      Unix_Sockets.Send
        (Unix_Sockets.Socket_Descriptor (Left), Backing,
         Unix_Sockets.Borrow);
      Assert (Wait_Child (Child) = 0, "shared-memory helper failed");
      Child := -1;
      Strings.Read (Object, Observed);
      Assert
        (Observed = Expected,
         "exec'd helper did not mutate the relocatable object");
      Ignored := Close_Socket (Left);
      Left := -1;
      Assert (Ignored = 0, "parent did not close handoff socket");

      Assert (Socketpair (Left'Access, Right'Access) = 0, "socketpair failed");
      Before := Open_FD_Count;
      Unix_Sockets.Send
        (Unix_Sockets.Socket_Descriptor (Left), Backing,
         Unix_Sockets.Borrow);
      begin
         Unix_Sockets.Receive
           (Unix_Sockets.Socket_Descriptor (Right), Mapping_Length / 2,
            Received);
      exception
         when Shared.Validation_Error =>
            Wrong_Size_Rejected := True;
      end;
      After := Open_FD_Count;
      Assert
        (Wrong_Size_Rejected,
         "wrong-size received descriptor was accepted");
      Assert (After = Before, "wrong-size receive leaked a descriptor");
      Ignored := Close_Socket (Left);
      Assert (Ignored = 0, "wrong-size sender socket close failed");
      Left := -1;
      Ignored := Close_Socket (Right);
      Assert (Ignored = 0, "wrong-size receiver socket close failed");
      Right := -1;

      Assert (Socketpair (Left'Access, Right'Access) = 0, "socketpair failed");
      Before := Open_FD_Count;
      Unix_Sockets.Send
        (Unix_Sockets.Socket_Descriptor (Left), Backing,
         Unix_Sockets.Borrow);
      begin
         Unix_Sockets.Receive
           (Unix_Sockets.Socket_Descriptor (Right), Mapping_Length, Received,
            Require_Immutable_Size => True);
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
      Assert
        (Send_Raw (Left, Left) = 0,
         "wrong-type ancillary test send failed");
      begin
         Unix_Sockets.Receive
           (Unix_Sockets.Socket_Descriptor (Right), Mapping_Length, Received);
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

      Assert (Socketpair (Left'Access, Right'Access) = 0, "socketpair failed");
      Before := Open_FD_Count;
      Assert
        (Send_Two
           (Left, Testing.Descriptor (Backing),
            Testing.Descriptor (Backing)) = 0,
         "malformed ancillary test send failed");
      begin
         Unix_Sockets.Receive
           (Unix_Sockets.Socket_Descriptor (Right), Mapping_Length, Received);
      exception
         when Shared.Operating_System_Error =>
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
   Check_Handoff;
end Shared_Memory_Smoke;
