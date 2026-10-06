"""`komira_op_agg_state` -- the aggregation state of the engine.

The accumulators (the dynamic accumulator and accumulator set, the columnar
typed, extra and UTF-8 accumulators, the statistical and percentile ones, the
adapter that runs a user-defined aggregate function), the aggregator and kernel
traits with their built-in and struct-state implementations, the slab of
per-group aggregate states, and the hash tables and hash sets that group keys
map into (byte-keyed, composite-keyed, dense, parametric, growable). Anything
that holds or updates a running aggregate lives here; the sinks and kernels that
drive it are in the packages above.

It depends on `komira_core`, `komira_agg`, `komira_expr`, `komira_kernels` and
`komira_udf`, and on no engine package.

Public API: import directly from sub-modules. No facade.
"""
