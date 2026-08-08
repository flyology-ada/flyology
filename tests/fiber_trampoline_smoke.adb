with Flyology;

--  GNAT gives a nested subprogram whose address escapes a heap-allocated
--  trampoline, created when the declaring subprogram is entered and released
--  when it returns. The compiler's helper keeps one allocation cursor per
--  pthread and reclaims slots by count alone, so it is correct only while
--  every thread creates and releases trampolines in stack order.
--
--  Lightweight tasks break that assumption: several fibers share one
--  event-loop thread and suspend with callbacks still live. The tasks below
--  force the interleaving. A publishes a callback and suspends, B publishes a
--  second and suspends, A resumes and returns so only its own callback is
--  released, then C publishes a third. A pthread-local cursor hands C the
--  slot B still owns, so B's stored callback would reach C's body with C's
--  static chain and report C's marker.
procedure Fiber_Trampoline_Smoke is
   type Callback_Access is access procedure;

   type Participant is (Fiber_A, Fiber_B, Fiber_C);

   type Callback_Array is array (Participant) of Callback_Access;

   A_Marker : constant := 1;
   B_Marker : constant := 2;
   C_Marker : constant := 3;

   protected Coordination is
      procedure Publish (Who : Participant; Action : Callback_Access);
      function Published (Who : Participant) return Callback_Access;
      procedure A_Created;
      entry Await_A_Created;
      procedure B_Created;
      entry Await_B_Created;
      procedure A_Released;
      entry Await_A_Released;
      procedure C_Created;
      entry Await_C_Created;
      procedure B_Called;
      entry Await_B_Called;
      procedure Record_Callback (Marker : Positive);
      function Observed return Natural;
   private
      Actions       : Callback_Array := (others => null);
      A_Is_Created  : Boolean := False;
      B_Is_Created  : Boolean := False;
      A_Is_Released : Boolean := False;
      C_Is_Created  : Boolean := False;
      B_Has_Called  : Boolean := False;
      Last_Marker   : Natural := 0;
   end Coordination;

   protected body Coordination is
      procedure Publish (Who : Participant; Action : Callback_Access) is
      begin
         Actions (Who) := Action;
      end Publish;

      function Published (Who : Participant) return Callback_Access is
        (Actions (Who));

      procedure A_Created is
      begin
         A_Is_Created := True;
      end A_Created;

      entry Await_A_Created when A_Is_Created is
      begin
         null;
      end Await_A_Created;

      procedure B_Created is
      begin
         B_Is_Created := True;
      end B_Created;

      entry Await_B_Created when B_Is_Created is
      begin
         null;
      end Await_B_Created;

      procedure A_Released is
      begin
         A_Is_Released := True;
      end A_Released;

      entry Await_A_Released when A_Is_Released is
      begin
         null;
      end Await_A_Released;

      procedure C_Created is
      begin
         C_Is_Created := True;
      end C_Created;

      entry Await_C_Created when C_Is_Created is
      begin
         null;
      end Await_C_Created;

      procedure B_Called is
      begin
         B_Has_Called := True;
      end B_Called;

      entry Await_B_Called when B_Has_Called is
      begin
         null;
      end Await_B_Called;

      procedure Record_Callback (Marker : Positive) is
      begin
         Last_Marker := Marker;
      end Record_Callback;

      function Observed return Natural is (Last_Marker);
   end Coordination;

   --  One shared execution group keeps all three fibers on a single
   --  event-loop thread, whose trampoline cursor they would otherwise share.
   task A with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end A;

   task B with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end B;

   task C with CPU => 1 is
      pragma Task_Info (Flyology.Lightweight_Task);
   end C;

   --  Every callback reads and writes a variable owned by the frame that
   --  declares it, so the compiler must keep a static chain and route the
   --  published access value through a heap trampoline.
   task body A is
      --  Entering Hold creates A's trampoline; returning releases it.
      procedure Hold is
         Marker : Positive := A_Marker;
         procedure Callback is
         begin
            Coordination.Record_Callback (Marker);
            Marker := A_Marker;
         end Callback;
      begin
         Coordination.Publish (Fiber_A, Callback'Unrestricted_Access);
         Coordination.A_Created;
         Coordination.Await_B_Created;
      end Hold;
   begin
      Hold;
      --  A's trampoline is now released while B's is still live.
      Coordination.A_Released;
   end A;

   task body B is
      procedure Hold is
         Marker : Positive := B_Marker;
         procedure Callback is
         begin
            Coordination.Record_Callback (Marker);
            Marker := B_Marker;
         end Callback;
      begin
         Coordination.Publish (Fiber_B, Callback'Unrestricted_Access);
         Coordination.B_Created;
         Coordination.Await_A_Released;
         Coordination.Await_C_Created;
         --  Reached through the protected object so the call stays indirect.
         Coordination.Published (Fiber_B).all;
         Coordination.B_Called;
      end Hold;
   begin
      Coordination.Await_A_Created;
      Hold;
   end B;

   task body C is
      procedure Hold is
         Marker : Positive := C_Marker;
         procedure Callback is
         begin
            Coordination.Record_Callback (Marker);
            Marker := C_Marker;
         end Callback;
      begin
         Coordination.Publish (Fiber_C, Callback'Unrestricted_Access);
         Coordination.C_Created;
         --  Hold C's trampoline live so a reused slot stays observable.
         Coordination.Await_B_Called;
      end Hold;
   begin
      Coordination.Await_A_Released;
      Hold;
   end C;

   pragma Unreferenced (A, B, C);
begin
   Coordination.Await_B_Called;
   if Coordination.Observed /= B_Marker then
      raise Program_Error
        with "a live lightweight-task callback was overwritten";
   end if;
end Fiber_Trampoline_Smoke;
