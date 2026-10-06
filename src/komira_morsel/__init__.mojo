"""`komira_morsel` -- the morsel layer of the engine.

The `Morsel` row chunk and its splitters, the trait surface that the
scheduler side and the operator side both need (`MorselSourceImpl`,
`MorselSinkImpl`, `MorselOperatorImpl`), the pipeline-execution context that
`MorselSinkImpl.combine()` carries, the vtable-erased source, scan-binding
resolution, the streaming source and sink contracts, and the morsel-level
filter kernels (fused filters, dynamic join filters, bloom masks, the top-N
boundary).

It depends on the core packages (Arrow, buffers, collections, the plan IR and
expressions, scan sources, the column kernels), `komira_metrics` and
`komira_atomic_alias`, and on no engine package, so the engine packages above it and the async runtime can
both import it without a cycle.

Public API: import directly from sub-modules. No facade.
"""
