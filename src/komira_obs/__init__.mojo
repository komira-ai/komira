"""`komira_obs` -- observability foundation.

A minimal Mojo span emitter: per-worker SPSC ring buffers, an FNV-1a comptime
name registry, a single JSONL file exporter, and deterministic test
infrastructure (MockClock / MockIdGenerator / CapturingExporter).

Per-worker state lives in a `Slab[WorkerContextSlot]` indexed by the `tid` of
`@parameter parallelize`: each worker owns a disjoint slot, so recording needs
no thread-local storage and no atomics on the hot path. `metrics_set.MetricsSet`
(per-operator metrics) uses the same disjoint-slot pattern.

Public API: import directly from sub-modules. No facade.

Dependency direction (DAG, leaf-ish):
  komira_obs -> komira_core (for Slab[T])

komira_obs MUST NOT depend on engine packages -- the engine takes a
*borrowed ref* on `Tracer` through EngineContext (constructed by the
embedder, library-first, no process-global singletons).
"""

