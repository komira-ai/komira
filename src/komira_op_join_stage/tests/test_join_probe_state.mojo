# =============================================================================
# test_join_probe_state -- `JoinProbeState`, the JOIN_PROBE breaker state:
# the rows, types and NULLs of `probe_batch` for INNER and LEFT, as DuckDB
# returns them for the same join
# =============================================================================
#
# The build side is (k INT64, p0 INT64, p1 FLOAT64, p2 STRING), built through
# `JoinBuildState`:
#     (1, 2^53 + 1, 1.5, "a"), (2, 7, NULL, NULL), (2, 8, 2.5, "c"),
#     (NULL, 9, 9.5, "z")
# and the probe keys are [2, 5, 1, NULL]. In SQL terms,
#     SELECT p.k, b.p0, b.p1, b.p2 FROM probe p [LEFT] JOIN build b ON p.k = b.k
# gives three rows for INNER (two for key 2, one for key 1) and five for LEFT
# (also 5 and the NULL key, each once with NULL build columns).
#
# What each test proves:
#   * `test_inner_rows_types_and_nulls`: the payloads come out at their own
#     types (2^53 + 1 stays exact, 1.5 stays FLOAT64), a NULL build payload
#     is NULL (not 0 or ""), and a duplicate build key gives both rows.
#   * `test_left_keeps_unmatched_and_null_keys`: the unmatched rows carry
#     NULL build columns, and the NULL probe key comes out NULL.
#   * `test_float_key_column_and_nan_match`: a FLOAT64 key is emitted as a
#     FLOAT64 column with the probe's own bits, and a NaN probe key matches a
#     NaN build key of another sign and payload.
#   * `test_unique_keys_give_one_row_per_matching_probe_row`: with no
#     duplicate build key each matching probe row gives one output row, in
#     probe order; a batch without a match emits nothing for INNER.
#   * `test_two_column_key_needs_both_columns_to_match`: with a two-column key
#     a match needs both columns, (a, b) and (b, a) are different keys, a
#     NULL in either probe column matches nothing, a build row with a NULL
#     second column was never stored, and `jkey` is key column 0.
#   * `test_stubs`: the accumulate entry points of the breaker trait.
# =============================================================================

from std.memory import bitcast
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import BatchView, batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_expr.stage_program import BREAKER_JOIN_PROBE, JOIN_INNER, JOIN_LEFT

from komira_op_join_stage.join_build_state import JoinBuildState
from komira_op_join_stage.join_build_table import JoinBuildTable
from komira_op_join_stage.join_key_bundle import KeyBundle1, KeyBundle2
from komira_op_join_stage.join_payload_column import (
    PayloadCol_JoinString,
    PayloadSlot,
)
from komira_op_join_stage.join_probe_state import JoinProbeState


comptime I64 = DType.int64
comptime F64 = DType.float64
comptime Table = JoinBuildTable[
    KeyBundle1[I64], PayloadSlot[I64], PayloadSlot[F64], PayloadCol_JoinString
]
comptime Build = JoinBuildState[
    0,
    -1,
    3,
    KeyBundle1[I64],
    PayloadSlot[I64],
    PayloadSlot[F64],
    PayloadCol_JoinString,
]
comptime Probe = JoinProbeState[
    0, -1, KeyBundle1[I64], PayloadSlot[I64], PayloadSlot[F64], PayloadCol_JoinString
]

comptime BIG: Int64 = 9007199254740993  # 2^53 + 1


def _col[
    dt: DType
](values: List[Scalar[dt]], nulls: List[Bool]) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[dt].allocate_nullable(len(values))
    for i in range(len(values)):
        a.set(i, values[i])
        if nulls[i]:
            a._set_null(i)
    return Column.from_primitive[dt](a^)


def _build_batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, True))
    sb.add_field(Field(String("p0"), ArrowType.INT64, True))
    sb.add_field(Field(String("p1"), ArrowType.FLOAT64, True))
    sb.add_field(Field(String("p2"), ArrowType.STRING, True))
    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(_col[I64]([1, 2, 2, 0], [False, False, False, True]))
    rbb.add_column(_col[I64]([BIG, 7, 8, 9], [False, False, False, False]))
    rbb.add_column(_col[F64]([1.5, 0.0, 2.5, 9.5], [False, True, False, False]))
    var strs: List[String] = ["a", "", "c", "z"]
    var valid: List[Bool] = [True, False, True, True]
    rbb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(strs, valid))
    )
    return rbb.build(sb.build())


def _feed_all[bo: Origin[mut=False]](mut st: Build, bv: BatchView[bo]) raises:
    for r in range(bv.n_rows()):
        st.feed_row(bv, r)


def _probe_state() raises -> Probe:
    var st = Build(Table(KeyBundle1[I64]()))
    var b = _build_batch()
    _feed_all(st, batch_view_over(b))
    var owned = st.take_join_build_table()
    return Probe(owned^.take())


def _keys_batch(keys: List[Int64], nulls: List[Bool]) raises -> RecordBatch:
    return RecordBatch.from_typed_columns_1(
        Schema.from_fields_1(Field("k", I64, True)), _col[I64](keys, nulls)
    )


def _run[
    join_t: Int, bo: Origin[mut=False]
](mut st: Probe, bv: BatchView[bo]) raises -> RecordBatch:
    var out = st.probe_batch[bo, join_t](bv)
    assert_true(Bool(out), "rows were emitted")
    return out.take()


def _try[
    join_t: Int, bo: Origin[mut=False]
](mut st: Probe, bv: BatchView[bo]) raises -> Optional[RecordBatch]:
    return st.probe_batch[bo, join_t](bv)


def _probe_asof[bo: Origin[mut=False]](mut st: Probe, bv: BatchView[bo]) raises:
    _ = st.probe_asof_batch[bo](bv)


comptime ProbeF = JoinProbeState[0, -1, KeyBundle1[F64], PayloadSlot[I64]]


def _run_f[bo: Origin[mut=False]](mut st: ProbeF, bv: BatchView[bo]) raises -> RecordBatch:
    var out = st.probe_batch[bo, JOIN_INNER](bv)
    assert_true(Bool(out), "rows were emitted")
    return out.take()


def _row_of_p0(rb: RecordBatch, p0: Int64) raises -> Int:
    """The output row whose p0 is `p0` (p0 is unique per build row)."""
    var col = rb.column_as_primitive[I64](1)
    for r in range(rb.num_rows()):
        if not rb.column_at(1).is_null_at(r) and col.get(r) == p0:
            return r
    raise Error("no output row with that p0")


def _check_build_row(
    rb: RecordBatch, r: Int, key: Int64, p0: Int64, p1: Float64, p1_null: Bool, p2: String
) raises:
    assert_equal(rb.column_as_primitive[I64](0).get(r), key)
    assert_equal(rb.column_as_primitive[I64](1).get(r), p0)
    assert_equal(rb.column_at(2).is_null_at(r), p1_null)
    assert_equal(rb.column_at(3).is_null_at(r), p1_null)
    if not p1_null:
        assert_equal(rb.column_as_primitive[F64](2).get(r), p1)
        assert_equal(rb.column_as_string(3).get(r), p2)


def test_inner_rows_types_and_nulls() raises:
    var st = _probe_state()
    var probe = _keys_batch([2, 5, 1, 0], [False, False, False, True])
    var rb = _run[JOIN_INNER](st, batch_view_over(probe))

    assert_equal(rb.num_rows(), 3)
    assert_true(rb.column_arrow_type(0) == ArrowType.INT64)
    assert_true(rb.column_arrow_type(1) == ArrowType.INT64)
    assert_true(rb.column_arrow_type(2) == ArrowType.FLOAT64, "p1 stays FLOAT64")
    assert_true(rb.column_arrow_type(3) == ArrowType.STRING)
    assert_false(rb.schema.field_nullable(0), "INNER jkey is never NULL")

    _check_build_row(rb, _row_of_p0(rb, BIG), 1, BIG, 1.5, False, "a")
    _check_build_row(rb, _row_of_p0(rb, 7), 2, 7, 0.0, True, "")
    _check_build_row(rb, _row_of_p0(rb, 8), 2, 8, 2.5, False, "c")
    # Probe rows in input order: both key-2 rows come before the key-1 row.
    assert_equal(_row_of_p0(rb, BIG), 2)


def test_left_keeps_unmatched_and_null_keys() raises:
    var st = _probe_state()
    var probe = _keys_batch([2, 5, 1, 0], [False, False, False, True])
    var rb = _run[JOIN_LEFT](st, batch_view_over(probe))

    assert_equal(rb.num_rows(), 5)
    assert_true(rb.schema.field_nullable(0), "LEFT jkey is nullable")
    # Rows 0 and 1: key 2's matches. Row 2: key 5, unmatched. Row 3: key 1.
    # Row 4: the NULL key, unmatched.
    assert_equal(rb.column_as_primitive[I64](0).get(2), 5)
    assert_false(rb.column_at(0).is_null_at(2))
    for c in range(1, 4):
        assert_true(rb.column_at(c).is_null_at(2), "unmatched: NULL build")
        assert_true(rb.column_at(c).is_null_at(4), "NULL key: NULL build")
    assert_true(rb.column_at(0).is_null_at(4), "the NULL probe key stays NULL")
    _check_build_row(rb, 3, 1, BIG, 1.5, False, "a")


def test_float_key_column_and_nan_match() raises:
    comptime TableF = JoinBuildTable[KeyBundle1[F64], PayloadSlot[I64]]
    comptime BuildF = JoinBuildState[0, -1, 1, KeyBundle1[F64], PayloadSlot[I64]]
    var st = BuildF(TableF(KeyBundle1[F64]()))
    var nan_build = bitcast[DType.float64](UInt64(0x7FF8000000000000))
    var nan_probe_bits = UInt64(0xFFF8000000000005)
    var build = RecordBatch.from_typed_columns_2(
        Schema.from_fields_2(Field("k", F64, True), Field("p", I64, True)),
        _col[F64]([nan_build, 4.25], [False, False]),
        _col[I64]([10, 20], [False, False]),
    )
    var bv = batch_view_over(build)
    for r in range(2):
        st.feed_row(bv, r)
    var owned = st.take_join_build_table()
    var pst = ProbeF(owned^.take())
    var probe = RecordBatch.from_typed_columns_1(
        Schema.from_fields_1(Field("k", F64, True)),
        _col[F64](
            [bitcast[DType.float64](nan_probe_bits), 4.25, 4.0],
            [False, False, False],
        ),
    )
    var rb = _run_f(pst, batch_view_over(probe))
    assert_equal(rb.num_rows(), 2, "NaN and 4.25 match; 4.0 does not")
    assert_true(rb.column_arrow_type(0) == ArrowType.FLOAT64)
    var keys = rb.column_as_primitive[F64](0)
    assert_equal(
        bitcast[DType.uint64](keys.get(0)), nan_probe_bits, "the probe's NaN"
    )
    assert_equal(rb.column_as_primitive[I64](1).get(0), 10)
    assert_equal(keys.get(1), Float64(4.25))
    assert_equal(rb.column_as_primitive[I64](1).get(1), 20)


def test_unique_keys_give_one_row_per_matching_probe_row() raises:
    var st = Build(Table(KeyBundle1[I64]()))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, True))
    sb.add_field(Field(String("p0"), ArrowType.INT64, True))
    sb.add_field(Field(String("p1"), ArrowType.FLOAT64, True))
    sb.add_field(Field(String("p2"), ArrowType.STRING, True))
    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(_col[I64]([10, 20], [False, False]))
    rbb.add_column(_col[I64]([1, 2], [False, False]))
    rbb.add_column(_col[F64]([0.5, 1.5], [False, False]))
    var strs: List[String] = ["x", "y"]
    rbb.add_column(Column.from_string(StringArray.from_strings(strs)))
    var b = rbb.build(sb.build())
    _feed_all(st, batch_view_over(b))
    var owned = st.take_join_build_table()
    var t = owned^.take()
    assert_false(t.has_duplicate_keys)
    var pst = Probe(t^)
    var probe = _keys_batch([20, 30, 10, 20], [False, False, False, False])
    var rb = _run[JOIN_INNER](pst, batch_view_over(probe))
    assert_equal(rb.num_rows(), 3)
    var k = rb.column_as_primitive[I64](0)
    assert_equal(k.get(0), 20)
    assert_equal(k.get(1), 10)
    assert_equal(k.get(2), 20)
    assert_equal(rb.column_as_string(3).get(1), String("x"))
    # A batch without a match emits nothing for INNER.
    var none = _keys_batch([99], [False])
    var nbv = batch_view_over(none)
    assert_false(Bool(_try[JOIN_INNER](pst, nbv)))


comptime P2 = JoinProbeState[0, 1, KeyBundle2[I64, I64], PayloadSlot[I64]]


def _run2[
    join_t: Int, bo: Origin[mut=False]
](mut st: P2, bv: BatchView[bo]) raises -> RecordBatch:
    var out = st.probe_batch[bo, join_t](bv)
    assert_true(Bool(out), "rows were emitted")
    return out.take()


def test_two_column_key_needs_both_columns_to_match() raises:
    comptime B2 = JoinBuildState[
        0, 1, 1, KeyBundle2[I64, I64], PayloadSlot[I64]
    ]
    var st = B2(JoinBuildTable[KeyBundle2[I64, I64], PayloadSlot[I64]](
        KeyBundle2[I64, I64]()
    ))
    # (4, NULL) is not stored. Keys (1, 2) and (2, 1) are different.
    var build = RecordBatch.from_typed_columns_3(
        Schema.from_fields_3(
            Field("k0", I64, True), Field("k1", I64, True), Field("p", I64, True)
        ),
        _col[I64]([3, 1, 2, 4], [False, False, False, False]),
        _col[I64]([0, 2, 1, 0], [False, False, False, True]),
        _col[I64]([10, 20, 30, 40], [False, False, False, False]),
    )
    var bv = batch_view_over(build)
    for r in range(bv.n_rows()):
        st.feed_row(bv, r)
    var owned = st.take_join_build_table()
    var pst = P2(owned^.take())
    # Probe rows: match, NULL second, match, match, NULL first, (4, 0) whose
    # build row had a NULL second column, and the swapped (0, 3).
    var probe = RecordBatch.from_typed_columns_2(
        Schema.from_fields_2(Field("k0", I64, True), Field("k1", I64, True)),
        _col[I64]([3, 3, 1, 2, 0, 4, 0], [False, False, False, False, True, False, False]),
        _col[I64]([0, 0, 2, 1, 0, 0, 3], [False, True, False, False, False, False, False]),
    )
    var pv = batch_view_over(probe)

    var rb = _run2[JOIN_INNER](pst, pv)
    assert_equal(rb.num_rows(), 3, "only (3,0), (1,2) and (2,1) match")
    assert_equal(rb.column_as_primitive[I64](0).get(0), 3)
    assert_equal(rb.column_as_primitive[I64](1).get(0), 10)
    assert_equal(rb.column_as_primitive[I64](0).get(1), 1)
    assert_equal(rb.column_as_primitive[I64](1).get(1), 20)
    assert_equal(rb.column_as_primitive[I64](0).get(2), 2)
    assert_equal(rb.column_as_primitive[I64](1).get(2), 30)

    var lb = _run2[JOIN_LEFT](pst, pv)
    assert_equal(lb.num_rows(), 7, "every probe row once")
    assert_false(lb.column_at(1).is_null_at(0))
    assert_true(lb.column_at(1).is_null_at(1), "NULL second column: no match")
    assert_false(lb.column_at(0).is_null_at(1), "jkey is column 0, still valid")
    assert_equal(lb.column_as_primitive[I64](0).get(1), 3)
    assert_true(lb.column_at(0).is_null_at(4), "NULL first column: NULL jkey")
    assert_true(lb.column_at(1).is_null_at(4))
    assert_equal(lb.column_as_primitive[I64](0).get(5), 4)
    assert_true(lb.column_at(1).is_null_at(5), "(4, 0) was never stored")
    assert_true(lb.column_at(1).is_null_at(6), "(0, 3) is not (3, 0)")


def test_stubs() raises:
    var st = _probe_state()
    assert_equal(Probe.state_tag(), BREAKER_JOIN_PROBE)
    assert_equal(Probe.payload_arity(), 3)
    var probe = _keys_batch([1], [False])
    var bv = batch_view_over(probe)
    st.feed_row(bv, 0)
    assert_false(Bool(st.drain_to_record_batch()))
    with assert_raises(contains="not an ASOF_JOIN state"):
        _probe_asof(st, bv)
    var other = _probe_state()
    with assert_raises(contains="not merged"):
        st.combine(other^)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
