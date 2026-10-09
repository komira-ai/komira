# =============================================================================
# The SIMD column builders and the parallel reader's per-column helpers,
# called directly on a hand-scanned cell index.
# =============================================================================
#
# The parallel reader is the only caller of these builders, and it hands them
# only well-formed, schema-checked rows, so their null, refusal and short-row
# arms are reachable only by a direct call. Each fixture puts, at the cell
# index a broken short-row check would read, a value the builder parses, so
# dropping that check turns a null into a valid wrong value (red). Each
# docstring names its mutant.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType

from komira_csv import CsvReadOptions, Rfc4180
from komira_csv.csv_scanner_phase1 import scan_csv_phase1_into_cells
from komira_csv.int_column_simd import (
    build_int64_column_simd,
    build_float64_column_simd,
    build_date32_column_simd,
)
from komira_csv.parallel_reader import (
    _build_bool_column,
    _build_column_typed,
    _arrow_type_has_fixed_width_concat,
)
from komira_csv.scanned_cells import ScannedCells
from komira_csv.string_column_simd import build_string_column_simd


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return out^


def _scan(b: List[UInt8]) raises -> ScannedCells:
    return scan_csv_phase1_into_cells[Rfc4180](
        Span(b), UInt8(ord(",")), UInt8(ord('"'))
    )


def test_simd_int64_short_row_and_refusals() raises:
    """Column 1 of `1,2 / 3 / 4,5 / 6,12x / 7,`: 2, missing, 5, unparsable,
    empty. Mutant: drop the short-row check (red: row 1 reads `4`)."""
    var b = _b("1,2\n3\n4,5\n6,12x\n7,\n")
    var c = build_int64_column_simd(Span(b), _scan(b), 0, 1, 5, CsvReadOptions())
    var a = c.as_primitive[DType.int64]()
    assert_equal(a.get(0), Int64(2))
    assert_true(a.is_null(1), "missing")
    assert_equal(a.get(2), Int64(5))
    assert_true(a.is_null(3), "12x")
    assert_true(a.is_null(4), "empty")
    assert_equal(a.null_count, 3)


def test_simd_float64_every_arm() raises:
    """Column 1 of `1,17 / 3 / 4,2.5 / 6,x / 7,`: the integer-shaped `17` takes
    the simple fast path, `2.5` the scalar parser, then a missing cell, an
    unparsable cell and an empty cell are null. Mutant: drop the null append
    on a failed parse (red: `x` reads valid)."""
    var b = _b("1,17\n3\n4,2.5\n6,x\n7,\n")
    var c = build_float64_column_simd(
        Span(b), _scan(b), 0, 1, 5, CsvReadOptions()
    )
    var a = c.as_primitive[DType.float64]()
    assert_equal(a.get(0), Float64(17.0))
    assert_true(a.is_null(1), "missing")
    assert_equal(a.get(2), Float64(2.5))
    assert_true(a.is_null(3), "x")
    assert_true(a.is_null(4), "empty")
    assert_equal(a.null_count, 3)


def test_simd_date32_every_arm() raises:
    """Column 1 of `a,1970-01-02 / b / 1970-01-03,c / d,2024-1-1 / e,`: the
    fast path decodes day 1; a missing cell, a non-canonical date (the
    scalar fallback refuses it too) and an empty cell are null. Mutant: drop
    the short-row check (red: row 1 decodes `1970-01-03`)."""
    var b = _b("a,1970-01-02\nb\n1970-01-03,c\nd,2024-1-1\ne,\n")
    var c = build_date32_column_simd(
        Span(b), _scan(b), 0, 1, 5, CsvReadOptions()
    )
    assert_equal(Int(c.arrow_type.type_id), Int(ArrowType.DATE32.type_id))
    var a = c.as_primitive[DType.int32]()
    assert_equal(a.get(0), Int32(1))
    assert_true(a.is_null(1), "missing")
    assert_true(a.is_null(2), "c")
    assert_true(a.is_null(3), "2024-1-1")
    assert_true(a.is_null(4), "empty")
    assert_equal(a.null_count, 4)


def test_simd_string_short_row() raises:
    """Column 1 of `a,x / b / c,y`: x, missing, y. Mutant: drop the
    short-row check (red: row 1 reads `c`)."""
    var b = _b("a,x\nb\nc,y\n")
    var s = build_string_column_simd(
        Span(b), _scan(b), 0, 1, 3, CsvReadOptions(), UInt8(ord('"')), True,
        UInt8(0),
    )
    assert_equal(s.get(0), "x")
    assert_true(s.is_null(1), "missing")
    assert_equal(s.get(2), "y")


def test_parallel_bool_builder_every_arm() raises:
    """Column 1 of `a,yes / b / no,c / d, / e,maybe`: true, missing, then `c`
    (not a token), empty and `maybe` are null. Mutant: drop the short-row
    check (red: row 1 reads `no`); drop the null append on a failed parse
    (red: `maybe` reads valid false)."""
    var b = _b("a,yes\nb\nno,c\nd,\ne,maybe\n")
    var c = _build_bool_column(Span(b), _scan(b), 0, 1, 5, CsvReadOptions())
    var a = c.as_boolean()
    assert_true(a.get(0), "yes")
    assert_true(a.is_null(1), "missing")
    assert_true(a.is_null(2), "c")
    assert_true(a.is_null(3), "empty")
    assert_true(a.is_null(4), "maybe")


def test_parallel_typed_dispatch() raises:
    """The parallel reader's per-column dispatch builds DATE32 through the SIMD
    date builder and refuses a type it does not build. Mutant: skip the
    DATE32 arm (red: DATE32 is refused as unsupported)."""
    var b = _b("1970-01-03\n")
    var cells = _scan(b)
    var c = _build_column_typed[Rfc4180](
        Span(b), cells, 0, 0, ArrowType.DATE32, 1, CsvReadOptions()
    )
    assert_equal(Int(c.arrow_type.type_id), Int(ArrowType.DATE32.type_id))
    assert_equal(c.as_primitive[DType.int32]().get(0), Int32(2))
    var msg = String("")
    try:
        _ = _build_column_typed[Rfc4180](
            Span(b), cells, 0, 0, ArrowType.INT32, 1, CsvReadOptions()
        )
    except e:
        msg = String(e)
    assert_true(
        msg.find("unsupported inferred ArrowType for column 0") >= 0, msg
    )


def test_fixed_width_concat_predicate() raises:
    """Every base numeric type takes the multi-way fixed-width concat; BOOL,
    DATE32 and STRING do not. Mutant: drop the INT8/UINT8 group (red: INT8
    reports False)."""
    assert_true(_arrow_type_has_fixed_width_concat(ArrowType.INT8), "int8")
    assert_true(_arrow_type_has_fixed_width_concat(ArrowType.UINT8), "uint8")
    assert_true(_arrow_type_has_fixed_width_concat(ArrowType.INT16), "int16")
    assert_true(_arrow_type_has_fixed_width_concat(ArrowType.UINT16), "uint16")
    assert_true(_arrow_type_has_fixed_width_concat(ArrowType.FLOAT16), "f16")
    assert_true(_arrow_type_has_fixed_width_concat(ArrowType.INT32), "int32")
    assert_true(_arrow_type_has_fixed_width_concat(ArrowType.UINT32), "uint32")
    assert_true(_arrow_type_has_fixed_width_concat(ArrowType.FLOAT32), "f32")
    assert_true(_arrow_type_has_fixed_width_concat(ArrowType.INT64), "int64")
    assert_true(_arrow_type_has_fixed_width_concat(ArrowType.FLOAT64), "f64")
    assert_false(_arrow_type_has_fixed_width_concat(ArrowType.BOOL), "bool")
    assert_false(_arrow_type_has_fixed_width_concat(ArrowType.DATE32), "date32")
    assert_false(_arrow_type_has_fixed_width_concat(ArrowType.STRING), "string")


def main() raises:
    test_simd_int64_short_row_and_refusals()
    test_simd_float64_every_arm()
    test_simd_date32_every_arm()
    test_simd_string_short_row()
    test_parallel_bool_builder_every_arm()
    test_parallel_typed_dispatch()
    test_fixed_width_concat_predicate()
    print("test_csv_cov_builders: 7 tests PASS")
