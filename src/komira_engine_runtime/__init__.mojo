"""`komira_engine_runtime` -- the engine's execution primitives, with no algorithm logic.

Anything an operator or a sink consumes but does not implement lives here: the
host profile a host lowers under (measured once), hardware detection, morsel
sizing as a pure function of the host profile and the segment, and the run
context a driver reads.

Dependency direction: the core packages, `komira_host` and
`komira_physical_plan` sit below it; the operator and dispatch packages sit
above it. Nothing in it imports an operator.

Public API: import directly from `komira_engine_runtime.<module>`. No facade.
"""
