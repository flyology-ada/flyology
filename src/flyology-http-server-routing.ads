with Ada.Strings.Unbounded;
with Flyology.Cancellation;
with Flyology.IO.Sockets;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Middleware;

--  Provides deterministic method-and-path routing above HTTP.Server.
--  @formal App_Context Application-owned context passed to every endpoint
generic
   --  Application context shared by routed handlers.
   type App_Context is limited private;
package Flyology.HTTP.Server.Routing is

   --  Typed middleware API used by this router instance. Applications may
   --  also instantiate Server.Middleware independently of routing.
   package Components is new
     Flyology.HTTP.Server.Middleware (App_Context);

   --  Application endpoint invoked with the typed context and borrowed
   --  request exchange.
   subtype Handler_Access is Components.Handler_Access;

   --  Around-handler component accepted by router middleware registration.
   subtype Middleware_Access is Components.Middleware_Access;

   --  Middleware execution boundary relative to request-body admission.
   --  @enum Request_Head Run before body acceptance and 100 Continue
   --  @enum Application Run after the selected body policy is applied
   type Middleware_Stage is (Request_Head, Application);

   --  Authentication policy interpreted by authentication middleware.
   subtype Authentication_Policy is
     Flyology.HTTP.Server.Applications.Authentication_Mode;
   --  Route does not request authentication.
   No_Authentication : constant Authentication_Policy :=
     Flyology.HTTP.Server.Applications.No_Authentication;
   --  Install a principal when valid credentials exist.
   Optional_Authentication : constant Authentication_Policy :=
     Flyology.HTTP.Server.Applications.Optional_Authentication;
   --  Reject requests without valid credentials.
   Required_Authentication : constant Authentication_Policy :=
     Flyology.HTTP.Server.Applications.Required_Authentication;

   --  Upgrade permission for higher-level endpoint adapters.
   subtype Upgrade_Policy is
     Flyology.HTTP.Server.Applications.Upgrade_Mode;
   --  Ordinary HTTP responses only.
   No_Upgrade : constant Upgrade_Policy :=
     Flyology.HTTP.Server.Applications.No_Upgrade;
   --  Permit an SSE lifecycle on the route.
   Allow_SSE : constant Upgrade_Policy :=
     Flyology.HTTP.Server.Applications.Allow_SSE;
   --  Permit a WebSocket lifecycle on the route.
   Allow_WebSocket : constant Upgrade_Policy :=
     Flyology.HTTP.Server.Applications.Allow_WebSocket;

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

   --  Immutable copy of one registered route's public configuration.
   --  Introspection is intended for diagnostics after setup; it is not part of
   --  request dispatch and adds no work to the routing hot path.
   --  @field Method Configured HTTP method
   --  @field Pattern Configured path pattern
   --  @field Name Stable route name
   --  @field Policy Route-local application policy
   --  @field Middleware_Count Route-local or mounted middleware count
   type Route_Description is record
      Method           : Ada.Strings.Unbounded.Unbounded_String;
      Pattern          : Ada.Strings.Unbounded.Unbounded_String;
      Name             : Ada.Strings.Unbounded.Unbounded_String;
      Policy           : Route_Policy;
      Middleware_Count : Natural;
   end record;

   --  Immutable copy of one middleware registration.
   --  An empty name means the application used the source-compatible unnamed
   --  registration form.
   --  @field Name Application-provided diagnostic name
   --  @field Stage Body-admission boundary where the component runs
   type Middleware_Description is record
      Name  : Ada.Strings.Unbounded.Unbounded_String;
      Stage : Middleware_Stage;
   end record;

   --  Return the number of configured routes without allocating.
   --  Registration and introspection must not occur concurrently.
   --  @param Item Router registry
   --  @return Number of routes in registration order
   function Route_Count (Item : Router) return Natural;

   --  Copy one configured route description.
   --  @param Item Router registry
   --  @param Index One-based registration index
   --  @return Owned route metadata that may outlive the router
   --  @exception Constraint_Error Index is outside 1 .. Route_Count
   function Describe_Route
     (Item  : Router;
      Index : Positive) return Route_Description;

   --  Return the number of global middleware registrations.
   --  @param Item Router registry
   --  @return Global middleware count in registration order
   function Global_Middleware_Count (Item : Router) return Natural;

   --  Copy one global middleware description.
   --  @param Item Router registry
   --  @param Index One-based registration index
   --  @return Owned middleware metadata
   --  @exception Constraint_Error Index is outside the configured range
   function Describe_Global_Middleware
     (Item  : Router;
      Index : Positive) return Middleware_Description;

   --  Return route-local and mounted middleware count for one route.
   --  @param Item Router registry
   --  @param Route_Index One-based route registration index
   --  @return Middleware count in execution order after global components
   --  @exception Constraint_Error Route_Index is outside the configured range
   function Route_Middleware_Count
     (Item        : Router;
      Route_Index : Positive) return Natural;

   --  Copy one route-local or mounted middleware description.
   --  @param Item Router registry
   --  @param Route_Index One-based route registration index
   --  @param Middleware_Index One-based middleware index for that route
   --  @return Owned middleware metadata
   --  @exception Constraint_Error Either index is outside its configured range
   function Describe_Route_Middleware
     (Item             : Router;
      Route_Index      : Positive;
      Middleware_Index : Positive) return Middleware_Description;

   --  Append global middleware. Global components wrap every matched route in
   --  registration order and are copied into mounted subrouter routes.
   --  @param Item Router registry
   --  @param Component Around-handler component
   --  @param Stage Body-admission boundary for the component
   --  @param Name Optional stable diagnostic name for introspection
   procedure Add_Middleware
     (Item      : in out Router;
      Component : not null Middleware_Access;
      Stage     : Middleware_Stage := Request_Head;
      Name      : String := "");

   --  Append middleware to one route selected by its unique configured name.
   --  Route-local components run after router-global components.
   --  @param Item Router registry
   --  @param Name Configured route name
   --  @param Component Around-handler component
   --  @param Stage Body-admission boundary for the component
   --  @param Middleware_Name Optional stable diagnostic name
   procedure Add_Route_Middleware
     (Item      : in out Router;
      Name      : String;
      Component : not null Middleware_Access;
      Stage     : Middleware_Stage := Request_Head;
      Middleware_Name : String := "");

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
      Peer       : Flyology.IO.Sockets.Endpoint;
      Token      : access Flyology.Cancellation.Token := null);

   --  Read and route persistent requests until close or upgrade. This optional
   --  adapter leaves the lower-level Connection_Handlers package available.
   --  @param Item Router registry
   --  @param Context Typed shared application context
   --  @param Connection Sole-writer HTTP connection
   --  @param Peer Connected peer address
   --  @param Timeout Original per-request deadline interval
   --  @param Max_Connection_Age Absolute lifetime bound for the connection;
   --  negative disables this additional bound
   --  @param Max_Requests Requests before connection close; zero is unlimited
   --  @param Token Optional cancellation token
   --  @param Header_Timeout Absolute slow-header budget for each request;
   --  negative uses the remaining request/connection lifetime
   procedure Serve
     (Item         : in out Router;
      Context      : in out App_Context;
      Connection   : aliased in out Flyology.HTTP.Server.Connection;
      Peer         : Flyology.IO.Sockets.Endpoint;
      Timeout      : Duration := 30.0;
      Max_Connection_Age : Duration := 300.0;
      Max_Requests : Natural := 1_000;
      Token        : access Flyology.Cancellation.Token := null;
      Header_Timeout : Duration := -1.0);

private
   use Ada.Strings.Unbounded;

   Max_Global_Middleware : constant := 16;
   Max_Route_Middleware  : constant := 16;
   Max_Segments          : constant := 64;

   type Segment_Array is
     array (Positive range 1 .. Max_Segments) of Unbounded_String;
   type Segment_List is record
      Values   : Segment_Array;
      Count    : Natural := 0;
      Trailing : Boolean := False;
   end record;

   type Middleware_Entry is record
      Component : Middleware_Access;
      Stage     : Middleware_Stage := Request_Head;
      Name      : Unbounded_String;
   end record;
   type Middleware_Array is
     array (Positive range <>) of Middleware_Entry;

   --  Registration compiles each pattern into bounded segment storage so
   --  dispatch does not split and allocate the same pattern per request.
   type Route_Entry is record
      Method              : Unbounded_String;
      Pattern             : Unbounded_String;
      Pattern_Segments    : Segment_List;
      Pattern_Specificity : Natural := 0;
      Name                : Unbounded_String;
      Handler             : Handler_Access;
      Policy              : Route_Policy;
      Middleware          : Middleware_Array (1 .. Max_Route_Middleware);
      Middleware_Count    : Natural := 0;
   end record;
   type Route_Array is array (Positive range <>) of Route_Entry;

   type Router
     (Capacity : Positive := 64;
      Slashes  : Trailing_Slash_Policy := Strict_Slashes)
   is tagged limited record
      Routes : Route_Array (1 .. Capacity);
      Count  : Natural := 0;
      Middleware : Middleware_Array (1 .. Max_Global_Middleware);
      Middleware_Count : Natural := 0;
   end record;

end Flyology.HTTP.Server.Routing;
