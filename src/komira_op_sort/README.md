# komira_op_sort

The sort kernels of the engine. A sort here never moves data: it returns a
permutation, a `PrimitiveArray[DType.int32]` of row indices such that
`keys[result[i]]` is in order, and the caller gathers every column of its
batch by it.

- `sort`: `sort_indices_int64`, `_int32`, `_int128` (DECIMAL128 unscaled
  values) and `_float64`, a stable merge sort written once over the key
  DType; `gather_by_indices_int64` / `_float64`; and `sort_key_lt`, the key
  order every kernel uses.
- `sort_radix`: `radix_sort_int64` (signed) and `radix_sort_u64_keys`
  (unsigned magnitudes), a stable ascending LSD radix sort that skips a pass
  whose byte is the same for every key.
- `sort_topn`: `topn_indices_int64` / `_float64`, the first K rows in order
  by bounded-heap selection, O(N log K).
- `sort_string`: `sort_indices_string`, STRING/BINARY columns in byte-wise
  order (the shorter string first on a shared prefix), nulls first or last.
  By default a prefix-key radix sort; `prefix_key=False` runs the
  byte-compare merge sort, which gives the same permutation.
- `sort_nested`: `sort_indices_nested`, STRUCT / LIST / UNION keys
  (field by field, element by element, type id then value). MAP refuses.
- `sort_multi`: `sort_batch_by_keys`, a stable multi-key sort of a
  `RecordBatch` (one stable pass per key, last key first).
- `sort_lex`: `sort_batch_lex`, the single-pass multi-key sort that
  `sort_batch_by_keys` uses when every key is INT32 / INT64 / STRING: keys
  are encoded as Int64 ranks and, when the ranks fit in 62 bits, packed into
  one Int64 and radix-sorted.
- `sort_topn_sink`: the sort and top-N sink kernels (`_execute_sort_sink`,
  `_execute_topn_sink` over `SortSinkData` / `TopNSinkData` of
  `komira_physical_plan`), and `append_deterministic_tiebreak[_schema]`,
  the one rule that makes a tied top-N cut deterministic across runs whose
  input order differs. `_execute_sort_sink` does not resolve dictionary
  keys: a numeric dictionary-encoded sort key raises an error (the message
  differs between the single-key and multi-key paths).
  `_execute_topn_sink` resolves a numeric dictionary key to its values first.
- `sort_topn_heap`: `topn_heap_select`, multi-key top-K over a
  `RecordBatch` by a bounded heap, O(N log K), for INT64 / INT32 / FLOAT64 /
  STRING keys. Rows that tie on every key compare by row index, so the heap
  keeps and orders tied rows as the stable full sort does. A numeric key
  stored as a dictionary (codes plus values) is resolved to its values before
  a top-N.
- `sort_buffer_untyped`: `SortBuffer_Untyped`, a multi-key sort buffer
  whose column types are known only at run time (a `ColDescriptor` layout
  over `komira_column_format` storage), fed from `BatchView`s and read back
  per DType; its cell codec is `sort_buffer_cells`. It does not track
  validity: a NULL cell sorts as its value bytes, so callers keep nullable
  keys out or place nulls themselves. TIMESTAMP, DECIMAL128 and BINARY
  columns can be fed and ordered but have no typed reader; the order is in
  `sorted_indices`.
- `sort_loser_tree`: `LoserTree`, a tournament tree for the k-way merge of
  sorted runs, driven by a caller's `LoserTreeComparator`.
- `sort_parallel`: `parallel_sort_single_key`, the single-key sort over an
  INT64 / INT32 / FLOAT64 key on the engine's fork-join runtime (a stable
  sort per slice, then a parallel co-rank merge of the slices), and
  `merge_sorted_partitions_single_key`, the k-way merge of batches that are
  each already sorted. `can_parallel_sort_single_key` is the gate (one key
  of those types, `MIN_PARALLEL_SORT_ROWS` rows unless forced).
- `sort_parallel_string`: the same for one STRING / BINARY key
  (`parallel_sort_single_key_string`), and the merges of sorted STRING
  partitions: `merge_sorted_partitions_single_key_string_parallel` (a
  parallel pairwise tree) and `merge_sorted_partitions_single_key_string`
  (its serial oracle). The per-slice string sort and its comparators are
  `sort_parallel_string_kernels`; the pairwise-tree merge is
  `sort_parallel_string_merge`.

- `sort_dictrank`: `parallel_dictrank_sort_string`, the sort of one
  low-cardinality STRING / BINARY key by dense ranks and a parallel stable
  counting sort (no comparison merge), and its gate
  `can_dictrank_sort_single_key_string` (a strided sampled distinct count
  under a ceiling). Above the ceiling after the exact build it falls back to
  `parallel_sort_single_key_string`. The dictionary build and the ranks are
  `sort_dictrank_build`. The gate's sample is a fixed stride, so a periodic
  key, or one that is distinct only past the last sampled row, can be
  admitted although it is high-cardinality; the exact build is the backstop
  (the rows stay correct and the sort falls back, at the cost of a full
  dictionary build). On the multi-worker `SortSink` route the gate samples
  partition 0 only. `dictrank_fallback_count` reports how many sorts took the
  fallback.
- `sort_sink`: `SortSink`, the sort as a `MorselSink` of
  `komira_operator_api`: per-worker batches, and a route chosen once in
  `combine` (partitioned parallel sort and merge, the counting sort, or the
  serial kernel) that changes the cost and never the rows. The switches are
  a value, `SortSinkRoutes`.

- `sort_external`: `ExternalSorter`, a sort past a memory budget: buffered
  batches are sorted into runs, runs over the budget are spilled to the local
  disk (`komira_engine_runtime` spill), and `finish` merges every run. The
  spill directory is an argument of the caller. The output is one stable
  `sort_batch_by_keys` of the input in absorb order. The merge
  (`k_way_merge_cursors`, the loser tree and
  `komira_column_kernels.cross_batch_gather`) is `sort_external_merge`; its
  comparator orders a key as the run sort does (floats by `sort_key_lt`).
  Full ties go to the earlier input, across spilled runs and the final
  in-memory run alike. Keys are INT32, INT64 or FLOAT64 (a STRING or FLOAT32
  key is refused, naming the key). A payload column of a type
  `cross_batch_gather` does not gather (DECIMAL128, DECIMAL256,
  INTERVAL_MONTH_DAY_NANO, DICTIONARY, LIST, STRUCT, ...) makes the sorter raise
  "unsupported column type" when it sorts a run. The spill sub-directory is
  `thsplc_sort_<pid>_<counter>`, created exclusively under the caller's
  `spill_dir`. After any error the sorter is unusable: its buffered rows are
  gone and it only releases its spill files when dropped.
- `sort_stage_buffer`: `SortBuffer[KB, *Payloads]`, the stage sort buffer
  typed at compile time (a key block `SortKeyBlock[*Keys]` and a variadic
  payload pack, stored column-wise), a `BreakerStateCombinable` and a
  `SpillableOp`; its key and payload column types are `sort_stage_columns`,
  `sort_stage_string_key` and `sort_stage_payloads`. Float keys compare by
  `sort_key_lt` everywhere, the top-N SIMD reject mask included.
  The key block types are `sort_stage_key_block` and the spill ledger is
  `sort_stage_buffer_spill`; `sort_stage_buffer` re-exports the key block
  names. The buffer stores values only, with no validity: `feed_row` refuses
  a row with a NULL in any bound key or payload column (an error naming the
  column, nothing appended), so callers filter or replace nulls first.
  Spill writes the pre-sort rows as one chunk and empties the buffer; the
  buffer may be fed again. `restore_from_storage` puts the spilled rows
  (chunks in spill order) before the rows fed since, so the drain is the
  drain of one buffer fed all rows in input order. A restore that fails
  (a missing chunk, a corrupt image) leaves the buffer and its chunk list
  unchanged and may be retried; `discard_spilled` releases the outstanding
  chunks without restoring them. A buffer dropped with chunks outstanding
  leaves them to the storage's `cleanup`.
- `sort_stage`: `Stage_Sort[KB, *Payloads]`, the sort breaker as a
  `FusedMorselOp`: feed every row, drain sorted in `finalize`.

Each parallel entry takes a `SharedForkJoinHandle` (the engine's dispatcher,
or `serial_fork_join_handle()` to run the same chunks inline; the `*_serial`
entries do that) and gives exactly the rows of the serial kernel, ties in
input order. `num_workers` sets the slice count; 0 means one per physical
core.

The numeric parallel sort (`sort_parallel`) does not read the key's validity:
a NULL cell sorts by its stored value, as the serial sort of a numeric key in
`sort_topn_sink` does, and `can_parallel_sort_single_key` does not look at
NULLs. The STRING / BINARY form places NULLs first ascending and last
descending, as `sort_indices_string` does. No sort sink calls the parallel
entries yet; they are covered by this package's tests, including a pooled run
of each entry family on a started runtime.

Every sort is stable: rows with equal keys keep their input order, in both
directions. Float keys are totally ordered the way DuckDB orders them: NaN
sorts above +inf (last ascending, first descending), every NaN equals every
other NaN, and -0.0 equals +0.0. The numeric kernels read values only;
`sort_indices_string`, `sort_indices_nested` and the BOOL arm of
`sort_batch_by_keys` place nulls (first ascending, last descending, unless
told otherwise). Import from the sub-modules; there is no facade.

## Examples

A float column with a NaN and an infinity, ascending and descending:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_arrow.primitive_array import PrimitiveArray
from komira_op_sort.sort import sort_indices_float64

var nan = Float64(0.0) / Float64(0.0)
var keys = PrimitiveArray[DType.float64].from_list([2.5, nan, -1.0, Float64.MAX])
var asc = sort_indices_float64(keys)
assert_equal(Int(asc.get(0)), 2)   # -1.0
assert_equal(Int(asc.get(3)), 1)   # NaN sorts last ascending
var desc = sort_indices_float64(keys, descending=True)
assert_equal(Int(desc.get(0)), 1)  # and first descending
```

Radix sort of signed keys, and the top two of a column:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_arrow.primitive_array import PrimitiveArray
from komira_op_sort.sort_radix import radix_sort_int64
from komira_op_sort.sort_topn import topn_indices_int64

var keys = PrimitiveArray[DType.int64].from_list([Int64(7), -3, 7, 0])
var perm = radix_sort_int64(keys)
assert_equal(Int(perm.get(0)), 1)  # -3
assert_equal(Int(perm.get(2)), 0)  # the two 7s keep their input order
assert_equal(Int(perm.get(3)), 2)

var top = topn_indices_int64(keys, 2, descending=True)
assert_equal(top.length, 2)
assert_equal(Int(keys.get(Int(top.get(0)))), 7)
```

The parallel sort of a FLOAT64 column, cut into three slices, gives the
serial sort's rows, NaN last:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_op_sort.sort_parallel import parallel_sort_single_key_serial

var nan = Float64(0.0) / Float64(0.0)
var keys = PrimitiveArray[DType.float64].from_list([2.0, nan, -1.0, 2.0, 0.5])
var schema = Schema.from_fields_1(Field("x", DType.float64, True))
var batch = RecordBatch.from_typed_columns_1(
    schema^, Column.from_primitive[DType.float64](keys^)
)
var out = parallel_sort_single_key_serial(batch^, "x", False, num_workers=3)
var col = out.column_at(0).as_primitive[DType.float64]()
assert_equal(col.get(0), -1.0)
assert_equal(col.get(3), 2.0)
assert_true(col.get(4) != col.get(4))  # NaN sorts last
```

A string column ascending, and the two string algorithms agreeing:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_arrow.column import Column
from komira_arrow.string_array import StringArray
from komira_op_sort.sort_string import sort_indices_string

var words: List[String] = ["pear", "apple", "pea", "apple"]
var col = Column.from_string(StringArray.from_strings(words))
var asc = sort_indices_string(col)
assert_equal(Int(asc.get(0)), 1)  # "apple" (row 1 before row 3: stable)
assert_equal(Int(asc.get(1)), 3)
assert_equal(Int(asc.get(2)), 2)  # "pea" before "pear": a prefix sorts first
var oracle = sort_indices_string(col, prefix_key=False)
for i in range(4):
    assert_equal(Int(asc.get(i)), Int(oracle.get(i)))
```
