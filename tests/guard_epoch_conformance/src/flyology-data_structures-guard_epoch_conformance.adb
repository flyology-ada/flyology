with Ada.Exceptions;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Data_Structures.Atomics;
with Flyology.Data_Structures.Guard_Test_Hooks;
with Flyology.Data_Structures.Layouts;
with Flyology.Data_Structures.Policy;
with Flyology.Data_Structures.Regions;
with Flyology.Data_Structures.Rings.SPSC;
with Flyology.Data_Structures.Storage_Types.Unsigned_64s;
with Flyology.Data_Structures.Vectors;
with Flyology_TLA.Command_Line;
with Flyology_TLA.Replay;
with Flyology_TLA.Traces;
with Interfaces;
with System;
with System.Storage_Elements;

procedure Flyology.Data_Structures.Guard_Epoch_Conformance is
   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_32;
   package DS renames Flyology.Data_Structures;
   package E renames DS.Storage_Types.Unsigned_64s;
   package V is new DS.Vectors (E.Element);
   package R is new DS.Rings.SPSC (E.Element);
   package Replay renames Flyology_TLA.Replay;
   Limits        : constant Flyology_TLA.Traces.Load_Limits :=
     (Maximum_File_Bytes   => 1_000_000,
      Maximum_Steps        => 10,
      Maximum_JSON_Depth   => 20,
      Maximum_Object_Names => 1000,
      Maximum_Name_Bytes   => 4096,
      Maximum_String_Bytes => 100_000,
      Maximum_Value_Bytes  => 500_000);
   Config        : Flyology_TLA.Command_Line.Configuration :=
     Flyology_TLA.Command_Line.Parse (Limits);
   type Storage_Type is new System.Storage_Elements.Storage_Array (1 .. 4096)
   with Alignment => 64;
   Storage       : aliased Storage_Type := [others => 0];
   Region        : Regions.View;
   First, Second : V.View;
   Ring          : R.View;
   Fixture       : Layouts.Local_View;
   Holder_Active : Boolean := False;
   Peer_Result   : Unbounded_String := To_Unbounded_String ("idle");

   --  Captures are published only by an actual guard owner. No snapshot
   --  mirrors asynchronously changing foreign state: the held caller stays
   --  at the observed CAS boundary until the replay releases it.
   protected Capture is
      procedure Reset;
      procedure Publish
        (Epoch, Auxiliary : Interfaces.Unsigned_32; Stale : Boolean);
      entry Wait_Arrived;
      entry Wait_Released;
      procedure Release;
      procedure Read
        (Epoch, Auxiliary : out Interfaces.Unsigned_32; Stale : out Boolean);
   private
      Arrived, Released, Ever_Stale      : Boolean := False;
      Captured_Epoch, Captured_Auxiliary : Interfaces.Unsigned_32 := 0;
   end Capture;
   protected body Capture is
      procedure Reset is
      begin
         Arrived := False;
         Released := False;
         Ever_Stale := False;
      end Reset;
      procedure Publish
        (Epoch, Auxiliary : Interfaces.Unsigned_32; Stale : Boolean) is
      begin
         Captured_Epoch := Epoch;
         Captured_Auxiliary := Auxiliary;
         Ever_Stale := Ever_Stale or Stale;
         Arrived := True;
      end Publish;
      entry Wait_Arrived when Arrived is
      begin
         null;
      end Wait_Arrived;
      entry Wait_Released when Released is
      begin
         null;
      end Wait_Released;
      procedure Release is
      begin
         Released := True;
      end Release;
      procedure Read
        (Epoch, Auxiliary : out Interfaces.Unsigned_32; Stale : out Boolean) is
      begin
         Epoch := Captured_Epoch;
         Auxiliary := Captured_Auxiliary;
         Stale := Ever_Stale;
      end Read;
   end Capture;

   procedure Observe (Core : Layouts.Local_View; Guard : System.Address) is
      Stale : Boolean := False;
      Probe : R.View;
   begin
      begin
         Layouts.Require_Ready (Core);
      exception
         when DS.Layout_Error =>
            Stale := True;
      end;
      Capture.Publish
        (Policy.State_Epoch
           (Atomics.Load_Acquire_U32 (Layouts.Address_At (Core, 0, 4, 4))),
         Atomics.Load_Acquire_U32 (Guard),
         Stale);
      if Stale then
         begin
            R.Attach (Probe, Region, 64, 2);
            R.Detach (Probe);
            Peer_Result := To_Unbounded_String ("attached");
         exception
            when DS.Layout_Error =>
               Peer_Result := To_Unbounded_String ("configuration-mismatch");
         end;
      else
         Capture.Wait_Released;
      end if;
   end Observe;

   task Holder is
      entry Start;
      entry Finished (Status : out Unbounded_String);
      entry Stop;
   end Holder;
   task body Holder is
      Result : Unbounded_String;
      N      : Natural;
   begin
      loop
         select
            accept Start;
         or
            accept Stop;
            exit;
         end select;
         begin
            N := V.Length (First);
            Result :=
              To_Unbounded_String
                (if N = 0 then "ok" else "unexpected-length");
         exception
            when Ex : others =>
               Result :=
                 To_Unbounded_String (Ada.Exceptions.Exception_Name (Ex));
         end;
         accept Finished (Status : out Unbounded_String) do
            Status := Result;
         end Finished;
      end loop;
   end Holder;

   type Guard_Adapter is new Replay.Adapter with null record;
   overriding
   procedure Reset
     (Self                : in out Guard_Adapter;
      Observed_State_JSON : out Unbounded_String;
      Outcome             : out Replay.Adapter_Outcome);
   overriding
   procedure Apply
     (Self                                       : in out Guard_Adapter;
      Command                                    : Replay.Replay_Command;
      Observed_Outcome_JSON, Observed_State_JSON : out Unbounded_String;
      Outcome                                    : out Replay.Adapter_Outcome);

   function State_JSON return Unbounded_String is
      Epoch, Auxiliary : Interfaces.Unsigned_32;
      Stale            : Boolean;
      function Number (Value : Interfaces.Unsigned_32) return String
      is (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Both));
   begin
      Capture.Read (Epoch, Auxiliary, Stale);
      if not Holder_Active then
         Epoch :=
           Policy.State_Epoch
             (Atomics.Load_Acquire_U32
                (Layouts.Address_At (Fixture, 0, 4, 4)));
         Auxiliary :=
           Atomics.Load_Acquire_U32 (Layouts.Address_At (Fixture, 44, 4, 4));
      end if;
      return
        To_Unbounded_String
          ("{""epoch"":"
           & Number (Epoch)
           & ",""auxiliary"":"
           & Number (Auxiliary)
           & ",""staleWrite"":"
           & (if Stale then "true" else "false")
           & ",""peer"":"""
           & To_String (Peer_Result)
           & """}");
   end State_JSON;

   overriding
   procedure Reset
     (Self                : in out Guard_Adapter;
      Observed_State_JSON : out Unbounded_String;
      Outcome             : out Replay.Adapter_Outcome)
   is
      pragma Unreferenced (Self);
   begin
      Regions.Attach (Region, Storage'Address, DS.Byte_Count (Storage'Length));
      V.Initialize (First, Region, 64, 2);
      V.Attach (Second, Region, 64, 2);
      Fixture := Layouts.Capture (Region, 64, Layouts.Header_Size, 8);
      Capture.Reset;
      if Guard_Test_Hooks.Enabled then
         Guard_Test_Hooks.Set_Observer (Observe'Unrestricted_Access);
      end if;
      Observed_State_JSON := State_JSON;
      Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
   end Reset;

   overriding
   procedure Apply
     (Self                                       : in out Guard_Adapter;
      Command                                    : Replay.Replay_Command;
      Observed_Outcome_JSON, Observed_State_JSON : out Unbounded_String;
      Outcome                                    : out Replay.Adapter_Outcome)
   is
      pragma Unreferenced (Self);
      Action : constant String := To_String (Command.Action);
      Result : Unbounded_String;
      N      : Natural;
      Probe  : R.View;
   begin
      if Action = "GuardedMapAttach!HoldValid" then
         Holder.Start;
         Holder_Active := True;
         Capture.Wait_Arrived;
         Result := To_Unbounded_String ("pending");
      elsif Action = "GuardedMapAttach!CallContended" then
         begin
            N := V.Length (Second);
            Result := To_Unbounded_String ("unexpected-success" & N'Image);
         exception
            when DS.Busy_Error =>
               Result := To_Unbounded_String ("busy");
         end;
      elsif Action = "GuardedMapAttach!ReleaseHeld" then
         Capture.Release;
         Holder.Finished (Result);
         Holder_Active := False;
      elsif Action = "GuardedMapAttach!ReinitializeSPSC" then
         R.Initialize (Ring, Region, 64, 2);
         Result := To_Unbounded_String ("reinitialized");
      elsif Action = "GuardedMapAttach!CallStale" then
         begin
            N := V.Length (Second);
            Result := To_Unbounded_String ("unexpected-success" & N'Image);
         exception
            when DS.Layout_Error =>
               Result := To_Unbounded_String ("stale");
         end;
      elsif Action = "GuardedMapAttach!AttachPeer" then
         R.Attach (Probe, Region, 64, 2);
         R.Detach (Probe);
         Peer_Result := To_Unbounded_String ("attached");
         Result := Peer_Result;
      else
         raise Program_Error with "unsupported guard replay action";
      end if;
      Observed_Outcome_JSON :=
        To_Unbounded_String ("{""status"":""" & To_String (Result) & """}");
      Observed_State_JSON := State_JSON;
      Outcome := (Succeeded => True, Detail => Null_Unbounded_String);
   end Apply;

   Adapter : Guard_Adapter;
   Result  : Replay.Replay_Result_V2;
   Ignored : Unbounded_String;

   procedure Shutdown is
   begin
      if Holder_Active then
         Capture.Release;
         Holder.Finished (Ignored);
         Holder_Active := False;
      end if;
      Holder.Stop;
      if Guard_Test_Hooks.Enabled then
         Guard_Test_Hooks.Reset;
      end if;
   end Shutdown;
begin
   if Flyology_TLA.Command_Line.Help_Requested (Config) then
      Flyology_TLA.Command_Line.Put_Help;
   else
      declare
         Trace : constant Flyology_TLA.Traces.Trace :=
           Flyology_TLA.Command_Line.Load (Config);
      begin
         Replay.Run
           (Adapter, Trace, Flyology_TLA.Command_Line.Limits (Config), Result);
         Flyology_TLA.Command_Line.Report (Config, Result);
         Flyology_TLA.Command_Line.Set_Exit_Status (Result);
      end;
   end if;
   Shutdown;
exception
   when others =>
      Shutdown;
      raise;
end Flyology.Data_Structures.Guard_Epoch_Conformance;
