with Flyology.TLS_Policy;

package body Flyology.IO.TLS_Driver is
   package TLS renames Flyology.IO.TLS;
   package Policy renames Flyology.TLS_Policy;

   use type Ada.Streams.Stream_Element_Offset;
   use type TLS.Step_Status;

   function Invalid_Progress_Bound
     (First : Ada.Streams.Stream_Element_Offset;
      Last  : Ada.Streams.Stream_Element_Offset)
      return Ada.Streams.Stream_Element_Offset
   is
      Choice : constant Policy.Sentinel_Choice :=
        Policy.Invalid_Progress_Sentinel (First, Last);
   begin
      if not Choice.Available then
         raise TLS.TLS_Error with
           "TLS buffer range leaves no invalid progress sentinel";
      end if;
      return Choice.Value;
   end Invalid_Progress_Bound;

   procedure Raise_Provider_Error (Item : TLS.Session'Class) is
   begin
      raise TLS.TLS_Error with TLS.Error_Message (Item);
   end Raise_Provider_Error;

   procedure Handshake_Once
     (Item   : in out TLS.Session'Class;
      Status : out TLS.Step_Status) is
   begin
      Status := TLS.Handshake_Step (Item);
      case Status is
         when TLS.Peer_Closed =>
            raise TLS.TLS_Error with "TLS peer closed during handshake";
         when TLS.Failed =>
            Raise_Provider_Error (Item);
         when others =>
            null;
      end case;
   end Handshake_Once;

   procedure Receive_Once
     (Item   : in out TLS.Session'Class;
      Data   : out Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Status : out TLS.Step_Status)
   is
      Before_Last : constant Ada.Streams.Stream_Element_Offset :=
        Data'First - 1;
   begin
      Last := Before_Last;
      if Data'Length = 0 then
         Status := TLS.Complete;
         return;
      end if;
      Status := TLS.Receive_Step (Item, Data, Last);
      case Status is
         when TLS.Complete =>
            if not Policy.Complete_Progress_Valid
              (Data'First, Data'Last, Last)
            then
               raise TLS.TLS_Error with
                 "TLS provider returned an invalid receive bound";
            end if;
         when TLS.Want_Read | TLS.Want_Write | TLS.Peer_Closed =>
            if not Policy.Progress_Preserved (Before_Last, Last) then
               raise TLS.TLS_Error with
                 "TLS provider changed receive output without progress";
            end if;
         when TLS.Failed =>
            Raise_Provider_Error (Item);
      end case;
   end Receive_Once;

   procedure Send_Once
     (Item   : in out TLS.Session'Class;
      Data   : Ada.Streams.Stream_Element_Array;
      Last   : out Ada.Streams.Stream_Element_Offset;
      Status : out TLS.Step_Status)
   is
      Before_Last : constant Ada.Streams.Stream_Element_Offset :=
        Data'First - 1;
   begin
      Last := Before_Last;
      if Data'Length = 0 then
         Status := TLS.Complete;
         return;
      end if;
      Status := TLS.Send_Step (Item, Data, Last);
      case Status is
         when TLS.Complete =>
            if not Policy.Complete_Progress_Valid
              (Data'First, Data'Last, Last)
            then
               raise TLS.TLS_Error with
                 "TLS provider returned an invalid send bound";
            end if;
         when TLS.Want_Read | TLS.Want_Write | TLS.Peer_Closed =>
            if not Policy.Progress_Preserved (Before_Last, Last) then
               raise TLS.TLS_Error with
                 "TLS provider changed send output without progress";
            end if;
         when TLS.Failed =>
            Raise_Provider_Error (Item);
      end case;
   end Send_Once;

   procedure Shutdown_Once
     (Item   : in out TLS.Session'Class;
      Status : out TLS.Step_Status) is
   begin
      Status := TLS.Shutdown_Step (Item);
      case Status is
         when TLS.Peer_Closed =>
            raise TLS.TLS_Error with
              "TLS peer closed before shutdown completed";
         when TLS.Failed =>
            Raise_Provider_Error (Item);
         when others =>
            null;
      end case;
   end Shutdown_Once;

   procedure Handshake
     (Item        : in out TLS.Session'Class;
      Check       : not null access procedure;
      Await_Ready : not null access procedure (Status : TLS.Step_Status))
   is
      Status : TLS.Step_Status;
   begin
      loop
         Check.all;
         Status := TLS.Handshake_Step (Item);
         case Status is
            when TLS.Complete =>
               return;
            when TLS.Want_Read | TLS.Want_Write =>
               Await_Ready.all (Status);
            when TLS.Peer_Closed =>
               raise TLS.TLS_Error with "TLS peer closed during handshake";
            when TLS.Failed =>
               Raise_Provider_Error (Item);
         end case;
      end loop;
   end Handshake;

   procedure Receive
     (Item        : in out TLS.Session'Class;
      Data        : out Ada.Streams.Stream_Element_Array;
      Last        : out Ada.Streams.Stream_Element_Offset;
      Check       : not null access procedure;
      Await_Ready : not null access procedure (Status : TLS.Step_Status))
   is
      Status      : TLS.Step_Status;
      Before_Last : Ada.Streams.Stream_Element_Offset;
   begin
      Last := Data'First - 1;
      if Data'Length = 0 then
         return;
      end if;
      loop
         Check.all;
         Before_Last := Last;
         Status := TLS.Receive_Step (Item, Data, Last);
         case Status is
            when TLS.Complete =>
               if not Policy.Complete_Progress_Valid
                 (Data'First, Data'Last, Last)
               then
                  raise TLS.TLS_Error with
                    "TLS provider returned an invalid receive bound";
               end if;
               return;
            when TLS.Peer_Closed =>
               if not Policy.Progress_Preserved (Before_Last, Last) then
                  raise TLS.TLS_Error with
                    "TLS provider changed receive output on peer close";
               end if;
               return;
            when TLS.Want_Read | TLS.Want_Write =>
               if not Policy.Progress_Preserved (Before_Last, Last) then
                  raise TLS.TLS_Error with
                    "TLS provider changed receive output while waiting";
               end if;
               Await_Ready.all (Status);
            when TLS.Failed =>
               Raise_Provider_Error (Item);
         end case;
      end loop;
   end Receive;

   procedure Receive_Exactly
     (Item        : in out TLS.Session'Class;
      Data        : out Ada.Streams.Stream_Element_Array;
      Check       : not null access procedure;
      Await_Ready : not null access procedure (Status : TLS.Step_Status))
   is
      Status      : TLS.Step_Status;
      First       : Ada.Streams.Stream_Element_Offset := Data'First;
      Last        : Ada.Streams.Stream_Element_Offset;
      Before_Last : Ada.Streams.Stream_Element_Offset;
   begin
      if Data'Length = 0 then
         return;
      end if;
      while First <= Data'Last loop
         Check.all;
         Before_Last := Invalid_Progress_Bound (First, Data'Last);
         Last := Before_Last;
         Status := TLS.Receive_Step
           (Item, Data (First .. Data'Last), Last);
         case Status is
            when TLS.Complete =>
               if not Policy.Complete_Progress_Valid
                 (First, Data'Last, Last)
               then
                  raise TLS.TLS_Error with
                    "TLS provider made no receive progress";
               end if;
               exit when Last = Data'Last;
               First := Policy.Next_Offset (Last);
            when TLS.Want_Read | TLS.Want_Write =>
               if not Policy.Progress_Preserved (Before_Last, Last) then
                  raise TLS.TLS_Error with
                    "TLS provider changed receive output while waiting";
               end if;
               Await_Ready.all (Status);
            when TLS.Peer_Closed =>
               if not Policy.Progress_Preserved (Before_Last, Last) then
                  raise TLS.TLS_Error with
                    "TLS provider changed receive output on peer close";
               end if;
               raise TLS.TLS_Error with
                 "TLS peer closed before receive completed";
            when TLS.Failed =>
               Raise_Provider_Error (Item);
         end case;
      end loop;
   end Receive_Exactly;

   procedure Send_All
     (Item        : in out TLS.Session'Class;
      Data        : Ada.Streams.Stream_Element_Array;
      Check       : not null access procedure;
      Await_Ready : not null access procedure (Status : TLS.Step_Status))
   is
      Status      : TLS.Step_Status;
      First       : Ada.Streams.Stream_Element_Offset := Data'First;
      Last        : Ada.Streams.Stream_Element_Offset;
      Before_Last : Ada.Streams.Stream_Element_Offset;
   begin
      if Data'Length = 0 then
         return;
      end if;
      while First <= Data'Last loop
         Check.all;
         Before_Last := Invalid_Progress_Bound (First, Data'Last);
         Last := Before_Last;
         Status := TLS.Send_Step
           (Item, Data (First .. Data'Last), Last);
         case Status is
            when TLS.Complete =>
               if not Policy.Complete_Progress_Valid
                 (First, Data'Last, Last)
               then
                  raise TLS.TLS_Error with
                    "TLS provider made no send progress";
               end if;
               exit when Last = Data'Last;
               First := Policy.Next_Offset (Last);
            when TLS.Want_Read | TLS.Want_Write =>
               if not Policy.Progress_Preserved (Before_Last, Last) then
                  raise TLS.TLS_Error with
                    "TLS provider changed send output while waiting";
               end if;
               Await_Ready.all (Status);
            when TLS.Peer_Closed =>
               if not Policy.Progress_Preserved (Before_Last, Last) then
                  raise TLS.TLS_Error with
                    "TLS provider changed send output on peer close";
               end if;
               raise TLS.TLS_Error with
                 "TLS peer closed before send completed";
            when TLS.Failed =>
               Raise_Provider_Error (Item);
         end case;
      end loop;
   end Send_All;

   procedure Shutdown
     (Item        : in out TLS.Session'Class;
      Check       : not null access procedure;
      Await_Ready : not null access procedure (Status : TLS.Step_Status))
   is
      Status : TLS.Step_Status;
   begin
      loop
         Check.all;
         Status := TLS.Shutdown_Step (Item);
         case Status is
            when TLS.Complete =>
               return;
            when TLS.Want_Read | TLS.Want_Write =>
               Await_Ready.all (Status);
            when TLS.Peer_Closed =>
               raise TLS.TLS_Error with
                 "TLS peer closed before shutdown completed";
            when TLS.Failed =>
               Raise_Provider_Error (Item);
         end case;
      end loop;
   end Shutdown;

end Flyology.IO.TLS_Driver;
