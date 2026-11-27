# op_agg_stage

The stage hash aggregation: `HashAggTable[KB, *Aggs]`, the HASH_AGG breaker state (`operator_api.BreakerStateCombinable`). One variadic struct covers every GROUP BY key arity and aggregate pack.

This is the compile-time-typed table: the key columns and the aggregate pack are type parameters, fixed when the program is compiled. A caller that learns the key types and the aggregate list only at run time (a SQL query, for example) cannot instantiate it; that needs an untyped table, which this package does not provide.

- `key_block`: the GROUP BY key block. `KeyTupleScalar` is the one group of an ungrouped aggregate; `AggKeyBlock[*Keys]` holds one or more key columns (`op_agg_distinct` `DistinctKeyColumn_Typed[dt, col]` / `DistinctKeyColumn_String[col]`) behind a growable open-addressing directory over an FNV-1a composite hash, numbering groups 0, 1, 2, ... in first-seen order, with no cap on the group count. A NULL key is one key value: rows group together by their NULL pattern and non-NULL keys, and the key reads back NULL. `KeyTuple1` / `KeyTuple2` / `KeyTuple3` name the numeric-key blocks of one to three keys.
- `agg_column`: `AggColumn`, one aggregate with one state per group, and `AggSlot[A]` over a `agg.Aggregator`. A row whose input is NULL (`A.input_is_null`) is not folded as a value (FIRST / LAST pick it, as DuckDB's do); a group with no non-NULL value answers NULL, except COUNT and COUNT(DISTINCT), which answer 0 (`A.EMPTY_IS_NULL`). An integer SUM is exact and narrowed to INT64 at emission; a total outside INT64 raises `op_agg_state.int_sum_overflow_message`. `eval.SumOfExprF64Agg` is outside this contract: an `ExprXF64` has no NULL probe, so it folds a NULL operand's data word. `AggBlock` carries the aggregate pack into the table's constructor.
- `agg_fn_slot`: `AggFnSlot[F, col]`, a user-defined `udf.AggFn` over one input column as an aggregate column: NULL inputs are skipped and an empty group answers `finalize(init())`, as `op_agg_state.AggFnAcc` does.
- `hash_agg`: `HashAggTable`. `feed_row` folds a row; `feed_chunk_global` / `fold_scalar_view` are the ungrouped masked folds; `consume_band` folds a decoded `arrow.BandView` without a RecordBatch (a band carries no NULLs: its keys and aggregands are all values). `combine` merges another worker's table by key value; `combine_move_distinct` moves COUNT(DISTINCT) value buffers instead of copying them; `combine_partition_from` merges the groups of one hash partition, for a parallel combine fanned out by `n_combine_partitions` (`with_radix_min_groups` sets its threshold). `drain_to_record_batch` emits one row per group (an ungrouped aggregate: exactly one row, also over no input); `drain_to_record_batch_parallel` counts COUNT(DISTINCT) and finalizes MEDIAN on the dispatcher's workers, with the same result. The drain-at-offset surface (`emit_at_offset_plan` / `_data_bytes` / `_write`) writes one partition straight into shared output columns; those carry no validity, so a column holding a NULL is ineligible and a write that meets one raises.

`waiting_tests.tsv` lists the tests of this code that move with packages not ported yet.

## Examples

A `HashAggTable` is typed by its key block and its aggregate pack. This one groups by the INT64 column 0 and computes `SUM(f)`, `COUNT(*)` and `MIN(i)`; groups are numbered in first-seen order. Two workers each fold their own rows, and `combine` merges the second table into the first by key value:

```mojo module
from std.testing import assert_equal

from arrow.arrow_types import ArrowType
from arrow.batch_view import BatchView
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder

from agg.count_star_op import CountStarOp
from agg.hash_agg_op_dt import HashAggOpAgg, MinOp, SumOp

from op_agg_stage.agg_column import AggSlot
from op_agg_stage.hash_agg import HashAggTable
from op_agg_stage.key_block import KeyTuple1

comptime _Sum = AggSlot[HashAggOpAgg[SumOp[DType.float64], 2]]
comptime _Count = AggSlot[HashAggOpAgg[CountStarOp[DType.int64], 1]]
comptime _Min = AggSlot[HashAggOpAgg[MinOp[DType.int64], 1]]
comptime _Table = HashAggTable[KeyTuple1[DType.int64, 0], _Sum, _Count, _Min]


def _batch(k: List[Int64], i: List[Int64], f: List[Float64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("i", ArrowType.INT64, False))
    sb.add_field(Field("f", ArrowType.FLOAT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(k)))
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(i)))
    rb.add_column(Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(f)))
    return rb.build(sb.build())


def _feed(mut table: _Table, batch: RecordBatch) raises:
    var view = BatchView(batch)
    for row in range(view.n_rows()):
        table.feed_row(view, row)


def main() raises:
    var worker0 = _Table()
    var k0: List[Int64] = [1, 2, 1, 1, 2, 1]
    var i0: List[Int64] = [5, 9, 7, 3, 1, 4]
    var f0: List[Float64] = [10.0, 20.0, 30.0, 40.0, 50.0, 60.0]
    _feed(worker0, _batch(k0, i0, f0))
    assert_equal(worker0.size(), 2)
    assert_equal(Int(worker0.agg_finalize_f64[0](0)), 140)
    assert_equal(Int(worker0.agg_finalize_f64[1](0)), 4)
    assert_equal(Int(worker0.agg_finalize_f64[2](0)), 3)

    var worker1 = _Table()
    var k1: List[Int64] = [2, 3]
    var i1: List[Int64] = [8, 6]
    var f1: List[Float64] = [5.0, 7.0]
    _feed(worker1, _batch(k1, i1, f1))
    worker0.combine(worker1^)
    assert_equal(worker0.size(), 3)
    # Key 2 is the second group: 70 + 5, 2 + 1 rows, MIN(1, 8).
    assert_equal(Int(worker0.agg_finalize_f64[0](1)), 75)
    assert_equal(Int(worker0.agg_finalize_f64[1](1)), 3)
    assert_equal(Int(worker0.agg_finalize_f64[2](1)), 1)
    # Key 3 arrived with the merge and is the third group.
    assert_equal(Int(worker0.agg_finalize_f64[0](2)), 7)
    assert_equal(Int(worker0.agg_finalize_f64[2](2)), 6)

    var names: List[String] = ["total", "n", "lo"]
    worker0.with_output_names(names^)
    var drained = worker0.drain_to_record_batch()
    assert_equal(drained.value().num_columns(), 4)
    assert_equal(drained.value().num_rows(), 3)
```

`KeyTupleScalar` is the one group of an ungrouped aggregate; the aggregate pack is passed in an `AggBlock`:

```mojo module
from std.testing import assert_equal

from arrow.arrow_types import ArrowType
from arrow.batch_view import BatchView
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatchBuilder, SchemaBuilder

from agg.count_star_op import CountStarOp
from agg.hash_agg_op_dt import HashAggOpAgg

from op_agg_stage.agg_column import AggBlock, AggSlot
from op_agg_stage.hash_agg import HashAggTable
from op_agg_stage.key_block import KeyTupleScalar

comptime _Count = AggSlot[HashAggOpAgg[CountStarOp[DType.int64], 0]]
comptime _Total = HashAggTable[KeyTupleScalar, _Count]


def main() raises:
    var values: List[Int64] = [4, 8, 15, 16, 23]
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(values)))
    var batch = rb.build(sb.build())

    var table = _Total(AggBlock[_Count](_Count()))
    assert_equal(_Total.key_arity(), 0)
    assert_equal(_Total.agg_arity(), 1)
    var view = BatchView(batch)
    for row in range(view.n_rows()):
        table.feed_row(view, row)
    assert_equal(table.size(), 1)
    assert_equal(Int(table.agg_finalize_f64[0](0)), 5)
```
