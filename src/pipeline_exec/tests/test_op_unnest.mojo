# =============================================================================
# OP_UNNEST
# =============================================================================
#
# Every test runs `UnnestOp` on morsels of (id INT64, xs LIST, name STRING).
# What these tests prove:
#
#   * A list of two elements gives two rows with the other columns repeated;
#     rows of lists of different lengths come out in input order and then list
#     order.
#   * An empty list and a NULL list (whose offsets span elements the list does
#     not own) give no row, or with keep_empty one row whose element is NULL.
#   * STRING and INT64 elements; a NULL element inside a list stays NULL.
#   * Columns before and after the list column keep their order, names and
#     values; the list column is replaced in place by the element column.
#   * The output schema holds the element type, nullable when the list's child
#     is nullable or keep_empty is set, and the other fields unchanged.
#   * A selection-masked input unnests only its selected rows.
#   * A batch whose output passes the chunk budget is emitted in chunks that
#     resume across HAVE_MORE_OUTPUT and hold every row once, in order.
#   * A morsel whose lists are all empty gives FILTERED_EMPTY, or with
#     keep_empty one NULL-element row per input row, also when the child has no
#     element at all. A morsel with no row gives FILTERED_EMPTY.
#   * An unknown column and a non-list column are refused by name; a spec that
#     is not an OP_UNNEST or names no column is refused.
#   * `RealBuilder` serves OP_UNNEST: a segment over a resident batch returns
#     the unnested rows and, over no input row, the unnested schema.

from std.builtin.swap import swap
from std.sys import size_of
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.column_builder import ColumnBuilder
from arrow.list_array import ListArray
from arrow.primitive_array import PrimitiveArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from arrow.string_array import StringArray
from async_api.token import CancellationToken
from byte_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from morsel.morsel import Morsel
from parquet.runtime_footer_cache import ParquetMetadataCache
from physical_plan.physical_plan import MorselOp, SegmentDescPod
from pipeline_exec.fake_dispatch import InlineDispatch
from pipeline_exec.op_filter import FilterShared
from pipeline_exec.op_unnest import UNNEST_CHUNK_ROWS, UnnestOp, UnnestShared
from pipeline_exec.plan_harness import (
    batch_segment,
    chain,
    column_names,
    int64_column,
    null_column,
    string_column,
)
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from plan_expr.expr import BIN_GE, Expr
from plan_expr.expr_pool import ExprPool
from plan_expr.scalar_value import ScalarValue


def _ids(n: Int) -> List[Int]:
    var out = List[Int]()
    for i in range(n):
        out.append(i)
    return out^


def _names_of(n: Int) -> List[String]:
    var out = List[String]()
    for i in range(n):
        out.append("n" + String(i))
    return out^


def _assemble(
    var ids: List[Int],
    var xs: Column,
    var names: List[String],
    child_nullable: Bool = True,
) raises -> RecordBatch:
    """A batch (id INT64, xs LIST<item>, name STRING) around the list column
    `xs`, whose item type is read from its child."""
    var item = xs.child_at(0).arrow_type
    var id_arr = PrimitiveArray[DType.int64].allocate(len(ids))
    for i in range(len(ids)):
        id_arr.set(i, Int64(ids[i]))
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    builder.add_column(Column.from_primitive[DType.int64](id_arr^))
    sb.add_field(Field.list_of("xs", item, True, child_nullable))
    builder.add_column(xs^)
    sb.add_field(Field("name", ArrowType.STRING, False))
    builder.add_column(Column.from_string(StringArray.from_strings(names)))
    return builder.build(sb.build())


def _int_batch(lists: List[List[Int]], valid: List[Bool]) raises -> RecordBatch:
    var xs = Column.from_list(ListArray.from_int_lists_nullable(lists, valid))
    return _assemble(_ids(len(lists)), xs^, _names_of(len(lists)))


def _valid(n: Int) -> List[Bool]:
    return List[Bool](length=n, fill=True)


def _op(keep_empty: Bool) raises -> UnnestOp:
    return UnnestShared(MorselOp.unnest("xs", keep_empty)).make()


def _expect(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "element " + String(i))


def _run(var batch: RecordBatch, keep_empty: Bool) raises -> Morsel:
    var op = _op(keep_empty)
    var m = Morsel(batch^, 0, 0)
    var rc = op.execute(m)
    assert_true(rc.is_need_more_input())
    return m^


def test_a_list_of_two_elements_gives_two_rows_with_the_id_repeated() raises:
    var lists = List[List[Int]]()
    lists.append([10, 11])
    var m = _run(_int_batch(lists, _valid(1)), False)
    assert_equal(m.num_rows(), 2)
    _expect(int64_column(m.batch, 0), [0, 0])
    _expect(int64_column(m.batch, 1), [10, 11])
    var names = string_column(m.batch, 2)
    assert_equal(names[0], "n0")
    assert_equal(names[1], "n0")


def test_rows_of_different_lengths_keep_input_then_list_order() raises:
    var lists = List[List[Int]]()
    lists.append([1, 2, 3])
    lists.append([4])
    lists.append([5, 6])
    var m = _run(_int_batch(lists, _valid(3)), False)
    _expect(int64_column(m.batch, 0), [0, 0, 0, 1, 2, 2])
    _expect(int64_column(m.batch, 1), [1, 2, 3, 4, 5, 6])


def test_an_empty_or_null_list_gives_no_row_without_keep_empty() raises:
    var lists = List[List[Int]]()
    lists.append([1])
    lists.append(List[Int]())
    lists.append([7, 8, 9])  # a NULL list that still spans elements
    lists.append([2])
    var valid = _valid(4)
    valid[2] = False
    var m = _run(_int_batch(lists, valid), False)
    _expect(int64_column(m.batch, 0), [0, 3])
    _expect(int64_column(m.batch, 1), [1, 2])
    assert_false(m.batch.column_at(1).is_null_at(0))


def test_an_empty_or_null_list_gives_one_null_row_with_keep_empty() raises:
    var lists = List[List[Int]]()
    lists.append([1])
    lists.append(List[Int]())
    lists.append([7, 8, 9])
    lists.append([2, 3])
    var valid = _valid(4)
    valid[2] = False
    var m = _run(_int_batch(lists, valid), True)
    _expect(int64_column(m.batch, 0), [0, 1, 2, 3, 3])
    var nulls = null_column(m.batch, 1)
    assert_false(nulls[0])
    assert_true(nulls[1])
    assert_true(nulls[2])
    assert_false(nulls[3])
    assert_false(nulls[4])
    var xs = int64_column(m.batch, 1)
    assert_equal(xs[0], 1)
    assert_equal(xs[3], 2)
    assert_equal(xs[4], 3)
    var names = string_column(m.batch, 2)
    assert_equal(names[1], "n1")
    assert_equal(names[2], "n2")


def test_string_elements_unnest_and_a_null_list_keeps_one_null_row() raises:
    var lists = List[List[String]]()
    lists.append(["a", "bb"])
    lists.append(List[String]())
    lists.append(["ccc"])
    var valid = _valid(3)
    valid[1] = False
    var xs = Column.from_list(ListArray.from_string_lists(lists, valid))
    var m = _run(_assemble(_ids(3), xs^, _names_of(3)), True)
    assert_equal(m.num_rows(), 4)
    _expect(int64_column(m.batch, 0), [0, 0, 1, 2])
    var got = string_column(m.batch, 1)
    assert_equal(got[0], "a")
    assert_equal(got[1], "bb")
    assert_equal(got[3], "ccc")
    var nulls = null_column(m.batch, 1)
    assert_true(nulls[2])
    assert_false(nulls[3])
    assert_true(m.batch.schema.field_arrow_type(1) == ArrowType.STRING)


def _list_with_null_elements() raises -> Column:
    """Two lists, [5, NULL, 6] and [NULL]."""
    var child = ColumnBuilder[DType.int64].with_capacity(4)
    child.append(Int64(5))
    child.append_null()
    child.append(Int64(6))
    child.append_null()
    var offsets = OwnedAlignedBuffer(3 * size_of[Int32]())
    offsets.set_typed[Int32](0, Int32(0))
    offsets.set_typed[Int32](1, Int32(3))
    offsets.set_typed[Int32](2, Int32(4))
    offsets.set_length(Int64(3 * size_of[Int32]()))
    var arr = ListArray(offsets^, child^.materialize(), None, 2, 0)
    return Column.from_list(arr^)


def test_a_null_element_inside_a_list_stays_null() raises:
    var m = _run(
        _assemble(_ids(2), _list_with_null_elements(), _names_of(2)), False
    )
    _expect(int64_column(m.batch, 0), [0, 0, 0, 1])
    var nulls = null_column(m.batch, 1)
    assert_false(nulls[0])
    assert_true(nulls[1])
    assert_false(nulls[2])
    assert_true(nulls[3])
    assert_equal(int64_column(m.batch, 1)[0], 5)
    assert_equal(int64_column(m.batch, 1)[2], 6)


def test_the_list_column_is_replaced_in_place_and_the_others_repeat() raises:
    var lists = List[List[Int]]()
    lists.append([1, 2])
    lists.append([3])
    var m = _run(_int_batch(lists, _valid(2)), False)
    var names = column_names(m.batch)
    assert_equal(len(names), 3)
    assert_equal(names[0], "id")
    assert_equal(names[1], "xs")
    assert_equal(names[2], "name")
    var got = string_column(m.batch, 2)
    assert_equal(got[0], "n0")
    assert_equal(got[1], "n0")
    assert_equal(got[2], "n1")
    assert_true(m.batch.schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(m.batch.schema.field_arrow_type(1) == ArrowType.INT64)
    assert_true(m.batch.schema.field_arrow_type(2) == ArrowType.STRING)


def test_the_output_field_is_the_element_type_nullable_by_child_or_keep_empty() raises:
    var lists = List[List[Int]]()
    lists.append([1])
    var batch = _int_batch(lists, _valid(1))
    var plain = UnnestShared(MorselOp.unnest("xs", False)).output_schema(
        batch.schema
    )
    assert_true(plain.field_arrow_type(1) == ArrowType.INT64)
    assert_true(plain.field_nullable(1))  # the child is nullable
    assert_false(plain.field_nullable(0))
    assert_equal(plain.field_name(1), "xs")

    var xs = Column.from_list(ListArray.from_int_lists(lists))
    var strict = _assemble(_ids(1), xs^, _names_of(1), child_nullable=False)
    var no_null = UnnestShared(MorselOp.unnest("xs", False)).output_schema(
        strict.schema
    )
    assert_false(no_null.field_nullable(1))
    var kept = UnnestShared(MorselOp.unnest("xs", True)).output_schema(
        strict.schema
    )
    assert_true(kept.field_nullable(1))
    assert_false(kept.field_nullable(2))


def test_a_selection_mask_limits_the_unnest_to_the_selected_rows() raises:
    var lists = List[List[Int]]()
    lists.append([1, 2])
    lists.append([3, 4])
    lists.append([5])
    lists.append([6, 7])
    var m = Morsel(_int_batch(lists, _valid(4)), 0, 0)
    var pred = Expr.binary(
        BIN_GE, Expr.col_ref("id"), Expr.literal(ScalarValue.from_int(2))
    )
    var filter = FilterShared(MorselOp.filter(pred^)).make()
    _ = filter.execute(m)
    assert_true(m.batch.has_selection_mask())
    var op = _op(False)
    var rc = op.execute(m)
    assert_true(rc.is_need_more_input())
    assert_false(m.batch.has_selection_mask())
    _expect(int64_column(m.batch, 0), [2, 3, 3])
    _expect(int64_column(m.batch, 1), [5, 6, 7])


def test_a_batch_past_the_chunk_budget_resumes_and_holds_every_row_once() raises:
    var n = UNNEST_CHUNK_ROWS + 5000
    var lists = List[List[Int]]()
    for i in range(n):
        lists.append([i * 2, i * 2 + 1])
    var op = _op(False)
    var m = Morsel(_int_batch(lists, _valid(n)), 0, 0)
    var rc = op.execute(m)
    var chunks = 0
    var next_id = 0
    var next_value = 0
    while True:
        assert_true(m.num_rows() > 0)
        assert_true(m.num_rows() <= UNNEST_CHUNK_ROWS)
        var ids = int64_column(m.batch, 0)
        var values = int64_column(m.batch, 1)
        for i in range(len(ids)):
            assert_equal(ids[i], next_id // 2)
            assert_equal(values[i], next_value)
            next_id += 1
            next_value += 1
        chunks += 1
        if not rc.is_have_more_output():
            break
        var shell = RecordBatch()
        swap(shell, m.batch)
        rc = op.execute(m)
    assert_true(rc.is_need_more_input())
    assert_equal(next_id, n * 2)
    assert_true(chunks >= 3)


def test_lists_that_are_all_empty_give_nothing_without_keep_empty() raises:
    var lists = List[List[Int]]()
    lists.append(List[Int]())
    lists.append(List[Int]())
    var op = _op(False)
    var m = Morsel(_int_batch(lists, _valid(2)), 0, 0)
    var rc = op.execute(m)
    assert_true(rc.is_filtered_empty())
    assert_equal(m.num_rows(), 0)
    # The operator is ready for the next morsel.
    var next = List[List[Int]]()
    next.append([9])
    var m2 = Morsel(_int_batch(next, _valid(1)), 0, 0)
    assert_true(op.execute(m2).is_need_more_input())
    _expect(int64_column(m2.batch, 1), [9])


def test_lists_with_no_element_at_all_give_null_rows_with_keep_empty() raises:
    var lists = List[List[Int]]()
    lists.append(List[Int]())
    lists.append(List[Int]())
    lists.append(List[Int]())
    var valid = _valid(3)
    valid[1] = False
    var m = _run(_int_batch(lists, valid), True)
    assert_equal(m.num_rows(), 3)
    _expect(int64_column(m.batch, 0), [0, 1, 2])
    var nulls = null_column(m.batch, 1)
    for i in range(3):
        assert_true(nulls[i])
    var strings = List[List[String]]()
    strings.append(List[String]())
    var xs = Column.from_list(ListArray.from_string_lists(strings, _valid(1)))
    var ms = _run(_assemble(_ids(1), xs^, _names_of(1)), True)
    assert_equal(ms.num_rows(), 1)
    assert_true(ms.batch.column_at(1).is_null_at(0))


def test_a_morsel_with_no_row_is_dropped() raises:
    var lists = List[List[Int]]()
    var op = _op(True)
    var m = Morsel(_int_batch(lists, _valid(0)), 0, 0)
    assert_true(op.execute(m).is_filtered_empty())


def test_an_unknown_column_and_a_non_list_column_are_refused_by_name() raises:
    var lists = List[List[Int]]()
    lists.append([1])
    var missing = UnnestShared(MorselOp.unnest("nope", False)).make()
    var m = Morsel(_int_batch(lists, _valid(1)), 0, 0)
    with assert_raises(contains="unnest: no column 'nope' in its input"):
        _ = missing.execute(m)
    var plain = UnnestShared(MorselOp.unnest("id", False)).make()
    var m2 = Morsel(_int_batch(lists, _valid(1)), 0, 0)
    with assert_raises(contains="unnest: column 'id' is not a list"):
        _ = plain.execute(m2)
    with assert_raises(contains="unnest: column 'name' is not a list"):
        _ = UnnestShared(MorselOp.unnest("name", True)).output_schema(
            m2.batch.schema
        )


def test_a_spec_that_is_not_an_unnest_or_names_no_column_is_refused() raises:
    with assert_raises(contains="an OP_UNNEST spec is expected"):
        _ = UnnestShared(MorselOp.limit(3))
    with assert_raises(contains="an OP_UNNEST names no column"):
        _ = UnnestShared(MorselOp.unnest("", False))


def test_the_real_builder_serves_unnest_over_a_resident_batch() raises:
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[origin_of(cache), origin_of(pool), origin_of(nf)](
        cache, pool
    )
    var lists = List[List[Int]]()
    lists.append([1, 2])
    lists.append(List[Int]())
    lists.append([3])
    var handle = builder.add_resident(_int_batch(lists, _valid(3)))
    var descs = List[SegmentDescPod]()
    descs.append(
        batch_segment(0, handle, chain(MorselOp.unnest("xs", True)), 2)
    )
    var dispatch = InlineDispatch()
    var out = run_plan(descs, builder, dispatch, 1, CancellationToken.new())
    var batch = out.take(0)
    assert_equal(batch.num_rows(), 4)
    _expect(int64_column(batch, 0), [0, 0, 1, 2])
    var nulls = null_column(batch, 1)
    assert_false(nulls[0])
    assert_true(nulls[2])
    assert_false(nulls[3])
    assert_true(batch.schema.field_arrow_type(1) == ArrowType.INT64)

    # A segment that reaches no input row still has the unnested schema.
    var none = List[SegmentDescPod]()
    none.append(
        batch_segment(
            0,
            builder.add_resident(_int_batch(List[List[Int]](), _valid(0))),
            chain(MorselOp.unnest("xs", False)),
            2,
        )
    )
    var empty = run_plan(none, builder, dispatch, 1, CancellationToken.new())
    var eb = empty.take(0)
    assert_equal(eb.num_rows(), 0)
    assert_true(eb.schema.field_arrow_type(1) == ArrowType.INT64)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
