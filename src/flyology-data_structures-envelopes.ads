with Interfaces;
private with Flyology.Data_Structures.Layouts;

--  Adds an optional application-level contract around one relocatable object.
--  Leaf structures always retain their own mandatory magic/version/schema;
--  this envelope additionally checks the consumer's chosen contract identity
--  and version before it computes the nested location. Initialization marks
--  the nested leaf incomplete, but the envelope does not otherwise initialize,
--  synchronize, or manage that object, and direct leaf use opts out.
--  @formal Nested_Identity Stable identity exported by the nested leaf
--  @formal Contract_Signature Nonzero 64-bit application contract identity
--  @formal Contract_Version Nonzero 64-bit application contract version
generic
   Nested_Identity   : Layout_Identity;
   Contract_Signature : Interfaces.Unsigned_64;
   Contract_Version   : Interfaces.Unsigned_64;
package Flyology.Data_Structures.Envelopes with Preelaborate is

   --  Eight-byte magic stored in every contract envelope.
   Magic : constant Interfaces.Unsigned_64 := 16#4644_5345_4E56_3031#;

   --  Schema identifier for the current envelope geometry.
   Schema : constant Interfaces.Unsigned_64 := 16#0001_454E_564C_0001#;

   --  Leaf-specific stored-layout version.
   Layout_Version : constant Interfaces.Unsigned_32 := 1;

   --  Complete stable identity of the envelope layout itself.
   Identity : constant Layout_Identity :=
     (Magic => Magic, Version => Layout_Version, Schema => Schema);

   --  Process-local attached envelope view.
   type View is limited private;

   --  Compute the envelope plus aligned nested extent.
   --  @param Content_Extent Complete nested structure extent
   --  @param Content_Alignment Required power-of-two nested alignment
   --  @return Complete envelope and nested byte extent
   function Required_Storage
     (Content_Extent    : Byte_Count;
      Content_Alignment : Byte_Count := 8) return Byte_Count;

   --  Initialize a contract envelope, atomically mark the nested leaf state
   --  incomplete, and then publish the envelope. The caller then initializes
   --  the nested leaf at Content_Location. A crash between those steps leaves
   --  the nested leaf incomplete even when this extent previously contained a
   --  ready leaf, so the leaf's own attachment rejects it.
   --  @param Item Envelope view attached on success
   --  @param Region Attached backing region
   --  @param Location Nonzero offset aligned for Content_Alignment
   --  @param Content_Extent Complete nested structure extent
   --  @param Content_Alignment Required power-of-two nested alignment
   --  @exception Constraint_Error Generic identity or geometry is invalid
   procedure Initialize
     (Item              : out View;
      Region            : Region_View;
      Location          : Region_Offset;
      Content_Extent    : Byte_Count;
      Content_Alignment : Byte_Count := 8);

   --  Attach only when the application contract, nested leaf identity,
   --  nested extent, and alignment all match this generic instance.
   --  @param Item Envelope view attached on success
   --  @param Region Independently attached backing region
   --  @param Location Stored envelope offset
   --  @param Content_Extent Expected complete nested structure extent
   --  @param Content_Alignment Expected nested alignment
   --  @exception Layout_Error Contract or geometry does not match
   procedure Attach
     (Item              : out View;
      Region            : Region_View;
      Location          : Region_Offset;
      Content_Extent    : Byte_Count;
      Content_Alignment : Byte_Count := 8);

   --  Return the validated stored offset at which the nested leaf begins.
   --  No native address is exposed.
   --  @param Item Attached envelope view
   --  @return Nonzero nested structure offset
   function Content_Location (Item : View) return Region_Offset;

   --  Return the validated nested structure extent.
   --  @param Item Attached envelope view
   --  @return Complete nested extent in bytes
   function Content_Extent (Item : View) return Byte_Count;

   --  Detach Item without modifying the envelope or nested object.
   --  @param Item Local envelope view to detach
   procedure Detach (Item : in out View);

   --  Report whether Item is locally attached.
   --  @param Item Envelope view to inspect
   --  @return True only while local mapping information is retained
   function Is_Attached (Item : View) return Boolean;

   --  Invalidate the envelope after the application has quiesced and
   --  destroyed or otherwise retired the nested object.
   --  @param Item Exclusively synchronized envelope view
   procedure Destroy (Item : in out View);

private
   type View is limited record
      Core              : Layouts.Local_View;
      Content_Offset    : Byte_Count := 0;
      Content_Size      : Byte_Count := 0;
      Content_Alignment : Byte_Count := 0;
   end record;
end Flyology.Data_Structures.Envelopes;
