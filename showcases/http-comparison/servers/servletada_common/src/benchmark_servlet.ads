with Servlet.Core;
with Servlet.Requests;
with Servlet.Responses;

package Benchmark_Servlet is
   use Servlet;

   type Servlet is new Core.Servlet with null record;

   overriding
   procedure Do_Get
     (Server   : in Servlet;
      Request  : in out Requests.Request'Class;
      Response : in out Responses.Response'Class);
end Benchmark_Servlet;
