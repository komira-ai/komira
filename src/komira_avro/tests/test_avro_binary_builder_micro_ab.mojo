# =============================================================================
# test_avro_binary_builder_micro_ab.mojo — correctness for the Avro
#   `_BinaryAcc` streaming binary accumulator.
# =============================================================================
#
# `_BinaryAcc` wraps the shared `ArrowStringBuilder` byte accumulator: raw
# value bytes stream directly into Arrow's `(offsets, data)` layout (one
# memcpy/value, no per-value `List[UInt8]`), and `build()` adopts the two Lists
# via `BinaryArray.from_buffers` (one bulk memcpy each — no re-serialize).
#
# This is the binary-heavy fixture: a wide (`AVG_LEN`-byte) binary column with
# N values. Typical fixtures have no binary columns, so the synthetic byte
# values here ARE the binary-heavy workload.
#
# Acceptance: the accumulator produces a byte-identical binary Column (null
# mask, offsets, value bytes).
# =============================================================================

from std.testing import assert_true, assert_equal

from komira_avro import ColumnAccVariant, ReadFieldData
from komira_avro import NULL_NONE, PROMOTE_NONE
from komira_avro.avro_schema import AVRO_KIND_BYTES
from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion


# -----------------------------------------------------------------------------
# Synthetic value generator: a deterministic `AVG_LEN`-byte payload per row.
# -----------------------------------------------------------------------------


@always_inline
def _make_value(i: Int, n_bytes: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n_bytes)
    for j in range(n_bytes):
        out.append(UInt8((i + j) & 0xFF))
    return out^


def _make_rfd_binary() -> ReadFieldData:
    return ReadFieldData(
        avro_kind=AVRO_KIND_BYTES,
        arrow_type=ArrowType.BINARY,
        nullability=NULL_NONE,
        fixed_size=0,
        precision=0,
        scale=0,
        logical_type=String(""),
        promote_to=PROMOTE_NONE,
    )


# -----------------------------------------------------------------------------
# Correctness: the rewritten path must produce a byte-identical binary Column.
# -----------------------------------------------------------------------------


def test_binary_builder_correctness() raises:
    var rfd = _make_rfd_binary()
    var acc = ColumnAccVariant.create(rfd)
    # Push a mix: value, value, null, value (exercise the lazy-validity path).
    var v0 = _make_value(0, 5)
    var v1 = _make_value(7, 3)
    var v3 = _make_value(99, 8)
    acc.push_binary_span(Span(v0))
    acc.push_binary_span(Span(v1))
    acc.push_null()
    acc.push_binary_span(Span(v3))
    var col = acc.build()
    assert_equal(col.length(), 4)

    var arr = col.as_binary()
    assert_equal(len(arr), 4)
    assert_true(not arr.is_null(0))
    assert_true(not arr.is_null(1))
    assert_true(arr.is_null(2))
    assert_true(not arr.is_null(3))

    # Byte-identical value check on the non-null rows.
    var g0 = arr.get(0)
    assert_equal(len(g0), 5)
    for j in range(5):
        assert_equal(Int(g0[j]), Int(v0[j]))
    var g3 = arr.get(3)
    assert_equal(len(g3), 8)
    for j in range(8):
        assert_equal(Int(g3[j]), Int(v3[j]))


def main() raises:
    test_binary_builder_correctness()
    print("test_avro_binary_builder_micro_ab: PASS")
