with Flyology;
with Semantic_Termination_Cases;

package Semantic_Termination_Lightweight_Native is new
  Semantic_Termination_Cases
    (Label         => "lightweight/native",
     Subject_Model => Flyology.Lightweight_Task,
     Peer_Model    => Flyology.Native_Task);
