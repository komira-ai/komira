# =============================================================================
# The serial reader's less-travelled paths: empty and blank input, the
# schema-only entry's options, the declared-type decode of cells that do not
# parse, nulls in every scalar builder, a short row handed to a builder, the
# file entries and the runtime quote-style dispatch of the schema entry.
# =============================================================================
#
# Each test names the mutant planted against it in its docstring.
# =============================================================================

from std.io import FileHandle
from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch, Schema

from komira_csv import CsvReadOptions, Rfc4180
from komira_csv.csv_options import (
    QUOTE_STYLE_TAG_RFC4180,
    QUOTE_STYLE_TAG_EXCEL,
    QUOTE_STYLE_TAG_POSIX,
)
from komira_csv.csv_scanner_phase1 import scan_csv_phase1_into_cells
from komira_csv.scanned_cells import ScannedCells
from komira_csv.reader import (
    read_csv_to_batch,
    read_csv_to_batch_with_options,
    read_csv_bytes_to_batch,
    read_csv_bytes_to_schema,
    read_csv_bytes_to_schema_dynamic,
    _build_int64_column,
    _build_float64_column,
    _build_date32_column,
    _build_bool_column,
)
from komira_runtime_paths import test_tmpdir


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return out^


def _read(text: String, opts: CsvReadOptions) raises -> RecordBatch:
    var b = _b(text)
    return read_csv_bytes_to_batch[Rfc4180](Span(b), opts)


def _schema(text: String, opts: CsvReadOptions) raises -> Schema:
    var b = _b(text)
    return read_csv_bytes_to_schema[Rfc4180](Span(b), opts)


def _tid(t: ArrowType) -> Int:
    return Int(t.type_id)


def test_blank_and_empty_input() raises:
    """Input of blank lines only decodes to an empty batch; the schema entry
    returns an empty schema for empty bytes and for blank lines. Mutant:
    drop the batch entry's `total_rows == 0` return (red: row 0 of an empty
    cell index is read)."""
    var rb = _read("\n\n", CsvReadOptions())
    assert_equal(rb.num_columns(), 0)
    assert_equal(rb.num_rows(), 0)
    assert_equal(_schema("", CsvReadOptions()).num_columns(), 0)
    assert_equal(_schema("\n\n\n", CsvReadOptions()).num_columns(), 0)


def test_schema_entry_options() raises:
    """The schema entry honours `has_header = False` (names `col_<i>`), a
    declared type list (used verbatim), temporal inference, and a projection
    (unprojected columns omitted). Mutant: keep unprojected columns (red: 3
    fields)."""
    var noh = CsvReadOptions()
    noh.has_header = False
    var s1 = _schema("1,x\n2,y\n", noh)
    assert_equal(s1.num_columns(), 2)
    assert_equal(s1.field_name(0), "col_0")
    assert_equal(s1.field_name(1), "col_1")
    assert_equal(_tid(s1.field_arrow_type(0)), _tid(ArrowType.INT64))

    var dec = CsvReadOptions()
    dec.declared_column_types.append(ArrowType.STRING)
    dec.declared_column_types.append(ArrowType.FLOAT64)
    var s2 = _schema("a,b\n1,2\n", dec)
    assert_equal(_tid(s2.field_arrow_type(0)), _tid(ArrowType.STRING))
    assert_equal(_tid(s2.field_arrow_type(1)), _tid(ArrowType.FLOAT64))

    var wide = CsvReadOptions()
    wide.with_temporal_inference(True)
    var s3 = _schema("t\n12:00:00\n", wide)
    assert_equal(_tid(s3.field_arrow_type(0)), _tid(ArrowType.TIME32_S))

    var proj = CsvReadOptions()
    proj.with_projection(String("c"))
    var s4 = _schema("a,b,c\n1,2,3\n", proj)
    assert_equal(s4.num_columns(), 1)
    assert_equal(s4.field_name(0), "c")


def test_schema_prefix_snaps_back_to_a_row_end() raises:
    """Over 256 KiB the schema entry scans a prefix ending at the last LF
    before the budget. Header `nnnn,mm` (8 bytes) and 11-byte rows
    `1234,-5678` put the budget end (262144) right after a row's `-`, so
    without the snap the sampled cell `-` would make column `mm` STRING; with
    it both columns infer INT64. `infer_rows = -1` makes inference read every
    scanned row, so the last one counts. Mutant: skip the walk back (`snap =
    snap - 1` -> `snap = scan_start`; red: `mm` is STRING)."""
    var text = String("nnnn,mm\n")
    var row = String("1234,-5678\n")
    for _ in range(30000):
        text += row
    assert_equal((262144 - 8) % 11, 6)
    var o = CsvReadOptions()
    o.infer_rows = -1  # sample every scanned row, the last one included
    var s = _schema(text, o)
    assert_equal(s.num_columns(), 2)
    assert_equal(_tid(s.field_arrow_type(0)), _tid(ArrowType.INT64))
    assert_equal(_tid(s.field_arrow_type(1)), _tid(ArrowType.INT64))


def test_declared_types_decode_unparsable_cells_to_null() raises:
    """At declared INT64 / FLOAT64 / DATE32 / BOOL a cell that does not parse
    is a typed null, not an error and not a wrong value; `2024-1-1` misses
    the date fast path and the scalar parser too. Mutant: drop the INT64
    builder's null append on a failed parse (red: `x` reads valid 0)."""
    var o = CsvReadOptions()
    o.declared_column_types.append(ArrowType.INT64)
    o.declared_column_types.append(ArrowType.FLOAT64)
    o.declared_column_types.append(ArrowType.DATE32)
    o.declared_column_types.append(ArrowType.BOOL)
    var rb = _read("i,f,d,b\n7,2.5,1970-01-02,yes\nx,y,2024-1-1,maybe\n", o)
    assert_equal(rb.num_rows(), 2)
    var i = rb.column_at(0).as_primitive[DType.int64]()
    assert_equal(i.get(0), Int64(7))
    assert_true(i.is_null(1), "int x -> null")
    var f = rb.column_at(1).as_primitive[DType.float64]()
    assert_equal(f.get(0), Float64(2.5))
    assert_true(f.is_null(1), "float y -> null")
    var d = rb.column_at(2).as_primitive[DType.int32]()
    assert_equal(d.get(0), Int32(1))
    assert_true(d.is_null(1), "date 2024-1-1 -> null")
    var bo = rb.column_at(3).as_boolean()
    assert_true(bo.get(0), "yes -> true")
    assert_true(bo.is_null(1), "maybe -> null")


def test_inferred_columns_with_null_cells() raises:
    """An empty cell in an inferred FLOAT64 / DATE32 / BOOL column is null and
    the other row keeps its value. Mutant: skip the FLOAT64 validity clear
    loop (red: the null reads valid)."""
    var rb = _read(
        "f,d,b,s\n1.5,2024-01-01,true,x\n,,,y\n", CsvReadOptions()
    )
    assert_equal(_tid(rb.schema.field_arrow_type(0)), _tid(ArrowType.FLOAT64))
    assert_equal(_tid(rb.schema.field_arrow_type(1)), _tid(ArrowType.DATE32))
    assert_equal(_tid(rb.schema.field_arrow_type(2)), _tid(ArrowType.BOOL))
    var f = rb.column_at(0).as_primitive[DType.float64]()
    assert_false(f.is_null(0), "1.5 valid")
    assert_true(f.is_null(1), "empty float null")
    var d = rb.column_at(1).as_primitive[DType.int32]()
    assert_equal(d.get(0), Int32(19723))
    assert_true(d.is_null(1), "empty date null")
    var bo = rb.column_at(2).as_boolean()
    assert_true(bo.get(0), "true")
    assert_true(bo.is_null(1), "empty bool null")


def _short_rows(text: String) raises -> ScannedCells:
    var b = _b(text)
    return scan_csv_phase1_into_cells[Rfc4180](
        Span(b), UInt8(ord(",")), UInt8(ord('"'))
    )


def test_builders_treat_a_missing_cell_as_null() raises:
    """The builders are handed rows by position; a row shorter than the column
    index (the readers refuse such records first, so only a direct call gets
    here) reads as null. Each fixture's row 2 holds, at the cell index a
    missing-row check would wrongly read, a value the builder parses.
    Mutant: drop the INT64 builder's short-row check (red: row 1 decodes row
    2's first cell)."""
    var o = CsvReadOptions()
    var bi = _b("1,2\n3\n4,5\n")
    var ci = _build_int64_column(Span(bi), _short_rows("1,2\n3\n4,5\n"), 0, 1, 3, o)
    var ai = ci.as_primitive[DType.int64]()
    assert_equal(ai.get(0), Int64(2))
    assert_true(ai.is_null(1), "int missing")
    assert_equal(ai.get(2), Int64(5))
    var cf = _build_float64_column(
        Span(bi), _short_rows("1,2\n3\n4,5\n"), 0, 1, 3, o
    )
    var af = cf.as_primitive[DType.float64]()
    assert_true(af.is_null(1), "float missing")
    assert_equal(af.get(2), Float64(5.0))
    var dt = String("a,1970-01-02\nb\n1970-01-03,c\n")
    var bd = _b(dt)
    var cd = _build_date32_column(Span(bd), _short_rows(dt), 0, 1, 3, o)
    var ad = cd.as_primitive[DType.int32]()
    assert_equal(ad.get(0), Int32(1))
    assert_true(ad.is_null(1), "date missing")
    var bt = String("a,no\nb\nyes,c\n")
    var bb = _b(bt)
    var cb = _build_bool_column(Span(bb), _short_rows(bt), 0, 1, 3, o)
    var ab = cb.as_boolean()
    assert_false(ab.get(0), "no -> false")
    assert_true(ab.is_null(1), "bool missing")


def test_file_entries_and_schema_dispatch() raises:
    """`read_csv_to_batch` and `read_csv_to_batch_with_options` read a file
    from disk; the schema entry's runtime dispatch reaches each dialect and
    refuses an unknown tag. Mutant: route the schema entry's Posix tag to
    Rfc4180 (red: the `\\"` escape is not honoured and the record is refused
    as a stray byte after a closing quote)."""
    var path = test_tmpdir() + "/cov_reader.csv"
    var fh = FileHandle(path, "w")
    fh.write("a,b\n1,x\n2,y\n")
    fh.close()
    var rb = read_csv_to_batch(path)
    assert_equal(rb.num_rows(), 2)
    assert_equal(rb.schema.field_name(1), "b")
    var noh = CsvReadOptions()
    noh.has_header = False
    var rb2 = read_csv_to_batch_with_options[Rfc4180](path, noh)
    assert_equal(rb2.num_rows(), 3)

    var posix_text = _b('a,b\n"p\\"q",1\n')
    var o = CsvReadOptions()
    o.quote_style_tag = QUOTE_STYLE_TAG_POSIX
    var sp = read_csv_bytes_to_schema_dynamic(Span(posix_text), o)
    assert_equal(sp.num_columns(), 2)
    assert_equal(_tid(sp.field_arrow_type(1)), _tid(ArrowType.INT64))
    o.quote_style_tag = QUOTE_STYLE_TAG_EXCEL
    var plain = _b("a\n1\n")
    assert_equal(read_csv_bytes_to_schema_dynamic(Span(plain), o).num_columns(), 1)
    o.quote_style_tag = QUOTE_STYLE_TAG_RFC4180
    assert_equal(read_csv_bytes_to_schema_dynamic(Span(plain), o).num_columns(), 1)
    o.quote_style_tag = 9
    var msg = String("")
    try:
        _ = read_csv_bytes_to_schema_dynamic(Span(plain), o)
    except e:
        msg = String(e)
    assert_true(msg.find("unknown options.quote_style_tag 9") >= 0, msg)


def main() raises:
    test_blank_and_empty_input()
    test_schema_entry_options()
    test_schema_prefix_snaps_back_to_a_row_end()
    test_declared_types_decode_unparsable_cells_to_null()
    test_inferred_columns_with_null_cells()
    test_builders_treat_a_missing_cell_as_null()
    test_file_entries_and_schema_dispatch()
    print("test_csv_cov_reader: 7 tests PASS")
