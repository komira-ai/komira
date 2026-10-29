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
- `komira_op_join_probe.join_probe_multi_key`: `execute_multi_key_join_probe`,
  the composite join probe operator: one probe batch against the completed
  build batch, as a physical plan's `MorselOp` says (keys, INNER / LEFT / SEMI
  / ANTI, output columns). It rewrites nothing and refuses what it does not
  run (a residual predicate, an algorithm other than hash, another join
  type); an INNER join indexes the smaller side when the build side has more
  than twice the probe side's rows, and probes in parallel from 100,000 probe
  rows. A result with no rows carries the output schema. Only the parallel
  probe looks at the cancellation token.
- `komira_op_join_probe.join_probe_settings`: the probe's process settings,
  set once from flags: the batched walk's width (0 is the row-at-a-time walk),
  the probe morsel, and the retile.
- `komira_op_join_probe.join_deferred`, `join_deferred_idx` and
  `join_defer_verdict`: the streaming join probe's DEFERRED output. A morsel
  either stages its output now or retains its probe batch and match indices
  (`DeferredJoinChunk`, the indices narrowed to 4 bytes when they fit) for one
  gather at the end; `deferral_verdict` decides which, by a DRAM-traffic rule
  (or the older memory rule), and names the line that decided.
- `komira_op_join_probe.join_probe_levers`: the streaming probe's chunk
  buffer reuse setting (off unless configured) and the counters of its
  probe-key share and buffers, printed as one witness line under the
  scheduler trace.
- `komira_op_join_probe.radix_join`: `RadixPartitionedHashJoin`, a hash join
  over one INT64 key split into 256 partitions by hash, each probed with its
  own scattered probe rows so one small table is cache-resident at a time;
  INNER, SEMI, ANTI and LEFT.
- `komira_op_join_probe.semi_join`: `SemiJoinHashSet`, the deduplicated set of
  build keys a single-INT64-key SEMI or ANTI join probes (serial or
  partitioned parallel build; serial, parallel and count-only probes). Every
  INT64 value is a key, INT64_MIN included. Keys that crowd into one of its
  eight partitions grow the table (a partition stays at most 3/4 full); a
  parallel build of such keys runs serially.
- `komira_op_join_probe.nested_loop_join`: `execute_residual_join_probe`, the
  join whose condition carries a residual (non-equi) predicate besides at most
  one equi-key: INNER, LEFT, SEMI and ANTI (a NULL residual does not pass), and
  `execute_residual_join_probe_parallel`, which runs a large SEMI or ANTI over
  one non-NULL INT64 key as the parallel mark join
  (`residual_semi_anti_parallel`), the same rows. `residual_mask_eval`
  evaluates the residual over candidate pairs, assembling only the columns it
  names; the mark join's levers are settings (`residual_mark_configure`).
- `komira_op_join_probe.join_key_extract`: `extract_join_key_columns_typed`
  (and `extract_join_key_columns_serial`, without a dispatcher) renders a
  batch's key columns into one Int64 key slot per row and key
  (`MultiKeyColumns`): the value for integers, the float model's canonical
  bits for FLOAT64, a 64-bit hash for strings, whose bytes ride along for the
  exact compare. Long string columns are hashed in parallel over the given
  dispatcher. `join_key_pairs_as_float64` says which key pairs (an
  INT32 or INT64 key against a FLOAT64 key) compare as FLOAT64, the integer
  side cast as DuckDB casts it to DOUBLE, and refuses a STRING key against a
  numeric key.
- `komira_op_join_probe.join_multi_key`: the key slots' constants, the
  composite hash and the string hash and equality the probes share.
- `komira_op_join_probe.join_probe`: `execute_join_probe`, the join probe
  operator over whole batches: one probe batch against the completed build
  batch, every join type (INNER, LEFT, RIGHT, FULL, SEMI, ANTI, CROSS), as a
  physical plan's `MorselOp` says. A residual predicate goes to
  `execute_residual_join_probe`; two or more key pairs, or a key that is not
  INT64-stored on both sides (`takes_composite_key_path`), to the
  composite-key join; `JOIN_ALGO_SORT_MERGE` to the sort-merge join (SEMI and
  ANTI keep their meaning under it); otherwise the single-INT64-key hash
  kernels, chosen by row counts and what the fused kernels can carry. The
  arms return the same rows.
- `komira_op_join_probe.join_probe_sort_merge` and `sort_merge_join_outer`:
  the sort-merge join over one INT64 key (INNER, LEFT, RIGHT, FULL): both
  sides radix-sorted, then merged; a NULL key matches nothing.
- `komira_op_join_probe.join_output_schema`: a join's output schema (probe
  columns, then build columns, a colliding build name suffixed `_right`; the
  outer form marks the side that can come out NULL nullable) and the
  projection of a SEMI / ANTI result.

A NULL key matches nothing: INNER and SEMI drop the row, LEFT and ANTI keep
it unmatched, RIGHT and FULL still emit a NULL-keyed build row. FLOAT64 keys
follow the query semantics' float model, as DuckDB does: every NaN equals
every NaN and `-0.0` equals `+0.0`. An INT32 or INT64 key joined to a FLOAT64 key
compares as FLOAT64, as DuckDB casts the integer to DOUBLE (`1 = 1.0`). Nothing here reads the environment.

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
