with Servlet.Streams;

package body Benchmark_Servlet is
   overriding
   procedure Do_Get
     (Server   : in Servlet;
      Request  : in out Requests.Request'Class;
      Response : in out Responses.Response'Class)
   is
      pragma Unreferenced (Server, Request);
      Output : Streams.Print_Stream := Response.Get_Output_Stream;
   begin
      Response.Set_Content_Type ("text/plain");
      Response.Set_Status (Responses.SC_OK);
      Output.Write ("Hello, World!");
   end Do_Get;
end Benchmark_Servlet;
