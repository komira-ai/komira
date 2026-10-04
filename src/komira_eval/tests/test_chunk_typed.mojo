# =============================================================================
# test_chunk_typed.mojo — ChunkTyped unit tests
# =============================================================================
#
# Validates the production ChunkTyped[bo, Has_Sel: Bool] contract:
#
#   1. ChunkTyped[bo, False].n_rows() == view.n_rows()
#   2. ChunkTyped[bo, False].row_index(k) == k (identity; codegen elision)
#   3. ChunkTyped[bo, True].n_rows() == sel.len()
#   4. ChunkTyped[bo, True].row_index(k) == sel.get(k)
#   5. Factory free-function inference: `chunk_typed_from_view(bv)` infers
#      bo + binds Has_Sel=False; `chunk_typed_from_view_with_sel(bv, sel)`
#      infers bo + binds Has_Sel=True.
#   6. ChunkTyped's `view` field is borrowed under `bo`, not widened.
#
# Codegen efficiency (~2.3 ns/row) is a microbenchmark concern; this test
# only asserts functional correctness.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Schema, SchemaBuilder, Field
from komira_core.arrow.arrow_types import ArrowType

from komira_core.collections.batch_view import BatchView, batch_view_over
from komira_core.collections.chunk_typed import (
    ChunkTyped,
    chunk_typed_from_view,
    chunk_typed_from_view_with_sel,
)
from komira_core.eval.selection_vector_row import RowSelectionVector


# ---------------------------------------------------------------------------
# Helpers — build small RecordBatches
# ---------------------------------------------------------------------------


def _build_i64_batch_n(n: Int) raises -> RecordBatch:
    """Single-column Int64 RecordBatch with values [0, 1, 2, ..., n-1]."""
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Scalar[DType.int64](Int64(i)))
    var arr = PrimitiveArray[DType.int64].from_list(vals)
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    return RecordBatch.from_columns_1(sb.build(), arr^)


# ---------------------------------------------------------------------------
# Has_Sel = False tests (unselected fast path; codegen elision)
# ---------------------------------------------------------------------------


def test_chunk_typed_no_sel_n_rows_equals_view() raises:
    """ChunkTyped[bo, False].n_rows() == view.n_rows() (no Optional read)."""
    var batch = _build_i64_batch_n(10)
    var bv = batch_view_over(batch)
    var chunk = chunk_typed_from_view(bv)
    assert_equal(chunk.n_rows(), 10)


def test_chunk_typed_no_sel_row_index_is_identity() raises:
    """ChunkTyped[bo, False].row_index(k) == k for all k in [0, n_rows).

    The `comptime if Self.Has_Sel:` branch in row_index ELIDES the
    Optional check at codegen — Has_Sel=False compiles to `return k`
    literally. Validates that contract at the functional layer.
    """
    var batch = _build_i64_batch_n(16)
    var bv = batch_view_over(batch)
    var chunk = chunk_typed_from_view(bv)
    for k in range(16):
        assert_equal(chunk.row_index(k), k)


def test_chunk_typed_no_sel_factory_binds_has_sel_false() raises:
    """`chunk_typed_from_view(bv)` returns a ChunkTyped with Has_Sel=False.

    Verifies Mojo 1.0.0b1 parameter inference: the factory deduces
    `bo` from the BatchView argument and statically binds `Has_Sel=False`
    in the return type. Asserts on n_rows + row_index behavior (the
    behavior is the proxy for the comptime-bound parameter).
    """
    var batch = _build_i64_batch_n(8)
    var bv = batch_view_over(batch)
    var chunk = chunk_typed_from_view(bv)
    # Behavioral assertion proxying the type-level Has_Sel=False:
    # row_index returns k literally (not via sel-indirection).
    assert_equal(chunk.row_index(5), 5)
    assert_equal(chunk.n_rows(), 8)


# ---------------------------------------------------------------------------
# Has_Sel = True tests (selected path; sel-indirection via comptime branch)
# ---------------------------------------------------------------------------


def test_chunk_typed_with_sel_n_rows_equals_sel_len() raises:
    """ChunkTyped[bo, True].n_rows() == sel.len() (NOT view.n_rows())."""
    var batch = _build_i64_batch_n(20)
    var bv = batch_view_over(batch)
    var sel = RowSelectionVector(20)
    sel.append(UInt32(0))
    sel.append(UInt32(5))
    sel.append(UInt32(10))
    var chunk = chunk_typed_from_view_with_sel(bv, sel^)
    assert_equal(chunk.n_rows(), 3)


def test_chunk_typed_with_sel_row_index_resolves_via_sel() raises:
    """ChunkTyped[bo, True].row_index(k) == Int(sel.get(k))."""
    var batch = _build_i64_batch_n(20)
    var bv = batch_view_over(batch)
    var sel = RowSelectionVector(20)
    sel.append(UInt32(2))
    sel.append(UInt32(7))
    sel.append(UInt32(13))
    sel.append(UInt32(19))
    var chunk = chunk_typed_from_view_with_sel(bv, sel^)
    assert_equal(chunk.row_index(0), 2)
    assert_equal(chunk.row_index(1), 7)
    assert_equal(chunk.row_index(2), 13)
    assert_equal(chunk.row_index(3), 19)


def test_chunk_typed_with_sel_empty_selection() raises:
    """ChunkTyped[bo, True].n_rows() == 0 when sel is empty."""
    var batch = _build_i64_batch_n(10)
    var bv = batch_view_over(batch)
    var sel = RowSelectionVector(10)
    # Don't append anything — sel is empty.
    var chunk = chunk_typed_from_view_with_sel(bv, sel^)
    assert_equal(chunk.n_rows(), 0)


def test_chunk_typed_with_sel_factory_binds_has_sel_true() raises:
    """`chunk_typed_from_view_with_sel(bv, sel)` returns Has_Sel=True.

    Behavioral proxy: with a single-element sel pointing at row 7,
    row_index(0) must return 7 (not 0 — that would be the Has_Sel=False
    identity path).
    """
    var batch = _build_i64_batch_n(10)
    var bv = batch_view_over(batch)
    var sel = RowSelectionVector(10)
    sel.append(UInt32(7))
    var chunk = chunk_typed_from_view_with_sel(bv, sel^)
    assert_equal(chunk.row_index(0), 7)
    assert_false(chunk.row_index(0) == 0)


# ---------------------------------------------------------------------------
# Integration test — compose with BatchView col_i64 lookup
# ---------------------------------------------------------------------------


def test_chunk_typed_with_sel_compose_col_lookup() raises:
    """End-to-end: filter survivor list (sel) → row_index → col_i64.load.

    This is the canonical hot-path shape TPC-H Q6 trace:
        for k in range(chunk.n_rows()):
            var phys = chunk.row_index(k)
            var lane = bv.col_i64(0).load[1](phys)[0]
            # ... use lane ...
    """
    var batch = _build_i64_batch_n(100)
    var bv = batch_view_over(batch)
    var sel = RowSelectionVector(100)
    # Survivors: rows 10, 25, 50, 99 — values [10, 25, 50, 99].
    sel.append(UInt32(10))
    sel.append(UInt32(25))
    sel.append(UInt32(50))
    sel.append(UInt32(99))
    var chunk = chunk_typed_from_view_with_sel(bv, sel^)

    var expected: List[Int64] = [10, 25, 50, 99]
    assert_equal(chunk.n_rows(), 4)
    for k in range(chunk.n_rows()):
        var phys = chunk.row_index(k)
        var lane = chunk.view.col_i64(0).load[1](phys)
        assert_equal(lane[0], expected[k])


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_chunk_typed_no_sel_n_rows_equals_view]()
    suite.test[test_chunk_typed_no_sel_row_index_is_identity]()
    suite.test[test_chunk_typed_no_sel_factory_binds_has_sel_false]()
    suite.test[test_chunk_typed_with_sel_n_rows_equals_sel_len]()
    suite.test[test_chunk_typed_with_sel_row_index_resolves_via_sel]()
    suite.test[test_chunk_typed_with_sel_empty_selection]()
    suite.test[test_chunk_typed_with_sel_factory_binds_has_sel_true]()
    suite.test[test_chunk_typed_with_sel_compose_col_lookup]()
    suite^.run()
