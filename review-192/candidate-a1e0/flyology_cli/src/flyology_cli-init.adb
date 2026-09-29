with Ada.Characters.Handling;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology_CLI.Processes;
with GNAT.OS_Lib;

package body Flyology_CLI.Init is
   use Ada.Strings.Unbounded;
   use Flyology_CLI.Processes;
   use type Ada.Directories.File_Kind;

   LF : constant Character := ASCII.LF;

   type Project_Kind is (Binary_Project, Library_Project);
   type Project_Profile is (Consumer_Project, Flyology_Project);
   type Options is record
      Destination : Unbounded_String := To_Unbounded_String (".");
      Name        : Unbounded_String;
      Name_Set    : Boolean := False;
      Kind        : Project_Kind := Binary_Project;
      Kind_Set    : Boolean := False;
      Profile     : Project_Profile := Consumer_Project;
      Agents      : Boolean := True;
      Website     : Boolean := False;
      Assume_Yes  : Boolean := False;
      Help        : Boolean := False;
   end record;

   Init_Error : exception;

   procedure Fail (Message : String) is
   begin
      raise Init_Error with Message;
   end Fail;

   function Quote (Value : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("""");
   begin
      for Character of Value loop
         if Character = '"' or else Character = '\' then
            Append (Result, '\');
         end if;
         Append (Result, Character);
      end loop;
      Append (Result, '"');
      return To_String (Result);
   end Quote;

   function Ada_Name (Crate_Name : String) return String is
      Result     : String := Ada.Characters.Handling.To_Lower (Crate_Name);
      Capitalize : Boolean := True;
   begin
      for Index in Result'Range loop
         if Capitalize then
            Result (Index) := Ada.Characters.Handling.To_Upper (Result (Index));
         end if;
         Capitalize := Result (Index) = '_';
      end loop;
      return Result;
   end Ada_Name;

   function Suggested_Name (Destination : String) return String is
      Base   : constant String :=
        (if Destination = "."
         then Ada.Directories.Simple_Name (Ada.Directories.Current_Directory)
         else Ada.Directories.Simple_Name (Destination));
      Result : String := Ada.Characters.Handling.To_Lower (Base);
   begin
      for Character of Result loop
         if Character = '-' then
            Character := '_';
         end if;
      end loop;
      return Result;
   end Suggested_Name;

   function Is_Valid_Crate_Name (Name : String) return Boolean is
      Previous_Underscore : Boolean := False;
   begin
      if Name'Length not in 3 .. 64 or else Name (Name'First) not in 'a' .. 'z' then
         return False;
      end if;
      for Character of Name loop
         if Character not in 'a' .. 'z' and then Character not in '0' .. '9' and then Character /= '_' then
            return False;
         end if;
         if Character = '_' and then Previous_Underscore then
            return False;
         end if;
         Previous_Underscore := Character = '_';
      end loop;
      return Name (Name'Last) /= '_';
   end Is_Valid_Crate_Name;

   function Is_Ada_Reserved_Word (Name : String) return Boolean is
   begin
      return
        Name
        in "abort"
         | "abs"
         | "abstract"
         | "accept"
         | "access"
         | "aliased"
         | "all"
         | "and"
         | "array"
         | "at"
         | "begin"
         | "body"
         | "case"
         | "constant"
         | "declare"
         | "delay"
         | "delta"
         | "digits"
         | "do"
         | "else"
         | "elsif"
         | "end"
         | "entry"
         | "exception"
         | "exit"
         | "for"
         | "function"
         | "generic"
         | "goto"
         | "if"
         | "in"
         | "interface"
         | "is"
         | "limited"
         | "loop"
         | "mod"
         | "new"
         | "not"
         | "null"
         | "of"
         | "or"
         | "others"
         | "out"
         | "overriding"
         | "package"
         | "parallel"
         | "pragma"
         | "private"
         | "procedure"
         | "protected"
         | "raise"
         | "range"
         | "record"
         | "rem"
         | "renames"
         | "requeue"
         | "return"
         | "reverse"
         | "select"
         | "separate"
         | "some"
         | "subtype"
         | "synchronized"
         | "tagged"
         | "task"
         | "terminate"
         | "then"
         | "type"
         | "until"
         | "use"
         | "when"
         | "while"
         | "with"
         | "xor";
   end Is_Ada_Reserved_Word;

   function Is_Forbidden_Crate_Name (Name : String) return Boolean is
   begin
      return Name in "ada" | "interfaces" | "standard" | "system" | "flyology" | "gnat";
   end Is_Forbidden_Crate_Name;

   function Prompt (Message : String; Default : String) return String is
   begin
      Ada.Text_IO.Put (Message & " [" & Default & "]: ");
      Ada.Text_IO.Flush;
      declare
         Answer : constant String := Ada.Text_IO.Get_Line;
      begin
         return (if Answer'Length = 0 then Default else Answer);
      end;
   exception
      when Ada.Text_IO.End_Error =>
         return Default;
   end Prompt;

   function Prompt_Yes_No (Message : String; Default : Boolean) return Boolean is
   begin
      Ada.Text_IO.Put (Message & (if Default then " [Y/n]: " else " [y/N]: "));
      Ada.Text_IO.Flush;
      declare
         Answer : constant String := Ada.Characters.Handling.To_Lower (Ada.Text_IO.Get_Line);
      begin
         if Answer'Length = 0 then
            return Default;
         elsif Answer = "y" or else Answer = "yes" then
            return True;
         elsif Answer = "n" or else Answer = "no" then
            return False;
         end if;
         Fail ("expected yes or no for: " & Message);
         return False;
      end;
   exception
      when Ada.Text_IO.End_Error =>
         return Default;
   end Prompt_Yes_No;

   procedure Show_Help is
   begin
      Ada.Text_IO.Put_Line ("Usage: flyology init [DIRECTORY] [OPTIONS]");
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("Scaffold a Flyology crate in DIRECTORY (default: current directory).");
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Put_Line ("Options:");
      Ada.Text_IO.Put_Line ("  --name NAME             Set the Alire crate name");
      Ada.Text_IO.Put_Line ("  --bin | --lib           Generate an executable or library crate");
      Ada.Text_IO.Put_Line ("  --flyology-project      Generate a flyology-ada project (default: consumer)");
      Ada.Text_IO.Put_Line ("  --no-agents             Do not provision flyology-ada/agents through APM");
      Ada.Text_IO.Put_Line ("  --website               Add website-kit and site generation");
      Ada.Text_IO.Put_Line ("  -y, --yes               Accept defaults and index installation");
      Ada.Text_IO.Put_Line ("  -h, --help              Show this help");
   end Show_Help;

   procedure Select_Exclusive (Already_Set : in out Boolean; Description : String) is
   begin
      if Already_Set then
         Fail ("conflicting " & Description & " options");
      end if;
      Already_Set := True;
   end Select_Exclusive;

   function Parse return Options is
      Result          : Options;
      Destination_Set : Boolean := False;
      Index           : Positive := 2;
   begin
      while Index <= Ada.Command_Line.Argument_Count loop
         declare
            Argument : constant String := Ada.Command_Line.Argument (Index);
         begin
            if Argument = "--bin" then
               Select_Exclusive (Result.Kind_Set, "project kind");
               Result.Kind := Binary_Project;
            elsif Argument = "--lib" then
               Select_Exclusive (Result.Kind_Set, "project kind");
               Result.Kind := Library_Project;
            elsif Argument = "--flyology-project" then
               Result.Profile := Flyology_Project;
            elsif Argument = "--no-agents" then
               Result.Agents := False;
            elsif Argument = "--website" then
               Result.Website := True;
            elsif Argument = "--yes" or else Argument = "-y" then
               Result.Assume_Yes := True;
            elsif Argument = "--help" or else Argument = "-h" then
               Show_Help;
               Result.Help := True;
               Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
               return Result;
            elsif Argument = "--name" then
               if Result.Name_Set then
                  Fail ("--name may be specified only once");
               end if;
               Index := Index + 1;
               if Index > Ada.Command_Line.Argument_Count then
                  Fail ("--name requires a value");
               end if;
               Result.Name := To_Unbounded_String (Ada.Command_Line.Argument (Index));
               Result.Name_Set := True;
            elsif Ada.Strings.Fixed.Index (Argument, "--name=") = 1 then
               if Result.Name_Set then
                  Fail ("--name may be specified only once");
               end if;
               Result.Name := To_Unbounded_String (Argument (Argument'First + 7 .. Argument'Last));
               Result.Name_Set := True;
            elsif Argument'Length > 0 and then Argument (Argument'First) = '-' then
               Fail ("unknown init option: " & Argument);
            elsif Destination_Set then
               Fail ("only one destination directory may be specified");
            else
               Result.Destination := To_Unbounded_String (Argument);
               Destination_Set := True;
            end if;
         end;
         Index := Index + 1;
      end loop;
      return Result;
   end Parse;

   function Has_Flyology_Index (Listing : String) return Boolean is
      Position : Positive := Listing'First;
   begin
      while Position <= Listing'Last loop
         declare
            Newline : constant Natural :=
              Ada.Strings.Fixed.Index (Listing (Position .. Listing'Last), String'(1 => LF));
            Last    : constant Natural := (if Newline = 0 then Listing'Last else Newline - 1);
         begin
            declare
               Line       : constant String := Listing (Position .. Last);
               Word_Start : Natural := Line'First;
               Word_End   : Natural;
            begin
               while Word_Start <= Line'Last and then Line (Word_Start) = ' ' loop
                  Word_Start := Word_Start + 1;
               end loop;
               while Word_Start <= Line'Last and then Line (Word_Start) not in ' ' | ASCII.HT loop
                  Word_Start := Word_Start + 1;
               end loop;
               while Word_Start <= Line'Last and then Line (Word_Start) in ' ' | ASCII.HT loop
                  Word_Start := Word_Start + 1;
               end loop;
               Word_End := Word_Start;
               while Word_End <= Line'Last and then Line (Word_End) not in ' ' | ASCII.HT loop
                  Word_End := Word_End + 1;
               end loop;
               if Word_Start < Word_End and then Line (Word_Start .. Word_End - 1) = "flyology" then
                  return True;
               end if;
            end;
            exit when Last = Listing'Last;
            Position := Last + 2;
         end;
      end loop;
      return False;
   end Has_Flyology_Index;

   procedure Ensure_Index (Assume_Yes : Boolean) is
      Arguments : String_Vectors.Vector;
      Output    : Unbounded_String;
      Status    : Integer;
   begin
      if not Is_Available ("alr") then
         Fail ("Alire 2.1 or newer is required; install it from https://alire.ada.dev/");
      end if;

      Arguments.Append ("index");
      Arguments.Append ("--list");
      Status := Capture ("alr", Arguments, Output);
      if Status /= 0 then
         Fail ("could not inspect configured Alire indexes");
      end if;
      if Has_Flyology_Index (To_String (Output)) then
         return;
      end if;

      if not Assume_Yes and then not Prompt_Yes_No ("Add the Flyology Alire index?", True) then
         Fail ("the Flyology Alire index is required");
      end if;

      Arguments.Clear;
      Arguments.Append ("index");
      Arguments.Append ("--reset-community");
      if Processes.Run ("alr", Arguments) /= 0 then
         Fail ("could not enable the Alire community index");
      end if;

      Arguments.Clear;
      Arguments.Append ("index");
      Arguments.Append ("--add=git+https://github.com/flyology-ada/alire-index.git");
      Arguments.Append ("--name=flyology");
      Arguments.Append ("--before=community");
      if Processes.Run ("alr", Arguments) /= 0 then
         Fail ("could not add the Flyology Alire index");
      end if;
   end Ensure_Index;

   procedure Check_Absent (Path : String) is
   begin
      if GNAT.OS_Lib.Is_Symbolic_Link (Path) or else Ada.Directories.Exists (Path) then
         Fail ("refusing to overwrite " & Path);
      end if;
   end Check_Absent;

   procedure Check_Output_Directory (Path : String) is
   begin
      if GNAT.OS_Lib.Is_Symbolic_Link (Path) then
         Fail ("refusing symbolic-link output directory " & Path);
      elsif Ada.Directories.Exists (Path) and then Ada.Directories.Kind (Path) /= Ada.Directories.Directory
      then
         Fail ("output path is not a directory: " & Path);
      end if;
   end Check_Output_Directory;

   procedure Write_File (Path : String; Contents : String) is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put (File, Contents);
      Ada.Text_IO.Close (File);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Write_File;

   function Manifest (Name : String; Kind : Project_Kind; Profile : Project_Profile) return String is
   begin
      return
        "name = "
        & Quote (Name)
        & LF
        & "description = "
        & Quote ("A Flyology-based Ada project")
        & LF
        & "version = ""0.1.0-dev"""
        & LF
        & LF
        & "licenses = ""MIT OR Apache-2.0"""
        & LF
        & (if Profile = Flyology_Project
           then "website = ""https://flyology.org/""" & LF & "tags = [""ada"", ""flyology""]" & LF
           else "tags = [""ada""]" & LF)
        & "project-files = ["
        & Quote (Name & ".gpr")
        & "]"
        & LF
        & LF
        & (if Kind = Binary_Project then "executables = [" & Quote (Name) & "]" & LF & LF else "")
        & "[[depends-on]]"
        & LF
        & "gnat = "">=13 & <17"""
        & LF
        & LF
        & "[[depends-on]]"
        & LF
        & "flyology = ""^0.1.0"""
        & LF;
   end Manifest;

   function Project_File (Name : String; Kind : Project_Kind) return String is
      Unit : constant String := Ada_Name (Name);
   begin
      return
        "with ""flyology.gpr"";"
        & LF
        & LF
        & "project "
        & Unit
        & " is"
        & LF
        & "   for Source_Dirs use (""src"");"
        & LF
        & "   for Object_Dir use ""obj"";"
        & LF
        & (if Kind = Binary_Project
           then "   for Exec_Dir use ""bin"";" & LF & "   for Main use (""" & Name & ".adb"");" & LF
           else
             "   for Library_Name use """
             & Name
             & """;"
             & LF
             & "   for Library_Kind use ""static"";"
             & LF
             & "   for Library_Dir use ""lib"";"
             & LF)
        & "   for Create_Missing_Dirs use ""True"";"
        & LF
        & LF
        & "   package Compiler is"
        & LF
        & "      for Default_Switches (""Ada"") use"
        & LF
        & "        (""-O2"", ""-gnat2022"", ""-gnatwa"", ""-gnatwJ"", ""-gnatVa"","
        & LF
        & "         ""-gnatyM110"");"
        & LF
        & "   end Compiler;"
        & LF
        & LF
        & "   package Format is"
        & LF
        & "      for Width (""Ada"") use ""110"";"
        & LF
        & "      for Indentation (""Ada"") use ""3"";"
        & LF
        & "      for Indentation_Continuation (""Ada"") use ""2"";"
        & LF
        & "      for Indentation_Kind (""Ada"") use ""spaces"";"
        & LF
        & "      for End_Of_Line (""Ada"") use ""lf"";"
        & LF
        & "      for Charset (""Ada"") use ""utf-8"";"
        & LF
        & "   end Format;"
        & LF
        & LF
        & "   package Documentation is"
        & LF
        & "      for Excluded_Project_Files use"
        & LF
        & "        (external (""FLYOLOGY_ROOT"", """") & ""/flyology.gpr"");"
        & LF
        & "      for Resources_Dir (""html"") use ""docs/gnatdoc/html"";"
        & LF
        & "   end Documentation;"
        & LF
        & "end "
        & Unit
        & ";"
        & LF;
   end Project_File;

   function Source_File (Name : String; Kind : Project_Kind) return String is
      Unit : constant String := Ada_Name (Name);
   begin
      if Kind = Binary_Project then
         return
           "with Ada.Text_IO;"
           & LF
           & LF
           & "procedure "
           & Unit
           & " is"
           & LF
           & "begin"
           & LF
           & "   Ada.Text_IO.Put_Line (""Hello from "
           & Name
           & """);"
           & LF
           & "end "
           & Unit
           & ";"
           & LF;
      else
         return "package " & Unit & " is" & LF & "end " & Unit & ";" & LF;
      end if;
   end Source_File;

   function APM_Manifest (Name : String; Website : Boolean) return String is
   begin
      return
        "name: "
        & Name
        & "-agent-context"
        & LF
        & "version: 0.1.0"
        & LF
        & "type: hybrid"
        & LF
        & "targets: [codex, claude]"
        & LF
        & "includes: auto"
        & LF
        & "dependencies:"
        & LF
        & "  apm:"
        & LF
        & "    - git: https://github.com/flyology-ada/agents.git"
        & LF
        & "      path: packages/profiles/ada-library"
        & LF
        & "      ref: main"
        & LF
        & (if Website
           then
             "    - git: https://github.com/flyology-ada/agents.git"
             & LF
             & "      path: packages/profiles/flyology-website"
             & LF
             & "      ref: main"
             & LF
           else "");
   end APM_Manifest;

   procedure Write_Website (Name : String) is
      Theme       : constant String :=
        "{"
        & LF
        & "  ""pageTitle"": """
        & Name
        & " API"","
        & LF
        & "  ""indexDescription"": ""API reference for "
        & Name
        & "."","
        & LF
        & "  ""indexTitle"": """
        & Name
        & " API"","
        & LF
        & "  ""canonicalUrl"": ""https://example.com/api/"","
        & LF
        & "  ""brandLabel"": """
        & Name
        & ""","
        & LF
        & "  ""navigationHtml"": ""<a href='../'>Home</a>"","
        & LF
        & "  ""indexIntroduction"": ""Public Ada API."","
        & LF
        & "  ""footerNote"": ""Generated with GNATdoc."""
        & LF
        & "}"
        & LF;
      Index_HTML  : constant String :=
        "<!doctype html>"
        & LF
        & "<html lang=""en""><head><meta charset=""utf-8"">"
        & LF
        & "<meta name=""viewport"" content=""width=device-width,initial-scale=1"">"
        & LF
        & "<title>"
        & Name
        & "</title><link rel=""stylesheet"" href=""assets/styles/site.css"">"
        & LF
        & "</head><body><main><h1>"
        & Name
        & "</h1><p>A Flyology-based Ada project.</p>"
        & LF
        & "<p><a href=""api/"">API reference</a></p></main></body></html>"
        & LF;
      Icon_SVG    : constant String :=
        "<svg xmlns=""http://www.w3.org/2000/svg"" viewBox=""0 0 256 256"" role=""img"" "
        & "aria-labelledby=""title desc"">"
        & LF
        & "  <title id=""title"">Flyology primary icon</title>"
        & LF
        & "  <desc id=""desc"">An abstract flight mark inside an open event loop with three "
        & "cooperative task nodes.</desc>"
        & LF
        & "  <defs>"
        & LF
        & "    <mask id=""node-gaps"" maskUnits=""userSpaceOnUse"" x=""0"" y=""0"" width=""256"" "
        & "height=""256"">"
        & LF
        & "      <rect width=""256"" height=""256"" fill=""white""/>"
        & LF
        & "      <circle cx=""203.4"" cy=""77.1"" r=""10.5"" fill=""black""/>"
        & LF
        & "      <circle cx=""219"" cy=""128"" r=""10.5"" fill=""black""/>"
        & LF
        & "      <circle cx=""203.4"" cy=""178.9"" r=""10.5"" fill=""black""/>"
        & LF
        & "    </mask>"
        & LF
        & "  </defs>"
        & LF
        & LF
        & "  <rect x=""12"" y=""12"" width=""232"" height=""232"" rx=""58"" fill=""#10172B""/>"
        & LF
        & LF
        & "  <g mask=""url(#node-gaps)"" fill=""none"" stroke-width=""8"" stroke-linecap=""round"">"
        & LF
        & "    <circle cx=""128"" cy=""128"" r=""91"" stroke=""#3C4868""/>"
        & LF
        & "    <path d=""M186.5 58.3A91 91 0 0 1 219 128"" stroke=""#756CF6""/>"
        & LF
        & "    <path d=""M219 128A91 91 0 0 1 186.5 197.7"" stroke=""#2CCBC1""/>"
        & LF
        & "  </g>"
        & LF
        & "  <circle cx=""203.4"" cy=""77.1"" r=""6.5"" fill=""#756CF6""/>"
        & LF
        & "  <circle cx=""219"" cy=""128"" r=""6.5"" fill=""#756CF6""/>"
        & LF
        & "  <circle cx=""203.4"" cy=""178.9"" r=""6.5"" fill=""#2CCBC1""/>"
        & LF
        & "  <path d=""M177.8 205.8C179.3 201.4 180.2 197.4 180.4 193.2C184 196.3 188.1 198.7 "
        & "192.5 199.9C187.9 201.1 182.8 203.2 177.8 205.8Z"" fill=""#2CCBC1""/>"
        & LF
        & LF
        & "  <g fill=""#F7F9FF"">"
        & LF
        & "    <path d=""M143 103C116 88 91 78 62 75C84 94 102 112 116 134C120 140 128 138 "
        & "134 132C141 124 145 113 143 103Z""/>"
        & LF
        & "    <path d=""M128 137C109 127 89 122 68 124C86 135 101 148 112 163C117 169 124 166 "
        & "129 160C134 153 134 144 128 137Z""/>"
        & LF
        & "    <path d=""M119 177C126 145 133 118 146 97C158 81 173 72 191 68C176 87 160 108 148 134"
        & "C140 152 133 165 119 177Z""/>"
        & LF
        & "    <circle cx=""129"" cy=""137"" r=""4""/>"
        & LF
        & "  </g>"
        & LF
        & "</svg>"
        & LF;
      Docs_Script : constant String :=
        "#!/bin/sh"
        & LF
        & "set -eu"
        & LF
        & "project_root=$(CDPATH= cd -- ""$(dirname -- ""$0"")/.."" && pwd)"
        & LF
        & "cd ""$project_root"""
        & LF
        & "alr build --stop-after=generation"
        & LF
        & "node vendor/website-kit/scripts/render-gnatdoc-theme.mjs "
        & "website/gnatdoc-theme.json docs/gnatdoc/html"
        & LF
        & "for template in docs/gnatdoc/html/template/*.xhtml; do"
        & LF
        & "  sed ""s|href='../guide/'|href='../'|"" ""$template"" >""$template.tmp"""
        & LF
        & "  mv ""$template.tmp"" ""$template"""
        & LF
        & "done"
        & LF
        & "rm -rf docs/api"
        & LF
        & "mkdir -p docs/api"
        & LF
        & "alr exec -- gnatdoc --backend=html --generate=public --warnings --style=leading "
        & "-P "
        & Name
        & ".gpr -O docs/api"
        & LF
        & "mkdir -p docs/api/fonts"
        & LF
        & "cp vendor/website-kit/assets/fonts/geologica-latin-variable.woff2 docs/api/fonts/"
        & LF
        & "cp vendor/website-kit/assets/scripts/ada-highlight.js docs/api/"
        & LF
        & "cp website/flyology-mark.svg docs/api/"
        & LF
        & "node vendor/website-kit/scripts/build-api-search-index.mjs docs/api"
        & LF;
      Site_Script : constant String :=
        "#!/bin/sh"
        & LF
        & "set -eu"
        & LF
        & "project_root=$(CDPATH= cd -- ""$(dirname -- ""$0"")/.."" && pwd)"
        & LF
        & "site_output=""$project_root/build/site"""
        & LF
        & "rm -rf ""$site_output"""
        & LF
        & "mkdir -p ""$site_output"""
        & LF
        & "cp -R ""$project_root/website/."" ""$site_output/"""
        & LF
        & "node ""$project_root/vendor/website-kit/scripts/install-assets.mjs"" ""$site_output"""
        & LF
        & """$project_root/scripts/docs.sh"""
        & LF
        & "cp -R ""$project_root/docs/api"" ""$site_output/api"""
        & LF
        & "touch ""$site_output/.nojekyll"""
        & LF
        & "node ""$project_root/vendor/website-kit/scripts/check-site.mjs"" ""$site_output"""
        & LF;
   begin
      Ada.Directories.Create_Path ("website");
      Ada.Directories.Create_Path ("scripts");
      Write_File ("website/index.html", Index_HTML);
      Write_File ("website/gnatdoc-theme.json", Theme);
      Write_File ("website/flyology-mark.svg", Icon_SVG);
      Write_File ("scripts/docs.sh", Docs_Script);
      Write_File ("scripts/build-site.sh", Site_Script);
      GNAT.OS_Lib.Set_Executable ("scripts/docs.sh");
      GNAT.OS_Lib.Set_Executable ("scripts/build-site.sh");
   end Write_Website;

   procedure Check_Required_Tools (Settings : Options) is
   begin
      if Settings.Agents and then not Is_Available ("apm") then
         Fail ("APM is required unless --no-agents is used; install APM 0.28.0 and retry");
      end if;
      if Settings.Website and then not Is_Available ("git") then
         Fail ("Git is required for --website");
      end if;
   end Check_Required_Tools;

   procedure Preflight_Project (Settings : Options; Name : String) is
      Source_Ext : constant String := (if Settings.Kind = Binary_Project then ".adb" else ".ads");
   begin
      Check_Output_Directory ("src");
      Check_Absent ("alire.toml");
      Check_Absent (Name & ".gpr");
      Check_Absent ("src/" & Name & Source_Ext);
      if Settings.Agents then
         Check_Absent ("apm.yml");
      end if;
      if Settings.Website then
         Check_Output_Directory ("scripts");
         Check_Output_Directory ("vendor");
         Check_Absent ("website");
         Check_Absent ("scripts/docs.sh");
         Check_Absent ("scripts/build-site.sh");
         Check_Absent ("vendor/website-kit");
      end if;
      Check_Absent ("README.md");
      Check_Absent (".gitignore");
   end Preflight_Project;

   procedure Run_In_Project (Settings : in out Options; Root : String; Name : String) is
      Arguments   : String_Vectors.Vector;
      Source_Ext  : constant String := (if Settings.Kind = Binary_Project then ".adb" else ".ads");
      Use_Agents  : constant Boolean := Settings.Agents;
      Use_Website : constant Boolean := Settings.Website;
   begin
      Preflight_Project (Settings, Name);

      Ada.Directories.Create_Path ("src");
      Write_File ("alire.toml", Manifest (Name, Settings.Kind, Settings.Profile));
      Write_File (Name & ".gpr", Project_File (Name, Settings.Kind));
      Write_File ("src/" & Name & Source_Ext, Source_File (Name, Settings.Kind));
      Write_File
        ("README.md",
         "# "
         & Name
         & LF
         & LF
         & "This "
         & (if Settings.Profile = Flyology_Project then "Flyology project" else "consumer project")
         & " is managed with Alire."
         & LF
         & LF
         & "```sh"
         & LF
         & "alr build"
         & LF
         & "```"
         & LF);
      Write_File
        (".gitignore",
         "/alire/"
         & LF
         & "/bin/"
         & LF
         & "/lib/"
         & LF
         & "/config/"
         & LF
         & "/obj/"
         & LF
         & "/build/"
         & LF
         & "/docs/api/"
         & LF
         & "/docs/gnatdoc/html/"
         & LF
         & "/.agents/"
         & LF
         & "/.claude/rules/"
         & LF
         & "/.claude/skills/"
         & LF
         & "/apm_modules/"
         & LF);

      if Use_Agents then
         Write_File ("apm.yml", APM_Manifest (Name, Use_Website));
         Arguments.Append ("install");
         if Processes.Run ("apm", Arguments) /= 0 then
            Fail ("apm install failed in " & Root);
         end if;
         Arguments.Clear;
         Arguments.Append ("compile");
         Arguments.Append ("--target");
         Arguments.Append ("codex");
         if Processes.Run ("apm", Arguments) /= 0 then
            Fail ("apm compile --target codex failed in " & Root);
         end if;
      end if;

      if Use_Website then
         if not Ada.Directories.Exists (".git") then
            Arguments.Clear;
            Arguments.Append ("init");
            if Processes.Run ("git", Arguments) /= 0 then
               Fail ("git init failed in " & Root);
            end if;
         end if;
         Arguments.Clear;
         Arguments.Append ("submodule");
         Arguments.Append ("add");
         Arguments.Append ("https://github.com/flyology-ada/website-kit.git");
         Arguments.Append ("vendor/website-kit");
         if Processes.Run ("git", Arguments) /= 0 then
            Fail ("could not add vendor/website-kit as a Git submodule");
         end if;
         Write_Website (Name);
      end if;
   end Run_In_Project;

   procedure Run is
      Settings : Options := Parse;
   begin
      if Settings.Help then
         return;
      end if;

      if not Settings.Kind_Set and then not Settings.Assume_Yes then
         declare
            Answer : constant String :=
              Ada.Characters.Handling.To_Lower (Prompt ("Project kind: binary or library?", "binary"));
         begin
            if Answer = "binary" or else Answer = "bin" or else Answer = "b" then
               Settings.Kind := Binary_Project;
            elsif Answer = "library" or else Answer = "lib" or else Answer = "l" then
               Settings.Kind := Library_Project;
            else
               Fail ("expected binary or library");
            end if;
         end;
      end if;

      if Length (Settings.Name) = 0 then
         declare
            Suggested : constant String := Suggested_Name (To_String (Settings.Destination));
         begin
            Settings.Name :=
              To_Unbounded_String
                (if Settings.Assume_Yes then Suggested else Prompt ("Crate name", Suggested));
         end;
      end if;
      if not Is_Valid_Crate_Name (To_String (Settings.Name)) then
         Fail ("invalid Alire/Ada crate name: " & To_String (Settings.Name));
      elsif Is_Ada_Reserved_Word (To_String (Settings.Name)) then
         Fail ("crate name is an Ada reserved word: " & To_String (Settings.Name));
      elsif Is_Forbidden_Crate_Name (To_String (Settings.Name)) then
         Fail ("crate name conflicts with a predefined unit or dependency: " & To_String (Settings.Name));
      end if;

      declare
         Original : constant String := Ada.Directories.Current_Directory;
         Target   : constant String := Ada.Directories.Full_Name (To_String (Settings.Destination));
      begin
         Check_Required_Tools (Settings);
         if Ada.Directories.Exists (Target) then
            if Ada.Directories.Kind (Target) /= Ada.Directories.Directory then
               Fail ("destination is not a directory: " & Target);
            end if;
            Ada.Directories.Set_Directory (Target);
            begin
               Preflight_Project (Settings, To_String (Settings.Name));
            exception
               when others =>
                  Ada.Directories.Set_Directory (Original);
                  raise;
            end;
            Ada.Directories.Set_Directory (Original);
         elsif GNAT.OS_Lib.Is_Symbolic_Link (Target) then
            Fail ("destination is a broken symbolic link: " & Target);
         end if;

         Ensure_Index (Settings.Assume_Yes);

         if not Ada.Directories.Exists (Target) then
            Ada.Directories.Create_Path (Target);
         elsif Ada.Directories.Kind (Target) /= Ada.Directories.Directory then
            Fail ("destination changed and is not a directory: " & Target);
         end if;
         Ada.Directories.Set_Directory (Target);
         begin
            Run_In_Project (Settings, Target, To_String (Settings.Name));
         exception
            when others =>
               Ada.Directories.Set_Directory (Original);
               raise;
         end;
         Ada.Directories.Set_Directory (Original);
         Ada.Text_IO.Put_Line ("Initialized " & To_String (Settings.Name) & " in " & Target);
      end;
   exception
      when Error : Init_Error =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error, "flyology init: " & Ada.Exceptions.Exception_Message (Error));
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      when Error : others =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "flyology init: "
            & Ada.Exceptions.Exception_Name (Error)
            & ": "
            & Ada.Exceptions.Exception_Message (Error));
         Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end Run;
end Flyology_CLI.Init;
