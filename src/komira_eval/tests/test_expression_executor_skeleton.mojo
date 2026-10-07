# =============================================================================
# Tests for `ExpressionExecutor`.
#
# The executor compiles, constructs over an AoS-as-index-arena pool, and
# serves `select_expression` (the runtime walker).
#
# Coverage:
#   - Construction smoke over leaf / binary-leaf / canonical-7-node pools:
#     the executor takes ownership and exposes `root_idx`. (The vestigial
#     per-node `root_state`/`intermediate_buf` scratch tree was deleted —
#     it had zero eval-path consumers — so the old tree-SHAPE asserts
#     `root_num_children`/`_debug_grandchild_count` are gone; the hot path
#     walks `expression_pool` from `root_idx` directly via tag-dispatch.)
#   - Construction is repeatable (build / drop / build again — a
#     construct/destruct smoke for slab-safety).
#   - `select_expression` filters correctly: `Col(0) > Lit(5)` on
#     `[7, 42, -1]` → rows 0, 1 survive; sel reset-on-entry; zero-row batch.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_kernels.runtime_expr import (
    RuntimeExpr,
    make_and,
    make_col,
    make_gt_i64,
    make_lit_i64,
    make_lt_i64,
)
from komira_eval.expression_executor import ExpressionExecutor
from komira_arrow.selection_vector_row import RowSelectionVector


# -----------------------------------------------------------------------------
# Test helper — build a single-element List[String]. The Mojo 1.0.0b1
# List initializer doesn't accept positional varargs (`List[String]("x")`
# raises "expected at most 0 positional arguments, got 1"), so the
# canonical idiom is construct-empty + append.
# -----------------------------------------------------------------------------


def _names1(s: String) -> List[String]:
    var out = List[String]()
    out.append(s)
    return out^


# -----------------------------------------------------------------------------
# Test pool builders — each returns a (pool, root_idx) pair the ExecutorCtor
# can consume. Pool indices are written explicitly so the test is the canonical
# documentation of the AoS-as-index-arena shape.
# -----------------------------------------------------------------------------


def _build_pool_lit() -> List[RuntimeExpr]:
    """Build a 1-node pool: [Lit(5)]. Root is slot 0 (the only node)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(Int64(5)))  # slot 0
    return pool^


def _build_pool_gt_col_lit() -> List[RuntimeExpr]:
    """Build a 3-node pool: [Lit(5), Col(0), Gt(Col, Lit)]. Root is slot 2."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(Int64(5)))  # slot 0
    pool.append(make_col(0))             # slot 1
    pool.append(make_gt_i64(1, 0))       # slot 2 (Col > Lit)
    return pool^


def _build_pool_and_gt_lt() -> List[RuntimeExpr]:
    """Build the canonical 7-node tree: And(Gt(Col, Lit), Lt(Col, Lit)).

    Pool layout (root at slot 6):
        slot 0: Lit(5)           - RHS of Gt
        slot 1: Col(0)           - LHS of Gt
        slot 2: Gt(Col, Lit)     - left child of And
        slot 3: Lit(100)         - RHS of Lt
        slot 4: Col(0)           - LHS of Lt
        slot 5: Lt(Col, Lit)     - right child of And
        slot 6: And(Gt, Lt)      - root
    """
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(Int64(5)))   # slot 0
    pool.append(make_col(0))              # slot 1
    pool.append(make_gt_i64(1, 0))        # slot 2
    pool.append(make_lit_i64(Int64(100))) # slot 3
    pool.append(make_col(0))              # slot 4
    pool.append(make_lt_i64(4, 3))        # slot 5
    pool.append(make_and(2, 5))           # slot 6 (root)
    return pool^


# -----------------------------------------------------------------------------
# Smoke construction tests
# -----------------------------------------------------------------------------


def test_construct_leaf_tree() raises:
    """A single-node Lit tree constructs; the executor owns its root_idx."""
    var pool = _build_pool_lit()
    var exec = ExpressionExecutor(pool^, 0, List[String]())
    assert_equal(exec.root_idx, 0)
    assert_equal(len(exec.expression_pool), 1)


def test_construct_binary_leaf_tree() raises:
    """A Gt(Col, Lit) pool (3 nodes, root at slot 2) constructs cleanly."""
    var pool = _build_pool_gt_col_lit()
    # column_names sidecar — single-col "x".
    var exec = ExpressionExecutor(pool^, 2, _names1("x"))
    assert_equal(exec.root_idx, 2)
    assert_equal(len(exec.expression_pool), 3)


def test_construct_canonical_m1_tree() raises:
    """The canonical 7-node `And(Gt(Col, Lit), Lt(Col, Lit))` pool constructs.

    Verifies the executor takes ownership of the full 7-node arena with
    the root at slot 6. (The old per-node state-tree SHAPE asserts were
    removed with the vestigial scratch tree — the hot path tag-dispatches
    over `expression_pool` from `root_idx` directly; the actual filter
    behavior is covered by the `select_expression` tests below.)
    """
    var pool = _build_pool_and_gt_lt()
    var exec = ExpressionExecutor(pool^, 6, _names1("x"))

    assert_equal(exec.root_idx, 6)
    assert_equal(len(exec.expression_pool), 7)


def test_construct_repeat_is_clean() raises:
    """Construction is repeatable: drop + rebuild over a fresh pool.

    Construct/destruct smoke for slab safety: the production-type smoke
    equivalent of a 100-cycle tcmalloc stress (4 cycles — enough to
    exercise the constructor / destructor pair).
    """
    var cycle = 0
    while cycle < 4:
        var pool = _build_pool_and_gt_lt()
        var exec = ExpressionExecutor(pool^, 6, _names1("x"))
        assert_equal(exec.root_idx, 6)
        # exec drops at scope end; the pool + sidecar Lists release.
        cycle += 1


# -----------------------------------------------------------------------------
# Stub `select_expression` behavior — identity selection / num_rows pass-through
# -----------------------------------------------------------------------------


def _build_batch_3_rows() raises -> RecordBatch:
    """Build a 3-row RecordBatch with a single Int64 column named "x"."""
    var vals = List[Scalar[DType.int64]]()
    vals.append(Scalar[DType.int64](Int64(7)))
    vals.append(Scalar[DType.int64](Int64(42)))
    vals.append(Scalar[DType.int64](Int64(-1)))
    var arr = PrimitiveArray[DType.int64].from_list(vals)
    var schema = Schema.from_fields_1(Field("x", DType.int64, True))
    var col = Column.from_primitive[DType.int64](arr)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def test_select_expression_gt_filters_correctly() raises:
    """Walker: `Col(0) > Lit(5)` on `[7, 42, -1]` → rows 0, 1 survive."""
    var pool = _build_pool_gt_col_lit()
    var exec = ExpressionExecutor(pool^, 2, _names1("x"))
    var batch = _build_batch_3_rows()
    var sel = RowSelectionVector()

    var n_surv = exec.select_expression(batch, sel)
    # batch = [7, 42, -1]; predicate = `x > 5`; rows 0 and 1 pass.
    assert_equal(n_surv, 2)
    assert_equal(sel.len(), 2)
    assert_equal(sel.get(0), UInt32(0))
    assert_equal(sel.get(1), UInt32(1))


def test_select_expression_resets_sel_on_entry() raises:
    """Walker writes only surviving rows; pre-populated `sel` entries
    are overwritten (the kernel's contract resets true_sel on entry).
    """
    var pool = _build_pool_gt_col_lit()
    var exec = ExpressionExecutor(pool^, 2, _names1("x"))
    var batch = _build_batch_3_rows()
    var sel = RowSelectionVector()
    # Pre-populate with garbage so we can prove reset() was called.
    sel.append(UInt32(999))
    sel.append(UInt32(998))
    sel.append(UInt32(997))
    assert_equal(sel.len(), 3)

    var n_surv = exec.select_expression(batch, sel)
    # Same batch / predicate as above → 2 survivors (rows 0, 1).
    assert_equal(n_surv, 2)
    assert_equal(sel.len(), 2)
    # The garbage 999/998/997 entries are gone (sel was reset by the
    # kernel, then populated with the surviving physical row indices).
    assert_equal(sel.get(0), UInt32(0))
    assert_equal(sel.get(1), UInt32(1))


def test_select_expression_zero_rows() raises:
    """Zero-row batch returns 0 and produces an empty sel."""
    var pool = _build_pool_gt_col_lit()
    var exec = ExpressionExecutor(pool^, 2, _names1("x"))
    # Build an empty 1-column batch via from_list with no values.
    var vals = List[Scalar[DType.int64]]()
    var arr = PrimitiveArray[DType.int64].from_list(vals)
    var schema = Schema.from_fields_1(Field("x", DType.int64, True))
    var col = Column.from_primitive[DType.int64](arr)
    var batch = RecordBatch.from_typed_columns_1(schema^, col^)
    var sel = RowSelectionVector()

    var n_surv = exec.select_expression(batch, sel)
    assert_equal(n_surv, 0)
    assert_equal(sel.len(), 0)
    assert_true(sel.is_empty())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
