with Ada.Strings.Unbounded;
with Flyology.HTTP.Server.Applications;

--  Supplies response construction and cookie helpers above Exchange.
package Flyology.HTTP.Server.Responses is

   --  SameSite cookie policy.
   --  @enum SameSite_Unspecified Omit SameSite
   --  @enum SameSite_Lax Emit SameSite=Lax
   --  @enum SameSite_Strict Emit SameSite=Strict
   --  @enum SameSite_None Emit SameSite=None and require Secure
   type SameSite_Mode is
     (SameSite_Unspecified, SameSite_Lax, SameSite_Strict, SameSite_None);

   --  Cookie attributes. Expires is an RFC-compatible HTTP date supplied by
   --  the application. Has_Max_Age distinguishes omission from zero deletion.
   --  @field Secure Emit Secure
   --  @field HTTP_Only Emit HttpOnly
   --  @field SameSite SameSite policy
   --  @field Path Cookie path or empty
   --  @field Domain Cookie domain or empty
   --  @field Has_Max_Age Whether Max-Age is emitted
   --  @field Max_Age Max-Age seconds
   --  @field Expires Optional HTTP date
   type Cookie_Options is record
      Secure      : Boolean := True;
      HTTP_Only   : Boolean := True;
      SameSite    : SameSite_Mode := SameSite_Lax;
      Path        : Ada.Strings.Unbounded.Unbounded_String;
      Domain      : Ada.Strings.Unbounded.Unbounded_String;
      Has_Max_Age : Boolean := False;
      Max_Age     : Integer := 0;
      Expires     : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Append one validated Set-Cookie field before response start.
   --  @param X Request exchange
   --  @param Name Cookie name
   --  @param Value Cookie value
   --  @param Options Cookie attributes
   procedure Set_Cookie
     (X       : in out Applications.Exchange;
      Name    : String;
      Value   : String;
      Options : Cookie_Options := (others => <>));

   --  Mutable response description that does not borrow an Exchange until
   --  Send. It is suitable for nontrivial fixed responses.
   type Builder is tagged private;

   --  Reset a builder to one status and media type.
   --  @param Item Response builder
   --  @param Status HTTP status
   --  @param Content_Type Media type or empty
   procedure Initialize
     (Item         : in out Builder;
      Status       : Positive;
      Content_Type : String := "");

   --  Append one validated response header.
   --  @param Item Response builder
   --  @param Name Header name
   --  @param Value Header value
   procedure Add_Header
     (Item  : in out Builder;
      Name  : String;
      Value : String);

   --  Replace the fixed response payload.
   --  @param Item Response builder
   --  @param Value Payload bytes
   procedure Set_Payload (Item : in out Builder; Value : String);

   --  Send the described response and consume no ownership from X.
   --  @param Item Response builder
   --  @param X Request exchange
   --  @param Close Force connection close
   procedure Send
     (Item  : Builder;
      X     : in out Applications.Exchange;
      Close : Boolean := False);

private
   type Builder is tagged record
      Status_Value : Positive := 200;
      Content_Type_Value : Ada.Strings.Unbounded.Unbounded_String;
      Header_Block : Ada.Strings.Unbounded.Unbounded_String;
      Payload_Value : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Flyology.HTTP.Server.Responses;
