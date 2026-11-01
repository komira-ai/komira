# =============================================================================
# test_broker_compacted_pushdown_offline.mojo
#   Compacted-tier row-group and column pruning unit tests
# =============================================================================
#
# Coverage for the compacted Parquet tier's consume pushdown
# (`dual_tier_consume.mojo`: `decode_compacted_parquet_bytes_pushdown`). No
# network: we build a real multi-row-group compacted Parquet object in memory
# (the `write_record_batches_to_parquet_bytes` seam the CompactionWorker PUTs
# to the object store,
# but with a small `max_rows_per_rg` to force several row groups with DISJOINT
# stat ranges), then drive the pushdown decoder directly and assert:
#
#   1. RG-PRUNING CLASSIFIER on the compacted arm:
#      - a `col <op> literal` predicate over a stat-friendly column SKIPS the
#        row groups whose min/max stats prove no match (rgs_pruned > 0), via the
#        row-group zonemap pruner (`rg_pruner.can_prune_row_group`).
#      - NO predicate -> NO pruning (rgs_pruned == 0; all RGs decoded).
#      - a non-stat-prunable predicate shape (col-op-col / unknown col) ->
#        conservative NO pruning (rgs_pruned == 0).
#   2. PROJECTION -> ColumnProjection flows into the row-group decode: a
#      projected subset returns ONLY those columns, in projection order.
#   3. CORRECTNESS oracle: the pushdown decode's surviving rows are IDENTICAL to
#      a full-decode-then-filter oracle (pruning never drops a matching row).
#
# Pointer rules: no UnsafePointer in any signature, no wildcard origins,
# no unsafe_from_address / take_pointee.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_collections.slab import Slab

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_plan_expr.expr import (
    Expr,
    BIN_LT,
    BIN_GE,
)
from komira_plan_expr.scalar_value import ScalarValue

from komira_parquet_writer.record_batch_writer import (
    write_record_batches_to_parquet_bytes,
)
from komira_parquet_api.types import CompressionCodec

from komira_broker_compaction.dual_tier_consume import (
    decode_compacted_parquet_bytes_pushdown,
    decode_compacted_parquet_bytes,
    CompactedDecodeResult,
)


# =============================================================================
# Fixtures — build a real multi-RG compacted Parquet object in memory.
# =============================================================================


def _make_two_col_batch(
    id_base: Int64, amount_base: Int64, n: Int
) raises -> RecordBatch:
    """A 2-column batch: id:INT64 (id_base + i), amount:INT64 (amount_base + i).
    The two columns let a predicate target one while a projection drops the
    other."""
    var schema = Schema(
        names=[String("id"), String("amount")],
        arrow_types=[ArrowType.INT64.type_id, ArrowType.INT64.type_id],
        dtypes=[DType.int64, DType.int64],
        nullables=[False, False],
    )
    var id_arr = PrimitiveArray[DType.int64].allocate(n)
    var id_p = id_arr._typed_ptr_mut()
    for i in range(n):
        id_p.store[width=1](i, id_base + Int64(i))
    var amt_arr = PrimitiveArray[DType.int64].allocate(n)
    var amt_p = amt_arr._typed_ptr_mut()
    for i in range(n):
        amt_p.store[width=1](i, amount_base + Int64(i))
    var id_col = Column.from_primitive[DType.int64](id_arr^)
    var amt_col = Column.from_primitive[DType.int64](amt_arr^)
    return RecordBatch.from_typed_columns_2(schema^, id_col^, amt_col^)


def _make_multi_rg_compacted_bytes() raises -> List[UInt8]:
    """Build a compacted Parquet object with 4 DISJOINT-range row groups.

    Each RG holds 10 rows; `max_rows_per_rg=10` forces one RG per source
    chunk. The `id` ranges are:
        RG0: id 0..9      amount 100..109
        RG1: id 100..109  amount 200..209
        RG2: id 200..209  amount 300..309
        RG3: id 300..309  amount 400..409
    So a predicate like `id < 150` matches RG0+RG1 only (RG2+RG3 prunable);
    `id >= 200` matches RG2+RG3 only (RG0+RG1 prunable)."""
    var batches = Slab[RecordBatch]()
    batches.append(_make_two_col_batch(Int64(0), Int64(100), 10))
    batches.append(_make_two_col_batch(Int64(100), Int64(200), 10))
    batches.append(_make_two_col_batch(Int64(200), Int64(300), 10))
    batches.append(_make_two_col_batch(Int64(300), Int64(400), 10))
    return write_record_batches_to_parquet_bytes(
        batches^, codec=CompressionCodec.SNAPPY, max_rows_per_rg=10
    )


def _pred_id_lt(v: Int64) -> Expr:
    return Expr.binary(
        BIN_LT,
        Expr.col_ref(String("id")),
        Expr.literal(ScalarValue.from_int64(v)),
    )


def _pred_id_ge(v: Int64) -> Expr:
    return Expr.binary(
        BIN_GE,
        Expr.col_ref(String("id")),
        Expr.literal(ScalarValue.from_int64(v)),
    )


def _i64_at(rb: RecordBatch, col_idx: Int, row: Int) raises -> Int64:
    """Read one INT64 cell from a RecordBatch column."""
    var arr = rb.column_at(col_idx).as_primitive[DType.int64]()
    return arr.get(row)


# =============================================================================
# Test 1 — RG-pruning: `id < 150` prunes the two high-range row groups.
# =============================================================================


def test_compacted_predicate_prunes_high_row_groups() raises:
    var pbytes = _make_multi_rg_compacted_bytes()
    var pred: Optional[Expr] = _pred_id_lt(Int64(150))
    var res = decode_compacted_parquet_bytes_pushdown(
        pbytes^, pred^, Optional[List[String]](None)
    )
    # The object has 4 row groups; RG2 (id 200-209) + RG3 (id 300-309) cannot
    # match `id < 150` -> pruned. RG0 + RG1 are decoded.
    assert_equal(res.rgs_total, 4)
    assert_equal(res.rgs_pruned, 2)
    assert_equal(res.rgs_decoded, 2)
    # 20 rows survive the row filter (id 0..9 + 100..109 are all < 150).
    assert_equal(res.batch.num_rows(), 20)
    assert_equal(res.batch.num_columns(), 2)
    _ = res^


# =============================================================================
# Test 2 — RG-pruning: `id >= 200` prunes the two low-range row groups.
# =============================================================================


def test_compacted_predicate_prunes_low_row_groups() raises:
    var pbytes = _make_multi_rg_compacted_bytes()
    var pred: Optional[Expr] = _pred_id_ge(Int64(200))
    var res = decode_compacted_parquet_bytes_pushdown(
        pbytes^, pred^, Optional[List[String]](None)
    )
    # RG0 (id 0-9) + RG1 (id 100-109) cannot match `id >= 200` -> pruned.
    assert_equal(res.rgs_total, 4)
    assert_equal(res.rgs_pruned, 2)
    assert_equal(res.rgs_decoded, 2)
    assert_equal(res.batch.num_rows(), 20)  # id 200..209 + 300..309
    _ = res^


# =============================================================================
# Test 3 — NO predicate -> NO pruning (all RGs decoded).
# =============================================================================


def test_compacted_no_predicate_no_pruning() raises:
    var pbytes = _make_multi_rg_compacted_bytes()
    var res = decode_compacted_parquet_bytes_pushdown(
        pbytes^, Optional[Expr](None), Optional[List[String]](None)
    )
    assert_equal(res.rgs_total, 4)
    assert_equal(res.rgs_pruned, 0)
    assert_equal(res.rgs_decoded, 4)
    assert_equal(res.batch.num_rows(), 40)  # all 4 RGs x 10 rows
    _ = res^


# =============================================================================
# Test 4 — non-stat-prunable predicate shape (col op col) -> conservative.
# =============================================================================


def test_compacted_non_stat_predicate_no_pruning() raises:
    var pbytes = _make_multi_rg_compacted_bytes()
    # `id < amount` is a col-op-col comparison: the RG zonemap pruner is
    # CONSERVATIVE on non-literal RHS (it cannot prove unsatisfiability from
    # min/max stats of two columns), so NO row group is pruned even though the
    # shape is valid + evaluable by the row filter. In our data id_base <
    # amount_base in every RG, so every row survives -> all 40 rows, 0 pruned.
    var pred: Optional[Expr] = Expr.binary(
        BIN_LT,
        Expr.col_ref(String("id")),
        Expr.col_ref(String("amount")),
    )
    var res = decode_compacted_parquet_bytes_pushdown(
        pbytes^, pred^, Optional[List[String]](None)
    )
    assert_equal(res.rgs_total, 4)
    assert_equal(res.rgs_pruned, 0)  # conservative — col-op-col never prunes
    assert_equal(res.rgs_decoded, 4)
    assert_equal(res.batch.num_rows(), 40)  # id < amount holds for every row
    _ = res^


# =============================================================================
# Test 5 — projection -> ColumnProjection flows: only projected cols returned.
# =============================================================================


def test_compacted_projection_flows_into_decode() raises:
    var pbytes = _make_multi_rg_compacted_bytes()
    # Project only `amount`, with a predicate on `id < 150` (filter-before-
    # project: the predicate column is NOT in the projection — the compacted
    # decode applies the projection at decode, but the RG prune + the row filter
    # run on the full RG before the post-fold projection).
    var pred: Optional[Expr] = _pred_id_lt(Int64(150))
    var proj_cols = List[String]()
    proj_cols.append(String("amount"))
    var proj: Optional[List[String]] = proj_cols^
    var res = decode_compacted_parquet_bytes_pushdown(
        pbytes^, pred^, proj^
    )
    # Pruning still fires (RG2+RG3 prunable on id).
    assert_equal(res.rgs_pruned, 2)
    # Output carries ONLY the projected `amount` column.
    assert_equal(res.batch.num_columns(), 1)
    assert_equal(res.batch.schema.field_name(0), String("amount"))
    assert_equal(res.batch.num_rows(), 20)
    # The 20 surviving amounts are 100..109 (RG0) + 200..209 (RG1).
    var first = _i64_at(res.batch, 0, 0)
    assert_equal(first, Int64(100))
    _ = res^


# =============================================================================
# Test 6 — CORRECTNESS oracle: pushdown == full-decode-then-filter.
# =============================================================================


def test_compacted_pushdown_matches_full_decode_oracle() raises:
    # ORACLE: decode the WHOLE object (no pushdown) and count rows with id < 250.
    var oracle_bytes = _make_multi_rg_compacted_bytes()
    var full = decode_compacted_parquet_bytes(oracle_bytes^)
    var oracle_count = 0
    for r in range(full.num_rows()):
        if _i64_at(full, 0, r) < Int64(250):  # col 0 == id
            oracle_count += 1
    _ = full^

    # PUSHDOWN: same predicate via the compacted-tier pushdown decode.
    var pbytes = _make_multi_rg_compacted_bytes()
    var pred: Optional[Expr] = _pred_id_lt(Int64(250))
    var res = decode_compacted_parquet_bytes_pushdown(
        pbytes^, pred^, Optional[List[String]](None)
    )
    # `id < 250` matches RG0 (0-9), RG1 (100-109), RG2 (200-209) -> RG3 prunable.
    assert_equal(res.rgs_pruned, 1)
    # IDENTICAL surviving row count vs the full-decode-then-filter oracle.
    assert_equal(res.batch.num_rows(), oracle_count)
    assert_equal(oracle_count, 30)
    _ = res^


def main() raises:
    test_compacted_predicate_prunes_high_row_groups()
    test_compacted_predicate_prunes_low_row_groups()
    test_compacted_no_predicate_no_pruning()
    test_compacted_non_stat_predicate_no_pruning()
    test_compacted_projection_flows_into_decode()
    test_compacted_pushdown_matches_full_decode_oracle()
    print("test_broker_compacted_pushdown_offline: ALL PASS")
