# komira_counters

Process-global census and falsifier counters plus the build-gated runtime introspection probe.

`global_counter` is the one primitive under every counter here: a process-global, name-keyed table of relaxed atomic counters (`GlobalCounter`, `GlobalCounterTable`) whose API exposes no pointer. Each counter module declares its names and keeps only its own meaning.
