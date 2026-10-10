# komira_op_agg_row_api

The shared vocabulary of the engine's row-hash aggregation: plain constants
and pure functions, with no table state, no pointer and no environment reads.
The package root re-exports nothing; import from the modules.

- `komira_op_agg_row_api.agg_spec`: the aggregate tags `AGG_*` (sums, count,
  min and max over signed, unsigned, float and string values, average,
  variance and standard deviation, and exact 128-bit sums), the per-aggregate
  descriptor `AggSpec` (tag, source column, state width in bytes, offset in
  the slot), predicates over tags (`is_exact_sum_op`, `is_minmax_str_op`,
  `is_minmax_u64_op`, `is_minmax_i64_family`), `dtype_is_integer`, and
  `merge_cell_class`, which maps a tag to the class of cell merge that
  combines two partial states (`MC_NONE` for a tag with no such merge, such
  as the variance family).
- `komira_op_agg_row_api.combine_agg_plan`: the merge classes `MC_*` and
  `merge_cell_class_bytes`, the state width each class reads, which a caller
  compares with an `AggSpec`'s declared width before merging.
- `komira_op_agg_row_api.agg_key_class`: `ingest_key_mono_class`, the one
  key class (`IKM_I64`, `IKM_I32`, `IKM_U32`) all of a batch's group-by key
  types share, or `IKM_NONE`.
- `komira_op_agg_row_api.agg_chunk_rows`: `agg_kbuf_chunk_rows`, the number
  of rows per key-staging window for a budget in KiB (default
  `AGG_KBUF_CHUNK_DEFAULT_KIB`, 256), never below 4096 rows, and exactly the
  batch size when the batch already fits.

It aggregates nothing itself; the hash tables and kernels that use these
types live in other packages.

## Examples

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_column_format.column_format_storage import DT_DATE64, DT_I32, DT_I64, DT_U32
from komira_op_agg_row_api.agg_chunk_rows import AGG_KBUF_CHUNK_DEFAULT_KIB, agg_kbuf_chunk_rows
from komira_op_agg_row_api.agg_key_class import IKM_I64, IKM_NONE, ingest_key_mono_class
from komira_op_agg_row_api.agg_spec import AGG_AVG_F64, AGG_COUNT, AGG_MAX_U64, AGG_STDDEV_SAMP_F64, AGG_SUM_I128, AGG_SUM_I64, AggSpec, dtype_is_integer, is_exact_sum_op, is_minmax_i64_family, merge_cell_class
from komira_op_agg_row_api.combine_agg_plan import MC_ADD_U64, MC_AVG_F64, MC_MAX_I64, MC_NONE, merge_cell_class_bytes

# How two partial states of each aggregate are merged, and how wide they are.
assert_equal(merge_cell_class(AGG_SUM_I64), MC_ADD_U64)
assert_equal(merge_cell_class(AGG_COUNT), MC_ADD_U64)
assert_equal(merge_cell_class(AGG_MAX_U64), MC_MAX_I64)  # unsigned max is stored biased
assert_equal(merge_cell_class(AGG_AVG_F64), MC_AVG_F64)
assert_equal(merge_cell_class(AGG_STDDEV_SAMP_F64), MC_NONE)
assert_equal(merge_cell_class_bytes(MC_ADD_U64), 8)
assert_equal(merge_cell_class_bytes(MC_AVG_F64), 16)  # sum and count
assert_true(is_exact_sum_op(AGG_SUM_I128))
assert_true(is_minmax_i64_family(AGG_MAX_U64))
assert_true(dtype_is_integer(DType.uint16))
assert_true(not dtype_is_integer(DType.float64))

# A descriptor whose declared width matches what its merge reads.
var avg = AggSpec(op_tag=AGG_AVG_F64, src_col_idx=2, state_byte_width=16, state_offset_in_slot=0)
assert_equal(Int(avg.state_byte_width), merge_cell_class_bytes(merge_cell_class(avg.op_tag)))

# One key class for the batch only when every key type shares it.
var keys: List[UInt8] = [DT_I64, DT_DATE64]
assert_equal(ingest_key_mono_class(keys), IKM_I64)
var mixed: List[UInt8] = [DT_I64, DT_I32]
assert_equal(ingest_key_mono_class(mixed), IKM_NONE)
var unsigned_keys: List[UInt8] = [DT_U32]
assert_true(ingest_key_mono_class(unsigned_keys) != IKM_NONE)

# Staging windows: (keys + 1) * 8 bytes per row against a 256 KiB budget.
assert_equal(agg_kbuf_chunk_rows(AGG_KBUF_CHUNK_DEFAULT_KIB, 1, 122_880), 16_384)
assert_equal(agg_kbuf_chunk_rows(AGG_KBUF_CHUNK_DEFAULT_KIB, 6, 122_880), 4_681)
assert_equal(agg_kbuf_chunk_rows(AGG_KBUF_CHUNK_DEFAULT_KIB, 1, 1_000), 1_000)  # fits: one window
assert_equal(agg_kbuf_chunk_rows(0, 1, 122_880), 122_880)  # a zero budget turns windows off
assert_equal(agg_kbuf_chunk_rows(1, 1, 122_880), 4_096)  # the floor
```
