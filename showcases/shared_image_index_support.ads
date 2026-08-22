with Flyology.Data_Structures;
with Flyology.Data_Structures.Hash_Maps;
with Flyology.Data_Structures.Rings.MPMC;
with Flyology.Data_Structures.Storage_Types.Elements;
with Flyology.Data_Structures.Storage_Types.Immutable;
with Flyology.Data_Structures.Storage_Types.Unsigned_64s;
with Interfaces;

package Shared_Image_Index_Support is
   package DS renames Flyology.Data_Structures;

   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   type Image_Job is record
      Batch_Id : U64 := 0;
      Image_Id : U64 := 0;
   end record;

   type Image_Result is record
      Batch_Id      : U64 := 0;
      Image_Id      : U64 := 0;
      Content_Hash  : U64 := 0;
      Red_Total     : U64 := 0;
      Green_Total   : U64 := 0;
      Blue_Total    : U64 := 0;
      Pixel_Count   : U64 := 0;
      Worker_Id     : U32 := 0;
      Index_Retries : U32 := 0;
      Queue_Retries : U32 := 0;
      Flags         : U32 := 0;
   end record;

   Worker_Attached   : constant U32 := 1;
   Worker_Race_Done  : constant U32 := 2;
   Worker_Won_Race   : constant U32 := 4;
   Worker_Finished   : constant U32 := 8;
   Image_Complete    : constant U32 := 16;
   Worker_Batch_Done : constant U32 := 32;

   Job_Ring_Name    : constant String := "jobs/pending";
   Result_Ring_Name : constant String := "jobs/results";
   Index_Name       : constant String := "index/by-image";
   Gate_Name        : constant String := "workers/gate";
   Race_Name        : constant String := "workers/shared-startup";

   Job_Ring_Capacity    : constant Positive := 64;
   Result_Ring_Capacity : constant Positive := 64;
   Gate_Capacity        : constant Positive := 16;
   Race_Capacity        : constant Positive := 64;

   package Job_Representation is new
     DS.Storage_Types.Immutable
       (Byte_Size          => 16,
        Required_Alignment => 8,
        Type_Signature     => 16#5348_4F57_4A4F_4202#,
        Layout_Version     => 2);

   function Create_Job (Data : Image_Job) return Job_Representation.Value;
   function Observe_Job (Item : Job_Representation.Const_Ref) return Image_Job;
   procedure Construct_Job (Item : in out Job_Representation.Builder; Data : Image_Job);

   package Job_Elements is new
     DS.Storage_Types.Elements
       (Representation     => Job_Representation,
        Source_Type        => Image_Job,
        Observed_Type      => Image_Job,
        Create_Value       => Create_Job,
        Observe_Value      => Observe_Job,
        Direct_Constructor => Construct_Job'Access);
   package Job_Rings is new DS.Rings.MPMC (Element => Job_Elements);

   package Result_Representation is new
     DS.Storage_Types.Immutable
       (Byte_Size          => 72,
        Required_Alignment => 8,
        Type_Signature     => 16#5348_4F57_5253_4C02#,
        Layout_Version     => 2);

   function Create_Result (Data : Image_Result) return Result_Representation.Value;
   function Observe_Result (Item : Result_Representation.Const_Ref) return Image_Result;
   procedure Construct_Result (Item : in out Result_Representation.Builder; Data : Image_Result);

   package Result_Elements is new
     DS.Storage_Types.Elements
       (Representation     => Result_Representation,
        Source_Type        => Image_Result,
        Observed_Type      => Image_Result,
        Create_Value       => Create_Result,
        Observe_Value      => Observe_Result,
        Direct_Constructor => Construct_Result'Access);
   package Result_Rings is new DS.Rings.MPMC (Element => Result_Elements);

   package U64_Elements renames DS.Storage_Types.Unsigned_64s;
   package Image_Maps is new DS.Hash_Maps (Key => U64_Elements.Element, Element => Result_Elements);

   function Image_Path (Directory : String; Image_Id : Positive) return String;

   procedure Generate_Image (Path : String; Width : Positive; Height : Positive; State : in out U64);

   procedure Analyze_Image
     (Path      : String;
      Width     : Positive;
      Height    : Positive;
      Passes    : Positive;
      Worker_Id : Positive;
      Result    : out Image_Result);
end Shared_Image_Index_Support;
