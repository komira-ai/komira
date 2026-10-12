"""`komira_operator_api` -- the operator interfaces of the engine's pipelines: the sink contract (`MorselSink`, its phase timings and keep-alive handle), the breaker-state trait that every blocking operator implements, the fused per-morsel operator and the map and filter kernels it fuses, the map operator and the unary, binary, hash and match function operators, the dynamic-filter application, the batch fold that sinks share, and the join-build fold and wave-decomposition counters. The concrete operators and sinks implement these traits in the packages that depend on this one.

Public API: import directly from sub-modules. No facade.
"""
