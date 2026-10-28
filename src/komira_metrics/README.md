# komira_metrics

The metrics model for code that runs on a fixed set of worker threads.

- `MetricsSet` is one operator's registry of at most 8 counters, 4 times
  (nanosecond totals) and 4 gauges, each named by a compile-time string. Every
  metric keeps one slot per worker (up to 64), so a worker records without a
  lock: `inc_in_pipeline(n, worker_id=...)`. `reduce` folds the slots
  (counters and times sum, gauges take the maximum) into a `MetricsSnapshot`
  keyed by the name's FNV-1a id. A registration past capacity is refused and
  counted, never a crash.
- `HistogramValue` is a fixed-bucket distribution (bounds 0, 5, 10, 25, 50,
  75, 100, 250, 500, 750, 1000, then +Inf) with count, sum, min and max;
  bucket counts add, so per-worker values merge exactly.
- Attribute-set interning, per-worker series and histogram tables with a
  delta export sweep, and the EXPLAIN ANALYZE collector and text renderer.

It does not export anything over a network and holds no process-global
metric registry: the embedder constructs a `MetricsSet` and hands it on by
reference. The one piece of process-global state is the EXPLAIN ANALYZE
collector (`explain_analyze_collect`): a slot table plus an armed flag kept
in a small C file. It records only while a caller has armed it around one
query, and costs one relaxed atomic load per instrumented point otherwise.
`MetricsSet` is not movable (its slots hold atomics); put one behind an
`OwnedPointer` with `new_owned_metrics_set` to store it in a field.

There is no facade: import from the sub-modules (`komira_metrics.metrics_set`,
`komira_metrics.histogram`, `komira_metrics.series_table`, and so on).

## Examples

Register metrics, record from two workers, and reduce:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_metrics.metrics_set import MAX_COUNTERS, MetricsSet

var ms = MetricsSet()
assert_true(ms.register_counter["rows_consumed"]())
assert_true(ms.register_time["elapsed_compute"]())
assert_true(ms.register_gauge["peak_groups"]())
assert_false(ms.register_counter["rows_consumed"]())  # already registered

ms.counter["rows_consumed"]().inc_in_pipeline(Int64(5), worker_id=0)
ms.counter["rows_consumed"]().inc_in_pipeline(Int64(7), worker_id=3)
ms.time["elapsed_compute"]().record_ns_in_pipeline(Int64(1_500), worker_id=0)
ms.gauge["peak_groups"]().set_in_pipeline(Int64(40), worker_id=0)
ms.gauge["peak_groups"]().set_in_pipeline(Int64(99), worker_id=1)

assert_equal(ms.counter["rows_consumed"]().reduce(), 12)  # sum of worker slots
assert_equal(ms.gauge["peak_groups"]().reduce(), 99)      # max of worker slots
var snapshot = ms.reduce()
assert_equal(snapshot.count(), 3)
assert_equal(ms.num_counters(), 1)
assert_equal(MAX_COUNTERS, 8)
```

A registration past capacity is refused and counted:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_metrics.metrics_set import MetricsSet

var ms = MetricsSet()
assert_true(ms.register_gauge["g0"]())
assert_true(ms.register_gauge["g1"]())
assert_true(ms.register_gauge["g2"]())
assert_true(ms.register_gauge["g3"]())
assert_false(ms.register_gauge["g4"]())  # 4 gauges at most
assert_equal(ms.num_gauges(), 4)
assert_equal(ms.num_dropped_registrations(), 1)
```

A histogram per worker, merged:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_metrics.histogram import HISTOGRAM_BOUNDS, HistogramValue, histogram_bound
from komira_metrics.histogram import histogram_bucket_index

var w0 = HistogramValue()
w0.record(3)
w0.record(40)
var w1 = HistogramValue()
w1.record(2_000)  # above the last bound: the +Inf bucket
w0.merge(w1)

assert_equal(w0.count, 3)
assert_equal(w0.sum, 2_043)
assert_equal(w0.min, 3)
assert_equal(w0.max, 2_000)
assert_equal(histogram_bucket_index(3), 1)  # 3 <= 5
assert_equal(histogram_bound(1), 5)
assert_equal(w0.buckets[1], 1)
assert_equal(w0.buckets[histogram_bucket_index(40)], 1)  # 40 <= 50
assert_equal(w0.buckets[HISTOGRAM_BOUNDS], 1)  # +Inf
```

EXPLAIN ANALYZE collection is armed around one query; the armed flag lives
in this package's C (`native/komira_metrics_ea_flag.c`), so this example
calls the package's shared library when it runs from an installed package:

<!-- mojo-hidden from std.testing import assert_equal, assert_true, assert_false -->
```mojo
from komira_metrics.explain_analyze_collect import EA_F_CALLS, EA_F_ROWS, EA_SORT
from komira_metrics.explain_analyze_collect import ea_arm, ea_armed, ea_disarm, ea_record, ea_reset, ea_slot

ea_reset()
assert_false(ea_armed())
ea_arm()
assert_true(ea_armed())
if ea_armed():  # every recording site checks the flag first
    ea_record(EA_SORT, rows=10, elapsed_ns=1_000)
ea_disarm()
assert_false(ea_armed())
assert_equal(ea_slot(EA_SORT, EA_F_CALLS), 1)
assert_equal(ea_slot(EA_SORT, EA_F_ROWS), 10)
```

## Build files

This package is built with buildrules' `mojo_package` and packaged for mopm as `komira_metrics`, version 0.1.0
(`mopm.toml`). The library is `src/komira_metrics/`, its tests are `tests/`. It depends on five sibling packages
(`[dependencies]` of `mopm.toml`, each `{ path = "../<name>", version = "0.1" }`): `komira_atomic_alias`,
`komira_clock`, `komira_collections`, `komira_hash` and `komira_name_registry`. `komira_collections` and
`komira_name_registry` have dependencies of their own, so `mopm.lock` lists the whole closure, direct and transitive,
while the `.conda` of this package records only the five direct ones (`mojo-<name> >=0.1,<0.2`) and holds none of
their files. `komira_fork_join`, which the tests use to fork real threads, is under `[dev-dependencies]`: it reaches
the tests, never `:lib` or a consumer. The C file `native/komira_metrics_ea_flag.c` is a native library of the
package, `[native.komira_metrics_ea_flag]` in `mopm.toml`: `mojo_package` compiles it into
`libkomira_metrics_ea_flag.a`, links it into the tests of this package and of every package that depends on it,
and packs it into the `.conda` under `lib/`. The files that are not sources:

| file | what |
|---|---|
| `mopm.toml` | the mopm manifest: name, version, the Mojo version, the dependencies, the native library, where the library and its tests are |
| `mopm.lock` | the toolchain pins and every path dependency of the closure (no registry is reached: all are siblings) |
| `mopm-toolchain.toml` | the exact mopm and Mojo versions the build uses (written by hand) |
| `coverage_floor.txt` | `lines NN.NN` and `branches NN.NN`: the least line and branch coverage `:coverage` may measure; `:coverage_floor` fails when either falls below |
| `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | written by `buildrules mojo sync` from the files above and from the manifests of the siblings; `buildrules mojo check` fails when they are stale |

`:lib` is the library file and exists only once every test of `tests/` has passed. After any change to a source, a
test, the C file, a manifest of this package or of a sibling, or `mopm.lock`, run `buildrules mojo sync` with the
workspaces of the five direct dependencies staged, commit what it writes, and build `komira//src/komira_metrics:lib`
on the farm.

`:conda` is the `.conda` of the mopm package (`mojo-komira_metrics-0.1.0-mojo1.0.0_0.conda`): the `.mojoc` and
`lib/libkomira_metrics_ea_flag.a`. `:komira_metrics` is `:lib` as komira's Mojo rules take it
(`mojo_adopted_library`): its `deps` are the adopted target of each package in `[dependencies]`, and the rule refuses
a list that is not the closure `:lib` was built from. It also compiles and runs the README's examples above
(`[tests][readme]`) against `:lib` and the archive. The shared library `libkomira_metrics_native.so.1`
(`:komira_metrics_native`) is the release set's packaging of the same C file.
