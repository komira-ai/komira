# komira_op_join_probe

The probe side of the engine's joins. The package root re-exports nothing;
import from the modules.

- `komira_op_join_probe.join_multi_key_builder`: `MultiKeyHashJoinBuilder`,
  the hash join over 1 to `MAX_JOIN_KEYS` (8) key columns of INT64, INT32,
  FLOAT64, STRING or DICTIONARY type, with separate chaining (so duplicate
  keys keep every match), a bloom filter over the inserted rows, and its INNER
  (`probe_inner_into`) and LEFT (`probe_left_into`) probes. Matches come back
  as parallel lists of build and probe row indices; LEFT marks an unmatched
  probe row with build index -1.
- `komira_op_join_probe.join_multi_key_filter`: `multi_key_probe_semi` and
  `multi_key_probe_anti`, which return the probe rows they keep.
- `komira_op_join_probe.join_multi_key_outer`: `multi_key_probe_right_into`
  and `multi_key_probe_full_into`, which also emit every unmatched build row
  (probe index -1).
- `komira_op_join_probe.join_multi_key_parallel`:
  `parallel_multi_key_inner_probe_into`, the INNER probe fanned over the
  engine's dispatcher: workers claim probe morsels and walk a batch of rows'
  chains together (`join_multi_key_parallel_task`), then one more fanned wave
  concatenates their matches. The same pairs as the serial probe, grouped by
  worker.
- `komira_op_join_probe.join_multi_key_parallel_build`:
  `multi_key_hash_join_build_parallel`, the build fanned over the engine's
  dispatcher (each row pushed onto its bucket's chain with an atomic
  compare-exchange), serial below 250,000 rows. The same rows in the same
  buckets as `MultiKeyHashJoinBuilder.build`, chain order aside. It follows the
  hash join's build mode (`komira_op_join_build`'s
  `join_parallel_build_configure`: AUTO, OFF, or the FORCE test hook).
- `komira_op_join_probe.join_probe_settings`: the probe's process settings,
  set once from flags: the batched walk's width (0 is the row-at-a-time walk),
  the probe morsel, and the retile.
- `komira_op_join_probe.join_deferred`, `join_deferred_idx` and
  `join_defer_verdict`: the streaming join probe's DEFERRED output. A morsel
  either stages its output now or retains its probe batch and match indices
  (`DeferredJoinChunk`, the indices narrowed to 4 bytes when they fit) for one
  gather at the end; `deferral_verdict` decides which, by a DRAM-traffic rule
  (or the older memory rule), and names the line that decided.
- `komira_op_join_probe.join_key_extract`: `extract_join_key_columns_typed`
  (and `extract_join_key_columns_serial`, without a dispatcher) renders a
  batch's key columns into one Int64 key slot per row and key
  (`MultiKeyColumns`): the value for integers, the float model's canonical
  bits for FLOAT64, a 64-bit hash for strings, whose bytes ride along for the
  exact compare. Long string columns are hashed in parallel over the given
  dispatcher.
- `komira_op_join_probe.join_multi_key`: the key slots' constants, the
  composite hash and the string hash and equality the probes share.

A NULL key matches nothing: INNER and SEMI drop the row, LEFT and ANTI keep
it unmatched, RIGHT and FULL still emit a NULL-keyed build row. FLOAT64 keys
follow the query semantics' float model, as DuckDB does: every NaN equals
every NaN and `-0.0` equals `+0.0`. Nothing here reads the environment.

## Examples

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_op_join_probe.join_key_extract import extract_join_key_columns_serial
from komira_op_join_probe.join_multi_key_builder import MultiKeyHashJoinBuilder
from komira_op_join_probe.join_multi_key_filter import multi_key_probe_anti
from komira_op_join_probe.join_probe_settings import MK_PROBE_BATCH_DEFAULT, mk_probe_batch_width

# A two-key join on (a, b). Build rows: (1, 10), (1, 20), (2, 10).
# Probe rows: (1, 20), (2, 99), (1, 10).
def batch(a: List[Int64], b: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(a)))
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(b)))
    return rb.build(sb.build())

var keys: List[String] = ["a", "b"]
var build = batch([1, 1, 2], [10, 20, 10])
var probe = batch([1, 2, 1], [20, 99, 10])
var join = MultiKeyHashJoinBuilder.build(extract_join_key_columns_serial(build, keys))

var build_rows = List[Int]()
var probe_rows = List[Int]()
join.probe_inner_into(extract_join_key_columns_serial(probe, keys), build_rows, probe_rows)
assert_equal(len(probe_rows), 2)
assert_equal(probe_rows[0], 0)  # (1, 20) matches build row 1
assert_equal(build_rows[0], 1)
assert_equal(probe_rows[1], 2)  # (1, 10) matches build row 0
assert_equal(build_rows[1], 0)

# ANTI keeps the probe row with no match: (2, 99).
var anti = multi_key_probe_anti(join, extract_join_key_columns_serial(probe, keys))
assert_equal(len(anti), 1)
assert_equal(anti[0], 1)

# Unconfigured, the parallel probe walks 512 rows' chains together.
assert_equal(mk_probe_batch_width(), MK_PROBE_BATCH_DEFAULT)
```
