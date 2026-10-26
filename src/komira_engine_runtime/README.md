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
- Topology (`hardware_topology`, `machine_topology`) and the async runtime
  construction derived from it (`engine_runtime_build`).
- Morsel sizing: `morsel_sizing_policy` is a pure function of
  `(host_profile, segment, schema)`; the host records its answer in the
  physical plan (`SegmentDescPod.morsel_rows`, `record_segment_morsel_rows`).
  `l1_chunk_sizing` holds the L1-chunk admission predicate it uses. The fork
  grain and the fan-out cap are decided at dispatch time from exact facts
  (`fan_out_grain`), and `grain_geometry` records what a fork chose.
- `run_context` and `segment_execution`: what a run of a physical plan reads
  from its host (the host profile and the worker count) and the per-segment
  dispatch and timing. No optimizer, and one path for bounded and unbounded
  input.

It depends on `komira_arrow`, `komira_async`, `komira_host`, `komira_morsel`,
`komira_physical_plan` and the other core packages listed in `BUCK`, and on no
operator package. Import from the defining
module, for example `from komira_engine_runtime.morsel_sizing_policy import
...`; the package has no facade.
