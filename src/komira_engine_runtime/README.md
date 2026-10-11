# komira_engine_runtime

The engine's execution primitives. **No algorithm logic**: anything an
operator or a sink consumes but does not implement belongs here.

- The host profile (`host_profile`): the engine build, hardware shape, worker
  threads, memory budget and spill tiers a host lowers under. It is measured
  once per host process (`detect_host_profile`, which calls
  `hardware_detect.detect_hardware_profile`) and then passed by value;
  `reference_host_profile` is a constant profile for comparing lowered plans
  across machines.
- Hardware (`hardware`, `hardware_detect`, `l2_share`): the profile value, its
  pure sizing accessors, and the one place that probes the machine.
- Morsel sizing: `morsel_sizing_policy` is a pure function of
  `(host_profile, segment, schema)`; the host records its answer in the
  physical plan (`SegmentDescPod.morsel_rows`, `record_segment_morsel_rows`).
  `l1_chunk_sizing` holds the L1-chunk admission predicate it uses.
- `run_context`: what a run of a physical plan reads from its host (the host
  profile and the worker count). No optimizer, and one path for bounded and
  unbounded input.

It depends on `komira_arrow`, `komira_collections`, `komira_host` and
`komira_physical_plan`, and on no operator package. Import from the defining
module, for example `from komira_engine_runtime.morsel_sizing_policy import
...`; the package has no facade.
