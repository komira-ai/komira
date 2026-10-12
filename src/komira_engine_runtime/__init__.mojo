"""`komira_engine_runtime` -- the engine's execution primitives, with no algorithm logic.

Anything an operator or a sink consumes but does not implement lives here: the
host profile a host lowers under (measured once), hardware and topology
detection, morsel sizing as a pure function of the host profile and the
segment, the dispatch-time fork grain, the run and segment execution context
a driver reads, wake primitives, counters, and the small row and column helpers
the operators share.

Dependency direction: the core packages, `komira_async`, `komira_host`,
`komira_morsel` and `komira_physical_plan` sit below it; the operator and dispatch packages sit
above it. Nothing in it imports an operator.

Public API: import directly from `komira_engine_runtime.<module>`. No facade.
"""
