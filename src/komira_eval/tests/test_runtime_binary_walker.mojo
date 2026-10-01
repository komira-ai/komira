# =============================================================================
# BINARY project-walker
# extraction tests.
#
# Exercises `ExpressionExecutor.eval_to_list_binary_from_view[bo]` — the
# FEED-side extraction that the typed-join build-payload passthrough needs to
# carry a BINARY column through a join byte-exact. BINARY is exactly STRING
# WITHOUT UTF-8 validation, so the walker mirrors the String walker but emits
# `List[List[UInt8]]` (raw bytes) instead of `List[String]`.
#
# What is asserted:
#   - identity sel: every selected row's bytes round-trip byte-exact (incl.
#     bytes that are NOT valid UTF-8: 0x00, 0xFF, 0xC0 0x80, ...).
#   - filter-narrowed sel: extraction is emitted in `sel` order.
#   - null-mask propagation: a null BINARY cell emits False validity + an
#     empty placeholder byte list; a valid cell emits True + its bytes.
#   - unsupported-kind raise: a non-BINARY root (EXPR_LIT_I64) raises.
#
# Sibling tests (typed walkers): test_runtime_project_walker.mojo
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.binary_array import BinaryArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.column import Column
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema
from komira_core.collections.batch_view import BatchView, batch_view_over
from komira_core.io.heap_region import HeapRegion
from komira_eval.expression_executor import ExpressionExecutor
from komira_eval.runtime_expr import (
    RuntimeExpr,
    make_col,
    make_col_binary,
    make_lit_i64,
)
from komira_eval.selection_vector import RowSelectionVector


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _names1(s0: String) -> List[String]:
    var out = List[String]()
    out.append(s0)
    return out^


def _bytes(*vs: UInt8) -> List[UInt8]:
    """Build a List[UInt8] from a varargs of byte literals."""
    var out = List[UInt8]()
    for v in vs:
        out.append(v)
    return out^


def _make_identity_sel(n: Int) -> RowSelectionVector:
    """Build an identity RowSelectionVector [0, 1, ..., n-1]."""
    var sel = RowSelectionVector()
    var i = 0
    while i < n:
        sel.append(UInt32(i))
        i = i + 1
    return sel^


def _build_binary_batch_4() raises -> RecordBatch:
    """Single-column BINARY batch named 'c0' with 4 byte sequences that
    include NON-UTF-8 bytes to prove the walker is byte-exact and does NOT
    UTF-8-validate:
      row0: [0x00, 0x01, 0x02]      (embedded NUL)
      row1: [0xFF, 0xFE]            (high bytes, invalid UTF-8 lead)
      row2: []                      (empty, but valid)
      row3: [0xC0, 0x80, 0x41]      (overlong NUL encoding + 'A')
    """
    var vals = List[List[UInt8]]()
    vals.append(_bytes(0x00, 0x01, 0x02))
    vals.append(_bytes(0xFF, 0xFE))
    vals.append(List[UInt8]())
    vals.append(_bytes(0xC0, 0x80, 0x41))
    var arr = BinaryArray.from_bytes_list(vals^)
    var schema = Schema.from_fields_1(Field("c0", ArrowType.BINARY, True))
    var col = Column.from_binary(arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_binary_batch_nullable() raises -> RecordBatch:
    """Single-column BINARY batch named 'c0' with a NULL at row 1:
      row0: [0x0A, 0x0B]    valid
      row1: NULL            (validity bit cleared)
      row2: [0x0C]          valid
    Built via from_buffers (offsets/data/validity) so we can attach a
    validity bitmap with one cleared bit.
    """
    # offsets (N+1) = [0, 2, 2, 3]; row1 is zero-length AND null.
    var offsets = List[Int32]()
    offsets.append(Int32(0))
    offsets.append(Int32(2))
    offsets.append(Int32(2))
    offsets.append(Int32(3))
    var data = List[UInt8]()
    data.append(UInt8(0x0A))
    data.append(UInt8(0x0B))
    data.append(UInt8(0x0C))
    var validity = Bitmap.create_all_valid(3)
    validity.clear(1)  # row1 -> null
    var arr = BinaryArray.from_buffers(
        offsets, data, Optional[Bitmap[HeapRegion]](validity^), 1
    )
    var schema = Schema.from_fields_1(Field("c0", ArrowType.BINARY, True))
    var col = Column.from_binary(arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _assert_bytes_eq(
    a: List[UInt8], b: List[UInt8], msg: String
) raises -> None:
    assert_equal(len(a), len(b), msg + " (length)")
    var i = 0
    while i < len(a):
        assert_equal(Int(a[i]), Int(b[i]), msg + " (byte " + String(i) + ")")
        i = i + 1


# -----------------------------------------------------------------------------
# BINARY walker tests
# -----------------------------------------------------------------------------


def test_binary_passthrough_identity_sel() raises:
    """`project(col("c0"))` over a BINARY batch (4 rows incl. non-UTF-8 bytes),
    identity sel — every byte round-trips byte-exact."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col_binary(0))
    var exec_ = ExpressionExecutor(pool^, 0, _names1("c0"))

    var batch = _build_binary_batch_4()
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[List[UInt8]]()
    exec_.eval_to_list_binary_from_view(view, 0, sel, out)

    assert_equal(len(out), 4, "binary-passthrough-identity: 4 outputs")
    _assert_bytes_eq(out[0], _bytes(0x00, 0x01, 0x02), "binary out[0]")
    _assert_bytes_eq(out[1], _bytes(0xFF, 0xFE), "binary out[1]")
    _assert_bytes_eq(out[2], List[UInt8](), "binary out[2] (empty)")
    _assert_bytes_eq(out[3], _bytes(0xC0, 0x80, 0x41), "binary out[3]")


def test_binary_passthrough_via_expr_col_legacy() raises:
    """The legacy untyped EXPR_COL leaf must also route through the BINARY
    walker (mirror of the STRING walker's EXPR_COL fallback)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))  # legacy EXPR_COL, not EXPR_COL_BINARY
    var exec_ = ExpressionExecutor(pool^, 0, _names1("c0"))

    var batch = _build_binary_batch_4()
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[List[UInt8]]()
    exec_.eval_to_list_binary_from_view(view, 0, sel, out)

    assert_equal(len(out), 4, "binary-expr-col-legacy: 4 outputs")
    _assert_bytes_eq(out[0], _bytes(0x00, 0x01, 0x02), "legacy out[0]")
    _assert_bytes_eq(out[3], _bytes(0xC0, 0x80, 0x41), "legacy out[3]")


def test_binary_passthrough_filter_narrowed_sel() raises:
    """BINARY walker with sel=[1, 3] over the 4-row batch ⇒ [row1, row3] bytes
    in sel order."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col_binary(0))
    var exec_ = ExpressionExecutor(pool^, 0, _names1("c0"))

    var batch = _build_binary_batch_4()
    var view = batch_view_over(batch)
    var sel = RowSelectionVector()
    sel.append(UInt32(1))
    sel.append(UInt32(3))

    var out = List[List[UInt8]]()
    exec_.eval_to_list_binary_from_view(view, 0, sel, out)

    assert_equal(len(out), 2, "binary-filter: 2 outputs")
    _assert_bytes_eq(out[0], _bytes(0xFF, 0xFE), "binary-filter out[0]=row1")
    _assert_bytes_eq(
        out[1], _bytes(0xC0, 0x80, 0x41), "binary-filter out[1]=row3"
    )


def test_binary_null_mask_propagation() raises:
    """5-arg overload over a nullable BINARY batch [valid, NULL, valid]:
    out_validity must be [True, False, True]; valid rows carry their bytes;
    the null row carries an empty placeholder."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col_binary(0))
    var exec_ = ExpressionExecutor(pool^, 0, _names1("c0"))

    var batch = _build_binary_batch_nullable()
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(3)

    var out = List[List[UInt8]]()
    var out_valid = List[Bool]()
    exec_.eval_to_list_binary_from_view(view, 0, sel, out, out_valid)

    assert_equal(len(out), 3, "binary-null: 3 outputs")
    assert_equal(len(out_valid), 3, "binary-null: 3 validity flags")
    assert_true(out_valid[0], "binary-null validity[0]=True")
    assert_true(not out_valid[1], "binary-null validity[1]=False (NULL)")
    assert_true(out_valid[2], "binary-null validity[2]=True")
    _assert_bytes_eq(out[0], _bytes(0x0A, 0x0B), "binary-null out[0]")
    _assert_bytes_eq(out[1], List[UInt8](), "binary-null out[1] (placeholder)")
    _assert_bytes_eq(out[2], _bytes(0x0C), "binary-null out[2]")


def test_binary_unsupported_kind_raises() raises:
    """BINARY walker on an EXPR_LIT_I64 root MUST raise (extraction-only:
    supports EXPR_COL + EXPR_COL_BINARY)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(Int64(7)))
    var exec_ = ExpressionExecutor(pool^, 0, List[String]())

    var batch = _build_binary_batch_4()
    var view = batch_view_over(batch)
    var sel = _make_identity_sel(4)

    var out = List[List[UInt8]]()
    var raised = False
    try:
        exec_.eval_to_list_binary_from_view(view, 0, sel, out)
    except e:
        raised = True
    assert_true(raised, "binary-unsupported: expected raise")


def main() raises:
    var suite = TestSuite()
    suite.test[test_binary_passthrough_identity_sel]()
    suite.test[test_binary_passthrough_via_expr_col_legacy]()
    suite.test[test_binary_passthrough_filter_narrowed_sel]()
    suite.test[test_binary_null_mask_propagation]()
    suite.test[test_binary_unsupported_kind_raises]()
    suite^.run()
