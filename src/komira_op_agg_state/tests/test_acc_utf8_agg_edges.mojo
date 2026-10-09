# =============================================================================
# test_acc_utf8_agg_edges.mojo — the refusals and edge paths of the UTF-8
# MIN/MAX, PERCENTILE and COUNT(DISTINCT) accumulators
# =============================================================================
#
#   MinUtf8Acc / MaxUtf8Acc   gid refusals on update and merge_at, the length
#                             refusal of merge_aligned, the raw-pointer trait
#                             update refused by name, merge_at into an unseen
#                             destination, a later better value replacing an
#                             earlier one on every path, and finalize_to_column
#                             carrying each seen group's string.
#   PercentileAcc             gid refusals, merge_at of an unseen source is a
#                             no-op, the readback of an out-of-range gid and of
#                             a group marked seen with no values is None, the
#                             interpolation's upper neighbour is the SMALLEST
#                             value above the k-th (quickselect leaves the
#                             right side unsorted), and finalize_to_column /
#                             flush_partial carry the per-group answers.
#   CountDistinctAcc          gid refusals on both update paths and merge_at.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_op_agg_state.columnar_acc_utf8 import MinUtf8Acc, MaxUtf8Acc
from komira_op_agg_state.columnar_acc_agg import PercentileAcc, CountDistinctAcc


def _bytes_f64(mut vals: List[Float64]) -> Span[UInt8, origin_of(vals)]:
    return Span[UInt8, origin_of(vals)](
        unsafe_ptr=vals.unsafe_ptr().bitcast[UInt8](), length=len(vals) * 8
    )


def _bytes_i64(mut vals: List[Int64]) -> Span[UInt8, origin_of(vals)]:
    return Span[UInt8, origin_of(vals)](
        unsafe_ptr=vals.unsafe_ptr().bitcast[UInt8](), length=len(vals) * 8
    )


def _expect(raised: Bool, got: String, want: String) raises:
    assert_true(raised, "expected a refusal: " + want)
    assert_equal(got, want)


# =============================================================================
# MinUtf8Acc
# =============================================================================


def test_min_utf8_refusals() raises:
    var a = MinUtf8Acc.new()
    a.ensure_capacity(2)
    assert_equal(a.num_groups(), 2)
    var g: List[UInt32] = [UInt32(1), UInt32(2)]
    var v: List[String] = ["m", "n"]
    var msg = String("")
    var raised = False
    try:
        a.update_batch(g, v, 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MinUtf8Acc.update_batch: gid out of range")
    assert_equal(a.state[1].value(), "m")

    var src = MinUtf8Acc.new()
    src.ensure_capacity(1)
    raised = False
    try:
        a.merge_at(2, src, 0)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MinUtf8Acc.merge_at: dst_gid out of range")
    raised = False
    try:
        a.merge_at(0, src, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MinUtf8Acc.merge_at: src_gid out of range")
    raised = False
    try:
        a.merge_aligned(src)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MinUtf8Acc.merge_aligned: length mismatch (self=2, src=1)")

    var gi: List[Int] = [0]
    var bytes: List[Float64] = [Float64(0.0)]
    raised = False
    try:
        a.update_batch(Span(gi), _bytes_f64(bytes), 0, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MinUtf8Acc: raw-pointer update_batch not supported for UTF8; use typed path")


def test_min_utf8_merges_and_column() raises:
    var src = MinUtf8Acc.new()
    src.ensure_capacity(3)
    var sg: List[UInt32] = [UInt32(0), UInt32(1)]
    var sv: List[String] = ["cherry", "apple"]
    src.update_batch(sg, sv, 2)
    # merge_at into an unseen destination takes the source value.
    var a = MinUtf8Acc.new()
    a.ensure_capacity(3)
    a.merge_at(2, src, 0)
    assert_equal(a.state[2].value(), "cherry")
    # merge_aligned: dst g0 "date" > src "cherry" -> replaced; g1 "aa" < "apple"
    # stays; g2 "cherry" vs src unseen g2 stays.
    var dg: List[UInt32] = [UInt32(0), UInt32(1)]
    var dv: List[String] = ["date", "aa"]
    a.update_batch(dg, dv, 2)
    a.merge_aligned(src)
    assert_equal(a.state[0].value(), "cherry")
    assert_equal(a.state[1].value(), "aa")
    assert_equal(a.state[2].value(), "cherry")
    var col = a.finalize_to_column()
    assert_equal(col.length(), 3)
    var fl = a.flush_partial_to_column()
    assert_equal(fl.length(), 3)
    var arr = fl.as_string()
    assert_equal(arr.get(0), "cherry")
    assert_equal(arr.get(1), "aa")
    assert_equal(arr.get(2), "cherry")


# =============================================================================
# MaxUtf8Acc
# =============================================================================


def test_max_utf8_refusals() raises:
    var a = MaxUtf8Acc.new()
    a.ensure_capacity(2)
    assert_equal(a.num_groups(), 2)
    var g: List[UInt32] = [UInt32(0), UInt32(3)]
    var v: List[String] = ["m", "n"]
    var msg = String("")
    var raised = False
    try:
        a.update_batch(g, v, 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MaxUtf8Acc.update_batch: gid out of range")
    assert_equal(a.state[0].value(), "m")

    var src = MaxUtf8Acc.new()
    src.ensure_capacity(1)
    raised = False
    try:
        a.merge_at(2, src, 0)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MaxUtf8Acc.merge_at: dst_gid out of range")
    raised = False
    try:
        a.merge_at(0, src, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MaxUtf8Acc.merge_at: src_gid out of range")
    raised = False
    try:
        a.merge_aligned(src)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MaxUtf8Acc.merge_aligned: length mismatch (self=2, src=1)")

    var gi: List[Int] = [0]
    var bytes: List[Float64] = [Float64(0.0)]
    raised = False
    try:
        a.update_batch(Span(gi), _bytes_f64(bytes), 0, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MaxUtf8Acc: raw-pointer update_batch not supported for UTF8; use typed path")


def test_max_utf8_later_larger_value_replaces() raises:
    var a = MaxUtf8Acc.new()
    a.ensure_capacity(3)
    # g0: "b" then "c" (replaces) then "a" (does not).
    var g: List[UInt32] = [UInt32(0), UInt32(0), UInt32(0), UInt32(1)]
    var v: List[String] = ["b", "c", "a", "k"]
    a.update_batch(g, v, 4)
    assert_equal(a.state[0].value(), "c")
    var src = MaxUtf8Acc.new()
    src.ensure_capacity(3)
    var sg: List[UInt32] = [UInt32(0), UInt32(1), UInt32(2)]
    var sv: List[String] = ["d", "j", "x"]
    src.update_batch(sg, sv, 3)
    # merge_aligned: g0 "d" > "c" replaces, g1 "j" < "k" stays, g2 unseen
    # dst takes "x".
    a.merge_aligned(src)
    assert_equal(a.state[0].value(), "d")
    assert_equal(a.state[1].value(), "k")
    assert_equal(a.state[2].value(), "x")
    var col = a.finalize_to_column()
    assert_equal(col.length(), 3)
    var fl = a.flush_partial_to_column()
    var arr = fl.as_string()
    assert_equal(arr.get(0), "d")
    assert_equal(arr.get(1), "k")
    assert_equal(arr.get(2), "x")


# =============================================================================
# PercentileAcc
# =============================================================================


def test_percentile_refusals_and_unseen_merge() raises:
    var a = PercentileAcc.new(0.5)
    a.ensure_capacity(2)
    assert_equal(a.num_groups(), 2)
    var g32: List[UInt32] = [UInt32(0), UInt32(2)]
    var v: List[Float64] = [Float64(1.0), Float64(2.0)]
    var msg = String("")
    var raised = False
    try:
        a.update_batch(Span(g32), Span(v), 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "PercentileAcc.update_batch: gid out of range")
    assert_true(a.seen[0])

    var src = PercentileAcc.new(0.5)
    src.ensure_capacity(1)
    raised = False
    try:
        a.merge_at(2, src, 0)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "PercentileAcc.merge_at: dst_gid out of range")
    raised = False
    try:
        a.merge_at(0, src, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "PercentileAcc.merge_at: src_gid out of range")
    # src gid 0 is unseen: merging it leaves the unseen dst gid 1 unseen.
    a.merge_at(1, src, 0)
    assert_false(a.seen[1])
    assert_equal(len(a.values[1]), 0)


def test_percentile_trait_update_refuses_an_out_of_range_gid() raises:
    var a = PercentileAcc.new(0.5)
    a.ensure_capacity(1)
    var g: List[Int] = [0, 1]
    var v: List[Float64] = [Float64(6.0), Float64(7.0)]
    var msg = String("")
    var raised = False
    try:
        a.update_batch(Span(g), _bytes_f64(v), 0, 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "PercentileAcc.update_batch: gid out of range")
    assert_equal(len(a.values[0]), 1)


def test_utf8_columns_keep_one_row_per_group_with_unseen_groups() raises:
    """An unseen group still takes a row, so the seen groups after it stay at
    their own index (the placeholder's value is not asserted)."""
    var mn = MinUtf8Acc.new()
    var mx = MaxUtf8Acc.new()
    mn.ensure_capacity(3)
    mx.ensure_capacity(3)
    var g: List[UInt32] = [UInt32(0), UInt32(2)]
    var v: List[String] = ["first", "last"]
    mn.update_batch(g, v, 2)
    mx.update_batch(g, v, 2)
    var c1 = mn.finalize_to_column()
    var c2 = mx.finalize_to_column()
    assert_equal(c1.length(), 3)
    assert_equal(c2.length(), 3)
    var a1 = c1.as_string()
    var a2 = c2.as_string()
    assert_equal(a1.get(0), "first")
    assert_equal(a1.get(2), "last")
    assert_equal(a2.get(0), "first")
    assert_equal(a2.get(2), "last")


def test_percentile_readback_guards() raises:
    var a = PercentileAcc.new(0.5)
    a.ensure_capacity(1)
    assert_false(Bool(a._finalize_one(5)), "out of range gid -> None")
    # A group flagged seen with no values (a state no update produces) still
    # answers None rather than reading an empty list.
    a.seen[0] = True
    assert_false(Bool(a._finalize_one(0)))


def test_percentile_upper_neighbour_is_the_smallest_above_k() raises:
    # {1, 2, 4, 3}, q = 0.5: k = 1, frac = 0.5. Quickselect leaves 4 at index
    # 2 and 3 at index 3; the answer interpolates 2 and 3 = 2.5 (not 3.0).
    var a = PercentileAcc.new(0.5)
    a.ensure_capacity(2)
    var g: List[UInt32] = [UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(1)]
    var v: List[Float64] = [Float64(1.0), Float64(2.0), Float64(4.0), Float64(3.0), Float64(9.0)]
    a.update_batch(Span(g), Span(v), 5)
    assert_equal(a._finalize_one(0).value(), Float64(2.5))
    var col = a.finalize_to_column()
    var p = col._data.view_typed_ro[DType.float64]()
    assert_equal(col.length(), 2)
    assert_equal(p[0], Float64(2.5))
    assert_equal(p[1], Float64(9.0))
    var fl = a.flush_partial_to_column()
    assert_equal(fl._data.view_typed_ro[DType.float64]()[0], Float64(2.5))


# =============================================================================
# CountDistinctAcc
# =============================================================================


def test_count_distinct_refusals() raises:
    var a = CountDistinctAcc.new()
    a.ensure_capacity(2)
    var g32: List[UInt32] = [UInt32(1), UInt32(2)]
    var v: List[Int64] = [Int64(7), Int64(8)]
    var msg = String("")
    var raised = False
    try:
        a.update_batch(Span(g32), Span(v), 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "CountDistinctAcc.update_batch: gid out of range")
    assert_equal(len(a.buffers[1]), 1)

    var g: List[Int] = [0, 4]
    raised = False
    try:
        a.update_batch(Span(g), _bytes_i64(v), 0, 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "CountDistinctAcc.update_batch: gid out of range")
    assert_equal(len(a.buffers[0]), 1)

    var src = CountDistinctAcc.new()
    src.ensure_capacity(1)
    raised = False
    try:
        a.merge_at(2, src, 0)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "CountDistinctAcc.merge_at: dst_gid out of range")
    raised = False
    try:
        a.merge_at(0, src, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "CountDistinctAcc.merge_at: src_gid out of range")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
