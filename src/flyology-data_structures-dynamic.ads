--  Shared contracts for relocatable data structures whose payload capacity
--  grows through a statically selected Flyology.Data_Structures.Arenas
--  instance. "Dynamic" describes growth within a caller-owned fixed arena;
--  these packages do not resize mappings, allocate process-local heap objects,
--  or own backing-region lifetimes.
package Flyology.Data_Structures.Dynamic with Preelaborate is

   --  Outcome of an operation that may need another arena allocation.
   --  @enum Completed The requested operation completed
   --  @enum Arena_Exhausted No arena block can satisfy the requested growth
   --  @enum Arena_Contended Another caller owns the arena metadata guard
   type Growth_Result is (Completed, Arena_Exhausted, Arena_Contended);

end Flyology.Data_Structures.Dynamic;
