with Servlet.Server;

package Benchmark_Server_Init is
   type Container_Type is new Servlet.Server.Container with private;

   overriding
   procedure Configure
     (Server : in out Container_Type;
      Config : in Servlet.Server.Configuration);

   overriding
   procedure Start (Server : in out Container_Type);

private
   type Container_Access is access all Container_Type'Class;

   type Container_Type is new Servlet.Server.Container with record
      Config : Servlet.Server.Configuration;
   end record;
end Benchmark_Server_Init;
