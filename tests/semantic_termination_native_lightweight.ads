with Flyology;
with Semantic_Termination_Cases;

package Semantic_Termination_Native_Lightweight is new
  Semantic_Termination_Cases
    (Label         => "native/lightweight",
     Subject_Model => Flyology.Native_Task,
     Peer_Model    => Flyology.Lightweight_Task);
