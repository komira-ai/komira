# komira_op_asof

The ASOF join: for each left row, the right row with the same equi key whose
ASOF value is the nearest at or before (BACKWARD), at or after (FORWARD), or
either side (NEAREST) of the left row's. The package root re-exports nothing;
import from the modules.

It answers as DuckDB's `ASOF JOIN` does (`l.t >= r.t` is BACKWARD, `l.t <=
r.t` FORWARD):

- a NULL equi key matches nothing, on either side, and neither does a NULL
  ASOF value;
- float keys and float ASOF values compare in the sort's order
  (`komira_op_sort.sort.sort_key_lt`): NaN equals NaN and sorts above +inf,
  and -0.0 equals +0.0;
- an equal ASOF value matches. Among right rows with equal key and ASOF
  value, BACKWARD takes the last in input order and FORWARD the first (DuckDB
  leaves that choice unspecified).

NEAREST and the tolerance are the engine's own (DuckDB has neither). NEAREST
breaks a distance tie toward the backward row; the tolerance is inclusive; a
NaN is never within a finite distance of a number.

- `komira_op_asof.asof_join_sink`: `AsofJoinSink`, the ASOF left join over two
  materialised sides. `consume` takes the left batches,
  `materialize_with_right` the right batch: it sorts both sides on
  `(equi_keys..., asof)` (`komira_op_sort.sort_multi.sort_batch_by_keys`),
  walks them and assembles every left column, then every right column made
  nullable (renamed `<name>_right` on a name collision), with NULL right
  columns for an unmatched left row.
- `komira_op_asof.asof_walker`: `asof_merge_into[strategy, dtype]`, the
  two-cursor merge over sorted sides, and `asof_merge_dispatch`, its run-time
  (strategy, dtype) switch (INT32, INT64, FLOAT64 ASOF values);
  `compare_equi_keys` (INT32, INT64, FLOAT64, STRING and DICTIONARY keys) and
  `compare_keys`. The sort places a NULL numeric key by the value in its slot;
  the walker steps over such rows instead of trusting their position.
- `komira_op_asof.asof_kernel`: the search of one left value in a right
  group, `_find_best_asof[strategy, dtype]`, with its hinted bounds and
  `AsofValue`.
- `komira_op_asof.asof_equi_key`: `EquiKeyCmp`, a comparison's sort order
  (`order`, two NULLs adjacent) apart from its join match (`matched`, never
  for a NULL).
- `komira_op_asof.asof_join_build`: `AsofJoinBuildTable[KB, TempK, *Payload]`,
  the stage pipelines' dense-append ASOF build table, with its equi-key
  blocks (`AsofKeyBundle0`, `AsofKeyBundle1`, `AsofKeyBundle2`), its payload
  columns (`PayloadSlot[dt]`, each value at its own type with its NULL) and
  the free functions `asof_build_append_N_f64` and `asof_probe_forward_N`.
  The probe is FORWARD: the first row at or after the probe value.
- `komira_op_asof.asof_join_build_state`: `AsofJoinBuildState`, the
  ASOF_JOIN_BUILD breaker state: `feed_row` stores a build row (not one with a
  NULL temporal key), `take_asof_build_table` moves the table out once.
- `komira_op_asof.asof_join_probe_state`: `AsofJoinProbeState`, the ASOF_JOIN
  breaker state: `probe_asof_batch` emits, per probe batch, each matched probe
  row's temporal key and the build row's payloads (an INNER join).

## Examples

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from std.math import nan
from komira_op_asof.asof_join_build import AsofJoinBuildTable, AsofKeyBundle0, PayloadBlock, PayloadSlot, asof_build_append_0_f64, asof_probe_forward_0, payload_slot

# A FLOAT64-keyed table with one INT64 payload, rows in ascending key order.
var t = AsofJoinBuildTable[AsofKeyBundle0, DType.float64, PayloadSlot[DType.int64]](
    PayloadBlock[PayloadSlot[DType.int64]](payload_slot[DType.int64](4))
)
var keys: List[Float64] = [1.0, 2.0, nan[DType.float64]()]
for i in range(len(keys)):
    var pay: List[Float64] = [Float64(100 + i)]
    asof_build_append_0_f64(t, keys[i], pay)

# FORWARD: the first key at or after the probe. NaN sorts above every number.
assert_equal(asof_probe_forward_0(t, Float64(1.5)), 1)
assert_equal(asof_probe_forward_0(t, Float64(-0.0)), 0)
assert_equal(asof_probe_forward_0(t, Float64(9.0)), 2)
assert_equal(asof_probe_forward_0(t, nan[DType.float64]()), 2)
assert_equal(t.payload[0].read_value(1), 101)
```
