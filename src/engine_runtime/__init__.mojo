"""`engine_runtime` -- the engine's execution primitives, with no algorithm logic.

Anything an operator or a sink consumes but does not implement lives here:
the detection of the host profile a host lowers under (measured once; the
profile value and morsel sizing are in `host_profile`), hardware and
topology detection, the dispatch-time fork grain, the run and segment execution context
a driver reads, counters, and the small row and column helpers
the operators share.

Dependency direction: the core packages, `async_rt`, `host_probe`,
`host_profile`, `morsel` and `physical_plan` sit below it;
the operator and dispatch packages sit above it. Nothing in it imports an operator.

Public API: import directly from `engine_runtime.<module>`. No facade.
"""
