"""`komira_metrics` -- the metrics model.

Per-operator `MetricsSet`s (counters, time, gauges), attribute-set interning,
the per-worker series and histogram tables with their export sweep, and the
EXPLAIN ANALYZE collector and renderer.

Per-worker state is indexed by the worker id: each worker owns a disjoint
slot, so recording needs no thread-local storage and no atomics on the hot
path.

Public API: import directly from sub-modules. No facade.

Dependency direction (DAG, leaf-ish):
  komira_metrics -> the core packages (Slab), komira_name_registry (comptime name
                    ids), komira_hash (FNV-1a constants), komira_clock

komira_metrics MUST NOT depend on engine packages, on `komira_trace` or on
`komira_log`. The embedder constructs a `MetricsSet` and hands it to the engine
by borrowed reference; there are no process-global registries.
"""
