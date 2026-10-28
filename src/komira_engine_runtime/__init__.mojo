"""`komira_engine_runtime` -- the engine's execution primitives, with no algorithm logic.

Anything an operator or a sink consumes but does not implement lives here:
the detection of the host profile a host lowers under (measured once; the
profile value and morsel sizing are in `komira_host_profile`), hardware and
topology detection, the dispatch-time fork grain, the run and segment execution context
a driver reads, counters, and the small row and column helpers
the operators share.

Dependency direction: the core packages, `komira_async`, `komira_host`,
`komira_host_profile`, `komira_morsel` and `komira_physical_plan` sit below it;
the operator and dispatch packages sit above it. Nothing in it imports an operator.

Public API: import directly from `komira_engine_runtime.<module>`. No facade.
"""
