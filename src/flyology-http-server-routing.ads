with Ada.Strings.Unbounded;
with GNAT.Sockets;
with Flyology.Cancellation;
with Flyology.HTTP.Server.Applications;

--  Provides deterministic method-and-path routing above HTTP.Server.
--  @formal App_Context Application-owned context passed to every endpoint
generic
   --  Application context shared by routed handlers.
   type App_Context is limited private;
package Flyology.HTTP.Server.Routing is

   --  Application endpoint invoked with the typed context and borrowed
   --  request exchange.
   --  @param Context Typed application context
   --  @param X Borrowed request exchange
   type Handler_Access is access procedure
     (Context : in out App_Context;
      X       : in out Flyology.HTTP.Server.Applications.Exchange);

   --  Authentication policy interpreted by authentication middleware.
   --  @enum No_Authentication Route does not request authentication
   --  @enum Optional_Authentication Install a principal when credentials exist
   --  @enum Required_Authentication Reject unauthenticated requests
   type Authentication_Policy is
     (No_Authentication, Optional_Authentication, Required_Authentication);

   --  Upgrade permission for higher-level endpoint adapters.
   --  @enum No_Upgrade Ordinary HTTP response only
   --  @enum Allow_SSE SSE lifecycle is permitted
   --  @enum Allow_WebSocket WebSocket lifecycle is permitted
   type Upgrade_Policy is (No_Upgrade, Allow_SSE, Allow_WebSocket);

   --  Route-local policy consumed incrementally by optional toolkit layers.
   --  A zero concurrency or rate value means unlimited. CORS_Policy is an
   --  application-defined bounded registry slot interpreted by CORS
   --  middleware; zero means no CORS policy.
   --  @field Body_Handling Request body handling
   --  @field Max_Body Maximum decoded body bytes
   --  @field Timeout Deadline narrowing in seconds; negative preserves it
   --  @field Concurrency Maximum active handlers; zero is unlimited
   --  @field Rate_Per_Second Per-client admission rate; zero is unlimited
   --  @field Authentication Route authentication requirement
   --  @field CORS_Policy Bounded application CORS policy slot
   --  @field Upgrade Permitted endpoint lifecycle
   type Route_Policy is record
      Body_Handling   :
        Flyology.HTTP.Server.Applications.Request_Body_Policy :=
          Flyology.HTTP.Server.Applications.Reject_Body;
      Max_Body        : Natural := Max_Request_Body;
      Timeout         : Duration := -1.0;
      Concurrency     : Natural := 0;
      Rate_Per_Second : Natural := 0;
      Authentication  : Authentication_Policy := No_Authentication;
      CORS_Policy     : Natural := 0;
      Upgrade         : Upgrade_Policy := No_Upgrade;
   end record;

   --  Baseline route policy: reject bodies and preserve the server deadline.
   Default_Route_Policy : constant Route_Policy := (others => <>);

   --  Trailing slash treatment.
   --  @enum Strict_Slashes Route pattern and target must agree
   --  @enum Ignore_Slashes A final slash does not affect matching
   --  @enum Redirect_Slashes Mismatches receive a permanent 308 redirect
   type Trailing_Slash_Policy is
     (Strict_Slashes, Ignore_Slashes, Redirect_Slashes);

   --  Invalid route registration or decoded request path.
   Route_Error : exception;

   --  Bounded route registry. Registration is intended during application
   --  setup, before concurrent dispatch begins.
   --  @field Capacity Maximum registered routes
   --  @field Slashes Explicit final-slash behavior
   type Router
     (Capacity : Positive := 64;
      Slashes  : Trailing_Slash_Policy := Strict_Slashes)
   is tagged limited private;

   --  Register one exact method and path pattern.
   --  @param Item Router registry
   --  @param Method Case-sensitive HTTP method token
   --  @param Pattern Static, {name}, or final {*name} path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name; empty derives Method and Pattern
   --  @param Policy Route-local application policy
   procedure Add
     (Item    : in out Router;
      Method  : String;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Register a GET route. HEAD falls back to it when no exact HEAD exists.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Get
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Register an explicit HEAD route.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Head
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Register a POST route.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Post
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Register a PUT route.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Put
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Register a PATCH route.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Patch
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Register a DELETE route.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Delete
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Register an OPTIONS route.
   --  @param Item Router registry
   --  @param Pattern Route path pattern
   --  @param Handler Application endpoint
   --  @param Name Stable route name
   --  @param Policy Route-local policy
   procedure Options
     (Item    : in out Router;
      Pattern : String;
      Handler : not null Handler_Access;
      Name    : String := "";
      Policy  : Route_Policy := Default_Route_Policy);

   --  Copy routes from Source under Prefix. Capacity is checked before any
   --  route is copied. Prefix must be a static path without parameters.
   --  @param Item Destination router
   --  @param Prefix Static mount path
   --  @param Source Source subrouter
   --  @param Name_Prefix Optional prefix for nonempty route names
   procedure Mount
     (Item        : in out Router;
      Prefix      : String;
      Source      : Router;
      Name_Prefix : String := "");

   --  Match and invoke one already parsed request. Automatic 404, 405, HEAD
   --  fallback, slash handling, body policy, and deadline narrowing occur
   --  before the endpoint is called.
   --  @param Item Router registry
   --  @param Context Typed shared application context
   --  @param Connection Sole-writer HTTP connection
   --  @param Value Parsed request head
   --  @param Peer Connected peer address
   --  @param Token Optional cancellation token
   procedure Dispatch
     (Item       : in out Router;
      Context    : in out App_Context;
      Connection : aliased in out Flyology.HTTP.Server.Connection;
      Value      : aliased in out Request;
      Peer       : GNAT.Sockets.Sock_Addr_Type;
      Token      : access Flyology.Cancellation.Token := null);

   --  Read and route persistent requests until close or upgrade. This optional
   --  adapter leaves the lower-level Connection_Handlers package available.
   --  @param Item Router registry
   --  @param Context Typed shared application context
   --  @param Connection Sole-writer HTTP connection
   --  @param Peer Connected peer address
   --  @param Timeout Original per-request deadline interval
   --  @param Max_Requests Requests before connection close; zero is unlimited
   --  @param Token Optional cancellation token
   procedure Serve
     (Item         : in out Router;
      Context      : in out App_Context;
      Connection   : aliased in out Flyology.HTTP.Server.Connection;
      Peer         : GNAT.Sockets.Sock_Addr_Type;
      Timeout      : Duration := 30.0;
      Max_Requests : Natural := 1_000;
      Token        : access Flyology.Cancellation.Token := null);

private
   use Ada.Strings.Unbounded;

   type Route_Entry is record
      Method  : Unbounded_String;
      Pattern : Unbounded_String;
      Name    : Unbounded_String;
      Handler : Handler_Access;
      Policy  : Route_Policy;
   end record;
   type Route_Array is array (Positive range <>) of Route_Entry;

   type Router
     (Capacity : Positive := 64;
      Slashes  : Trailing_Slash_Policy := Strict_Slashes)
   is tagged limited record
      Routes : Route_Array (1 .. Capacity);
      Count  : Natural := 0;
   end record;

end Flyology.HTTP.Server.Routing;
