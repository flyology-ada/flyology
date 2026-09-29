with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

package Flyology_CLI.Processes is
   package String_Vectors is new
     Ada.Containers.Indefinite_Vectors (Index_Type => Positive, Element_Type => String);

   function Is_Available (Program_Name : String) return Boolean;

   function Run (Program_Name : String; Arguments : String_Vectors.Vector) return Integer;

   function Capture
     (Program_Name : String;
      Arguments    : String_Vectors.Vector;
      Output       : out Ada.Strings.Unbounded.Unbounded_String) return Integer;
end Flyology_CLI.Processes;
