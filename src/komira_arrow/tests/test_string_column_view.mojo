# =============================================================================
# Unit tests for StringColumnView[origin] + BinaryColumnView[origin]
# =============================================================================
#
# The untyped varlen column views used by the row and column untyped
# execution paths.
#
# Coverage:
#   StringColumnView:
#     1. basic 4-row STRING column round-trip via .get(row).to_string()
#     2. offset_at(row) cumulative byte semantics
#     3. n_data_bytes() = offset_at(length())
#     4. byte_at(i) per-byte access within a cell
#     5. empty strings (0-length cells)
#     6. 1000-row stress (capacity grow + correctness)
#     7. round-trip via BatchView.col_str() accessor
#
#   BinaryColumnView:
#     8. basic 3-row BINARY column round-trip (mirror of STRING)
#     9. round-trip via BatchView.col_binary() accessor
#
#   Error paths:
#    10. get() on non-varlen column raises
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.binary_array import BinaryArray
from komira_arrow.column import Column
from komira_arrow.large_binary_array import LargeBinaryArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_arrow.string_array import StringArray
from komira_arrow.batch_view import BatchView, batch_view_over
from komira_arrow.string_column_view import BinaryColumnView, StringColumnView


# =============================================================================
# Builders
# =============================================================================


def _build_string_batch_4rows() raises -> RecordBatch:
    """4-row STRING batch: ['hello', 'world', 'foo', 'bar']."""
    var vals = List[String]()
    vals.append(String("hello"))
    vals.append(String("world"))
    vals.append(String("foo"))
    vals.append(String("bar"))
    var arr = StringArray.from_strings(vals^)
    var schema = Schema.from_fields_1(Field("s", DType.uint8, True))
    var col = Column.from_string(arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_string_batch_with_empty() raises -> RecordBatch:
    """4-row STRING batch with empty cells: ['', 'x', '', 'longer']."""
    var vals = List[String]()
    vals.append(String(""))
    vals.append(String("x"))
    vals.append(String(""))
    vals.append(String("longer"))
    var arr = StringArray.from_strings(vals^)
    var schema = Schema.from_fields_1(Field("s", DType.uint8, True))
    var col = Column.from_string(arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_int64_batch_3rows() raises -> RecordBatch:
    """Non-varlen column for error-path tests."""
    var vals = List[Scalar[DType.int64]]()
    vals.append(Scalar[DType.int64](Int64(10)))
    vals.append(Scalar[DType.int64](Int64(20)))
    vals.append(Scalar[DType.int64](Int64(30)))
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var schema = Schema.from_fields_1(Field("x", DType.int64, True))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_string_batch_1000rows() raises -> RecordBatch:
    """1000-row stress STRING batch with varying lengths."""
    var vals = List[String]()
    for i in range(1000):
        # Mix of lengths: 0, short, medium, with index in the content
        var modi = i % 4
        if modi == 0:
            vals.append(String(""))
        elif modi == 1:
            vals.append(String("a"))
        elif modi == 2:
            vals.append(String("medium-len"))
        else:
            vals.append(String("longer-content-here-") + String(i))
    var arr = StringArray.from_strings(vals^)
    var schema = Schema.from_fields_1(Field("s", DType.uint8, True))
    var col = Column.from_string(arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_binary_batch_3rows() raises -> RecordBatch:
    """3-row BINARY batch with arbitrary byte payloads."""
    var blobs = List[List[UInt8]]()
    var b0 = List[UInt8]()
    b0.append(UInt8(0xDE))
    b0.append(UInt8(0xAD))
    blobs.append(b0^)
    var b1 = List[UInt8]()
    b1.append(UInt8(0xBE))
    b1.append(UInt8(0xEF))
    b1.append(UInt8(0xCA))
    b1.append(UInt8(0xFE))
    blobs.append(b1^)
    var b2 = List[UInt8]()
    blobs.append(b2^)  # empty
    var arr = BinaryArray.from_bytes_list(blobs^)
    var schema = Schema.from_fields_1(Field("b", DType.uint8, True))
    var col = Column.from_binary(arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


# =============================================================================
# Tests
# =============================================================================


def test_string_column_view_basic_round_trip() raises:
    """Gate 1: basic 4-row STRING column .get(row).to_string()."""
    var batch = _build_string_batch_4rows()
    var bv = batch_view_over(batch)
    var sv = StringColumnView(bv._batch, 0)

    assert_equal(sv.length(), 4)

    var s0 = sv.get(0)
    assert_equal(s0.length(), 5)
    assert_equal(s0.to_string(), String("hello"))

    var s1 = sv.get(1)
    assert_equal(s1.length(), 5)
    assert_equal(s1.to_string(), String("world"))

    var s2 = sv.get(2)
    assert_equal(s2.length(), 3)
    assert_equal(s2.to_string(), String("foo"))

    var s3 = sv.get(3)
    assert_equal(s3.length(), 3)
    assert_equal(s3.to_string(), String("bar"))


def test_string_column_view_offset_at() raises:
    """Gate 2: offset_at(row) returns cumulative byte offset."""
    var batch = _build_string_batch_4rows()
    var bv = batch_view_over(batch)
    var sv = StringColumnView(bv._batch, 0)

    # Lengths: "hello"=5, "world"=5, "foo"=3, "bar"=3
    # Cumulative offsets: 0, 5, 10, 13, 16
    assert_equal(sv.offset_at(0), 0)
    assert_equal(sv.offset_at(1), 5)
    assert_equal(sv.offset_at(2), 10)
    assert_equal(sv.offset_at(3), 13)
    assert_equal(sv.offset_at(4), 16)


def test_string_column_view_n_data_bytes() raises:
    """Gate 3: n_data_bytes() returns total payload byte count."""
    var batch = _build_string_batch_4rows()
    var bv = batch_view_over(batch)
    var sv = StringColumnView(bv._batch, 0)

    # 5 + 5 + 3 + 3 = 16
    assert_equal(sv.n_data_bytes(), 16)


def test_string_view_byte_at() raises:
    """Gate 4: byte_at(i) per-byte access within a cell."""
    var batch = _build_string_batch_4rows()
    var bv = batch_view_over(batch)
    var sv = StringColumnView(bv._batch, 0)

    # "hello" -> [0x68, 0x65, 0x6C, 0x6C, 0x6F]
    var s0 = sv.get(0)
    assert_equal(s0.byte_at(0), UInt8(0x68))  # 'h'
    assert_equal(s0.byte_at(1), UInt8(0x65))  # 'e'
    assert_equal(s0.byte_at(2), UInt8(0x6C))  # 'l'
    assert_equal(s0.byte_at(3), UInt8(0x6C))  # 'l'
    assert_equal(s0.byte_at(4), UInt8(0x6F))  # 'o'


def test_string_column_view_empty_cells() raises:
    """Gate 5: 0-length cells are read back as 0-length, not error."""
    var batch = _build_string_batch_with_empty()
    var bv = batch_view_over(batch)
    var sv = StringColumnView(bv._batch, 0)

    assert_equal(sv.length(), 4)

    var s0 = sv.get(0)
    assert_equal(s0.length(), 0)
    assert_equal(s0.to_string(), String(""))

    var s1 = sv.get(1)
    assert_equal(s1.length(), 1)
    assert_equal(s1.to_string(), String("x"))

    var s2 = sv.get(2)
    assert_equal(s2.length(), 0)

    var s3 = sv.get(3)
    assert_equal(s3.length(), 6)
    assert_equal(s3.to_string(), String("longer"))


def test_string_column_view_1000_row_stress() raises:
    """Gate 6: 1000-row stress (capacity grow + correctness)."""
    var batch = _build_string_batch_1000rows()
    var bv = batch_view_over(batch)
    var sv = StringColumnView(bv._batch, 0)

    assert_equal(sv.length(), 1000)

    # Verify a sampling
    for i in range(0, 1000, 100):
        var sv_cell = sv.get(i)
        var modi = i % 4
        if modi == 0:
            assert_equal(sv_cell.length(), 0)
        elif modi == 1:
            assert_equal(sv_cell.length(), 1)
            assert_equal(sv_cell.to_string(), String("a"))
        elif modi == 2:
            assert_equal(sv_cell.length(), 10)
            assert_equal(sv_cell.to_string(), String("medium-len"))
        else:
            # "longer-content-here-" + index
            var expect = String("longer-content-here-") + String(i)
            assert_equal(sv_cell.to_string(), expect)


def test_batch_view_col_str_accessor() raises:
    """Gate 7: BatchView.col_str(idx) returns StringColumnView."""
    var batch = _build_string_batch_4rows()
    var bv = batch_view_over(batch)

    var sv = bv.col_str(0)
    assert_equal(sv.length(), 4)
    var s0 = sv.get(0)
    assert_equal(s0.to_string(), String("hello"))


def test_binary_column_view_basic_round_trip() raises:
    """Gate 8: basic 3-row BINARY column .get(row) round-trip."""
    var batch = _build_binary_batch_3rows()
    var bv = batch_view_over(batch)
    var bcv = BinaryColumnView(bv._batch, 0)

    assert_equal(bcv.length(), 3)

    var b0 = bcv.get(0)
    assert_equal(b0.length(), 2)
    assert_equal(b0.byte_at(0), UInt8(0xDE))
    assert_equal(b0.byte_at(1), UInt8(0xAD))

    var b1 = bcv.get(1)
    assert_equal(b1.length(), 4)
    assert_equal(b1.byte_at(0), UInt8(0xBE))
    assert_equal(b1.byte_at(1), UInt8(0xEF))
    assert_equal(b1.byte_at(2), UInt8(0xCA))
    assert_equal(b1.byte_at(3), UInt8(0xFE))

    var b2 = bcv.get(2)
    assert_equal(b2.length(), 0)


def test_batch_view_col_binary_accessor() raises:
    """Gate 9: BatchView.col_binary(idx) returns BinaryColumnView."""
    var batch = _build_binary_batch_3rows()
    var bv = batch_view_over(batch)

    var bcv = bv.col_binary(0)
    assert_equal(bcv.length(), 3)
    var b1 = bcv.get(1)
    assert_equal(b1.length(), 4)
    assert_equal(b1.byte_at(0), UInt8(0xBE))


def test_string_column_view_non_varlen_raises() raises:
    """Gate 10: .get() on a non-varlen (Int64) column raises."""
    var batch = _build_int64_batch_3rows()
    var bv = batch_view_over(batch)
    var sv = StringColumnView(bv._batch, 0)

    var raised = False
    try:
        var _s = sv.get(0)
    except:
        raised = True
    assert_true(raised, "expected raise on get() over non-varlen column")


# =============================================================================
# WIDE-OFFSET (LARGE_STRING / LARGE_BINARY) COVERAGE, at the UNTYPED VIEW
# substrate rather than in the agg consumers.
# =============================================================================
#
# THE HAZARD. A view that read the offsets buffer with a HARDCODED
# `read_i32_le_at(row * 4)` and never consulted the column's own `arrow_type`
# would misread a LARGE_STRING / LARGE_BINARY column, which carries an INT64
# offsets buffer: that read is element-indexed at the wrong stride: index k
# returns low32(O[k/2]) for even k and high32(O[k/2]) for odd k. Sub-2GB
# offsets have an all-zero high half, so the wide offsets [0, 5, 10] decode as
# [0, 0, 5, ...] and EVERY row gets the wrong byte span.
#
# CONSEQUENCE: a silent wrong VALUE with a correct row COUNT — `length()` is
# read off the column, not the offsets, so every row-count assertion passes.
# These views are the untyped substrate under `BatchView.col_str` /
# `col_binary`, i.e. under the sort/top-N payload ingest, the untyped hash agg,
# the untyped join build, `distinct_state` and the search sink. Any promoted
# (>2 GiB) string column reaching ANY of them is read as garbage.
#
# WHY 2 ROWS AND WHY THE ASSERTIONS STOP AT ROW 1. At row index 2 a 4-byte
# read gives start=low32(O[1]), end=high32(O[1])=0, so the byte length goes
# NEGATIVE. `to_string` iterates `range(negative)` and yields "", but a third
# row buys no coverage the first two do not already provide, and the sibling
# falsifier for this defect class (a large-string offset-width test in
# komira_engine_operators) records an ALLOCATOR ABORT at that index in its own consumers. 2 rows is the
# largest case that stays unambiguously in bounds and it falsifies every read.
#
# EACH WIDE CASE IS PAIRED WITH A BYTE-IDENTICAL NARROW CONTROL. If a control
# ever fails, the harness is wrong, not the view.
# =============================================================================


def _build_large_string_batch_2rows() raises -> RecordBatch:
    """2-row LARGE_STRING batch: ['hello', 'world'] (INT64 offsets)."""
    var vals = List[String]()
    vals.append(String("hello"))
    vals.append(String("world"))
    var arr = LargeStringArray.from_strings(vals)
    var schema = Schema.from_fields_1(Field("s", ArrowType.LARGE_STRING, True))
    var col = Column.from_large_string(arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_string_batch_2rows() raises -> RecordBatch:
    """The NARROW control: byte-identical values, INT32 offsets."""
    var vals = List[String]()
    vals.append(String("hello"))
    vals.append(String("world"))
    var arr = StringArray.from_strings(vals^)
    var schema = Schema.from_fields_1(Field("s", ArrowType.STRING, True))
    var col = Column.from_string(arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_large_binary_batch_2rows() raises -> RecordBatch:
    """2-row LARGE_BINARY batch: [DE AD, BE EF CA FE] (INT64 offsets)."""
    var blobs = List[List[UInt8]]()
    var b0 = List[UInt8]()
    b0.append(UInt8(0xDE))
    b0.append(UInt8(0xAD))
    blobs.append(b0^)
    var b1 = List[UInt8]()
    b1.append(UInt8(0xBE))
    b1.append(UInt8(0xEF))
    b1.append(UInt8(0xCA))
    b1.append(UInt8(0xFE))
    blobs.append(b1^)
    var arr = LargeBinaryArray.from_bytes_list(blobs)
    var schema = Schema.from_fields_1(Field("b", ArrowType.LARGE_BINARY, True))
    var col = Column.from_large_binary(arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _assert_two_string_rows(imm batch: RecordBatch) raises:
    """`['hello', 'world']` reads back verbatim. One body, both widths — the
    expectation is IDENTICAL by construction, since the two columns hold
    byte-identical values and differ only in offset width."""
    var bv = batch_view_over(batch)
    var scv = bv.col_str(0)

    assert_equal(scv.length(), 2)

    # (a) the defect stated directly: the decoded byte SPAN. Asserted before
    #     the value, because a wrong span is the mechanism and a wrong string
    #     is merely its symptom.
    assert_equal(scv.offset_at(0), 0)
    assert_equal(scv.offset_at(1), 5)
    assert_equal(scv.n_data_bytes(), 10)

    # (b) the values themselves.
    var v0 = scv.get(0)
    assert_equal(v0.length(), 5)
    assert_equal(v0.to_string(), String("hello"))

    var v1 = scv.get(1)
    assert_equal(v1.length(), 5)
    assert_equal(v1.to_string(), String("world"))


def test_string_column_view_wide_offsets_falsifier() raises:
    """FALSIFIER: a LARGE_STRING column read through `col_str` must decode at
    INT64 offset width. A 4-byte read would decode row 0 as the EMPTY string
    (start=low32(O[0])=0, end=high32(O[0])=0) while `length()` still says 2."""
    _assert_two_string_rows(_build_large_string_batch_2rows())


def test_string_column_view_narrow_offsets_control() raises:
    """CONTROL for the falsifier above: byte-identical STRING values at INT32
    offset width. Must always pass."""
    _assert_two_string_rows(_build_string_batch_2rows())


def test_binary_column_view_wide_offsets_falsifier() raises:
    """FALSIFIER: the `BinaryColumnView` mirror. LARGE_BINARY carries the same
    INT64 offsets buffer and the same hardcoded 4-byte read."""
    var batch = _build_large_binary_batch_2rows()
    var bv = batch_view_over(batch)
    var bcv = bv.col_binary(0)

    assert_equal(bcv.length(), 2)
    assert_equal(bcv.offset_at(0), 0)
    assert_equal(bcv.offset_at(1), 2)
    assert_equal(bcv.n_data_bytes(), 6)

    var b0 = bcv.get(0)
    assert_equal(b0.length(), 2)
    assert_equal(b0.byte_at(0), UInt8(0xDE))
    assert_equal(b0.byte_at(1), UInt8(0xAD))

    var b1 = bcv.get(1)
    assert_equal(b1.length(), 4)
    assert_equal(b1.byte_at(0), UInt8(0xBE))
    assert_equal(b1.byte_at(3), UInt8(0xFE))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
