# =============================================================================
# test_materialize_zerocopy_gate.mojo -- the bare multi-batch in-memory scan
#   gate: which plans it takes, and that its fold is the chunks in order.
# =============================================================================
#
# SUBJECT: `is_bare_multi_batch_in_memory_scan` and
# `run_bare_multi_batch_in_memory_scan`.
#   1. the gate takes a bare scan over two or more chunks, and declines one or
#      zero chunks, a pushed projection, a pushed filter, an operator root and
#      a scan node with no payload;
#   2. the fold returns every row of every chunk, in chunk order, against an
#      oracle computed from the fixture (not from either arm);
#   3. the fold borrows: the source chunks are intact and fold again to the
#      same batch; the result owns its bytes and outlives the chunks.
# A gate that ignored the projection or the filter fails section 1; a fold
# that reordered or dropped chunks fails section 2; one that consumed the
# chunks fails section 3.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import LogicalPlan, PLAN_SCAN, SOURCE_IN_MEMORY

from komira_dispatch_sources.materialize_zerocopy_gate import (
    is_bare_multi_batch_in_memory_scan,
    run_bare_multi_batch_in_memory_scan,
)


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    return sb.build()


def _chunk(start: Int, n: Int) raises -> RecordBatch:
    """`n` rows: k = start .. start+n-1, s = "r<k>"."""
    var keys = PrimitiveArray[DType.int64].allocate(n)
    var strs = List[String](capacity=n)
    for i in range(n):
        keys.store[1](i, SIMD[DType.int64, 1](Int64(start + i)))
        strs.append(String("r", start + i))
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(Column.from_primitive[DType.int64](keys))
    rbb.add_column(Column.from_string(StringArray.from_strings(strs)))
    return rbb.build(_schema())


def _chunks(sizes: List[Int]) raises -> Slab[RecordBatch]:
    var out = Slab[RecordBatch].create(0)
    var start = 0
    for n in sizes:
        out.append(_chunk(start, n))
        start += n
    return out^


def _scan(
    var projection: Optional[List[String]] = None,
    var filter: Optional[Expr] = None,
) -> LogicalPlan:
    return LogicalPlan.scan(
        String("t_mem"),
        SOURCE_IN_MEMORY,
        _schema(),
        projection=projection^,
        filter=filter^,
    )


def _only_k() -> Optional[List[String]]:
    var names = List[String]()
    names.append(String("k"))
    return Optional[List[String]](names^)


def _k_gt_1() -> Expr:
    return Expr.binary(
        BIN_GT,
        Expr.col_ref(String("k")),
        Expr.literal(ScalarValue.from_int64(Int64(1))),
    )


def _assert_rows_0_to(b: RecordBatch, n: Int) raises:
    """The oracle: rows k = 0 .. n-1 with s = "r<k>", in order."""
    assert_equal(b.num_rows(), n)
    assert_equal(b.num_columns(), 2)
    var ks = b.column_at(0).as_primitive[DType.int64]()
    var ss = b.column_at(1).as_string()
    for i in range(n):
        assert_equal(ks.get(i), Int64(i))
        assert_equal(ss.get(i), String("r", i))


# --- 1. the gate ------------------------------------------------------------


def test_takes_a_bare_scan_over_several_chunks() raises:
    var two = _chunks([3, 4])
    var three = _chunks([1, 1, 1])
    assert_true(is_bare_multi_batch_in_memory_scan(_scan(), two))
    assert_true(is_bare_multi_batch_in_memory_scan(_scan(), three))


def test_declines_one_or_zero_chunks() raises:
    var one = _chunks([5])
    var none = Slab[RecordBatch].create(0)
    assert_false(is_bare_multi_batch_in_memory_scan(_scan(), one), "one chunk")
    assert_false(is_bare_multi_batch_in_memory_scan(_scan(), none), "no chunk")


def test_declines_pushed_ops_and_operator_roots() raises:
    var two = _chunks([3, 4])
    assert_false(
        is_bare_multi_batch_in_memory_scan(
            _scan(projection=_only_k()), two
        ),
        "a pushed projection",
    )
    assert_false(
        is_bare_multi_batch_in_memory_scan(_scan(filter=_k_gt_1()), two),
        "a pushed filter",
    )
    assert_false(
        is_bare_multi_batch_in_memory_scan(
            LogicalPlan.filter(_k_gt_1(), _scan()), two
        ),
        "a FILTER root",
    )
    assert_false(
        is_bare_multi_batch_in_memory_scan(
            LogicalPlan(PLAN_SCAN, _schema()), two
        ),
        "a SCAN node with no payload",
    )


# --- 2 and 3. the fold ------------------------------------------------------


def test_the_fold_is_every_chunk_in_order() raises:
    var chunks = _chunks([3, 1, 5, 2])
    _assert_rows_0_to(run_bare_multi_batch_in_memory_scan(chunks), 11)


def test_the_fold_leaves_the_source_chunks_intact() raises:
    var chunks = _chunks([2, 3])
    var first = run_bare_multi_batch_in_memory_scan(chunks)
    assert_equal(len(chunks), 2, "nothing moved out of the Slab")
    assert_equal(chunks[0].num_rows(), 2)
    assert_equal(chunks[1].num_rows(), 3)
    var second = run_bare_multi_batch_in_memory_scan(chunks)
    _assert_rows_0_to(first, 5)
    _assert_rows_0_to(second, 5)


def _fold_then_drop_the_chunks() raises -> RecordBatch:
    var chunks = _chunks([4, 4])
    var out = run_bare_multi_batch_in_memory_scan(chunks)
    _ = chunks^
    return out^


def test_the_result_outlives_the_chunks() raises:
    _assert_rows_0_to(_fold_then_drop_the_chunks(), 8)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
