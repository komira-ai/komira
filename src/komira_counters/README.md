# komira_counters

Process-global census and falsifier counters plus the build-gated runtime introspection probe.

`global_counter` is the one primitive under every counter here: a process-global, name-keyed table of relaxed atomic counters (`GlobalCounter`, `GlobalCounterTable`) whose API exposes no pointer. Each counter module declares its names and keeps only its own meaning.

A counter that has one owner lives in its owner's package and uses `global_counter` from here: `gather_width_counter`, `rxcensus` and `string_eq_arm_counter` in `komira_column_kernels`, `join_index_window_counter` in `komira_join_assembly`. The counters that are cross-cutting (`runtime_introspection`, `keyeq_census`) or whose owners are not packages yet (`strdrain_counter`, `planner_scale_counter`, `parquet_read_counter`) stay here.
