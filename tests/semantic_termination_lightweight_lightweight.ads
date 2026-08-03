with Flyology;
with Semantic_Termination_Cases;

package Semantic_Termination_Lightweight_Lightweight is new
  Semantic_Termination_Cases
    (Label         => "lightweight/lightweight",
     Subject_Model => Flyology.Lightweight_Task,
     Peer_Model    => Flyology.Lightweight_Task);
