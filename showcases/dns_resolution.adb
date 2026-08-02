with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Text_IO;
with GNAT.Sockets;
with Gnatevl;
with Gnatevl.IO.DNS;

procedure DNS_Resolution is
   use type Ada.Real_Time.Time;

   Host : constant String :=
     (if Ada.Command_Line.Argument_Count = 0
      then "example.com" else Ada.Command_Line.Argument (1));

   protected Output is
      procedure Show
        (Lane : String; Values : Gnatevl.IO.DNS.Address_Array;
         Elapsed : Duration);
      procedure Failed (Lane, Message : String);
   end Output;

   protected body Output is
      procedure Show
        (Lane : String; Values : Gnatevl.IO.DNS.Address_Array;
         Elapsed : Duration)
      is
      begin
         Ada.Text_IO.Put_Line
           (Lane & " resolved " & Host & " in" & Elapsed'Image & " s");
         for Value of Values loop
            Ada.Text_IO.Put_Line ("  " & GNAT.Sockets.Image (Value));
         end loop;
      end Show;

      procedure Failed (Lane, Message : String) is
      begin
         Ada.Text_IO.Put_Line (Lane & " failed: " & Message);
      end Failed;
   end Output;

   task type Resolver (Model : Gnatevl.Execution_Model; Native : Boolean) is
      pragma Task_Info (Model);
   end Resolver;

   task body Resolver is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Values  : constant Gnatevl.IO.DNS.Address_Array :=
        Gnatevl.IO.DNS.Resolve (Host, Timeout => 5.0);
      Lane    : constant String := (if Native then "native " else "evented");
   begin
      Output.Show
        (Lane, Values,
         Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started));
   exception
      when Occurrence : others =>
         Output.Failed
           ((if Native then "native " else "evented"),
            Ada.Exceptions.Exception_Message (Occurrence));
   end Resolver;

   type Resolver_Access is access Resolver;
begin
   GNAT.Sockets.Initialize;
   declare
      Native  : constant Resolver_Access :=
        new Resolver (Gnatevl.Native_Thread, True);
      Evented : constant Resolver_Access :=
        new Resolver (Gnatevl.Event_Loop_Task, False);
      pragma Unreferenced (Native, Evented);
   begin
      null;
   end;
   GNAT.Sockets.Finalize;
end DNS_Resolution;
