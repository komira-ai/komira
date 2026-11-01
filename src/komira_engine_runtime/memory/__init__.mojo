"""`komira_engine_runtime.memory`: memory accounting for breakers.

`reservation.MemoryReservation` tracks the bytes a breaker holds against a
budget; `try_grow` returning False is the signal a spill-capable breaker
answers by spilling. The budget comes from the host profile
(`MemoryReservation.for_host`), never from the environment."""
