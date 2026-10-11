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
- Memory and spill: `memory.reservation.MemoryReservation` is the tally a
  breaker grows before it buffers more input; its budget comes from the host
  profile (`MemoryReservation.for_host`), and a denied grow is the breaker's
  cue to spill. The spill layer (`spill`) holds the `SpillStorage` trait and
  its storage over any `komira_fs` file system (`filesystem_spill_storage`,
  and `local_disk` for the local disk), the column (`thsplc`) and row
  (`thspill2`) spill formats with their codecs, and the run writer and
  reader (`native_spill`); the arbitrators that pick which breaker or
  partition spills under a budget (`spill_arbitrator`,
  `intra_op_slab_arbitrator`, `op_coordinator`, `routed_grow`); and the
  shuffle producer's spillable combine (`shuffle_combine_buffer`,
  `shuffle_stream_combine`). Whether a breaker may spill, and to
  which tiers, is `HostProfile.spill_tiers_for`, recorded in the physical
  plan.
- The parallel RecordBatch concat (`streaming_concat_parallel`, the public
  entry points; `concat_fan_plan` decides the route and the fan from the bytes
  moved and the pool's worker count; `concat_tasks`, `concat_tiled`,
  `concat_release`; `concat_dict_unify` unifies STRING dictionaries first;
  `concat_options` holds the route switches as a value).
- Wake primitives (`wake_primitives`: wait on and wake an address, with an
  optional timeout), counters, the FNV-1a hash (`spill.fnv1a`), and the small
  shared row and column helpers (`row`, `group_ref`, `scan_source`,
  `streaming_morsel`, `dynamic_filter`, `band_sink`).

It depends on `komira_arrow`, `komira_async`, `komira_fs`, `komira_host`, `komira_morsel`, `komira_shuffle`,
`komira_physical_plan` and the other core packages listed in `BUCK`, and on no
operator package. Import from the defining module, for example
`from komira_engine_runtime.morsel_sizing_policy import ...`; the package has
no facade.
