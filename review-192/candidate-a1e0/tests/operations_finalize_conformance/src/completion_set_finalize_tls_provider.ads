with Flyology.IO.TLS;

--  Minimal deterministic provider for the failed-upgrade conformance step.

package Completion_Set_Finalize_TLS_Provider is
   type Provider is new Flyology.IO.TLS.Provider with null record;

   overriding
   function Retain
     (Item : in out Provider) return Flyology.IO.TLS.Provider_Access;

   overriding
   function Name (Item : Provider) return String;

   overriding
   function Is_Available (Item : Provider) return Boolean;

   overriding
   function Create_Session
     (Item        : in out Provider;
      FD          : Flyology.IO.Descriptor;
      Side        : Flyology.IO.TLS.Role;
      Server_Name : String) return Flyology.IO.TLS.Session_Access;
end Completion_Set_Finalize_TLS_Provider;
