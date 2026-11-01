# =============================================================================
# test_join_build_state -- `JoinBuildState`, the JOIN_BUILD breaker state:
# what `feed_row` stores, what `combine` carries across, and the single take
# of the table
# =============================================================================
#
# The build batch is (k INT64, p0 INT64, p1 FLOAT64, p2 INT32, p3 STRING),
# with NULLs in the key and in payloads. What each test proves:
#   * `test_feed_stores_payloads_at_their_types`: every payload is stored at
#     its own type: an INT64 payload keeps all 64 bits (2^53 + 1 stays exact),
#     an INT32 payload is read as INT32, and a NULL payload stays NULL
#     instead of becoming 0 or "". A row with a NULL key is not inserted.
#   * `test_combine_carries_exact_payloads_and_nulls`: `combine` carries the
#     exact payload bits and every NULL of the folded-in side.
#   * `test_table_grows_and_keeps_rows`: 300 rows from 64 slots; every key
#     still finds its own payload after the rehashes. Every fifth row has
#     NULL INT64, FLOAT64, INT32 and STRING payloads, and they are still NULL
#     after the rehashes.
#   * `test_two_column_key_skips_a_null_in_either_column`: with a two-column
#     key, a row with a NULL in key column 0 or in key column 1 is not
#     inserted, so (3, NULL) never matches (3, 0); (1, 2) and (2, 1) are
#     different keys.
#   * `test_single_take_and_stubs`: the table moves out once; feeding,
#     taking or combining after that raises; the drain is None and the probe
#     entry points raise.
# =============================================================================

from std.memory import OwnedPointer
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
from komira_expr.stage_program import BREAKER_JOIN_BUILD

from komira_op_join_stage.join_build_state import JoinBuildState
from komira_op_join_stage.join_build_table import JoinBuildTable
from komira_op_join_stage.join_build_table_fns import (
    join_build_probe_1,
    join_build_probe_2,
    join_build_probe_all_slots_1,
)
from komira_op_join_stage.join_key_bundle import KeyBundle1, KeyBundle2
from komira_op_join_stage.join_payload_column import (
    PayloadCol_JoinString,
    PayloadSlot,
)


comptime I64 = DType.int64
comptime F64 = DType.float64
comptime I32 = DType.int32
comptime Table = JoinBuildTable[
    KeyBundle1[I64],
    PayloadSlot[I64],
    PayloadSlot[F64],
    PayloadSlot[I32],
    PayloadCol_JoinString,
]
comptime State = JoinBuildState[
    0,
    -1,
    4,
    KeyBundle1[I64],
    PayloadSlot[I64],
    PayloadSlot[F64],
    PayloadSlot[I32],
    PayloadCol_JoinString,
]

comptime BIG: Int64 = 9007199254740993  # 2^53 + 1: not a Float64


def _col[
    dt: DType
](values: List[Scalar[dt]], nulls: List[Bool]) raises -> Column[HeapRegion]:
    var a = PrimitiveArray[dt].allocate_nullable(len(values))
    for i in range(len(values)):
        a.set(i, values[i])
        if nulls[i]:
            a._set_null(i)
    return Column.from_primitive[dt](a^)


def _str_col(values: List[String], nulls: List[Bool]) raises -> Column[HeapRegion]:
    var valid = List[Bool]()
    for i in range(len(nulls)):
        valid.append(not nulls[i])
    return Column.from_string(StringArray.from_strings_with_validity(values, valid))


struct Rows(Movable):
    """Build rows; `*_null[i]` makes that cell NULL."""

    var k: List[Int64]
    var k_null: List[Bool]
    var p0: List[Int64]
    var p0_null: List[Bool]
    var p1: List[Float64]
    var p1_null: List[Bool]
    var p2: List[Int32]
    var p2_null: List[Bool]
    var p3: List[String]
    var p3_null: List[Bool]

    def __init__(out self):
        self.k = []
        self.k_null = []
        self.p0 = []
        self.p0_null = []
        self.p1 = []
        self.p1_null = []
        self.p2 = []
        self.p2_null = []
        self.p3 = []
        self.p3_null = []

    def add(
        mut self,
        k: Int64,
        p0: Int64,
        p1: Float64,
        p2: Int32,
        p3: String,
        k_null: Bool = False,
        p1_null: Bool = False,
        p3_null: Bool = False,
        p0_null: Bool = False,
        p2_null: Bool = False,
    ):
        self.k.append(k)
        self.k_null.append(k_null)
        self.p0.append(p0)
        self.p0_null.append(p0_null)
        self.p1.append(p1)
        self.p1_null.append(p1_null)
        self.p2.append(p2)
        self.p2_null.append(p2_null)
        self.p3.append(p3)
        self.p3_null.append(p3_null)

    def batch(self) raises -> RecordBatch:
        var sb = SchemaBuilder()
        sb.add_field(Field(String("k"), ArrowType.INT64, True))
        sb.add_field(Field(String("p0"), ArrowType.INT64, True))
        sb.add_field(Field(String("p1"), ArrowType.FLOAT64, True))
        sb.add_field(Field(String("p2"), ArrowType.INT32, True))
        sb.add_field(Field(String("p3"), ArrowType.STRING, True))
        var rbb = RecordBatchBuilder.with_capacity(5)
        rbb.add_column(_col[I64](self.k, self.k_null))
        rbb.add_column(_col[I64](self.p0, self.p0_null))
        rbb.add_column(_col[F64](self.p1, self.p1_null))
        rbb.add_column(_col[I32](self.p2, self.p2_null))
        rbb.add_column(_str_col(self.p3, self.p3_null))
        return rbb.build(sb.build())


def _feed_all[bo: Origin[mut=False]](mut st: State, bv: BatchView[bo]) raises:
    for r in range(bv.n_rows()):
        st.feed_row[bo](bv, r)


def _fed(rows: Rows) raises -> State:
    var st = State(Table(KeyBundle1[I64]()))
    var b = rows.batch()
    _feed_all(st, batch_view_over(b))
    return st^


def _taken(mut st: State) raises -> Table:
    var owned = st.take_join_build_table()
    return owned^.take()


def _sample() -> Rows:
    var rows = Rows()
    rows.add(1, BIG, 1.5, -7, "a")
    rows.add(2, -5, 0.0, 70000, "", p1_null=True, p3_null=True)
    rows.add(3, 9, 2.0, 1, "x", k_null=True)
    rows.add(2, 7, -0.25, 2, "bb")
    return rows^


def _check_sample(t: Table) raises:
    assert_equal(t.n_rows(), 3, "the NULL-key row is not inserted")
    assert_true(t.has_duplicate_keys, "key 2 twice")

    var s1 = join_build_probe_1(t, Int64(1))
    assert_true(s1 >= 0)
    assert_equal(t.payload[0].read_slot(s1), BIG, "INT64 payload, all bits")
    assert_equal(t.payload[1].read_slot(s1), Float64(1.5))
    assert_equal(t.payload[2].read_slot(s1), Int32(-7), "INT32 read as INT32")
    assert_equal(t.payload_str_at[3](s1), String("a"))
    assert_false(t.payload_is_null[1](s1))
    assert_false(t.payload_is_null[3](s1))

    var hits = List[Int]()
    join_build_probe_all_slots_1(t, Int64(2), hits)
    assert_equal(len(hits), 2)
    var seen_null_row = False
    var seen_value_row = False
    for i in range(len(hits)):
        var s = hits[i]
        if t.payload[0].read_slot(s) == -5:
            assert_true(t.payload_is_null[1](s), "FLOAT64 NULL kept")
            assert_true(t.payload_is_null[3](s), "STRING NULL kept")
            assert_equal(t.payload[2].read_slot(s), Int32(70000))
            seen_null_row = True
        else:
            assert_equal(t.payload[0].read_slot(s), Int64(7))
            assert_equal(t.payload[1].read_slot(s), Float64(-0.25))
            assert_false(t.payload_is_null[1](s))
            assert_equal(t.payload_str_at[3](s), String("bb"))
            seen_value_row = True
    assert_true(seen_null_row and seen_value_row)

    assert_equal(join_build_probe_1(t, Int64(3)), -1, "NULL key not inserted")


def test_feed_stores_payloads_at_their_types() raises:
    var st = _fed(_sample())
    var t = _taken(st)
    _check_sample(t)


def _copy_row(src: Rows, i: Int, mut dst: Rows):
    dst.add(
        src.k[i],
        src.p0[i],
        src.p1[i],
        src.p2[i],
        src.p3[i],
        src.k_null[i],
        src.p1_null[i],
        src.p3_null[i],
        src.p0_null[i],
        src.p2_null[i],
    )


def test_combine_carries_exact_payloads_and_nulls() raises:
    var all = _sample()
    var first = Rows()
    var second = Rows()
    # The side folded in (`second`) holds 2^53 + 1 and the NULL payloads, so
    # they cross through `copy_slot`.
    for i in range(len(all.k)):
        if i >= 2:
            _copy_row(all, i, first)
        else:
            _copy_row(all, i, second)
    var a = _fed(first)
    var b = _fed(second)
    a.combine(b^)
    var t = _taken(a)
    _check_sample(t)


def test_table_grows_and_keeps_rows() raises:
    # Every fifth row (from row 1, which lives through every growth) has all
    # four payloads NULL: INT64, FLOAT64, INT32 and STRING.
    var rows = Rows()
    for i in range(300):
        var n = i % 5 == 1
        rows.add(
            Int64(i * 7),
            BIG + Int64(i),
            Float64(i) + 0.5,
            Int32(-i),
            String(i),
            p1_null=n,
            p3_null=n,
            p0_null=n,
            p2_null=n,
        )
    var st = _fed(rows)
    var t = _taken(st)
    assert_equal(t.n_rows(), 300)
    assert_true(t.capacity() >= 512, "grew from 64 slots")
    assert_false(t.has_duplicate_keys)
    for i in range(300):
        var s = join_build_probe_1(t, Int64(i * 7))
        assert_true(s >= 0)
        if i % 5 == 1:
            assert_true(t.payload_is_null[0](s), "INT64 NULL survives rehash")
            assert_true(t.payload_is_null[1](s), "FLOAT64 NULL survives rehash")
            assert_true(t.payload_is_null[2](s), "INT32 NULL survives rehash")
            assert_true(t.payload_is_null[3](s), "STRING NULL survives rehash")
            continue
        assert_false(t.payload_is_null[0](s))
        assert_false(t.payload_is_null[1](s))
        assert_false(t.payload_is_null[2](s))
        assert_false(t.payload_is_null[3](s))
        assert_equal(t.payload[0].read_slot(s), BIG + Int64(i))
        assert_equal(t.payload[1].read_slot(s), Float64(i) + 0.5)
        assert_equal(t.payload[2].read_slot(s), Int32(-i))
        assert_equal(t.payload_str_at[3](s), String(i))


def test_two_column_key_skips_a_null_in_either_column() raises:
    comptime T2 = JoinBuildTable[KeyBundle2[I64, I64], PayloadSlot[I64]]
    comptime S2 = JoinBuildState[
        0, 1, 1, KeyBundle2[I64, I64], PayloadSlot[I64]
    ]
    var st = S2(T2(KeyBundle2[I64, I64]()))
    # Rows: (3, NULL) and (NULL, 5) are skipped; the others are kept.
    var b = RecordBatch.from_typed_columns_3(
        Schema.from_fields_3(
            Field("k0", I64, True), Field("k1", I64, True), Field("p", I64, True)
        ),
        _col[I64]([3, 3, 1, 2, 0], [False, False, False, False, True]),
        _col[I64]([0, 0, 2, 1, 5], [True, False, False, False, False]),
        _col[I64]([100, 101, 102, 103, 104], [False, False, False, False, False]),
    )
    var bv = batch_view_over(b)
    for r in range(bv.n_rows()):
        st.feed_row(bv, r)
    var owned = st.take_join_build_table()
    var t = owned^.take()
    assert_equal(t.n_rows(), 3, "both NULL-key rows are skipped")
    assert_false(t.has_duplicate_keys, "(3, NULL) was not stored as (3, 0)")
    var s30 = join_build_probe_2(t, Int64(3), Int64(0))
    assert_true(s30 >= 0)
    assert_equal(t.payload[0].read_slot(s30), Int64(101))
    var s12 = join_build_probe_2(t, Int64(1), Int64(2))
    var s21 = join_build_probe_2(t, Int64(2), Int64(1))
    assert_true(s12 >= 0 and s21 >= 0 and s12 != s21)
    assert_equal(t.payload[0].read_slot(s12), Int64(102))
    assert_equal(t.payload[0].read_slot(s21), Int64(103))
    assert_equal(join_build_probe_2(t, Int64(0), Int64(5)), -1, "NULL k0 skipped")


def _probe[bo: Origin[mut=False]](mut st: State, bv: BatchView[bo]) raises:
    _ = st.probe_batch[bo, 0](bv)


def _probe_asof[bo: Origin[mut=False]](mut st: State, bv: BatchView[bo]) raises:
    _ = st.probe_asof_batch[bo](bv)


def test_single_take_and_stubs() raises:
    var st = _fed(_sample())
    assert_equal(State.state_tag(), BREAKER_JOIN_BUILD)
    assert_equal(State.payload_arity(), 4)
    assert_false(Bool(st.drain_to_record_batch()), "the build emits nothing")
    var b = _sample().batch()
    var bv = batch_view_over(b)
    with assert_raises(contains="not a JOIN_PROBE state"):
        _probe(st, bv)
    with assert_raises(contains="not an ASOF_JOIN state"):
        _probe_asof(st, bv)

    _ = _taken(st)
    with assert_raises(contains="already taken"):
        _ = st.take_join_build_table()
    with assert_raises(contains="already taken"):
        st.feed_row(bv, 0)
    var other = _fed(_sample())
    with assert_raises(contains="already taken"):
        st.combine(other^)
    var fresh = _fed(_sample())
    var spent = _fed(_sample())
    _ = _taken(spent)
    with assert_raises(contains="already taken"):
        fresh.combine(spent^)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
