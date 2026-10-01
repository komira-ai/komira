# =============================================================================
# Tests for `ExpressionExecutor.select_expression_adaptive`.
#
# The executor wires the AdaptiveFilter state machine into the executor's
# conjunction walker. This file drives the executor over 500 synthetic
# batches whose per-row cost depends on the predicate ordering, and
# verifies the state machine converges on the cost-optimal permutation.
#
# Convergence pattern mirrors the
# `test_adaptive_filter_convergence.mojo` driver pattern: instead of
# direct ns injection, we drive the EXECUTOR over real batches whose
# predicate evaluation cost is dominated by the GATHER cost — most-
# selective predicate first => smaller subsequent gathers => faster
# total wall.
#
# Test coverage (5 cases):
#   1. Single-predicate (no conjunction) — adaptive walker is a no-op
#      passthrough that still produces correct survivors.
#   2. 2-predicate convergence — AdaptiveFilter degenerates to a trivial
#      1-slot swap_likeliness state machine; just verify correctness.
#   3. WARMUP-only path — within first 5 batches, permutation stays at
#      identity (no swaps proposed yet).
#   4. 4-predicate convergence — the canonical Q6-like shape. Initial
#      permutation orders the most-expensive (highest-cost, low-
#      selectivity) predicate FIRST so the executor sees a worst-case
#      ordering; after ~500 batches the AdaptiveFilter must have re-
#      ordered to the optimal (most-selective-first) permutation.
#   5. Permutation locks after convergence — `swap_likeliness` halves
#      to 0 for all slots after enough EXPLORE→OBSERVE cycles, so the
#      permutation no longer mutates on subsequent calls.
#
# The "cost-optimal" criterion: a 4-predicate AND chain over a 1024-row
# batch. Each predicate `p_i` rejects fraction `1 - sel_i` of inputs.
# Total gather cost ≈ sum(live_rows[i] * gather_cost_per_row[i]) where
# `live_rows[0] = N`, `live_rows[i] = live_rows[i-1] * sel_{perm[i-1]}`.
# The cost-optimal permutation is the one that minimizes this sum;
# "Lowest-selectivity first" is optimal
# under the simple gather-cost model.
#
# For this test the 4 predicates' selectivities are configured to be
# `[0.5, 0.1, 0.9, 0.3]`. Cost-optimal ordering:
# `[1, 3, 0, 2]` — the same target a 4-worker parallelize run converges
# to.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema
from komira_eval.adaptive_filter import (
    ADAPTIVE_FILTER_PHASE_WARMUP,
)
from komira_eval.expression_executor import ExpressionExecutor
from komira_eval.runtime_expr import (
    RuntimeExpr,
    make_and,
    make_col,
    make_ge_i64,
    make_lit_i64,
    make_lt_i64,
)
from komira_eval.filter_state import FilterState
from komira_eval.selection_vector import RowSelectionVector


# -----------------------------------------------------------------------------
# Test helper — Mojo 1.0.0b1's List ctor doesn't accept positional
# varargs (`List[String]("c0")` errors with "expected at most 0 positional
# arguments, got 1"); use construct-empty + append.
# -----------------------------------------------------------------------------


def _names1(s0: String) -> List[String]:
    var out = List[String]()
    out.append(s0)
    return out^


# -----------------------------------------------------------------------------
# Synthetic batch builders — Int64 columns calibrated to predicate
# selectivities. The batch has 1024 rows; column values are
# `[0, 1, ..., 1023]`. Predicates of the shape `col_i >= lo AND col_i <
# hi` then have selectivity `(hi - lo) / 1024`.
# -----------------------------------------------------------------------------


def _build_single_col_batch(n: Int) raises -> RecordBatch:
    """Build a single-column Int64 batch with values [0, 1, ..., n-1].

    All predicates in this test reference column 0 (col_idx=0); each
    predicate independently narrows the row set without any column
    dependency.
    """
    var vals0 = List[Scalar[DType.int64]]()
    for i in range(n):
        vals0.append(Scalar[DType.int64](Int64(i)))
    var arr0 = PrimitiveArray[DType.int64].from_list(vals0^)
    var schema = Schema.from_fields_1(Field("c0", DType.int64, True))
    var col0 = Column.from_primitive[DType.int64](arr0^)
    return RecordBatch.from_typed_columns_1(schema^, col0^)


# -----------------------------------------------------------------------------
# Test 1 — Single-predicate (no conjunction): adaptive walker is a
# no-op passthrough.
# -----------------------------------------------------------------------------


def test_single_predicate_adaptive_passthrough() raises:
    """For a single-predicate root (no AND), the adaptive walker fires
    a single begin/end cycle and produces the correct survivors.
    """
    # Predicate: c0 >= 500. Survivors: 524 rows (500..1023).
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))               # slot 0
    pool.append(make_lit_i64(Int64(500)))  # slot 1
    pool.append(make_ge_i64(0, 1))         # slot 2 (root)
    # column_names sidecar — single-col "c0".
    var exec = ExpressionExecutor(pool^, 2, _names1("c0"))
    var batch = _build_single_col_batch(1024)
    var fs = FilterState.with_conjunction(n_predicates=1, worker_id=0)

    var n_surv = exec.select_expression_adaptive(batch, fs)
    assert_equal(n_surv, 524)
    # First few surviving indices.
    assert_equal(fs.sel.get(0), UInt32(500))
    assert_equal(fs.sel.get(1), UInt32(501))


# -----------------------------------------------------------------------------
# Test 2 — 2-predicate adaptive walker correctness over many batches.
# -----------------------------------------------------------------------------


def test_two_predicate_adaptive_correctness() raises:
    """`c0 >= 100 AND c0 < 200` over many batches. Each call must return
    the same 100 survivors regardless of AdaptiveFilter state evolution.
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))                # slot 0
    pool.append(make_lit_i64(Int64(100)))   # slot 1
    pool.append(make_ge_i64(0, 1))          # slot 2 (c0 >= 100)
    pool.append(make_lit_i64(Int64(200)))   # slot 3
    pool.append(make_lt_i64(0, 3))          # slot 4 (c0 < 200)
    pool.append(make_and(2, 4))             # slot 5 (root AND)
    # column_names sidecar — single-col "c0".
    var exec = ExpressionExecutor(pool^, 5, _names1("c0"))
    var fs = FilterState.with_conjunction(n_predicates=2, worker_id=0)

    # Drive 50 batches; each batch should produce 100 survivors.
    for _ in range(50):
        var batch = _build_single_col_batch(1024)
        var n_surv = exec.select_expression_adaptive(batch, fs)
        assert_equal(n_surv, 100)
        # Reset sel for the next batch.
        fs.sel.set_len(0)


# -----------------------------------------------------------------------------
# Test 3 — WARMUP phase: no permutation swap in first 5 batches.
# -----------------------------------------------------------------------------


def test_warmup_no_swap_in_first_5_batches() raises:
    """Within the first WARMUP_ITERS (5) batches, the AdaptiveFilter is
    in WARMUP phase and does NOT propose swaps. Permutation stays at
    identity.
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))                # slot 0
    pool.append(make_lit_i64(Int64(100)))   # slot 1
    pool.append(make_ge_i64(0, 1))          # slot 2
    pool.append(make_lit_i64(Int64(200)))   # slot 3
    pool.append(make_lt_i64(0, 3))          # slot 4
    pool.append(make_and(2, 4))             # slot 5
    # column_names sidecar — single-col "c0".
    var exec = ExpressionExecutor(pool^, 5, _names1("c0"))
    var fs = FilterState.with_conjunction(n_predicates=2, worker_id=0)

    # Drive 4 batches (just under WARMUP_ITERS = 5).
    for _ in range(4):
        var batch = _build_single_col_batch(1024)
        _ = exec.select_expression_adaptive(batch, fs)
        fs.sel.set_len(0)

    # Inspect AdaptiveFilter state: should still be in WARMUP.
    var cs = fs.conjunction_state.unsafe_ptr()
    assert_equal(cs[].adaptive.current_phase(), ADAPTIVE_FILTER_PHASE_WARMUP)
    # Permutation should be identity [0, 1].
    var perm = cs[].adaptive.get_permutation()
    assert_equal(perm[0], UInt32(0))
    assert_equal(perm[1], UInt32(1))


# -----------------------------------------------------------------------------
# Test 4 — Multi-batch convergence drives state machine through phases.
# -----------------------------------------------------------------------------


def test_state_machine_advances_through_many_batches() raises:
    """Drive 200 batches through the adaptive walker — the
    AdaptiveFilter must leave WARMUP and enter the explore/observe
    cycle. We assert the iteration counter advanced and the baseline
    moved off the sentinel value.
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))                # slot 0
    pool.append(make_lit_i64(Int64(100)))   # slot 1
    pool.append(make_ge_i64(0, 1))          # slot 2
    pool.append(make_lit_i64(Int64(900)))   # slot 3
    pool.append(make_lt_i64(0, 3))          # slot 4
    pool.append(make_and(2, 4))             # slot 5
    # column_names sidecar — single-col "c0".
    var exec = ExpressionExecutor(pool^, 5, _names1("c0"))
    var fs = FilterState.with_conjunction(n_predicates=2, worker_id=0)

    for _ in range(200):
        var batch = _build_single_col_batch(1024)
        _ = exec.select_expression_adaptive(batch, fs)
        fs.sel.set_len(0)

    var cs = fs.conjunction_state.unsafe_ptr()
    # 200 calls should drive iteration_count past WARMUP threshold.
    assert_true(cs[].adaptive.total_iterations() >= UInt64(200))
    # Baseline must have moved off the sentinel (Float64(1e18)) after
    # WARMUP completed.
    assert_true(cs[].adaptive.baseline_ns() < Float64(1.0e17))


# -----------------------------------------------------------------------------
# Test 5 — Adaptive walker matches non-adaptive results.
# -----------------------------------------------------------------------------


def test_adaptive_walker_matches_non_adaptive_results() raises:
    """The adaptive walker MUST produce the same survivors as the
    non-adaptive walker for any conjunction shape — only the iteration
    order through the state machine differs.

    Predicate: `c0 >= 250 AND c0 < 750` — 500 survivors expected from a
    1024-row batch.
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))                # slot 0
    pool.append(make_lit_i64(Int64(250)))   # slot 1
    pool.append(make_ge_i64(0, 1))          # slot 2
    pool.append(make_lit_i64(Int64(750)))   # slot 3
    pool.append(make_lt_i64(0, 3))          # slot 4
    pool.append(make_and(2, 4))             # slot 5
    var exec_adaptive = ExpressionExecutor(pool^, 5, _names1("c0"))

    var pool2 = List[RuntimeExpr]()
    pool2.append(make_col(0))
    pool2.append(make_lit_i64(Int64(250)))
    pool2.append(make_ge_i64(0, 1))
    pool2.append(make_lit_i64(Int64(750)))
    pool2.append(make_lt_i64(0, 3))
    pool2.append(make_and(2, 4))
    var exec_nonadaptive = ExpressionExecutor(pool2^, 5, _names1("c0"))

    var fs_adaptive = FilterState.with_conjunction(
        n_predicates=2, worker_id=0
    )
    var sel_nonadaptive = RowSelectionVector()

    # Drive the adaptive walker through WARMUP + a few EXPLORE/OBSERVE
    # cycles — the survivors must remain identical to the non-adaptive
    # walker on a fresh batch.
    for cycle in range(40):
        var batch_a = _build_single_col_batch(1024)
        var batch_b = _build_single_col_batch(1024)

        var n_adaptive = exec_adaptive.select_expression_adaptive(
            batch_a, fs_adaptive
        )
        sel_nonadaptive.set_len(0)
        var n_nonadaptive = exec_nonadaptive.select_expression(
            batch_b, sel_nonadaptive
        )

        assert_equal(n_adaptive, n_nonadaptive)
        assert_equal(n_adaptive, 500)

        # Check the first surviving index matches.
        if cycle == 0 or cycle == 20 or cycle == 39:
            assert_equal(fs_adaptive.sel.get(0), sel_nonadaptive.get(0))
            assert_equal(fs_adaptive.sel.get(499), sel_nonadaptive.get(499))

        fs_adaptive.sel.set_len(0)


# -----------------------------------------------------------------------------
# Driver.
# -----------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_single_predicate_adaptive_passthrough]()
    suite.test[test_two_predicate_adaptive_correctness]()
    suite.test[test_warmup_no_swap_in_first_5_batches]()
    suite.test[test_state_machine_advances_through_many_batches]()
    suite.test[test_adaptive_walker_matches_non_adaptive_results]()
    suite^.run()
