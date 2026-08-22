with Flyology;
with Semantic_Termination_Cases;

package Semantic_Termination_Native_Native is new
  Semantic_Termination_Cases
    (Label         => "native/native",
     Subject_Model => Flyology.Native_Task,
     Peer_Model    => Flyology.Native_Task);
