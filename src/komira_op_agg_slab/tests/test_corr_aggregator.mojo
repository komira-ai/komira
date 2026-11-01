# =============================================================================
# Tests -- CorrelationAggregator, alone and through SlabStorage
# =============================================================================
#
#   T1-T6b: the bivariate Welford kernel. `init` is the zero state; one
#     update sets the means and leaves the co-moments 0; corr of a perfect
#     line is +1 / -1; combining two partials equals one pass over both (and
#     a zero-count side is the identity); finalize is NaN when r is
#     undefined (n = 0, n = 1, or a constant column), as DuckDB returns a
#     non-NULL NaN there.
#   T7: two worker storages committed through
#     `commit_corr_aggregator_with_struct` and merged with
#     `combine_donor_keys_with_struct`; each group's r matches the
#     closed-form Pearson coefficient to 1e-9. Catches x and y swapped or
#     misaligned in the bivariate commit, and a merge that keeps one side.
# =============================================================================

from std.collections import Array
from std.collections.optional import Optional
from std.math import sqrt
from std.memory import UnsafePointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_op_agg_hash.flat_hash_agg import EntryHandle
from komira_op_agg_hash.flat_hash_agg import _fib_hash_1
from komira_op_agg_state.aggregators_struct_builtin import (
    CorrelationAggregator,
    CorrelationState,
)
from komira_op_agg_slab.slab_storage import (
    SlabStorage,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _abs(x: Float64) -> Float64:
    if x < Float64(0.0):
        return -x
    return x


def _approx_equal(a: Float64, b: Float64, tol: Float64 = 1e-9) -> Bool:
    var diff = _abs(a - b)
    if diff <= tol:
        return True
    var mag = _abs(a) + _abs(b)
    return diff <= tol * mag


def _corr_reference(xs: List[Float64], ys: List[Float64]) -> Float64:
    """Closed-form Pearson r = cov(x,y) / (sd_x * sd_y).

    Returns NaN if n == 0; returns 0.0 if either dimension has zero
    variance (matches `CorrelationAggregator.finalize` semantics).
    """
    var n = len(xs)
    if n == 0:
        return Float64(0.0) / Float64(0.0)
    var sum_x = Float64(0.0)
    var sum_y = Float64(0.0)
    for i in range(n):
        sum_x += xs[i]
        sum_y += ys[i]
    var mx = sum_x / Float64(n)
    var my = sum_y / Float64(n)
    var c = Float64(0.0)
    var sx = Float64(0.0)
    var sy = Float64(0.0)
    for i in range(n):
        var dx = xs[i] - mx
        var dy = ys[i] - my
        c += dx * dy
        sx += dx * dx
        sy += dy * dy
    if sx <= Float64(0.0) or sy <= Float64(0.0):
        return Float64(0.0)
    return c / sqrt(sx * sy)


# -----------------------------------------------------------------------------
# T1 — init returns zero state
# -----------------------------------------------------------------------------


def test_T1_init_returns_zero_state() raises:
    var s = CorrelationAggregator.init()
    assert_equal(s.n, UInt64(0))
    assert_true(s.mean_x == Float64(0.0))
    assert_true(s.mean_y == Float64(0.0))
    assert_true(s.C == Float64(0.0))
    assert_true(s.Sx == Float64(0.0))
    assert_true(s.Sy == Float64(0.0))


# -----------------------------------------------------------------------------
# T2 — single-row update
# -----------------------------------------------------------------------------


def test_T2_single_row_update() raises:
    """After one update(x,y): n=1, mean_x=x, mean_y=y, C=Sx=Sy=0."""
    var s = CorrelationAggregator.init()
    CorrelationAggregator.update_bivariate(s, Float64(3.5), Float64(7.5))
    assert_equal(s.n, UInt64(1))
    assert_true(s.mean_x == Float64(3.5))
    assert_true(s.mean_y == Float64(7.5))
    assert_true(s.C == Float64(0.0))
    assert_true(s.Sx == Float64(0.0))
    assert_true(s.Sy == Float64(0.0))
    # Finalize on n=1: r is undefined -> NaN. DuckDB v1.5.3 returns a
    # non-NULL `nan` for `SELECT corr(a,b) FROM (VALUES (1.0,2.0)) v(a,b)`;
    # 0.0 would read as "no linear relationship".
    var r = CorrelationAggregator.finalize(s)
    assert_true(r != r, "n=1 -> NaN (self-inequality), not 0.0")


# -----------------------------------------------------------------------------
# T3 — perfect positive correlation
# -----------------------------------------------------------------------------


def test_T3_perfect_positive() raises:
    """corr([1,2,3,4,5], [1,2,3,4,5]) == 1.0 within tolerance."""
    var s = CorrelationAggregator.init()
    var xs = List[Float64]()
    var ys = List[Float64]()
    for i in range(1, 6):
        xs.append(Float64(i))
        ys.append(Float64(i))
        CorrelationAggregator.update_bivariate(
            s, Float64(i), Float64(i)
        )
    var r = CorrelationAggregator.finalize(s)
    assert_true(_approx_equal(Float64(r), Float64(1.0), Float64(1e-12)))
    var ref_val = _corr_reference(xs, ys)
    assert_true(_approx_equal(Float64(r), ref_val, Float64(1e-9)))


# -----------------------------------------------------------------------------
# T4 — perfect negative correlation
# -----------------------------------------------------------------------------


def test_T4_perfect_negative() raises:
    """corr([1,2,3,4,5], [5,4,3,2,1]) == -1.0 within tolerance."""
    var s = CorrelationAggregator.init()
    var xs = List[Float64]()
    var ys = List[Float64]()
    for i in range(5):
        var x = Float64(i + 1)
        var y = Float64(5 - i)
        xs.append(x)
        ys.append(y)
        CorrelationAggregator.update_bivariate(s, x, y)
    var r = CorrelationAggregator.finalize(s)
    assert_true(_approx_equal(Float64(r), Float64(-1.0), Float64(1e-12)))
    var ref_val = _corr_reference(xs, ys)
    assert_true(_approx_equal(Float64(r), ref_val, Float64(1e-9)))


# -----------------------------------------------------------------------------
# T5 — partition split equivalence
# -----------------------------------------------------------------------------


def test_T5_partition_split_combine() raises:
    """Split a 100-row sequence into two halves, combine partials,
    assert combined finalize matches single-pass within 1e-9 rel tol.

    Using a known correlated sequence: y = 2x + N(0)-shaped synthetic
    where x = i, y = 2*i + (i mod 7) - 3 (deterministic small-noise).
    """
    var xs = List[Float64]()
    var ys = List[Float64]()
    for i in range(100):
        var x = Float64(i)
        var y = Float64(2 * i) + Float64(i % 7) - Float64(3.0)
        xs.append(x)
        ys.append(y)

    # Single-pass.
    var ref_state = CorrelationAggregator.init()
    for i in range(100):
        CorrelationAggregator.update_bivariate(ref_state, xs[i], ys[i])

    # Partials.
    var a = CorrelationAggregator.init()
    for i in range(50):
        CorrelationAggregator.update_bivariate(a, xs[i], ys[i])

    var b = CorrelationAggregator.init()
    for i in range(50, 100):
        CorrelationAggregator.update_bivariate(b, xs[i], ys[i])

    CorrelationAggregator.combine(a, b)

    assert_equal(a.n, ref_state.n)
    var ref_out = CorrelationAggregator.finalize(ref_state)
    var combined_out = CorrelationAggregator.finalize(a)
    assert_true(
        _approx_equal(Float64(ref_out), Float64(combined_out), Float64(1e-9))
    )

    # Sanity: the combined value should match the closed-form reference.
    var closed = _corr_reference(xs, ys)
    assert_true(
        _approx_equal(Float64(combined_out), closed, Float64(1e-9))
    )


def test_T5b_combine_zero_donor_is_noop() raises:
    var accum = CorrelationAggregator.init()
    CorrelationAggregator.update_bivariate(
        accum, Float64(1.0), Float64(2.0)
    )
    CorrelationAggregator.update_bivariate(
        accum, Float64(3.0), Float64(4.0)
    )
    var saved_n = accum.n
    var saved_mx = accum.mean_x
    var saved_my = accum.mean_y

    var zero_donor = CorrelationAggregator.init()
    CorrelationAggregator.combine(accum, zero_donor)

    assert_equal(accum.n, saved_n)
    assert_true(accum.mean_x == saved_mx)
    assert_true(accum.mean_y == saved_my)


def test_T5c_combine_zero_accum_takes_donor() raises:
    var donor = CorrelationAggregator.init()
    CorrelationAggregator.update_bivariate(
        donor, Float64(10.0), Float64(20.0)
    )
    CorrelationAggregator.update_bivariate(
        donor, Float64(30.0), Float64(40.0)
    )

    var accum = CorrelationAggregator.init()
    CorrelationAggregator.combine(accum, donor)

    assert_equal(accum.n, donor.n)
    assert_true(accum.mean_x == donor.mean_x)
    assert_true(accum.mean_y == donor.mean_y)


# -----------------------------------------------------------------------------
# T6 — finalize edge cases
# -----------------------------------------------------------------------------


def test_T6a_finalize_n_zero_returns_nan() raises:
    var s = CorrelationAggregator.init()
    var r = CorrelationAggregator.finalize(s)
    assert_true(r != r)  # NaN: self-inequality


def test_T6b_finalize_constant_x_returns_nan() raises:
    """If all x values are equal, Sx == 0 and r is undefined -> NaN.

    DuckDB v1.5.3 returns a non-NULL `nan` for a constant x, a constant y,
    and both constant:
        corr over (1,2),(1,5)   -> nan   (constant x)
        corr over (1,2),(7,2)   -> nan   (constant y)
        corr over (1,2),(1,2)   -> nan   (both)
    """
    var s = CorrelationAggregator.init()
    CorrelationAggregator.update_bivariate(s, Float64(5.0), Float64(1.0))
    CorrelationAggregator.update_bivariate(s, Float64(5.0), Float64(2.0))
    CorrelationAggregator.update_bivariate(s, Float64(5.0), Float64(3.0))
    var r = CorrelationAggregator.finalize(s)
    assert_true(r != r, "constant x -> NaN (self-inequality), not 0.0")


# -----------------------------------------------------------------------------
# T7 — END-TO-END THROUGH STORAGE LAYER
# -----------------------------------------------------------------------------


def _commit_corr_chunk(
    mut storage: SlabStorage,
    keys: List[Int64],
    xs: List[Float64],
    ys: List[Float64],
) raises:
    """Helper: probe + init + bivariate commit a chunk of (k, x, y) rows."""
    var n = len(keys)
    var eids = List[Int32](capacity=n)
    eids.resize(unsafe_uninit_length=n)
    for i in range(n):
        var k = keys[i]
        var h = _fib_hash_1(k)
        var key_buf = List[UInt8](length=8, fill=0)
        key_buf.unsafe_ptr().bitcast[Int64]()[] = k
        var pair = storage.probe_or_insert_multi_key_with_hash(
            h, Span(key_buf)
        )
        var handle = pair[0]
        var was_new = pair[1]
        if was_new:
            storage.init_state_with_struct[0, CorrelationAggregator](handle)
        eids[i] = handle._entry_idx

    var eids_span = Span[Int32, origin_of(eids)](
        unsafe_ptr=eids.unsafe_ptr(), length=n
    )
    var x_bytes_span = Span[UInt8, origin_of(xs)](
        unsafe_ptr=xs.unsafe_ptr().bitcast[UInt8](), length=n * 8
    )
    var y_bytes_span = Span[UInt8, origin_of(ys)](
        unsafe_ptr=ys.unsafe_ptr().bitcast[UInt8](), length=n * 8
    )

    storage.commit_corr_aggregator_with_struct[0](
        eids_span, x_bytes_span, y_bytes_span, n
    )


def test_T7_end_to_end_through_slab_storage() raises:
    """Two-worker bivariate aggregation via SlabStorage's
    commit_corr_aggregator_with_struct.

    Group A (key=1): 100 rows, y = 2x + small noise → r ≈ +1 (high).
    Group B (key=2): 100 rows, y = -3x + small noise → r ≈ -1 (high).

    Pass criteria: per-group finalize matches closed-form reference
    within 1e-9 relative tolerance after partition combine.
    """
    var xs_a = List[Float64]()
    var ys_a = List[Float64]()
    var xs_b = List[Float64]()
    var ys_b = List[Float64]()
    for i in range(100):
        var x_a = Float64(i)
        var y_a = Float64(2 * i) + Float64(i % 5) * Float64(0.1)
        var x_b = Float64(i)
        var y_b = -Float64(3 * i) + Float64(i % 7) * Float64(0.1)
        xs_a.append(x_a)
        ys_a.append(y_a)
        xs_b.append(x_b)
        ys_b.append(y_b)
    var ref_a = _corr_reference(xs_a, ys_a)
    var ref_b = _corr_reference(xs_b, ys_b)

    var strides = List[Int]()
    strides.append(CorrelationAggregator.STATE_BYTES)
    var w1_storage = SlabStorage(
        num_keys=1,
        num_aggs=1,
        initial_capacity=64,
        agg_state_strides_in=Optional[List[Int]](strides^),
    )

    var strides2 = List[Int]()
    strides2.append(CorrelationAggregator.STATE_BYTES)
    var w2_storage = SlabStorage(
        num_keys=1,
        num_aggs=1,
        initial_capacity=64,
        agg_state_strides_in=Optional[List[Int]](strides2^),
    )

    # Worker 1: rows 0..49 of each group.
    var w1_keys = List[Int64](capacity=100)
    var w1_x = List[Float64](capacity=100)
    var w1_y = List[Float64](capacity=100)
    for i in range(50):
        w1_keys.append(Int64(1))
        w1_x.append(xs_a[i])
        w1_y.append(ys_a[i])
        w1_keys.append(Int64(2))
        w1_x.append(xs_b[i])
        w1_y.append(ys_b[i])
    _commit_corr_chunk(w1_storage, w1_keys, w1_x, w1_y)

    # Worker 2: rows 50..99 of each group.
    var w2_keys = List[Int64](capacity=100)
    var w2_x = List[Float64](capacity=100)
    var w2_y = List[Float64](capacity=100)
    for i in range(50, 100):
        w2_keys.append(Int64(1))
        w2_x.append(xs_a[i])
        w2_y.append(ys_a[i])
        w2_keys.append(Int64(2))
        w2_x.append(xs_b[i])
        w2_y.append(ys_b[i])
    _commit_corr_chunk(w2_storage, w2_keys, w2_x, w2_y)

    # Merge worker 2 into worker 1 (both groups take the HIT branch).
    w1_storage.combine_donor_keys_with_struct[CorrelationAggregator](
        w2_storage
    )

    # Finalize.
    var n_groups = w1_storage.num_groups()
    assert_equal(n_groups, 2)

    var out_list = List[Float64](capacity=n_groups)
    out_list.resize(unsafe_uninit_length=n_groups)
    var out_span = Span[UInt8, origin_of(out_list)](
        unsafe_ptr=out_list.unsafe_ptr().bitcast[UInt8](),
        length=n_groups * 8,
    )
    w1_storage.finalize_aggregator_with_struct[0, CorrelationAggregator](
        out_span
    )

    var keys_list = List[Int64](capacity=n_groups)
    keys_list.resize(unsafe_uninit_length=n_groups)
    var keys_span = Span[UInt8, origin_of(keys_list)](
        unsafe_ptr=keys_list.unsafe_ptr().bitcast[UInt8](),
        length=n_groups * 8,
    )
    w1_storage.finalize_keys_int64(keys_span)

    var saw_a = False
    var saw_b = False
    for i in range(n_groups):
        var k = keys_list[i]
        var v = out_list[i]
        if k == Int64(1):
            saw_a = True
            assert_true(_approx_equal(v, ref_a, Float64(1e-9)))
        elif k == Int64(2):
            saw_b = True
            assert_true(_approx_equal(v, ref_b, Float64(1e-9)))
        else:
            assert_true(False)
    assert_true(saw_a)
    assert_true(saw_b)


# -----------------------------------------------------------------------------
# Test runner
# -----------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_T1_init_returns_zero_state]()
    suite.test[test_T2_single_row_update]()
    suite.test[test_T3_perfect_positive]()
    suite.test[test_T4_perfect_negative]()
    suite.test[test_T5_partition_split_combine]()
    suite.test[test_T5b_combine_zero_donor_is_noop]()
    suite.test[test_T5c_combine_zero_accum_takes_donor]()
    suite.test[test_T6a_finalize_n_zero_returns_nan]()
    suite.test[test_T6b_finalize_constant_x_returns_nan]()
    suite.test[test_T7_end_to_end_through_slab_storage]()
    suite^.run()
