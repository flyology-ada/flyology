--  Internal, proved resolver decisions taken from parsed DNS state.
--
--  The transports, clocks, and packet parsing remain outside this package;
--  it proves the pure choices the resolver makes from their results: which
--  configured endpoint an attempt round visits, how long a receive wait may
--  last, whether a decoded label byte is usable, and which outcome an
--  exhausted attempt sequence reports.
--
--  Example: `Window := Receive_Window (0.4, 1.2, False);`

private package Flyology.DNS_Policy
  with Preelaborate, SPARK_Mode => On
is

   --  Result reported once every attempt round of one query kind is spent.
   --  @enum Report_Malformed No response survived validation
   --  @enum Report_Server_Failure Every answer carried a failure code
   --  @enum Report_Transport_Failure A transport failed without an answer
   --  @enum Report_Deadline No server produced anything before the deadline
   type Exhausted_Outcome is
     (Report_Malformed, Report_Server_Failure, Report_Transport_Failure, Report_Deadline);

   --  Zero-based offset added to an attempt round when picking an endpoint.
   subtype Rotation_Offset is Natural;

   --  Offset of the endpoint an attempt round visits, counted from the first
   --  configured endpoint. Rotation only changes where a round starts, so one
   --  full round still visits every endpoint exactly once and the configured
   --  order remains the identity of the server set.
   --  @param Attempt One-based attempt round counter
   --  @param Rotation Offset applied to the configured order
   --  @param Count Number of configured endpoints
   --  @return Zero-based offset of the selected endpoint
   function Selected_Endpoint
     (Attempt : Positive; Rotation : Rotation_Offset; Count : Positive) return Natural
   with
     Global => null,
     Pre    => Attempt <= Integer'Last - Rotation,
     Post   =>
       Selected_Endpoint'Result < Count
       and then Selected_Endpoint'Result = (Attempt - 1 + Rotation) mod Count;

   --  Seconds assigned to one attempt. Overall_Remaining may carry the
   --  caller's negative infinite sentinel only when Infinite is true; that
   --  sentinel must never participate in deadline arithmetic.
   --  @param Per_Attempt Configured duration of one attempt
   --  @param Overall_Remaining Seconds left in the caller's deadline
   --  @param Infinite The caller supplied no overall deadline
   --  @return Seconds assigned to the attempt
   function Attempt_Window
     (Per_Attempt : Duration; Overall_Remaining : Duration; Infinite : Boolean) return Duration
   with
     Global => null,
     Pre    => Per_Attempt > 0.0 and then (Infinite or else Overall_Remaining >= 0.0),
     Post   =>
       Attempt_Window'Result
       = (if Infinite then Per_Attempt else Duration'Min (Per_Attempt, Overall_Remaining))
       and then Attempt_Window'Result >= 0.0
       and then Attempt_Window'Result <= Per_Attempt;

   --  Seconds a receive wait may last. A hostile peer can keep a socket
   --  readable indefinitely, so the caller re-evaluates this before every
   --  wait and abandons the attempt once it reaches zero. Overall_Remaining
   --  is ignored when the caller supplied no overall deadline.
   --  @param Attempt_Remaining Seconds left in the current attempt
   --  @param Overall_Remaining Seconds left in the caller's deadline
   --  @param Infinite The caller supplied no overall deadline
   --  @return Nonnegative seconds the next wait may block
   function Receive_Window
     (Attempt_Remaining : Duration; Overall_Remaining : Duration; Infinite : Boolean) return Duration
   with
     Global => null,
     Post   =>
       Receive_Window'Result >= 0.0
       and then Receive_Window'Result <= Duration'Max (0.0, Attempt_Remaining)
       and then (if not Infinite then Receive_Window'Result <= Duration'Max (0.0, Overall_Remaining))
       and then (if Attempt_Remaining > 0.0 and then (Infinite or else Overall_Remaining > 0.0)
                 then Receive_Window'Result > 0.0);

   --  True when neither deadline leaves room for another receive wait.
   --  @param Attempt_Remaining Seconds left in the current attempt
   --  @param Overall_Remaining Seconds left in the caller's deadline
   --  @param Infinite The caller supplied no overall deadline
   --  @return True when the attempt must be abandoned
   function Receive_Window_Expired
     (Attempt_Remaining : Duration; Overall_Remaining : Duration; Infinite : Boolean) return Boolean
   with
     Global => null,
     Post   =>
       Receive_Window_Expired'Result
       = (Receive_Window (Attempt_Remaining, Overall_Remaining, Infinite) <= 0.0);

   --  Character code of the presentation separator between DNS labels.
   Label_Separator : constant Natural := Character'Pos ('.');

   --  True when a decoded label byte can be stored in a dotted name without
   --  becoming indistinguishable from a label boundary. A separator byte
   --  inside a label would re-encode as a different wire name and compare
   --  equal to wire-distinct owners, so it is rejected.
   --  @param Value Byte taken from a wire-format label
   --  @return True when the byte is usable in a dotted name
   function Label_Byte_Is_Usable (Value : Natural) return Boolean
   with Global => null, Post => Label_Byte_Is_Usable'Result = (Value /= Label_Separator);

   --  Outcome reported once every attempt round is spent. A server-failure
   --  answer is distinguished from a deadline because the servers replied and
   --  the caller's deadline is still unspent.
   --  @param Malformed Some response failed validation
   --  @param Server_Failed Some response carried a failure code
   --  @param Transport_Failed Some transport failed without an answer
   --  @return Outcome the caller reports for the exhausted query
   function Classify_Exhausted
     (Malformed : Boolean; Server_Failed : Boolean; Transport_Failed : Boolean) return Exhausted_Outcome
   with
     Global         => null,
     Contract_Cases =>
       (Malformed                                                              =>
          Classify_Exhausted'Result = Report_Malformed,
        not Malformed and then Server_Failed                                   =>
          Classify_Exhausted'Result = Report_Server_Failure,
        not Malformed and then not Server_Failed and then Transport_Failed     =>
          Classify_Exhausted'Result = Report_Transport_Failure,
        not Malformed and then not Server_Failed and then not Transport_Failed =>
          Classify_Exhausted'Result = Report_Deadline);

end Flyology.DNS_Policy;
