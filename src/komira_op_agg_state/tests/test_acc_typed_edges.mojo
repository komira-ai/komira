# =============================================================================
# test_acc_typed_edges.mojo — the refusals and edge paths of the Int64 and
# Kahan Float64 SoA accumulators (columnar_acc_typed.mojo)
# =============================================================================
#
# For SumI64Acc, CountI64Acc, MinI64Acc, MaxI64Acc and SumF64KahanAcc:
#
#   - a gid past `ensure_capacity` is refused by name on BOTH update paths
#     (the typed UInt32-gid one and the trait Int-gid one), and by merge_at on
#     either side; nothing is written before the refusal;
#   - merge_aligned refuses two columns of different lengths and is a no-op on
#     two empty ones;
#   - merge_aligned over 11 groups (a SIMD body plus a scalar tail for any
#     lane width 2, 4 or 8) folds EVERY group, the tail included;
#   - MaxI64Acc.merge_at skips an unseen source group (it must not stamp the
#     sentinel into a seen destination);
#   - flush_partial_to_column is finalize_to_column for these kinds.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_op_agg_state.columnar_acc_typed import (
    SumI64Acc, CountI64Acc, MinI64Acc, MaxI64Acc, SumF64KahanAcc,
)


comptime N_ALIGNED = 11


def _bytes_i64(mut vals: List[Int64]) -> Span[UInt8, origin_of(vals)]:
    return Span[UInt8, origin_of(vals)](
        unsafe_ptr=vals.unsafe_ptr().bitcast[UInt8](), length=len(vals) * 8
    )


def _bytes_f64(mut vals: List[Float64]) -> Span[UInt8, origin_of(vals)]:
    return Span[UInt8, origin_of(vals)](
        unsafe_ptr=vals.unsafe_ptr().bitcast[UInt8](), length=len(vals) * 8
    )


def _expect(raised: Bool, got: String, want: String) raises:
    assert_true(raised, "expected a refusal: " + want)
    assert_equal(got, want)


# =============================================================================
# SumI64Acc
# =============================================================================


def test_sum_i64_refuses_out_of_range_gids() raises:
    var a = SumI64Acc.new()
    a.ensure_capacity(2)
    var g32: List[UInt32] = [UInt32(1), UInt32(2)]
    var v: List[Int64] = [Int64(5), Int64(6)]
    var msg = String("")
    var raised = False
    try:
        a.update_batch(Span(g32), Span(v), 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "SumI64Acc.update_batch: gid out of range — caller must ensure_capacity first")
    # Row 0 (gid 1) was applied before the refusal; gid 0 is untouched.
    assert_equal(a.state[1], Int64(5))
    assert_equal(a.state[0], Int64(0))

    var g: List[Int] = [0, 2]
    raised = False
    try:
        a.update_batch(Span(g), _bytes_i64(v), 0, 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "SumI64Acc.update_batch: gid out of range")

    var src = SumI64Acc.new()
    src.ensure_capacity(1)
    raised = False
    try:
        a.merge_at(2, src, 0)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "SumI64Acc.merge_at: dst_gid out of range")
    raised = False
    try:
        a.merge_at(0, src, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "SumI64Acc.merge_at: src_gid out of range")


def test_sum_i64_flush_partial_is_finalize() raises:
    var a = SumI64Acc.new()
    a.ensure_capacity(2)
    a.state[0] = 7
    a.state[1] = -9
    var col = a.flush_partial_to_column()
    var p = col._data.view_typed_ro[DType.int64]()
    assert_equal(col.length(), 2)
    assert_equal(p[0], Int64(7))
    assert_equal(p[1], Int64(-9))


# =============================================================================
# CountI64Acc
# =============================================================================


def test_count_i64_refusals_and_empty_merge() raises:
    var a = CountI64Acc.new()
    a.ensure_capacity(2)
    assert_equal(a.num_groups(), 2)
    var g32: List[UInt32] = [UInt32(0), UInt32(5)]
    var msg = String("")
    var raised = False
    try:
        a.update_batch(Span(g32), 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "CountI64Acc.update_batch: gid out of range")
    assert_equal(a.state[0], Int64(1))

    var g: List[Int] = [1, 3]
    var v: List[Int64] = [Int64(0), Int64(0)]
    raised = False
    try:
        a.update_batch(Span(g), _bytes_i64(v), 0, 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "CountI64Acc.update_batch: gid out of range")
    assert_equal(a.state[1], Int64(1))

    var src = CountI64Acc.new()
    src.ensure_capacity(1)
    raised = False
    try:
        a.merge_at(2, src, 0)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "CountI64Acc.merge_at: dst_gid out of range")
    raised = False
    try:
        a.merge_at(0, src, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "CountI64Acc.merge_at: src_gid out of range")
    raised = False
    try:
        a.merge_aligned(src)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "CountI64Acc.merge_aligned: length mismatch (self=2, src=1)")

    var e1 = CountI64Acc.new()
    var e2 = CountI64Acc.new()
    e1.merge_aligned(e2)
    assert_equal(e1.num_groups(), 0)


def test_count_i64_flush_partial_is_finalize() raises:
    var a = CountI64Acc.new()
    a.ensure_capacity(3)
    var g32: List[UInt32] = [UInt32(2), UInt32(2), UInt32(0)]
    a.update_batch(Span(g32), 3)
    var col = a.flush_partial_to_column()
    var p = col._data.view_typed_ro[DType.int64]()
    assert_equal(p[0], Int64(1))
    assert_equal(p[1], Int64(0))
    assert_equal(p[2], Int64(2))


# =============================================================================
# MinI64Acc
# =============================================================================


def test_min_i64_refusals_and_empty_merge() raises:
    var a = MinI64Acc.new()
    a.ensure_capacity(2)
    assert_equal(a.num_groups(), 2)
    var g32: List[UInt32] = [UInt32(0), UInt32(2)]
    var v: List[Int64] = [Int64(-4), Int64(8)]
    var msg = String("")
    var raised = False
    try:
        a.update_batch(Span(g32), Span(v), 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MinI64Acc.update_batch: gid out of range")
    assert_true(a.seen[0])
    assert_false(a.seen[1])

    var g: List[Int] = [1, 9]
    raised = False
    try:
        a.update_batch(Span(g), _bytes_i64(v), 0, 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MinI64Acc.update_batch: gid out of range")

    var src = MinI64Acc.new()
    src.ensure_capacity(1)
    raised = False
    try:
        a.merge_at(2, src, 0)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MinI64Acc.merge_at: dst_gid out of range")
    raised = False
    try:
        a.merge_at(0, src, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MinI64Acc.merge_at: src_gid out of range")
    raised = False
    try:
        a.merge_aligned(src)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MinI64Acc.merge_aligned: length mismatch (self=2, src=1)")

    var e1 = MinI64Acc.new()
    e1.merge_aligned(MinI64Acc.new())
    assert_equal(e1.num_groups(), 0)


def test_min_i64_merge_aligned_folds_the_scalar_tail() raises:
    """11 groups: src holds a smaller value in every one, so every group --
    the ones past the last full SIMD chunk included -- must take src's."""
    var dst = MinI64Acc.new()
    var src = MinI64Acc.new()
    dst.ensure_capacity(N_ALIGNED)
    src.ensure_capacity(N_ALIGNED)
    var g: List[Int] = []
    var dv: List[Int64] = []
    var sv: List[Int64] = []
    for i in range(N_ALIGNED):
        g.append(i)
        dv.append(Int64(100 + i))
        sv.append(Int64(-100 - i))
    dst.update_batch(Span(g), _bytes_i64(dv), 0, N_ALIGNED)
    src.update_batch(Span(g), _bytes_i64(sv), 0, N_ALIGNED)
    dst.merge_aligned(src)
    for i in range(N_ALIGNED):
        assert_equal(dst.state[i], Int64(-100 - i), "group " + String(i))
        assert_true(dst.seen[i])
    var col = dst.flush_partial_to_column()
    var p = col._data.view_typed_ro[DType.int64]()
    assert_equal(p[N_ALIGNED - 1], Int64(-100 - (N_ALIGNED - 1)))


# =============================================================================
# MaxI64Acc
# =============================================================================


def test_max_i64_refusals_and_empty_merge() raises:
    var a = MaxI64Acc.new()
    a.ensure_capacity(2)
    assert_equal(a.num_groups(), 2)
    var g32: List[UInt32] = [UInt32(1), UInt32(4)]
    var v: List[Int64] = [Int64(3), Int64(8)]
    var msg = String("")
    var raised = False
    try:
        a.update_batch(Span(g32), Span(v), 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MaxI64Acc.update_batch: gid out of range")
    assert_equal(a.state[1], Int64(3))

    var g: List[Int] = [0, 2]
    raised = False
    try:
        a.update_batch(Span(g), _bytes_i64(v), 0, 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MaxI64Acc.update_batch: gid out of range")

    var src = MaxI64Acc.new()
    src.ensure_capacity(1)
    raised = False
    try:
        a.merge_at(2, src, 0)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MaxI64Acc.merge_at: dst_gid out of range")
    raised = False
    try:
        a.merge_at(0, src, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MaxI64Acc.merge_at: src_gid out of range")
    raised = False
    try:
        a.merge_aligned(src)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MaxI64Acc.merge_aligned: length mismatch (self=2, src=1)")

    var e1 = MaxI64Acc.new()
    e1.merge_aligned(MaxI64Acc.new())
    assert_equal(e1.num_groups(), 0)


def test_max_i64_merge_at_skips_an_unseen_source() raises:
    var a = MaxI64Acc.new()
    a.ensure_capacity(1)
    var g: List[Int] = [0]
    var v: List[Int64] = [Int64(-50)]
    a.update_batch(Span(g), _bytes_i64(v), 0, 1)
    var src = MaxI64Acc.new()
    src.ensure_capacity(1)
    a.merge_at(0, src, 0)
    assert_equal(a.state[0], Int64(-50))
    assert_true(a.seen[0])
    # And an unseen destination stays unseen.
    var b = MaxI64Acc.new()
    b.ensure_capacity(1)
    b.merge_at(0, src, 0)
    assert_false(b.seen[0])


def test_max_i64_merge_aligned_folds_the_scalar_tail() raises:
    var dst = MaxI64Acc.new()
    var src = MaxI64Acc.new()
    dst.ensure_capacity(N_ALIGNED)
    src.ensure_capacity(N_ALIGNED)
    var g: List[Int] = []
    var dv: List[Int64] = []
    var sv: List[Int64] = []
    for i in range(N_ALIGNED):
        g.append(i)
        dv.append(Int64(-100 - i))
        sv.append(Int64(100 + i))
    dst.update_batch(Span(g), _bytes_i64(dv), 0, N_ALIGNED)
    src.update_batch(Span(g), _bytes_i64(sv), 0, N_ALIGNED)
    dst.merge_aligned(src)
    for i in range(N_ALIGNED):
        assert_equal(dst.state[i], Int64(100 + i), "group " + String(i))
    # finalize_to_column and flush_partial carry the seen groups' maxima.
    var col = dst.finalize_to_column()
    var p = col._data.view_typed_ro[DType.int64]()
    assert_equal(col.length(), N_ALIGNED)
    for i in range(N_ALIGNED):
        assert_equal(p[i], Int64(100 + i))
    var fl = dst.flush_partial_to_column()
    assert_equal(fl._data.view_typed_ro[DType.int64]()[3], Int64(103))


# =============================================================================
# SumF64KahanAcc
# =============================================================================


def test_sum_f64_kahan_refusals() raises:
    var a = SumF64KahanAcc.new()
    a.ensure_capacity(2)
    var g32: List[UInt32] = [UInt32(0), UInt32(2)]
    var v: List[Float64] = [Float64(1.5), Float64(2.5)]
    var msg = String("")
    var raised = False
    try:
        a.update_batch(Span(g32), Span(v), 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "SumF64KahanAcc.update_batch: gid out of range")
    assert_equal(a.sum[0], Float64(1.5))

    var g: List[Int] = [1, 7]
    raised = False
    try:
        a.update_batch(Span(g), _bytes_f64(v), 0, 2)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "SumF64KahanAcc.update_batch: gid out of range")
    assert_equal(a.sum[1], Float64(1.5))

    var src = SumF64KahanAcc.new()
    src.ensure_capacity(1)
    raised = False
    try:
        a.merge_at(2, src, 0)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "SumF64KahanAcc.merge_at: dst_gid out of range")
    raised = False
    try:
        a.merge_at(0, src, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "SumF64KahanAcc.merge_at: src_gid out of range")
    raised = False
    try:
        a.merge_aligned(src)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "SumF64KahanAcc.merge_aligned: length mismatch (self=2, src=1)")


def test_sum_f64_kahan_flush_partial_is_finalize() raises:
    var a = SumF64KahanAcc.new()
    a.ensure_capacity(2)
    var g: List[Int] = [0, 1, 0]
    var v: List[Float64] = [Float64(0.25), Float64(-4.0), Float64(0.5)]
    a.update_batch(Span(g), _bytes_f64(v), 0, 3)
    var col = a.flush_partial_to_column()
    var p = col._data.view_typed_ro[DType.float64]()
    assert_equal(p[0], Float64(0.75))
    assert_equal(p[1], Float64(-4.0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
