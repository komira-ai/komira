# komira_host_profile

The host profile as a value, and the sizing that is a pure function of it.
Nothing here measures the machine: `komira_engine_runtime` does that
(`host_detect.detect_host_profile`, `hardware_detect`) and hands the result to
whoever lowers a plan.

- `hardware`: `HardwareProfile`, the core counts, the L1d/L2/L3 sizes, the
  cache line, the RAM and the binding L2 share, with the derived sizes
  (`optimal_morsel_rows`, `optimal_agg_morsel_rows`, `l3_resident_rows`,
  `compute_threads`, `effective_e_core_l2_per_worker`,
  `default_memory_budget`) and the `DEFAULT_*` constants of the fallback
  shape.
- `host_profile`: `HostProfile`, the engine build, the hardware, the worker
  count, the memory budget and the spill tiers the host offers
  (`spill_tiers_for`, `may_spill`); the constructor refuses a thread count or
  budget below 1 and unknown spill bits. `reference_host_profile` is a profile
  made only of constants, so a check that compares rendered plans across
  machines lowers under it.
- `morsel_sizing_policy`: `MorselSizingPolicy`, rows per morsel as a function
  of a profile, a schema and a tier; `segment_morsel_tier` reads the tier off a
  segment's shape and `record_segment_morsel_rows` writes the answer into the
  segment.
- `l1_chunk_sizing`: the L1-chunk admission predicate and the grain rounding.

The package root exports nothing; import each module by name.

## Dependencies

It depends on `komira_arrow` and `komira_physical_plan` and the packages they
need. Its `BUCK` file lists `komira_fs`, `komira_objectstore`, `komira_async`
and `komira_shuffle` in `closure_excludes`, so analysis fails if any of them
enters the closure, directly or through another package. The names are
compared exactly: `komira_async_api`, the trait surface the closure needs, is
not refused.

## Example

The reference profile is the same on every machine, so the morsel size it
gives a schema is a constant.

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_host_profile.host_profile import reference_host_profile
from komira_host_profile.morsel_sizing_policy import MorselSizingPolicy

var sb = SchemaBuilder()
sb.add_field(Field("a", ArrowType.INT64, False))
var schema = sb.build()
var host = reference_host_profile("example")
var policy = MorselSizingPolicy.for_host(host)
# A 1 MiB L2 share, half of it for operator state: 512 KiB / 8 B = 65536.
assert_equal(policy.agg_morsel_rows(schema), 65536)
assert_equal(host.thread_count, 8)
```
