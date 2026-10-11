# =============================================================================
# Tests -- StddevSampAggregator through the AggregatorWithStruct surface,
# alone and through SlabStorage
# =============================================================================
#
#   T1-T4c: the Welford kernel itself. `init` is the zero state; `update`
#     matches a two-pass mean/variance; `combine` of two partials equals one
#     pass over both (and a zero-count side is the identity); `finalize` is
#     the sample stddev, NaN at count 0 and 1.
#   T7: two worker storages merged with `combine_donor_keys_with_struct`, the
#     combine the sinks run. Groups present in both workers take the HIT
#     branch (`combine` of the two states); a group only the donor has takes
#     the MISS branch (insert, then copy the donor's state). Each group's
#     finalized stddev matches the closed-form reference to 1e-9. Catches a
#     MISS that drops or zeroes the donor's state, and a HIT that keeps only
#     one side.
# =============================================================================

from std.collections import Array
from std.collections.optional import Optional
from std.math import sqrt
from std.memory import UnsafePointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_op_agg_hash.flat_hash_agg import EntryHandle
from komira_op_agg_hash.flat_hash_agg import _fib_hash_1
from komira_op_agg_state.aggregator_with_struct_trait import (
    AggregatorWithStruct,
)
from komira_op_agg_state.aggregators_struct_builtin import (
    StddevSampAggregator,
    WelfordState,
)
from komira_op_agg_slab.slab_storage import (
    SlabStorage,
)


# -----------------------------------------------------------------------------
# Helpers — closed-form numpy-equivalent reference computations
# -----------------------------------------------------------------------------


def _stddev_samp_reference(values: List[Float64]) -> Float64:
    """Closed-form sample stddev: numpy.std(values, ddof=1).

    Returns NaN for len(values) <= 1 to match `StddevSampAggregator.finalize`.
    """
    var n = len(values)
    if n <= 1:
        return Float64(0.0) / Float64(0.0)  # NaN
    var sum = Float64(0.0)
    for i in range(n):
        sum += values[i]
    var mean = sum / Float64(n)
    var sq_sum = Float64(0.0)
    for i in range(n):
        var d = values[i] - mean
        sq_sum += d * d
    return sqrt(sq_sum / Float64(n - 1))


def _abs(x: Float64) -> Float64:
    if x < Float64(0.0):
        return -x
    return x


def _approx_equal(a: Float64, b: Float64, tol: Float64 = 1e-9) -> Bool:
    """Float64 approximate-equal with absolute + relative tolerance."""
    var diff = _abs(a - b)
    if diff <= tol:
        return True
    var mag = _abs(a) + _abs(b)
    return diff <= tol * mag


# -----------------------------------------------------------------------------
# T1 — init returns zero state
# -----------------------------------------------------------------------------


def test_T1_init_returns_zero_state() raises:
    """`StddevSampAggregator.init()` returns WelfordState(0, 0.0, 0.0)."""
    var s = StddevSampAggregator.init()
    assert_equal(s.count, UInt64(0))
    assert_true(s.mean == Float64(0.0))
    assert_true(s.m2 == Float64(0.0))


# -----------------------------------------------------------------------------
# T2 — update single-row Welford correctness
# -----------------------------------------------------------------------------


def test_T2_update_welford_correctness() raises:
    """Apply `update` over a known sequence; assert state matches reference.

    Reference: 5-element sequence [2.0, 4.0, 4.0, 4.0, 5.0], mean = 3.8,
    m2 = sum((xi - mean)^2) over the same Welford recurrence formula.

    We compute the reference via the same Welford recurrence (single-pass
    semantics) and assert byte-equivalent state. Single-pass Welford is
    deterministic for finite sequences, so the kernel's state should be
    bitwise-identical to the reference for short sequences.
    """
    var values = List[Float64]()
    values.append(Float64(2.0))
    values.append(Float64(4.0))
    values.append(Float64(4.0))
    values.append(Float64(4.0))
    values.append(Float64(5.0))

    var s = StddevSampAggregator.init()
    for i in range(len(values)):
        StddevSampAggregator.update(s, values[i])

    # Reference: same recurrence, applied independently.
    var rs = WelfordState()
    for i in range(len(values)):
        rs.count += UInt64(1)
        var delta = values[i] - rs.mean
        rs.mean += delta / Float64(rs.count)
        rs.m2 += delta * (values[i] - rs.mean)

    assert_equal(s.count, rs.count)
    # Single-pass Welford on a 5-element sequence is exact-equal across
    # the two computations (same op order). Use `==` instead of approx.
    assert_true(s.mean == rs.mean)
    assert_true(s.m2 == rs.m2)
    # Mean = 3.8 exactly (Float64 representable).
    assert_true(s.mean == Float64(3.8))


# -----------------------------------------------------------------------------
# T3 — combine parallel-Welford correctness
# -----------------------------------------------------------------------------


def test_T3_combine_parallel_welford() raises:
    """Split a 100-element sequence into two halves; combine partials;
    assert combined state matches single-pass.

    Reference: single-pass over [0.0, 1.0, ..., 99.0]; partials over
    [0.0..49.0] and [50.0..99.0]. Chan/Welford merge formula must produce
    a state with the same finalize value within 1e-9 relative tolerance.
    """
    # Single-pass.
    var ref_state = StddevSampAggregator.init()
    for i in range(100):
        StddevSampAggregator.update(ref_state, Float64(i))

    # Partials.
    var a = StddevSampAggregator.init()
    for i in range(50):
        StddevSampAggregator.update(a, Float64(i))

    var b = StddevSampAggregator.init()
    for i in range(50, 100):
        StddevSampAggregator.update(b, Float64(i))

    # Merge b into a.
    StddevSampAggregator.combine(a, b)

    # Counts must match exactly.
    assert_equal(a.count, ref_state.count)
    # Mean is exactly representable (sum of 0..99 / 100 = 49.5).
    assert_true(_approx_equal(a.mean, ref_state.mean, Float64(1e-12)))
    # m2 may differ in the last bit due to op order; allow relative tol.
    assert_true(_approx_equal(a.m2, ref_state.m2, Float64(1e-9)))
    # Finalize values must agree.
    var ref_out = StddevSampAggregator.finalize(ref_state)
    var combined_out = StddevSampAggregator.finalize(a)
    assert_true(
        _approx_equal(
            Float64(ref_out), Float64(combined_out), Float64(1e-9)
        )
    )


def test_T3b_combine_zero_count_donor_is_noop() raises:
    """`combine(accum, zero_donor)` is a no-op (donor.count == 0 early-out)."""
    var accum = StddevSampAggregator.init()
    StddevSampAggregator.update(accum, Float64(1.0))
    StddevSampAggregator.update(accum, Float64(2.0))
    StddevSampAggregator.update(accum, Float64(3.0))
    var saved_count = accum.count
    var saved_mean = accum.mean
    var saved_m2 = accum.m2

    var zero_donor = StddevSampAggregator.init()
    StddevSampAggregator.combine(accum, zero_donor)

    assert_equal(accum.count, saved_count)
    assert_true(accum.mean == saved_mean)
    assert_true(accum.m2 == saved_m2)


def test_T3c_combine_zero_accum_takes_donor() raises:
    """`combine(zero_accum, donor)` makes accum equal to donor."""
    var donor = StddevSampAggregator.init()
    StddevSampAggregator.update(donor, Float64(10.0))
    StddevSampAggregator.update(donor, Float64(20.0))

    var accum = StddevSampAggregator.init()
    StddevSampAggregator.combine(accum, donor)

    assert_equal(accum.count, donor.count)
    assert_true(accum.mean == donor.mean)
    assert_true(accum.m2 == donor.m2)


# -----------------------------------------------------------------------------
# T4 — finalize sample stddev correctness
# -----------------------------------------------------------------------------


def test_T4_finalize_sample_stddev() raises:
    """Known sequence; assert finalize matches numpy.std(values, ddof=1).

    Sequence: [2.0, 4.0, 4.0, 4.0, 5.0].
    mean = 19/5 = 3.8
    sum((xi - mean)^2) = 3.24 + 0.04 + 0.04 + 0.04 + 1.44 = 4.8
    var_samp = 4.8 / 4 = 1.2
    stddev_samp = sqrt(1.2) ≈ 1.09544511501...
    """
    var values = List[Float64]()
    values.append(Float64(2.0))
    values.append(Float64(4.0))
    values.append(Float64(4.0))
    values.append(Float64(4.0))
    values.append(Float64(5.0))

    var s = StddevSampAggregator.init()
    for i in range(len(values)):
        StddevSampAggregator.update(s, values[i])

    var out = StddevSampAggregator.finalize(s)
    var ref_out = _stddev_samp_reference(values)
    assert_true(_approx_equal(Float64(out), ref_out, Float64(1e-12)))
    # Closed form: sqrt(1.2) ≈ 1.09544511501033... Welford's m2 may
    # differ from closed-form sum-of-squared-deviations by a few ulps
    # for small N due to accumulated mean updates; use 1e-9 relative
    # tolerance (same gate as numpy.testing.assert_allclose default).
    assert_true(
        _approx_equal(
            Float64(out), sqrt(Float64(1.2)), Float64(1e-9)
        )
    )


def test_T4b_finalize_count_zero_returns_nan() raises:
    """`finalize` on count==0 (no rows) returns NaN."""
    var s = StddevSampAggregator.init()
    var out = StddevSampAggregator.finalize(s)
    # NaN: self-inequality is the canonical detection.
    assert_true(out != out)


def test_T4c_finalize_count_one_returns_nan() raises:
    """`finalize` on count==1 (single row, sample stddev undefined) returns NaN.
    """
    var s = StddevSampAggregator.init()
    StddevSampAggregator.update(s, Float64(42.0))
    var out = StddevSampAggregator.finalize(s)
    assert_true(out != out)


# -----------------------------------------------------------------------------
# Storage helper
# -----------------------------------------------------------------------------


def _commit_chunk[
    Agg: AggregatorWithStruct
](
    mut storage: SlabStorage,
    keys: List[Int64],
    values: List[Float64],
) raises:
    """Helper: chunk-major commit of (keys, values) rows into storage's
    AggIdx 0 slot.

    Per-row pattern: probe + init_state_with_struct on new entries, then
    one batched `commit_aggregator_with_struct` call over the full chunk.
    The same shape the struct sinks commit with.

    Args:
        storage: target SlabStorage (caller-constructed with strides for Agg).
        keys: per-row group key (Int64).
        values: per-row input value (Float64).
    """
    var n = len(keys)

    # Probe all rows; collect entry_ids; call init_state_with_struct on
    # first-seen entries (matches the WAS_NEW path used by
    # SlabHashAggSinkStruct / SlabHashAggSinkStructCorr).
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
            storage.init_state_with_struct[0, Agg](handle)
        eids[i] = handle._entry_idx

    # Build the Span[Int32, _] entry_ids buffer pointing into `eids` List.
    var eids_span = Span[Int32, origin_of(eids)](
        unsafe_ptr=eids.unsafe_ptr(), length=n
    )

    # Build the Span[UInt8, _] values buffer pointing into `values` List
    # (reinterpret Float64 buffer as UInt8 byte buffer).
    var vbytes_span = Span[UInt8, origin_of(values)](
        unsafe_ptr=values.unsafe_ptr().bitcast[UInt8](), length=n * 8
    )

    storage.commit_aggregator_with_struct[0, Agg](eids_span, vbytes_span, n)


def test_T7_combine_donor_keys_with_struct_single_pass() raises:
    """Donor merge via `SlabStorage.combine_donor_keys_with_struct[*Ss]`.

    Scenario (exercises BOTH the MISS branch — donor-only key — and the
    HIT branch — overlapping key):
      Group A (key=1): 80 values [0.0 .. 79.0]      — split across both
      Group B (key=2): 80 values [200.0 .. 279.0]   — split across both
      Group C (key=3): 40 values [500.0 .. 539.0]   — ONLY in worker 2
      Worker 1: rows 0..39 of A, 0..39 of B          (no C → MISS on merge)
      Worker 2: rows 40..79 of A, 40..79 of B, all of C

    After `w1.combine_donor_keys_with_struct[StddevSampAggregator](w2)`:
      * 3 groups present.
      * Group A / B finalize == closed-form numpy.std(values, ddof=1).
      * Group C finalize == closed-form on its 40 values (came in via the
        MISS path: donor's state copied as the merged state).
    """
    var values_a = List[Float64]()
    var values_b = List[Float64]()
    var values_c = List[Float64]()
    for i in range(80):
        values_a.append(Float64(i))
        values_b.append(Float64(200 + i))
    for i in range(40):
        values_c.append(Float64(500 + i))
    var ref_a = _stddev_samp_reference(values_a)
    var ref_b = _stddev_samp_reference(values_b)
    var ref_c = _stddev_samp_reference(values_c)

    var strides = List[Int]()
    strides.append(StddevSampAggregator.STATE_BYTES)
    var w1_storage = SlabStorage(
        num_keys=1,
        num_aggs=1,
        initial_capacity=64,
        agg_state_strides_in=Optional[List[Int]](strides^),
    )
    var strides2 = List[Int]()
    strides2.append(StddevSampAggregator.STATE_BYTES)
    var w2_storage = SlabStorage(
        num_keys=1,
        num_aggs=1,
        initial_capacity=64,
        agg_state_strides_in=Optional[List[Int]](strides2^),
    )

    var w1_keys = List[Int64](capacity=80)
    var w1_vals = List[Float64](capacity=80)
    for i in range(40):
        w1_keys.append(Int64(1))
        w1_vals.append(values_a[i])
        w1_keys.append(Int64(2))
        w1_vals.append(values_b[i])
    _commit_chunk[StddevSampAggregator](w1_storage, w1_keys, w1_vals)

    var w2_keys = List[Int64](capacity=120)
    var w2_vals = List[Float64](capacity=120)
    for i in range(40, 80):
        w2_keys.append(Int64(1))
        w2_vals.append(values_a[i])
        w2_keys.append(Int64(2))
        w2_vals.append(values_b[i])
    for i in range(40):
        w2_keys.append(Int64(3))
        w2_vals.append(values_c[i])
    _commit_chunk[StddevSampAggregator](w2_storage, w2_keys, w2_vals)

    w1_storage.combine_donor_keys_with_struct[StddevSampAggregator](
        w2_storage
    )

    var n_groups = w1_storage.num_groups()
    assert_equal(n_groups, 3)

    var out_list = List[Float64](capacity=n_groups)
    out_list.resize(unsafe_uninit_length=n_groups)
    var out_span = Span[UInt8, origin_of(out_list)](
        unsafe_ptr=out_list.unsafe_ptr().bitcast[UInt8](),
        length=n_groups * 8,
    )
    w1_storage.finalize_aggregator_with_struct[0, StddevSampAggregator](
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
    var saw_c = False
    for i in range(n_groups):
        var k = keys_list[i]
        var v = out_list[i]
        if k == Int64(1):
            saw_a = True
            assert_true(_approx_equal(v, ref_a, Float64(1e-9)))
        elif k == Int64(2):
            saw_b = True
            assert_true(_approx_equal(v, ref_b, Float64(1e-9)))
        elif k == Int64(3):
            saw_c = True
            assert_true(_approx_equal(v, ref_c, Float64(1e-9)))
        else:
            assert_true(False)
    assert_true(saw_a)
    assert_true(saw_b)
    assert_true(saw_c)


# -----------------------------------------------------------------------------
# Test runner
# -----------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_T1_init_returns_zero_state]()
    suite.test[test_T2_update_welford_correctness]()
    suite.test[test_T3_combine_parallel_welford]()
    suite.test[test_T3b_combine_zero_count_donor_is_noop]()
    suite.test[test_T3c_combine_zero_accum_takes_donor]()
    suite.test[test_T4_finalize_sample_stddev]()
    suite.test[test_T4b_finalize_count_zero_returns_nan]()
    suite.test[test_T4c_finalize_count_one_returns_nan]()
    suite.test[test_T7_combine_donor_keys_with_struct_single_pass]()
    suite^.run()
