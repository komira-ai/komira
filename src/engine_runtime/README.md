# engine_runtime

The engine's execution primitives. **No algorithm logic**: anything an
operator or a sink consumes but does not implement belongs here.

- Detection of the host profile: `host_detect.detect_host_profile` measures
  the host once per host process (it calls
  `hardware_detect.detect_hardware_profile`) and returns the
  `host_profile.host_profile.HostProfile` value, which is then passed
  by value. `hardware_detect.default_hardware_profile` is the fallback profile
  a failed probe returns. The value types, the morsel sizing policy and the
  L1-chunk predicate live in `host_profile`, which depends on no file
  system, object store or async runtime package.
- Hardware and topology detection (`hardware_detect`, `hardware_topology`,
  `machine_topology`, `l2_share`) and the async runtime construction derived
  from them (`engine_runtime_build`).
- Dispatch-time fan-out and fork grain (`fan_out_grain`) and grain geometry
  (`grain_geometry`); the morsel size itself is recorded by the host when it
  lowers (`host_profile.morsel_sizing_policy`).
- The run and segment execution context (`run_context`, `segment_execution`):
  no optimizer, and one path for bounded and unbounded input.
- Memory and spill: `memory.reservation.MemoryReservation` is the tally a
  breaker grows before it buffers more input; its budget comes from the host
  profile (`MemoryReservation.for_host`), and a denied grow is the breaker's
  cue to spill. The spill layer (`spill`) holds the `SpillStorage` trait and
  its storage over any `fs` file system (`filesystem_spill_storage`,
  and `local_disk` for the local disk), the row spill format (`thspill2`,
  `thspill2_header`) with its codec, and the native spill run writer and reader
  (`native_spill`). Whether a breaker may spill, and to
  which tiers, is `HostProfile.spill_tiers_for`, recorded in the physical
  plan.
- Spill arbitration (`spill.spillable_op`, `spill.policies`,
  `spill.spill_arbitrator`, `spill.intra_op_slab_arbitrator`,
  `spill.op_coordinator`, `spill.routed_grow`): when a grow would pass a byte
  budget, the arbitrator spills the oldest spillable op (or, within one
  operator, partition) and reports the bytes freed. A breaker's grow that its
  `MemoryReservation` refuses spills one of its own partitions and retries
  once (if that retry is refused too, the freed bytes stay released and the
  result is False); a negative grow, or one above the whole budget, is
  refused without spilling. Only the oldest-first policy is implemented.
- The parallel RecordBatch concat (`streaming_concat_parallel`, the public
  entry points; `concat_fan_plan` decides the route and the fan from the bytes
  moved and the pool's worker count; `concat_tasks`, `concat_tiled`,
  `concat_release`; `concat_dict_unify` unifies STRING dictionaries first;
  `concat_options` holds the route switches as a value; `concat_schema_check`
  refuses input batches whose columns differ).
- The shuffle combine buffer (`spill.shuffle_combine_buffer`: per-partition
  encode scratch with a bounded high-water) and the driver-side retention
  policy (`shuffle_retention_policy`: reaps sealed epochs below the slowest
  durable consumer cursor, at a cadence, fail-safe).
- The shuffle producer's streaming combine (`spill.shuffle_stream_combine`):
  writes a producer's R partition slices into one `.seg` object through a
  streaming write, byte-identical to what `shuffle`'s `SegWriter` builds.
  With a byte budget, a partition above the budget is staged in a
  `SpillStorage` in chunks of at most the budget and streamed back, and the
  result reports the most bytes the combine itself staged at once, never above
  the budget. That bounds the combine's own staging, not process memory: the
  slice the source hands over for a partition is outside it. A failure from the source, the spill storage or the file system is
  raised to the caller after the spilled chunks are released and the partial
  write is aborted.
- Counters, the FNV-1a hash (`spill.fnv1a`), and the small
  shared row and column helpers (`row`, `group_ref`, `scan_source`,
  `streaming_morsel`, `dynamic_filter`, `band_sink`).
- The THSPLC column codec (`spill.thsplc`, `spill.thsplc_header`): a
  RecordBatch to one contiguous chunk and back, with a zero-copy restore; and
  the RecordBatch <-> ColumnNativeBatch bridges (`spill.column_native_shims`).
- Filter by predicate (`column_filter_predicate`): a RecordBatch or a
  ColumnNativeBatch filtered by a predicate `Expr` with the evaluator a FILTER
  operator uses (`batch_eval.conjunction.evaluate_filter_narrowed`), so
  a scan can filter without depending on an operator package.

It depends on `arrow`, `async_rt`, `batch_eval`, `fs`,
`host_probe`, `host_profile`, `morsel`, `physical_plan`,
`objectstore`, `shuffle` and the other core packages listed in `BUCK`, and on no
operator package. Import from the defining module, for example
`from engine_runtime.host_detect import ...`; the package has
no facade.

## Examples

A reservation with a budget grants grows until the budget is reached, then
denies them and counts the denial. Releasing bytes makes room again.

```mojo
from std.testing import assert_equal, assert_false, assert_true
from engine_runtime.memory.reservation import MemoryReservation

var r = MemoryReservation.with_budget(1024)
assert_true(r.has_budget())
assert_equal(r.budget_bytes(), 1024)
assert_true(r.try_grow(1000))
assert_false(r.try_grow(100))
assert_equal(r.try_grow_denied_count(), 1)
assert_equal(r.held_bytes(), 1000)
r.release(800)
assert_true(r.try_grow(100))
assert_equal(r.held_bytes(), 300)
```

The FNV-1a 64-bit hash of a byte list, as a list and as a span, gives the
published value for the input "a".

```mojo
from std.testing import assert_equal
from engine_runtime.spill.fnv1a import (
    FNV1A_64_OFFSET_BASIS,
    fnv1a_64_over,
    fnv1a_64_over_span,
)

var a: List[UInt8] = [97]
assert_equal(fnv1a_64_over(List[UInt8]()), FNV1A_64_OFFSET_BASIS)
assert_equal(fnv1a_64_over(a), UInt64(0xAF63DC4C8601EC8C))
assert_equal(fnv1a_64_over_span(Span(a)), fnv1a_64_over(a))
```
