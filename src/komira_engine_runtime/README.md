# komira_engine_runtime

The engine's execution primitives. **No algorithm logic**: anything an
operator or a sink consumes but does not implement belongs here.

- The host profile (`host_profile`): the engine build, hardware shape, worker
  threads, memory budget and spill tiers a host lowers under. It is measured
  once per host process (`detect_host_profile`, which calls
  `hardware_detect.detect_hardware_profile`) and then passed by value;
  `reference_host_profile` is a constant profile for comparing lowered plans
  across machines.
- Hardware and topology (`hardware`, `hardware_detect`, `hardware_topology`,
  `machine_topology`, `l2_share`) and the async runtime construction derived
  from them (`engine_runtime_build`).
- Morsel sizing: `morsel_sizing_policy` is a pure function of
  `(host_profile, segment, schema)`; the host records its answer in the
  physical plan (`SegmentDescPod.morsel_rows`, `record_segment_morsel_rows`).
  Dispatch-time fan-out and fork grain (`fan_out_grain`), the L1-chunk
  predicate (`l1_chunk_sizing`) and grain geometry (`grain_geometry`).
- The run and segment execution context (`run_context`, `segment_execution`):
  no optimizer, and one path for bounded and unbounded input.
- Wake primitives (`wake_primitives`: wait on and wake an address, with an
  optional timeout), counters, the FNV-1a hash (`spill.fnv1a`), and the small
  shared row and column helpers (`row`, `group_ref`, `scan_source`,
  `streaming_morsel`, `dynamic_filter`, `band_sink`).

It depends on `komira_arrow`, `komira_async`, `komira_host`, `komira_morsel`,
`komira_physical_plan` and the other core packages listed in `BUCK`, and on no
operator package. Import from the defining module, for example
`from komira_engine_runtime.morsel_sizing_policy import ...`; the package has
no facade.
