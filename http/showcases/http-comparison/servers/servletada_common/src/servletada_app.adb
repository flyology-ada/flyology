with Ada.Command_Line;
with Ada.Text_IO;
with Benchmark_Servlet;
with Benchmark_Server_Init;
with Servlet.Core;
with Servlet.Server;

procedure ServletAda_App is
   Port : constant Servlet.Server.Port_Number :=
     (if Ada.Command_Line.Argument_Count >= 1
      then Servlet.Server.Port_Number'Value (Ada.Command_Line.Argument (1))
      else 18_090);
   Capacity : constant Positive :=
     (if Ada.Command_Line.Argument_Count >= 2
      then Positive'Value (Ada.Command_Line.Argument (2)) else 256);

   Handler : aliased Benchmark_Servlet.Servlet;
   App     : aliased Servlet.Core.Servlet_Registry;
   Config  : constant Servlet.Server.Configuration :=
     (Listening_Port    => Port,
      Max_Connection    => Capacity,
      Accept_Queue_Size => Capacity,
      TCP_No_Delay      => True,
      others            => <>);
   WS      : Benchmark_Server_Init.Container_Type;
begin
   WS.Configure (Config);
   App.Add_Servlet
     (Name => "benchmark", Server => Handler'Unchecked_Access);
   App.Add_Mapping (Name => "benchmark", Pattern => "*.html");
   WS.Register_Application ("/benchmark", App'Unchecked_Access);
   WS.Start;

   Ada.Text_IO.Put_Line
     ("READY servletada http://127.0.0.1:"
      & Servlet.Server.Port_Number'Image (Port)
      & "/benchmark/route.html");
   Ada.Text_IO.Flush;
   loop
      delay 3_600.0;
   end loop;
end ServletAda_App;
