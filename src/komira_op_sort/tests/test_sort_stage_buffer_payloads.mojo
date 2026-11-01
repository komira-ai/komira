# =============================================================================
# SortBuffer with two keys (INT64, INT32) and three payloads of mixed DTypes
# (INT64, FLOAT64, INT32): feed, sort, read back, drain, and combine
# =============================================================================
#
# The payloads ride the keys' order cell for cell; a DESC primary key reverses
# the primary order and keeps the secondary ascending; combining two buffers
# drains the rows of one buffer fed both inputs in order.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_op_sort.sort_stage_buffer import SortBuffer, SortKeyBlock
from komira_op_sort.sort_stage_columns import (
    SORT_DIR_ASC_U8,
    SORT_DIR_DESC_U8,
    SortKeyColumn_Typed,
)
from komira_op_sort.sort_stage_payloads import PayloadCol_Typed


# 2 keys (i64 @0, i32 @1) + 3 mixed payloads (i64 @0, f64 @1, i32 @2). Column
# indices are sentinel (this test appends pre-extracted values, never feeds from
# a batch).
comptime _K0 = SortKeyColumn_Typed[DType.int64, 0]
comptime _K1 = SortKeyColumn_Typed[DType.int32, 1]
comptime _KB = SortKeyBlock[_K0, _K1]
comptime _P0 = PayloadCol_Typed[DType.int64, 0]
comptime _P1 = PayloadCol_Typed[DType.float64, 1]
comptime _P2 = PayloadCol_Typed[DType.int32, 2]
comptime _Buf = SortBuffer[_KB, _P0, _P1, _P2]


def _new_buffer(dir0: UInt8, dir1: UInt8) -> _Buf:
    var buf = _Buf(
        _KB((_K0.new(16), _K1.new(16))),
        (_P0.new(16), _P1.new(16), _P2.new(16)),
        initial_capacity=16,
    )
    buf.set_direction(0, dir0)
    buf.set_direction(1, dir1)
    return buf^


def _feed_one(
    mut buf: _Buf,
    k0: Int64,
    k1: Int32,
    p0: Int64,
    p1: Float64,
    p2: Int32,
):
    buf.append_key[0, DType.int64](k0)
    buf.append_key[1, DType.int32](k1)
    buf.append_payload[0, DType.int64](p0)
    buf.append_payload[1, DType.float64](p1)
    buf.append_payload[2, DType.int32](p2)
    buf.commit_row()


# The fixture. Deliberately includes:
#   * a duplicate (k0, k1) TIE: rows (5, 2) at p0=100 and p0=400 — stable sort
#     must keep them in buffer order.
#   * negative + zero key values.
#   * a unique f64 payload per row so the drain's f64 column is checkable.
def _feed_fixture(mut buf: _Buf):
    # (k0, k1, p0, p1, p2)
    _feed_one(buf, Int64(5), Int32(2), Int64(100), Float64(1.5), Int32(11))
    _feed_one(buf, Int64(-3), Int32(9), Int64(101), Float64(2.5), Int32(12))
    _feed_one(buf, Int64(5), Int32(1), Int64(102), Float64(3.5), Int32(13))
    _feed_one(buf, Int64(0), Int32(-4), Int64(103), Float64(4.5), Int32(14))
    _feed_one(buf, Int64(5), Int32(2), Int64(400), Float64(5.5), Int32(15))  # tie
    _feed_one(buf, Int64(-3), Int32(0), Int64(105), Float64(6.5), Int32(16))


comptime _FIXTURE_N: Int = 6


# Expected ASC/ASC lexicographic order on (k0, k1):
#   (-3,0,p=105) (-3,9,p=101) (0,-4,p=103) (5,1,p=102) (5,2,p=100) (5,2,p=400)
#   tie (5,2): p0=100 (buffer row 0) before p0=400 (buffer row 4) — stable.
def _exp_k0_asc() -> List[Int64]:
    return [Int64(-3), Int64(-3), Int64(0), Int64(5), Int64(5), Int64(5)]


def _exp_k1_asc() -> List[Int32]:
    return [Int32(0), Int32(9), Int32(-4), Int32(1), Int32(2), Int32(2)]


def _exp_p0_asc() -> List[Int64]:
    return [Int64(105), Int64(101), Int64(103), Int64(102), Int64(100), Int64(400)]


def _exp_p1_asc() -> List[Float64]:
    return [
        Float64(6.5),
        Float64(2.5),
        Float64(4.5),
        Float64(3.5),
        Float64(1.5),
        Float64(5.5),
    ]


def _exp_p2_asc() -> List[Int32]:
    return [Int32(16), Int32(12), Int32(14), Int32(13), Int32(11), Int32(15)]


# =============================================================================
# §1 — feed -> sort_in_place -> per-row read (ASC)
# =============================================================================


def test_widened_feed_sort_read_asc() raises:
    """ASC/ASC: feed 6 rows, sort_in_place, read keys + all 3 payloads per row in
    sorted order. Proves the 2-key lex comparator + the mixed-DType payload pack
    round-trip (i64 + f64 + i32) bit-exactly."""
    var buf = _new_buffer(SORT_DIR_ASC_U8, SORT_DIR_ASC_U8)
    _feed_fixture(buf)
    assert_equal(buf.size(), _FIXTURE_N, "fixture row count")

    buf.sort_in_place()

    var ek0 = _exp_k0_asc()
    var ek1 = _exp_k1_asc()
    var ep0 = _exp_p0_asc()
    var ep1 = _exp_p1_asc()
    var ep2 = _exp_p2_asc()
    for pos in range(_FIXTURE_N):
        var row = buf.ordered_row(pos)
        assert_equal(buf.key_at[0, DType.int64](row), ek0[pos], "k0 @" + String(pos))
        assert_equal(buf.key_at[1, DType.int32](row), ek1[pos], "k1 @" + String(pos))
        assert_equal(
            buf.payload_at[0, DType.int64](row), ep0[pos], "p0 @" + String(pos)
        )
        assert_equal(
            buf.payload_at[1, DType.float64](row), ep1[pos], "p1 @" + String(pos)
        )
        assert_equal(
            buf.payload_at[2, DType.int32](row), ep2[pos], "p2 @" + String(pos)
        )


# =============================================================================
# §2 — drain_to_record_batch full-frame schema + values (ASC)
# =============================================================================


def test_widened_drain_full_frame_asc() raises:
    """ASC/ASC drain emits a 5-column RecordBatch (k0 i64, k1 i32, p0 i64, p1
    f64, p2 i32) with rows in sorted order — the full-frame schema the *Payloads
    widening unlocks (OLD shape could emit at most key(s) + ONE i64 payload)."""
    var buf = _new_buffer(SORT_DIR_ASC_U8, SORT_DIR_ASC_U8)
    _feed_fixture(buf)

    var rb_opt = buf.drain_to_record_batch()
    assert_true(rb_opt.__bool__(), "drain produced a batch")
    var rb = rb_opt.take()

    assert_equal(rb.num_rows(), _FIXTURE_N, "drain row count")
    assert_equal(rb.num_columns(), 5, "k0,k1,p0,p1,p2 = 5 cols")

    var c_k0 = rb.column_as_primitive_int64(0)
    var c_k1 = rb.column_as_primitive_int32(1)
    var c_p0 = rb.column_as_primitive_int64(2)
    var c_p1 = rb.column_as_primitive_float64(3)
    var c_p2 = rb.column_as_primitive_int32(4)

    var ek0 = _exp_k0_asc()
    var ek1 = _exp_k1_asc()
    var ep0 = _exp_p0_asc()
    var ep1 = _exp_p1_asc()
    var ep2 = _exp_p2_asc()
    for r in range(_FIXTURE_N):
        assert_equal(c_k0.load[1](r)[0], ek0[r], "drain k0 @" + String(r))
        assert_equal(c_k1.load[1](r)[0], ek1[r], "drain k1 @" + String(r))
        assert_equal(c_p0.load[1](r)[0], ep0[r], "drain p0 @" + String(r))
        assert_equal(c_p1.load[1](r)[0], ep1[r], "drain p1 @" + String(r))
        assert_equal(c_p2.load[1](r)[0], ep2[r], "drain p2 @" + String(r))


# =============================================================================
# §3 — DESC on the primary key
# =============================================================================


def test_widened_drain_desc_primary() raises:
    """DESC primary (k0), ASC secondary (k1): the per-key runtime direction is
    honored. Expected order: (5,1) (5,2)x2 (0,-4) (-3,0) (-3,9). The (5,2) tie
    stays stable (p0=100 before p0=400)."""
    var buf = _new_buffer(SORT_DIR_DESC_U8, SORT_DIR_ASC_U8)
    _feed_fixture(buf)

    var rb_opt = buf.drain_to_record_batch()
    var rb = rb_opt.take()
    assert_equal(rb.num_rows(), _FIXTURE_N)
    assert_equal(rb.num_columns(), 5)

    var c_k0 = rb.column_as_primitive_int64(0)
    var c_k1 = rb.column_as_primitive_int32(1)
    var c_p0 = rb.column_as_primitive_int64(2)
    # DESC k0, ASC k1: 5 before 0 before -3; within k0=5 ASC k1: 1,2,2;
    # within k0=-3 ASC k1: 0,9.
    var ek0: List[Int64] = [
        Int64(5), Int64(5), Int64(5), Int64(0), Int64(-3), Int64(-3)
    ]
    var ek1: List[Int32] = [
        Int32(1), Int32(2), Int32(2), Int32(-4), Int32(0), Int32(9)
    ]
    var ep0: List[Int64] = [
        Int64(102), Int64(100), Int64(400), Int64(103), Int64(105), Int64(101)
    ]
    for r in range(_FIXTURE_N):
        assert_equal(c_k0.load[1](r)[0], ek0[r], "desc k0 @" + String(r))
        assert_equal(c_k1.load[1](r)[0], ek1[r], "desc k1 @" + String(r))
        assert_equal(c_p0.load[1](r)[0], ep0[r], "desc p0 @" + String(r))


# =============================================================================
# §4 — cross-worker combine equivalence (multi-segment == single-segment ref)
# =============================================================================


def _feed_range(mut buf: _Buf, lo: Int, hi: Int):
    """Feed fixture rows [lo, hi) into `buf`."""
    var k0: List[Int64] = [
        Int64(5), Int64(-3), Int64(5), Int64(0), Int64(5), Int64(-3)
    ]
    var k1: List[Int32] = [
        Int32(2), Int32(9), Int32(1), Int32(-4), Int32(2), Int32(0)
    ]
    var p0: List[Int64] = [
        Int64(100), Int64(101), Int64(102), Int64(103), Int64(400), Int64(105)
    ]
    var p1: List[Float64] = [
        Float64(1.5),
        Float64(2.5),
        Float64(3.5),
        Float64(4.5),
        Float64(5.5),
        Float64(6.5),
    ]
    var p2: List[Int32] = [
        Int32(11), Int32(12), Int32(13), Int32(14), Int32(15), Int32(16)
    ]
    for r in range(lo, hi):
        _feed_one(buf, k0[r], k1[r], p0[r], p1[r], p2[r])


def test_widened_combine_equiv() raises:
    """Split-then-combine == single feed. Feed all 6 rows into `single`; feed
    [0,3) into A and [3,6) into B then `A.combine(B^)`. Both drains MUST be
    logically identical — same keys, all 3 payloads, same order (incl. the
    (5,2) tie, which the concatenation preserves in buffer order)."""
    var single = _new_buffer(SORT_DIR_ASC_U8, SORT_DIR_ASC_U8)
    _feed_range(single, 0, _FIXTURE_N)
    var single_opt = single.drain_to_record_batch()
    var single_rb = single_opt.take()

    var a = _new_buffer(SORT_DIR_ASC_U8, SORT_DIR_ASC_U8)
    _feed_range(a, 0, 3)
    var b = _new_buffer(SORT_DIR_ASC_U8, SORT_DIR_ASC_U8)
    _feed_range(b, 3, _FIXTURE_N)
    a.combine(b^)
    var combined_opt = a.drain_to_record_batch()
    var combined_rb = combined_opt.take()

    assert_equal(
        single_rb.num_rows(), combined_rb.num_rows(), "combine row count"
    )
    assert_equal(single_rb.num_columns(), 5, "single 5 cols")
    assert_equal(combined_rb.num_columns(), 5, "combined 5 cols")

    var s_k0 = single_rb.column_as_primitive_int64(0)
    var c_k0 = combined_rb.column_as_primitive_int64(0)
    var s_k1 = single_rb.column_as_primitive_int32(1)
    var c_k1 = combined_rb.column_as_primitive_int32(1)
    var s_p0 = single_rb.column_as_primitive_int64(2)
    var c_p0 = combined_rb.column_as_primitive_int64(2)
    var s_p1 = single_rb.column_as_primitive_float64(3)
    var c_p1 = combined_rb.column_as_primitive_float64(3)
    var s_p2 = single_rb.column_as_primitive_int32(4)
    var c_p2 = combined_rb.column_as_primitive_int32(4)
    for r in range(single_rb.num_rows()):
        assert_equal(s_k0.load[1](r)[0], c_k0.load[1](r)[0], "combine k0 @" + String(r))
        assert_equal(s_k1.load[1](r)[0], c_k1.load[1](r)[0], "combine k1 @" + String(r))
        assert_equal(s_p0.load[1](r)[0], c_p0.load[1](r)[0], "combine p0 @" + String(r))
        assert_equal(s_p1.load[1](r)[0], c_p1.load[1](r)[0], "combine p1 @" + String(r))
        assert_equal(s_p2.load[1](r)[0], c_p2.load[1](r)[0], "combine p2 @" + String(r))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
