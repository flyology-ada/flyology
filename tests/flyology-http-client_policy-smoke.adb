procedure Flyology.HTTP.Client_Policy.Smoke is

   procedure Check_Upload_Validation is
   begin
      for Retained in Boolean loop
         for Source in Boolean loop
            for Known in Boolean loop
               for Source_Content in Boolean loop
                  for Trailers in Boolean loop
                     for Expect in Boolean loop
                        declare
                           Expected : constant Upload_Validation_Action :=
                             (if Retained and then Source
                              then Reject_Mixed_Body
                              elsif Trailers
                                and then (not Source or else Known)
                              then Reject_Trailer_Framing
                              elsif Expect
                                and then
                                  not (Retained
                                         or else
                                           (Source and then Source_Content))
                              then Reject_Empty_Expectation
                              else Accept_Upload);
                        begin
                           pragma Assert
                             (Validate_Upload
                                (Retained, Source, Known, Source_Content,
                                 Trailers, Expect) = Expected);
                        end;
                     end loop;
                  end loop;
               end loop;
            end loop;
         end loop;
      end loop;
   end Check_Upload_Validation;

   procedure Check_Pulls is
   begin
      pragma Assert
        (Classify_Pull (False, 0, 0, False) = Reject_No_Progress);
      pragma Assert (Classify_Pull (False, 0, 0, True) = Accept_Pull);
      pragma Assert (Classify_Pull (False, 7, 0, False) = Accept_Pull);
      pragma Assert
        (Classify_Pull (True, 0, 5, False) = Reject_No_Progress);
      pragma Assert
        (Classify_Pull (True, 0, 5, True) = Reject_Too_Short);
      pragma Assert
        (Classify_Pull (True, 6, 5, False) = Reject_Too_Long);
      pragma Assert
        (Classify_Pull (True, 6, 5, True) = Reject_Too_Long);
      pragma Assert
        (Classify_Pull (True, 3, 5, False) = Accept_Pull);
      pragma Assert
        (Classify_Pull (True, 3, 5, True) = Reject_Too_Short);
      pragma Assert
        (Classify_Pull (True, 5, 5, False) = Reject_Not_Finished);
      pragma Assert (Classify_Pull (True, 5, 5, True) = Accept_Pull);
      pragma Assert
        (Classify_Pull
           (True, Body_Byte_Count'Last, Body_Byte_Count'Last, True) =
         Accept_Pull);
      pragma Assert
        (Classify_Pull
           (True, Body_Byte_Count'Last, Body_Byte_Count'Last, False) =
         Reject_Not_Finished);
   end Check_Pulls;

   procedure Check_Stale_Retries is
   begin
      for Replay in Replay_Kind loop
         for Reused in Boolean loop
            for Retried in Boolean loop
               for Idempotent in Boolean loop
                  for Saw_Response in Boolean loop
                     for Source_Failed in Boolean loop
                        for Time_Remains in Boolean loop
                           declare
                              Eligible : constant Boolean :=
                                Reused
                                  and then not Retried
                                  and then Idempotent
                                  and then not Saw_Response
                                  and then not Source_Failed
                                  and then Time_Remains;
                              Expected : constant Stale_Retry_Action :=
                                (if not Eligible
                                   or else Replay = One_Shot_Stream
                                 then Propagate_Failure
                                 elsif Replay = Direct_Replay
                                 then Retry_Directly
                                 else Rewind_And_Retry);
                           begin
                              pragma Assert
                                (Classify_Stale_Retry
                                   (Replay, Reused, Retried, Idempotent,
                                    Saw_Response, Source_Failed,
                                    Time_Remains) = Expected);
                           end;
                        end loop;
                     end loop;
                  end loop;
               end loop;
            end loop;
         end loop;
      end loop;
   end Check_Stale_Retries;

   procedure Check_Informational is
   begin
      for Status in Status_Code range 100 .. 199 loop
         for Framing in Boolean loop
            for Accepted in Informational_Count loop
               declare
                  Expected : constant Informational_Action :=
                    (if Status = 101 then Reject_Upgrade
                     elsif Framing then Reject_Informational_Framing
                     elsif Accepted = Maximum_Informational_Responses
                     then Reject_Informational_Excess
                     elsif Status = 100 then Accept_Continue
                     else Accept_Other_Informational);
               begin
                  pragma Assert
                    (Classify_Informational
                       (Status, Framing, Accepted) = Expected);
                  if Accepted < Maximum_Informational_Responses then
                     pragma Assert
                       (Next_Informational_Count (Accepted) = Accepted + 1);
                  end if;
               end;
            end loop;
         end loop;
      end loop;
   end Check_Informational;

   procedure Check_Expectation_Responses is
   begin
      for Sent in Boolean loop
         for Body_Sent in Boolean loop
            for Retried in Boolean loop
               for Allowed in Boolean loop
                  for Status in Status_Code loop
                     declare
                        Expected : constant Expectation_Response_Action :=
                          (if Sent
                             and then not Body_Sent
                             and then not Retried
                             and then Status = 417
                             and then Allowed
                           then Retry_Without_Expectation
                           else Return_Response);
                     begin
                        pragma Assert
                          (Classify_Expectation_Response
                             (Sent, Body_Sent, Retried, Status, Allowed) =
                           Expected);
                     end;
                  end loop;
               end loop;
            end loop;
         end loop;
      end loop;
   end Check_Expectation_Responses;

   procedure Check_Redirects is
   begin
      for Enabled in Boolean loop
         for Has_Location in Boolean loop
            for Status in Status_Code loop
               for Is_Post in Boolean loop
                  for Is_Head in Boolean loop
                     declare
                        Expected : constant Redirect_Action :=
                          (if not Enabled
                             or else not Has_Location
                             or else Status not in 301 | 302 | 303 | 307 | 308
                           then Return_Redirect_Response
                           elsif Status = 303 and then Is_Head
                           then Follow_As_Head
                           elsif Status = 303
                             or else
                               (Status in 301 | 302 and then Is_Post)
                           then Follow_As_Get
                           else Follow_Preserving_Method);
                     begin
                        pragma Assert
                          (Classify_Redirect
                             (Enabled, Has_Location, Status, Is_Post,
                              Is_Head) = Expected);
                     end;
                  end loop;
               end loop;
            end loop;
         end loop;
      end loop;
   end Check_Redirects;

begin
   Check_Upload_Validation;
   Check_Pulls;
   Check_Stale_Retries;
   Check_Informational;
   Check_Expectation_Responses;
   Check_Redirects;
end Flyology.HTTP.Client_Policy.Smoke;
