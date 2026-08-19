--  Copyright (c) 2026 Yurii Rashkovskii
--  SPDX-License-Identifier: MIT OR Apache-2.0

with Ada.Unchecked_Deallocation;
with Flyology_Bench.Internal_Probes.Counters;
with Interfaces.C;
with System;

package body Flyology_Bench.Internal_Probes.Sessions is
   package C renames Interfaces.C;

   use type C.int;
   use type C.size_t;
   use type Interfaces.Unsigned_64;
   use type System.Address;

   ---------------------------------------------------------------------
   --  Registry lock                                                   --
   ---------------------------------------------------------------------

   --  A pthread mutex rather than a protected object: the same lock is
   --  taken from a thread-exit callback, which runs while the platform is
   --  tearing the thread down and must not depend on the tasking runtime.
   Native_Mutex_Size : constant C.size_t;
   pragma Import
     (C, Native_Mutex_Size, "flyology_bench_pthread_mutex_size");

   --  Reserved storage, checked against the platform's own size during
   --  elaboration, so the mutex can be initialized in place.
   Mutex_Storage_Bytes : constant := 128;

   type Mutex_Storage is
     array (1 .. Mutex_Storage_Bytes) of Interfaces.Unsigned_8
     with Alignment => 16;

   Registry : Mutex_Storage := [others => 0];
   Registry_Ready : Boolean := False;

   function Mutex_Initialize
     (Mutex : System.Address; Attributes : System.Address) return C.int;
   pragma Import (C, Mutex_Initialize, "pthread_mutex_init");

   function Mutex_Lock (Mutex : System.Address) return C.int;
   pragma Import (C, Mutex_Lock, "pthread_mutex_lock");

   function Mutex_Unlock (Mutex : System.Address) return C.int;
   pragma Import (C, Mutex_Unlock, "pthread_mutex_unlock");

   function Acquire return Boolean is
     (Registry_Ready and then Mutex_Lock (Registry'Address) = 0);

   procedure Release is
      Ignored : constant C.int := Mutex_Unlock (Registry'Address);
      pragma Unreferenced (Ignored);
   begin
      null;
   end Release;

   ---------------------------------------------------------------------
   --  Worker identity                                                 --
   ---------------------------------------------------------------------

   type Exit_Handler is access procedure (Token : System.Address)
     with Convention => C;

   function Thread_Token (At_Exit : Exit_Handler) return System.Address;
   pragma Import (C, Thread_Token, "flyology_bench_thread_token");

   procedure Release_Thread (Token : System.Address)
     with Convention => C;

   ---------------------------------------------------------------------
   --  Registry                                                        --
   ---------------------------------------------------------------------

   type Context_Record;
   type Context_Access is access Context_Record;
   type Context_Record is limited record
      Owner : System.Address := System.Null_Address;
      Group : Counters.Group;
      Next  : Context_Access := null;
   end record;

   type Session_Record;
   type Session_Access is access Session_Record;
   type Session_Record is limited record
      Name      : Identifier := No_Session;
      Requested : Interfaces.Unsigned_64 := 0;
      Contexts  : Context_Access := null;
      Next      : Session_Access := null;
   end record;

   procedure Free is new Ada.Unchecked_Deallocation
     (Context_Record, Context_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (Session_Record, Session_Access);

   Known : Session_Access := null;
   Issued : Identifier := No_Session;

   --  Callers hold the registry lock for every operation below.

   function Find (Session : Identifier) return Session_Access is
      Item : Session_Access := Known;
   begin
      while Item /= null and then Item.Name /= Session loop
         Item := Item.Next;
      end loop;
      return Item;
   end Find;

   procedure Clear (Item : Session_Access) is
      Context : Context_Access := Item.Contexts;
      Retired : Context_Access;
   begin
      while Context /= null loop
         Retired := Context;
         Context := Context.Next;
         Counters.Close (Retired.Group);
         Free (Retired);
      end loop;
      Item.Contexts := null;
   end Clear;

   procedure Drop_Owner (Item : Session_Access; Token : System.Address) is
      Previous : Context_Access := null;
      Context  : Context_Access := Item.Contexts;
      Retired  : Context_Access;
   begin
      while Context /= null loop
         if Context.Owner = Token then
            Retired := Context;
            Context := Context.Next;
            if Previous = null then
               Item.Contexts := Context;
            else
               Previous.Next := Context;
            end if;
            Counters.Close (Retired.Group);
            Free (Retired);
         else
            Previous := Context;
            Context := Context.Next;
         end if;
      end loop;
   end Drop_Owner;

   --  Runs on the exiting worker, so its counters close before a later
   --  thread can be handed the same platform identity.
   procedure Release_Thread (Token : System.Address) is
      Locked : Boolean := False;
      Item   : Session_Access;
   begin
      if Token = System.Null_Address then
         return;
      end if;
      Locked := Acquire;
      if not Locked then
         return;
      end if;
      Item := Known;
      while Item /= null loop
         Drop_Owner (Item, Token);
         Item := Item.Next;
      end loop;
      Release;
   exception
      --  A callback that raised into the platform's thread teardown would
      --  end the process rather than the thread.
      when others =>
         if Locked then
            Release;
         end if;
   end Release_Thread;

   ---------------------------------------------------------------------
   --  Sessions                                                        --
   ---------------------------------------------------------------------

   function Start
     (Requested_Mask : Interfaces.Unsigned_64) return Identifier
   is
      Created : Session_Access := null;
      Locked  : Boolean := False;
      Name    : Identifier;
   begin
      if Requested_Mask = 0 then
         return No_Session;
      end if;
      Created := new Session_Record;
      Locked := Acquire;
      if not Locked then
         Free (Created);
         return No_Session;
      end if;
      Issued := Issued + 1;
      if Issued = No_Session then
         Issued := Issued + 1;
      end if;
      Created.Name := Issued;
      Created.Requested := Requested_Mask;
      Created.Next := Known;
      Known := Created;
      Name := Created.Name;
      Release;
      return Name;
   exception
      when others =>
         if Locked then
            Release;
         end if;
         return No_Session;
   end Start;

   procedure Stop (Session : Identifier) is
      Previous : Session_Access := null;
      Locked   : Boolean := False;
      Item     : Session_Access;
   begin
      if Session = No_Session then
         return;
      end if;
      Locked := Acquire;
      if not Locked then
         return;
      end if;
      Item := Known;
      while Item /= null and then Item.Name /= Session loop
         Previous := Item;
         Item := Item.Next;
      end loop;
      if Item /= null then
         if Previous = null then
            Known := Item.Next;
         else
            Previous.Next := Item.Next;
         end if;
         Clear (Item);
         Free (Item);
      end if;
      Release;
   exception
      when others =>
         if Locked then
            Release;
         end if;
   end Stop;

   procedure Snapshot
     (Session   : Identifier;
      Result    : out Perf_Values;
      Enabled   : out Perf_Values;
      Running   : out Perf_Values;
      Status    : out Perf_Status_Values;
      Mask      : out Interfaces.Unsigned_64;
      Available : out Boolean)
   is
      Token   : System.Address;
      Locked  : Boolean := False;
      Item    : Session_Access;
      Context : Context_Access;
   begin
      Result := [others => 0];
      Enabled := [others => 0];
      Running := [others => 0];
      Status := [others => Metric_Not_Requested];
      Mask := 0;
      Available := False;
      if Session = No_Session then
         return;
      end if;
      Token := Thread_Token (Release_Thread'Access);
      if Token = System.Null_Address then
         return;
      end if;
      Locked := Acquire;
      if not Locked then
         return;
      end if;
      Item := Find (Session);
      if Item = null then
         Release;
         return;
      end if;
      Context := Item.Contexts;
      while Context /= null and then Context.Owner /= Token loop
         Context := Context.Next;
      end loop;
      if Context = null then
         Context := new Context_Record;
         Context.Owner := Token;
         Counters.Open (Context.Group, Item.Requested);
         Counters.Start (Context.Group);
         Context.Next := Item.Contexts;
         Item.Contexts := Context;
      end if;
      Counters.Sample (Context.Group, Result, Enabled, Running, Status, Mask);
      Available := True;
      Release;
   exception
      when others =>
         if Locked then
            Release;
         end if;
         Available := False;
   end Snapshot;

begin
   if Native_Mutex_Size > Mutex_Storage_Bytes then
      raise Program_Error with
        "platform mutex is larger than the recorder registry reserves";
   end if;
   Registry_Ready :=
     Mutex_Initialize (Registry'Address, System.Null_Address) = 0;
end Flyology_Bench.Internal_Probes.Sessions;
