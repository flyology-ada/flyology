with Ada.Strings.Unbounded;

--  Defines explicit reusable CORS policies for optional middleware.
package Flyology.HTTP.Server.CORS is

   --  Immutable-after-setup CORS policy value.
   type Policy is private;

   --  Construct a policy. Allowed_Origins is a space-separated exact origin
   --  list or "*". Methods and headers are comma-separated token lists.
   --  Wildcard origin with credentials is rejected.
   --  @param Allowed_Origins Exact origins or wildcard
   --  @param Allowed_Methods Allowed request methods
   --  @param Allowed_Headers Allowed request headers
   --  @param Exposed_Headers Response headers exposed to scripts
   --  @param Allow_Credentials Whether credentials are allowed
   --  @param Max_Age Preflight cache duration; negative omits it
   --  @return Validated CORS policy
   function Create
     (Allowed_Origins   : String;
      Allowed_Methods   : String;
      Allowed_Headers   : String := "";
      Exposed_Headers   : String := "";
      Allow_Credentials : Boolean := False;
      Max_Age           : Duration := -1.0) return Policy;

   --  Report whether one serialized origin is allowed.
   --  @param Item CORS policy
   --  @param Origin Serialized origin
   --  @return True for exact membership or wildcard
   function Origin_Allowed (Item : Policy; Origin : String) return Boolean;

   --  Report whether one method is allowed.
   --  @param Item CORS policy
   --  @param Method Request method
   --  @return True for token membership
   function Method_Allowed (Item : Policy; Method : String) return Boolean;

   --  Report whether every requested comma-separated header is allowed.
   --  Header matching is ASCII case-insensitive.
   --  @param Item CORS policy
   --  @param Headers Requested header list
   --  @return True when every requested header is allowed
   function Headers_Allowed (Item : Policy; Headers : String) return Boolean;

   --  Return the configured allowed method list.
   --  @param Item CORS policy
   --  @return Header-ready method list
   function Methods (Item : Policy) return String;

   --  Return the configured allowed header list.
   --  @param Item CORS policy
   --  @return Header-ready allowed header list
   function Headers (Item : Policy) return String;

   --  Return the configured exposed header list.
   --  @param Item CORS policy
   --  @return Header-ready exposed header list
   function Exposed (Item : Policy) return String;

   --  Report credential permission.
   --  @param Item CORS policy
   --  @return True when credentials are allowed
   function Credentials (Item : Policy) return Boolean;

   --  Report whether wildcard origin is configured.
   --  @param Item CORS policy
   --  @return True only for "*"
   function Wildcard (Item : Policy) return Boolean;

   --  Return preflight cache duration.
   --  @param Item CORS policy
   --  @return Seconds; negative means omitted
   function Preflight_Max_Age (Item : Policy) return Duration;

private
   type Policy is record
      Origins_Value    : Ada.Strings.Unbounded.Unbounded_String;
      Methods_Value    : Ada.Strings.Unbounded.Unbounded_String;
      Headers_Value    : Ada.Strings.Unbounded.Unbounded_String;
      Exposed_Value    : Ada.Strings.Unbounded.Unbounded_String;
      Credentials_Value : Boolean := False;
      Max_Age_Value    : Duration := -1.0;
   end record;

end Flyology.HTTP.Server.CORS;
