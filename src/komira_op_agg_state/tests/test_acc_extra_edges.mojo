# =============================================================================
# test_acc_extra_edges.mojo — the refusals and edge paths of the COUNT(*),
# MIN/MAX(Float64) and AVG accumulators (columnar_acc_typed_extra.mojo)
# =============================================================================
#
#   - a gid past `ensure_capacity` is refused by name on both update paths and
#     by merge_at on either side;
#   - merge_aligned refuses two columns of different lengths and is a no-op on
#     two empty ones;
#   - merge_aligned over 11 groups folds every group, the scalar tail after the
#     last full SIMD chunk included, and ORs the source's `seen` bits in (a
#     group seen only in the source must read as seen after the merge);
#   - MaxF64Acc.finalize answers None for an unseen group;
#   - flush_partial_to_column is finalize_to_column.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_op_agg_state.columnar_acc_typed_extra import (
    CountStarAcc, MinF64Acc, MaxF64Acc, AvgAcc,
)


comptime N_ALIGNED = 11


def _bytes_f64(mut vals: List[Float64]) -> Span[UInt8, origin_of(vals)]:
    return Span[UInt8, origin_of(vals)](
        unsafe_ptr=vals.unsafe_ptr().bitcast[UInt8](), length=len(vals) * 8
    )


def _expect(raised: Bool, got: String, want: String) raises:
    assert_true(raised, "expected a refusal: " + want)
    assert_equal(got, want)


def _iota(n: Int) -> List[Int]:
    var g: List[Int] = []
    for i in range(n):
        g.append(i)
    return g^


# =============================================================================
# CountStarAcc
# =============================================================================


def test_count_star_refusals_and_empty_merge() raises:
    var a = CountStarAcc.new()
    a.ensure_capacity(2)
    var g32: List[UInt32] = [UInt32(1), UInt32(2)]
    var msg = String("")
    var raised = False
    try:
        a.update_batch(Span(g32), 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "CountStarAcc.update_batch: gid out of range")
    assert_equal(a.state[1], Int64(1))

    var g: List[Int] = [0, 2]
    var v: List[Float64] = [Float64(0.0), Float64(0.0)]
    raised = False
    try:
        a.update_batch(Span(g), _bytes_f64(v), 0, 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "CountStarAcc.update_batch: gid out of range")
    assert_equal(a.state[0], Int64(1))

    var src = CountStarAcc.new()
    src.ensure_capacity(1)
    raised = False
    try:
        a.merge_at(2, src, 0)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "CountStarAcc.merge_at: dst_gid out of range")
    raised = False
    try:
        a.merge_at(0, src, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "CountStarAcc.merge_at: src_gid out of range")
    raised = False
    try:
        a.merge_aligned(src)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "CountStarAcc.merge_aligned: length mismatch (self=2, src=1)")

    var e1 = CountStarAcc.new()
    e1.merge_aligned(CountStarAcc.new())
    assert_equal(e1.num_groups(), 0)


def test_count_star_merge_aligned_folds_the_scalar_tail() raises:
    var dst = CountStarAcc.new()
    var src = CountStarAcc.new()
    dst.ensure_capacity(N_ALIGNED)
    src.ensure_capacity(N_ALIGNED)
    for i in range(N_ALIGNED):
        dst.state[i] = Int64(i)
        src.state[i] = Int64(1000 * (i + 1))
    dst.merge_aligned(src)
    for i in range(N_ALIGNED):
        assert_equal(dst.state[i], Int64(i + 1000 * (i + 1)), "group " + String(i))


# =============================================================================
# MinF64Acc
# =============================================================================


def test_min_f64_refusals_and_empty_merge() raises:
    var a = MinF64Acc.new()
    a.ensure_capacity(2)
    var g32: List[UInt32] = [UInt32(0), UInt32(3)]
    var v: List[Float64] = [Float64(2.5), Float64(-1.0)]
    var msg = String("")
    var raised = False
    try:
        a.update_batch(Span(g32), Span(v), 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MinF64Acc.update_batch: gid out of range")
    assert_equal(a.state[0], Float64(2.5))

    var g: List[Int] = [1, 2]
    raised = False
    try:
        a.update_batch(Span(g), _bytes_f64(v), 0, 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MinF64Acc.update_batch: gid out of range")

    var src = MinF64Acc.new()
    src.ensure_capacity(1)
    raised = False
    try:
        a.merge_at(2, src, 0)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MinF64Acc.merge_at: dst_gid out of range")
    raised = False
    try:
        a.merge_at(0, src, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MinF64Acc.merge_at: src_gid out of range")
    raised = False
    try:
        a.merge_aligned(src)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MinF64Acc.merge_aligned: length mismatch (self=2, src=1)")

    var e1 = MinF64Acc.new()
    e1.merge_aligned(MinF64Acc.new())
    assert_equal(e1.num_groups(), 0)


def test_min_f64_merge_aligned_tail_and_seen_bits() raises:
    """dst has seen only the even groups, src every group with a smaller
    value: after the merge every group is seen and holds src's value."""
    var dst = MinF64Acc.new()
    var src = MinF64Acc.new()
    dst.ensure_capacity(N_ALIGNED)
    src.ensure_capacity(N_ALIGNED)
    var dg: List[Int] = []
    var dv: List[Float64] = []
    for i in range(0, N_ALIGNED, 2):
        dg.append(i)
        dv.append(Float64(50 + i))
    dst.update_batch(Span(dg), _bytes_f64(dv), 0, len(dg))
    var sg = _iota(N_ALIGNED)
    var sv: List[Float64] = []
    for i in range(N_ALIGNED):
        sv.append(Float64(-0.5) - Float64(i))
    src.update_batch(Span(sg), _bytes_f64(sv), 0, N_ALIGNED)
    dst.merge_aligned(src)
    var fin = dst.finalize()
    for i in range(N_ALIGNED):
        assert_true(dst.seen[i], "group " + String(i) + " seen")
        assert_equal(fin[i].value(), Float64(-0.5) - Float64(i))
    var col = dst.flush_partial_to_column()
    var p = col._data.view_typed_ro[DType.float64]()
    assert_equal(p[N_ALIGNED - 1], Float64(-0.5) - Float64(N_ALIGNED - 1))


# =============================================================================
# MaxF64Acc
# =============================================================================


def test_max_f64_refusals_and_empty_merge() raises:
    var a = MaxF64Acc.new()
    a.ensure_capacity(2)
    var g32: List[UInt32] = [UInt32(1), UInt32(2)]
    var v: List[Float64] = [Float64(-2.5), Float64(1.0)]
    var msg = String("")
    var raised = False
    try:
        a.update_batch(Span(g32), Span(v), 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MaxF64Acc.update_batch: gid out of range")
    assert_equal(a.state[1], Float64(-2.5))

    var g: List[Int] = [0, 5]
    raised = False
    try:
        a.update_batch(Span(g), _bytes_f64(v), 0, 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MaxF64Acc.update_batch: gid out of range")

    var src = MaxF64Acc.new()
    src.ensure_capacity(1)
    raised = False
    try:
        a.merge_at(2, src, 0)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MaxF64Acc.merge_at: dst_gid out of range")
    raised = False
    try:
        a.merge_at(0, src, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MaxF64Acc.merge_at: src_gid out of range")
    raised = False
    try:
        a.merge_aligned(src)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MaxF64Acc.merge_aligned: length mismatch (self=2, src=1)")

    var e1 = MaxF64Acc.new()
    e1.merge_aligned(MaxF64Acc.new())
    assert_equal(e1.num_groups(), 0)


def test_max_f64_merge_aligned_tail_and_seen_bits() raises:
    var dst = MaxF64Acc.new()
    var src = MaxF64Acc.new()
    dst.ensure_capacity(N_ALIGNED)
    src.ensure_capacity(N_ALIGNED)
    var dg: List[Int] = []
    var dv: List[Float64] = []
    for i in range(1, N_ALIGNED, 2):
        dg.append(i)
        dv.append(Float64(-50 - i))
    dst.update_batch(Span(dg), _bytes_f64(dv), 0, len(dg))
    var sg = _iota(N_ALIGNED)
    var sv: List[Float64] = []
    for i in range(N_ALIGNED):
        sv.append(Float64(0.5) + Float64(i))
    src.update_batch(Span(sg), _bytes_f64(sv), 0, N_ALIGNED)
    dst.merge_aligned(src)
    var fin = dst.finalize()
    for i in range(N_ALIGNED):
        assert_true(dst.seen[i], "group " + String(i) + " seen")
        assert_equal(fin[i].value(), Float64(0.5) + Float64(i))
    var col = dst.flush_partial_to_column()
    assert_equal(col._data.view_typed_ro[DType.float64]()[N_ALIGNED - 1], Float64(0.5) + Float64(N_ALIGNED - 1))


def test_max_f64_finalize_answers_none_for_an_unseen_group() raises:
    var a = MaxF64Acc.new()
    a.ensure_capacity(3)
    var g: List[Int] = [0, 2]
    var v: List[Float64] = [Float64(4.0), Float64(-4.0)]
    a.update_batch(Span(g), _bytes_f64(v), 0, 2)
    var fin = a.finalize()
    assert_equal(len(fin), 3)
    assert_equal(fin[0].value(), Float64(4.0))
    assert_false(Bool(fin[1]))
    assert_equal(fin[2].value(), Float64(-4.0))


# =============================================================================
# AvgAcc
# =============================================================================


def test_avg_refusals() raises:
    var a = AvgAcc.new()
    a.ensure_capacity(2)
    var g32: List[UInt32] = [UInt32(0), UInt32(2)]
    var v: List[Float64] = [Float64(3.0), Float64(5.0)]
    var msg = String("")
    var raised = False
    try:
        a.update_batch(Span(g32), Span(v), 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "AvgAcc.update_batch: gid out of range")
    assert_equal(a.count[0], Int64(1))

    var g: List[Int] = [1, 4]
    raised = False
    try:
        a.update_batch(Span(g), _bytes_f64(v), 0, 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "AvgAcc.update_batch: gid out of range")
    assert_equal(a.count[1], Int64(1))

    var src = AvgAcc.new()
    src.ensure_capacity(1)
    raised = False
    try:
        a.merge_at(2, src, 0)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "AvgAcc.merge_at: dst_gid out of range")
    raised = False
    try:
        a.merge_at(0, src, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "AvgAcc.merge_at: src_gid out of range")
    raised = False
    try:
        a.merge_aligned(src)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "AvgAcc.merge_aligned: length mismatch (self=2, src=1)")


def test_avg_flush_partial_is_finalize() raises:
    var a = AvgAcc.new()
    a.ensure_capacity(2)
    var g: List[Int] = [0, 0, 1]
    var v: List[Float64] = [Float64(1.0), Float64(4.0), Float64(-6.0)]
    a.update_batch(Span(g), _bytes_f64(v), 0, 3)
    var col = a.flush_partial_to_column()
    var p = col._data.view_typed_ro[DType.float64]()
    assert_equal(p[0], Float64(2.5))
    assert_equal(p[1], Float64(-6.0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
