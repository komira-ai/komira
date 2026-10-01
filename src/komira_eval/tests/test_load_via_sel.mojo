# =============================================================================
# Tests for `load_via_sel` — the column-borrow-site gather primitive.
#
# The row-mode design slices a BatchOf through a SelectionVector at the COLUMN borrow site
# (not via a typed batch wrapper, which is structurally hostile in Mojo
# 1.0.0b1). The `load_via_sel` free function in `komira_eval.selection_vector`
# is that primitive.
#
# Correctness contract: `load_via_sel[T](array, sel, k)` is byte-identical to
# `array.get_typed[Scalar[T]](Int(sel.get(k)))` for every primitive DType.
#
# Coverage: 10 primitive types (i8, i16, i32, i64, u8, u16, u32, u64, f32, f64)
# plus a "two-column gather" parity test that mirrors the
# sum(price * disc) shape (revenue agg over a filtered Q6-style batch).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_eval.selection_vector import (
    RowSelectionVector,
    load_via_sel,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _sel_from_indices(indices: List[UInt32]) -> RowSelectionVector:
    """Build a RowSelectionVector pre-loaded with `indices`."""
    var sv = RowSelectionVector()
    for i in range(len(indices)):
        sv.append(indices[i])
    return sv^


# -----------------------------------------------------------------------------
# Per-DType byte-identical gather (10 primitive types)
# -----------------------------------------------------------------------------


def test_load_via_sel_int8() raises:
    var src = List[Scalar[DType.int8]]()
    for i in range(16):
        src.append(Scalar[DType.int8](i - 8))   # -8..7
    var arr = PrimitiveArray[DType.int8].from_list(src)
    var sel_indices = List[UInt32]()
    sel_indices.append(UInt32(0))
    sel_indices.append(UInt32(3))
    sel_indices.append(UInt32(15))
    var sel = _sel_from_indices(sel_indices)

    for k in range(3):
        var got = load_via_sel[DType.int8](arr, sel, k)
        var want = arr.get_typed[Scalar[DType.int8]](Int(sel.get(k)))
        assert_equal(got, want)


def test_load_via_sel_int16() raises:
    var src = List[Scalar[DType.int16]]()
    for i in range(32):
        src.append(Scalar[DType.int16](i * 100 - 1000))
    var arr = PrimitiveArray[DType.int16].from_list(src)
    var sel_indices = List[UInt32]()
    sel_indices.append(UInt32(1))
    sel_indices.append(UInt32(7))
    sel_indices.append(UInt32(31))
    var sel = _sel_from_indices(sel_indices)

    for k in range(3):
        var got = load_via_sel[DType.int16](arr, sel, k)
        var want = arr.get_typed[Scalar[DType.int16]](Int(sel.get(k)))
        assert_equal(got, want)


def test_load_via_sel_int32() raises:
    var src = List[Scalar[DType.int32]]()
    for i in range(64):
        src.append(Scalar[DType.int32](i * 1_000_000))
    var arr = PrimitiveArray[DType.int32].from_list(src)
    var sel_indices = List[UInt32]()
    sel_indices.append(UInt32(0))
    sel_indices.append(UInt32(17))
    sel_indices.append(UInt32(63))
    var sel = _sel_from_indices(sel_indices)

    for k in range(3):
        var got = load_via_sel[DType.int32](arr, sel, k)
        var want = arr.get_typed[Scalar[DType.int32]](Int(sel.get(k)))
        assert_equal(got, want)


def test_load_via_sel_int64() raises:
    var src = List[Scalar[DType.int64]]()
    for i in range(128):
        src.append(Scalar[DType.int64](Int64(i) * Int64(1_000_000_000)))
    var arr = PrimitiveArray[DType.int64].from_list(src)
    var sel_indices = List[UInt32]()
    sel_indices.append(UInt32(0))
    sel_indices.append(UInt32(64))
    sel_indices.append(UInt32(127))
    var sel = _sel_from_indices(sel_indices)

    for k in range(3):
        var got = load_via_sel[DType.int64](arr, sel, k)
        var want = arr.get_typed[Scalar[DType.int64]](Int(sel.get(k)))
        assert_equal(got, want)


def test_load_via_sel_uint8() raises:
    var src = List[Scalar[DType.uint8]]()
    for i in range(16):
        src.append(Scalar[DType.uint8](i))
    var arr = PrimitiveArray[DType.uint8].from_list(src)
    var sel_indices = List[UInt32]()
    sel_indices.append(UInt32(2))
    sel_indices.append(UInt32(8))
    var sel = _sel_from_indices(sel_indices)

    for k in range(2):
        var got = load_via_sel[DType.uint8](arr, sel, k)
        var want = arr.get_typed[Scalar[DType.uint8]](Int(sel.get(k)))
        assert_equal(got, want)


def test_load_via_sel_uint16() raises:
    var src = List[Scalar[DType.uint16]]()
    for i in range(32):
        src.append(Scalar[DType.uint16](i * 200))
    var arr = PrimitiveArray[DType.uint16].from_list(src)
    var sel_indices = List[UInt32]()
    sel_indices.append(UInt32(5))
    sel_indices.append(UInt32(31))
    var sel = _sel_from_indices(sel_indices)

    for k in range(2):
        var got = load_via_sel[DType.uint16](arr, sel, k)
        var want = arr.get_typed[Scalar[DType.uint16]](Int(sel.get(k)))
        assert_equal(got, want)


def test_load_via_sel_uint32() raises:
    var src = List[Scalar[DType.uint32]]()
    for i in range(64):
        src.append(Scalar[DType.uint32](UInt32(i) * UInt32(1_000_000)))
    var arr = PrimitiveArray[DType.uint32].from_list(src)
    var sel_indices = List[UInt32]()
    sel_indices.append(UInt32(0))
    sel_indices.append(UInt32(33))
    sel_indices.append(UInt32(63))
    var sel = _sel_from_indices(sel_indices)

    for k in range(3):
        var got = load_via_sel[DType.uint32](arr, sel, k)
        var want = arr.get_typed[Scalar[DType.uint32]](Int(sel.get(k)))
        assert_equal(got, want)


def test_load_via_sel_uint64() raises:
    var src = List[Scalar[DType.uint64]]()
    for i in range(128):
        src.append(Scalar[DType.uint64](UInt64(i) * UInt64(1_000_000_000)))
    var arr = PrimitiveArray[DType.uint64].from_list(src)
    var sel_indices = List[UInt32]()
    sel_indices.append(UInt32(0))
    sel_indices.append(UInt32(64))
    sel_indices.append(UInt32(127))
    var sel = _sel_from_indices(sel_indices)

    for k in range(3):
        var got = load_via_sel[DType.uint64](arr, sel, k)
        var want = arr.get_typed[Scalar[DType.uint64]](Int(sel.get(k)))
        assert_equal(got, want)


def test_load_via_sel_float32() raises:
    var src = List[Scalar[DType.float32]]()
    for i in range(64):
        src.append(Scalar[DType.float32](Float32(i) * 3.14159))
    var arr = PrimitiveArray[DType.float32].from_list(src)
    var sel_indices = List[UInt32]()
    sel_indices.append(UInt32(0))
    sel_indices.append(UInt32(15))
    sel_indices.append(UInt32(63))
    var sel = _sel_from_indices(sel_indices)

    for k in range(3):
        var got = load_via_sel[DType.float32](arr, sel, k)
        var want = arr.get_typed[Scalar[DType.float32]](Int(sel.get(k)))
        # Float32 equality: same bit pattern (we read the same memory).
        assert_equal(got, want)


def test_load_via_sel_float64() raises:
    var src = List[Scalar[DType.float64]]()
    for i in range(128):
        src.append(Scalar[DType.float64](Float64(i) * 2.71828))
    var arr = PrimitiveArray[DType.float64].from_list(src)
    var sel_indices = List[UInt32]()
    sel_indices.append(UInt32(0))
    sel_indices.append(UInt32(64))
    sel_indices.append(UInt32(127))
    var sel = _sel_from_indices(sel_indices)

    for k in range(3):
        var got = load_via_sel[DType.float64](arr, sel, k)
        var want = arr.get_typed[Scalar[DType.float64]](Int(sel.get(k)))
        assert_equal(got, want)


# -----------------------------------------------------------------------------
# Two-column gather parity — the `sum(price * disc)` shape.
# -----------------------------------------------------------------------------


def test_two_column_gather_revenue_sum() raises:
    """Two columns gathered through the SAME sel produce
    the SAME `sum(a[sel[k]] * b[sel[k]])` as direct pointer arithmetic.

    This is the Q6 inner loop after the filter has installed a sel.
    """
    var n = 256
    var price_src = List[Scalar[DType.float64]]()
    var disc_src = List[Scalar[DType.float64]]()
    for i in range(n):
        price_src.append(Scalar[DType.float64](1000.0 + Float64(i)))
        disc_src.append(Scalar[DType.float64](0.01 * Float64(i % 100)))

    var price = PrimitiveArray[DType.float64].from_list(price_src)
    var disc = PrimitiveArray[DType.float64].from_list(disc_src)

    # Sel picks every 7th row, 256 / 7 = 37 survivors.
    var sel_indices = List[UInt32]()
    var idx = 0
    while idx < n:
        sel_indices.append(UInt32(idx))
        idx += 7
    var sel = _sel_from_indices(sel_indices)

    var revenue_via_load_via_sel: Float64 = 0.0
    for k in range(sel.len()):
        var p = load_via_sel[DType.float64](price, sel, k)
        var d = load_via_sel[DType.float64](disc, sel, k)
        revenue_via_load_via_sel += Float64(p) * Float64(d)

    # Reference path: direct get_typed at the physical index.
    var revenue_reference: Float64 = 0.0
    for k in range(sel.len()):
        var physical = Int(sel.get(k))
        var p = price.get_typed[Scalar[DType.float64]](physical)
        var d = disc.get_typed[Scalar[DType.float64]](physical)
        revenue_reference += Float64(p) * Float64(d)

    # The two sums walk identical reads — bit-identical, not just close.
    assert_equal(revenue_via_load_via_sel, revenue_reference)


# -----------------------------------------------------------------------------
# Identity selection parity — load_via_sel under identity sel equals
# straight indexing.
# -----------------------------------------------------------------------------


def test_load_via_sel_identity_parity() raises:
    """Under identity selection, load_via_sel[T](arr, sel, k) === arr[k]."""
    var n = 64
    var src = List[Scalar[DType.int64]]()
    for i in range(n):
        src.append(Scalar[DType.int64](Int64(i) * Int64(42)))
    var arr = PrimitiveArray[DType.int64].from_list(src)
    var sel = RowSelectionVector.identity_selection(n)

    for k in range(n):
        var via_sel = load_via_sel[DType.int64](arr, sel, k)
        var direct = arr.get_typed[Scalar[DType.int64]](k)
        assert_equal(via_sel, direct)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
