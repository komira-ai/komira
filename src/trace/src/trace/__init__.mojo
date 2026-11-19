"""`trace` -- the span tracer.

Per-worker span rings, a name registry shared with the exporter, the Tracer
that emits OPEN / CLOSE packets, and a JSONL exporter that joins the packets
back into span records.

Per-worker state lives in a `Slab[WorkerContextSlot]` indexed by the worker id
(`tid`): each worker owns a disjoint slot, so recording needs no thread-local
storage and no atomics on the hot path. The per-worker packet ring is
`spsc_ring.SpscRing[SpanPacket]` (see `span_ring`).

Public API: import directly from sub-modules. No facade.

Dependency direction:
  trace -> the core packages (Slab)
                  spsc_ring, name_registry, clock
                  atomic_alias (the atomic id counters)

trace MUST NOT depend on engine packages: the engine takes a borrowed
ref on a `Tracer` the embedder constructed.
"""
