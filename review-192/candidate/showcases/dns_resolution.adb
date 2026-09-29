with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Text_IO;
with Flyology.IO.Sockets;
with Flyology;
with Flyology.IO.DNS;

procedure DNS_Resolution is
   use type Ada.Real_Time.Time;

   Host : constant String :=
     (if Ada.Command_Line.Argument_Count = 0 then "example.com" else Ada.Command_Line.Argument (1));

   protected Output is
      procedure Show (Lane : String; Values : Flyology.IO.DNS.Address_Array; Elapsed : Duration);
      procedure Failed (Lane, Message : String);
   end Output;

   protected body Output is
      procedure Show (Lane : String; Values : Flyology.IO.DNS.Address_Array; Elapsed : Duration) is
      begin
         Ada.Text_IO.Put_Line (Lane & " resolved " & Host & " in" & Elapsed'Image & " s");
         for Value of Values loop
            Ada.Text_IO.Put_Line ("  " & Flyology.IO.Sockets.Image (Value));
         end loop;
      end Show;

      procedure Failed (Lane, Message : String) is
      begin
         Ada.Text_IO.Put_Line (Lane & " failed: " & Message);
      end Failed;
   end Output;

   task type Resolver
     (Model  : Flyology.Execution_Model;
      Native : Boolean)
   is
      pragma Task_Info (Model);
   end Resolver;

   task body Resolver is
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Values  : constant Flyology.IO.DNS.Address_Array := Flyology.IO.DNS.Resolve (Host, Timeout => 5.0);
      Lane    : constant String := (if Native then "native " else "lightweight");
   begin
      Output.Show (Lane, Values, Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started));
   exception
      when Occurrence : others =>
         Output.Failed
           ((if Native then "native " else "lightweight"), Ada.Exceptions.Exception_Message (Occurrence));
   end Resolver;

   type Resolver_Access is access Resolver;
begin
   declare
      Native      : constant Resolver_Access := new Resolver (Flyology.Native_Task, True);
      Lightweight : constant Resolver_Access := new Resolver (Flyology.Lightweight_Task, False);
      pragma Unreferenced (Native, Lightweight);
   begin
      null;
   end;
end DNS_Resolution;
