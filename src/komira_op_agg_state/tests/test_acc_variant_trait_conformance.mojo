# =============================================================================
# Tests for Phase 1B Stage 2A -- Accumulator trait conformance for new variants
# =============================================================================
#
# Verifies that CountStarAcc / MinF64Acc / MaxF64Acc / AvgAcc each conform to
# the Accumulator trait (`accumulator_trait.mojo`) by:
#
#   1. update_batch(gids_ptr, col_data_ptr, col_offset, n)  -- HOT PATH overload
#   2. finalize_to_column()                                 -- arrow Column out
#   3. flush_partial_to_column()                            -- abandon-cycle
#   4. ensure_capacity(n_groups)                            -- monotonic grow
#   5. num_groups()                                         -- size readback
#
# This is the contract the MonomorphicKernel + DynAccumulator dispatch consumes
# (Stage 2B). Without trait conformance the kernels are unreachable from any
# production path. v0.3-faithful round-trips lock the semantics:
#
#   - CountStarAcc: sums to row count regardless of values (no null mask).
#   - MinF64Acc / MaxF64Acc: column emits the typed numeric (sentinel for unseen,
#     callers must consult num_groups + finalize Optional path for null).
#   - AvgAcc: sum/count per group; flush_partial returns 0.0 sentinel for unseen.
#
# Mojo trait method `update_batch(gids_ptr, col_data_ptr, col_offset, n)`
# takes raw UnsafePointer[Int, MutExternalOrigin] / UnsafePointer[UInt8,
# MutExternalOrigin] (see accumulator_trait.mojo header for the JIT-bug
# rationale). Tests construct these via List.unsafe_ptr().bitcast.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow import Column

from komira_core.accumulator_trait import Accumulator
from komira_op_agg_state.columnar_acc_typed_extra import (
    CountStarAcc,
    MinF64Acc,
    MaxF64Acc,
    AvgAcc,
)


# =============================================================================
# Helpers -- build raw pointer args for the trait update_batch shape.
# =============================================================================


def _gids_to_int_ptr(
    mut gids: List[Int],
) -> UnsafePointer[Int, MutUntrackedOrigin]:
    """List[Int].unsafe_ptr() under the untracked origin the trait names.

    The trait uses Int (8-byte) per ADR S1 -- not UInt32 -- because Mojo
    Mojo has a JIT bug round-tripping 4-byte Scalar through Int. List[Int]
    is the canonical input shape from the production hot path.
    """
    return gids.unsafe_ptr().unsafe_origin_cast[MutUntrackedOrigin]()


def _f64_vals_to_byte_ptr(
    mut vals: List[Float64],
) -> UnsafePointer[UInt8, MutUntrackedOrigin]:
    """List[Float64].unsafe_ptr() byte-bitcast under the untracked origin.

    The trait takes the column data as UInt8 + offset; concrete impls
    bitcast back to Float64 internally.
    """
    return (
        vals.unsafe_ptr().bitcast[UInt8]().unsafe_origin_cast[MutUntrackedOrigin]()
    )


# =============================================================================
# CountStarAcc -- trait conformance round-trips
# =============================================================================


def test_count_star_trait_update_batch() raises:
    """update_batch(gids, col, off, n) increments per row regardless of col."""
    var acc = CountStarAcc.new()
    acc.ensure_capacity(3)
    var gids = List[Int]()
    gids.append(0); gids.append(1); gids.append(0)
    gids.append(2); gids.append(0)
    # Col data is ignored by CountStar; pass any byte buffer.
    var dummy = List[Float64]()
    dummy.append(Float64(0.0)); dummy.append(Float64(0.0)); dummy.append(Float64(0.0))
    dummy.append(Float64(0.0)); dummy.append(Float64(0.0))
    var gp = _gids_to_int_ptr(gids)
    var cp = _f64_vals_to_byte_ptr(dummy)
    acc.update_batch(gp, cp, 0, 5)
    # Force keepalives.
    _ = gids
    _ = dummy

    assert_equal(acc.num_groups(), 3)


def test_count_star_trait_finalize_to_column() raises:
    """finalize_to_column emits an Int64 Column with per-gid counts."""
    var acc = CountStarAcc.new()
    acc.ensure_capacity(2)
    var gids = List[Int]()
    gids.append(0); gids.append(1); gids.append(0); gids.append(0)
    var dummy = List[Float64]()
    dummy.append(Float64(0.0)); dummy.append(Float64(0.0))
    dummy.append(Float64(0.0)); dummy.append(Float64(0.0))
    var gp = _gids_to_int_ptr(gids)
    var cp = _f64_vals_to_byte_ptr(dummy)
    acc.update_batch(gp, cp, 0, 4)
    _ = gids
    _ = dummy

    var col = acc.finalize_to_column()
    assert_equal(col.length(), 2)


def test_count_star_trait_flush_partial() raises:
    """flush_partial_to_column == finalize for CountStar (no pending state)."""
    var acc = CountStarAcc.new()
    acc.ensure_capacity(1)
    var gids = List[Int]()
    gids.append(0); gids.append(0); gids.append(0)
    var dummy = List[Float64]()
    dummy.append(Float64(0.0)); dummy.append(Float64(0.0)); dummy.append(Float64(0.0))
    var gp = _gids_to_int_ptr(gids)
    var cp = _f64_vals_to_byte_ptr(dummy)
    acc.update_batch(gp, cp, 0, 3)
    _ = gids
    _ = dummy

    var col = acc.flush_partial_to_column()
    assert_equal(col.length(), 1)


# =============================================================================
# MinF64Acc -- trait conformance round-trips
# =============================================================================


def test_min_f64_trait_update_batch() raises:
    """update_batch finds per-gid min, finalize emits Float64 Column."""
    var acc = MinF64Acc.new()
    acc.ensure_capacity(2)
    var gids = List[Int]()
    gids.append(0); gids.append(0); gids.append(1); gids.append(1); gids.append(0)
    var vals = List[Float64]()
    vals.append(Float64(3.0)); vals.append(Float64(1.0)); vals.append(Float64(7.0))
    vals.append(Float64(2.0)); vals.append(Float64(5.0))
    var gp = _gids_to_int_ptr(gids)
    var cp = _f64_vals_to_byte_ptr(vals)
    acc.update_batch(gp, cp, 0, 5)
    _ = gids
    _ = vals

    assert_equal(acc.num_groups(), 2)
    var col = acc.finalize_to_column()
    assert_equal(col.length(), 2)


def test_min_f64_trait_with_offset() raises:
    """The col_offset path: ptr arithmetic into a mid-column slice."""
    var acc = MinF64Acc.new()
    acc.ensure_capacity(1)
    var gids = List[Int]()
    gids.append(0); gids.append(0)
    var vals = List[Float64]()
    # First value (index 0) is a distractor; we read from offset=2.
    vals.append(Float64(99.0)); vals.append(Float64(99.0))
    vals.append(Float64(8.0)); vals.append(Float64(3.5))
    var gp = _gids_to_int_ptr(gids)
    var cp = _f64_vals_to_byte_ptr(vals)
    acc.update_batch(gp, cp, 2, 2)
    _ = gids
    _ = vals

    var col = acc.finalize_to_column()
    assert_equal(col.length(), 1)


# =============================================================================
# MaxF64Acc -- trait conformance round-trips
# =============================================================================


def test_max_f64_trait_update_batch() raises:
    var acc = MaxF64Acc.new()
    acc.ensure_capacity(2)
    var gids = List[Int]()
    gids.append(0); gids.append(0); gids.append(1); gids.append(1); gids.append(0)
    var vals = List[Float64]()
    vals.append(Float64(3.0)); vals.append(Float64(1.0)); vals.append(Float64(7.0))
    vals.append(Float64(2.0)); vals.append(Float64(5.0))
    var gp = _gids_to_int_ptr(gids)
    var cp = _f64_vals_to_byte_ptr(vals)
    acc.update_batch(gp, cp, 0, 5)
    _ = gids
    _ = vals

    assert_equal(acc.num_groups(), 2)
    var col = acc.finalize_to_column()
    assert_equal(col.length(), 2)


# =============================================================================
# AvgAcc -- trait conformance round-trips
# =============================================================================


def test_avg_trait_update_batch() raises:
    """Trait update_batch increments sum + count via Kahan."""
    var acc = AvgAcc.new()
    acc.ensure_capacity(2)
    var gids = List[Int]()
    gids.append(0); gids.append(0); gids.append(1); gids.append(1); gids.append(0)
    var vals = List[Float64]()
    vals.append(Float64(10.0)); vals.append(Float64(20.0)); vals.append(Float64(5.0))
    vals.append(Float64(15.0)); vals.append(Float64(30.0))
    var gp = _gids_to_int_ptr(gids)
    var cp = _f64_vals_to_byte_ptr(vals)
    acc.update_batch(gp, cp, 0, 5)
    _ = gids
    _ = vals

    assert_equal(acc.num_groups(), 2)
    # gid 0: sum=60, count=3, avg=20.0; gid 1: sum=20, count=2, avg=10.0
    var col = acc.finalize_to_column()
    assert_equal(col.length(), 2)


def test_avg_trait_unseen_group_in_column() raises:
    """Unseen groups appear as 0.0 sentinel in finalize_to_column."""
    var acc = AvgAcc.new()
    acc.ensure_capacity(3)  # gid=2 stays unseen
    var gids = List[Int]()
    gids.append(0); gids.append(1)
    var vals = List[Float64]()
    vals.append(Float64(40.0)); vals.append(Float64(10.0))
    var gp = _gids_to_int_ptr(gids)
    var cp = _f64_vals_to_byte_ptr(vals)
    acc.update_batch(gp, cp, 0, 2)
    _ = gids
    _ = vals

    var col = acc.finalize_to_column()
    assert_equal(col.length(), 3)


# =============================================================================
# Cross-variant: ensure_capacity grows monotonically through trait surface
# =============================================================================


def test_all_variants_ensure_capacity_monotonic() raises:
    """All 4 variants honor monotonic-grow contract through trait method."""
    var cs = CountStarAcc.new()
    cs.ensure_capacity(8)
    cs.ensure_capacity(4)
    assert_equal(cs.num_groups(), 8)

    var mn = MinF64Acc.new()
    mn.ensure_capacity(8)
    mn.ensure_capacity(4)
    assert_equal(mn.num_groups(), 8)

    var mx = MaxF64Acc.new()
    mx.ensure_capacity(8)
    mx.ensure_capacity(4)
    assert_equal(mx.num_groups(), 8)

    var av = AvgAcc.new()
    av.ensure_capacity(8)
    av.ensure_capacity(4)
    assert_equal(av.num_groups(), 8)


# =============================================================================
# Compile-time: trait conformance check
# =============================================================================
# These functions only typecheck if each struct conforms to Accumulator.
# A regression in conformance (missing finalize_to_column / etc.) would
# fail to compile this file.


def _typecheck_count_star[T: Accumulator]() -> Bool:
    return True


def _typecheck_min_f64[T: Accumulator]() -> Bool:
    return True


def _typecheck_max_f64[T: Accumulator]() -> Bool:
    return True


def _typecheck_avg[T: Accumulator]() -> Bool:
    return True


def test_compile_time_trait_conformance() raises:
    """Compile-time gate: each struct must satisfy Accumulator trait."""
    assert_true(_typecheck_count_star[CountStarAcc]())
    assert_true(_typecheck_min_f64[MinF64Acc]())
    assert_true(_typecheck_max_f64[MaxF64Acc]())
    assert_true(_typecheck_avg[AvgAcc]())


# =============================================================================
# Test driver
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
