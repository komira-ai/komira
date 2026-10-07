# =============================================================================
# Tests for komira_csv/reader.mojo — end-to-end RecordBatch materialization.
# =============================================================================
#
# Coverage:
#   T1  read_csv_bytes_to_batch: plain CSV with mixed Int64/String columns.
#   T2  read_csv_bytes_to_batch: per-column type inference works on the
#       full Int64 -> Float64 -> Date32 -> Bool -> String lattice.
#   T3  read_csv_bytes_to_batch: RFC-4180 quoted cell with embedded comma
#       is parsed correctly as ONE column (vs the toy reader which would
#       split it).
#   T4  read_csv_bytes_to_batch: RFC-4180 doubled-quote escape unescape.
#   T5  read_csv_bytes_to_batch: pandas-default nulls produce Arrow nulls.
#   T6  read_csv_bytes_to_batch: empty CSV produces empty batch.
#   T7  read_csv_bytes_to_batch: header=False generates col_N names.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch

from komira_csv import (
    CsvReadOptions,
    Rfc4180,
    read_csv_bytes_to_batch,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def test_plain_csv_mixed_columns() raises:
    """T1: plain CSV with Int64 + String columns."""
    var buf = _bytes(String("id,name\n1,alice\n2,bob\n3,charlie\n"))
    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_columns(), 2, "2 columns")
    assert_equal(rb.num_rows(), 3, "3 rows")
    # Column types
    assert_true(rb.schema.field_at(0).arrow_type == ArrowType.INT64, "id is INT64")
    assert_true(rb.schema.field_at(1).arrow_type == ArrowType.STRING, "name is STRING")
    assert_equal(String(rb.schema.field_at(0).name), String("id"))
    assert_equal(String(rb.schema.field_at(1).name), String("name"))


def test_type_inference_lattice() raises:
    """T2: Each row exercises one type; the lattice picks correctly."""
    # 4 cols: int / float / date / bool
    var buf = _bytes(String(
        "a_int,a_float,a_date,a_bool\n"
        "1,1.5,2024-01-01,true\n"
        "2,2.5,2024-01-02,false\n"
        "3,3.5,2024-01-03,true\n"
    ))
    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_columns(), 4)
    assert_equal(rb.num_rows(), 3)
    assert_true(rb.schema.field_at(0).arrow_type == ArrowType.INT64, "INT64")
    assert_true(rb.schema.field_at(1).arrow_type == ArrowType.FLOAT64, "FLOAT64")
    assert_true(rb.schema.field_at(2).arrow_type == ArrowType.DATE32, "DATE32")
    assert_true(rb.schema.field_at(3).arrow_type == ArrowType.BOOL, "BOOL")


def test_rfc4180_quoted_with_comma() raises:
    """T3: KILLER FEATURE — quoted cells with embedded commas are ONE cell.
    A naive split on the delimiter gets this wrong."""
    var buf = _bytes(String(
        "name,addr\n"
        "alice,\"123 Main St, Springfield\"\n"
        "bob,\"456 Oak Ave, Anytown\"\n"
    ))
    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    # MUST be 2 columns (not 3 — the comma inside the quotes is part of
    # the addr field, not a column separator).
    assert_equal(rb.num_columns(), 2, "quoted comma -> still 2 cols")
    assert_equal(rb.num_rows(), 2)
    assert_true(rb.schema.field_at(1).arrow_type == ArrowType.STRING)


def test_rfc4180_doubled_quote_unescape() raises:
    """T4: `""` inside a quoted cell collapses to `"`."""
    var buf = _bytes(String(
        "quote\n"
        "\"hello \"\"world\"\"\"\n"
    ))
    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_rows(), 1)
    assert_equal(rb.num_columns(), 1)
    # Read the cell back: should be `hello "world"`.
    ref col = rb.column_at(0)
    var sarr = col.as_string()
    var s = sarr.get(0)
    assert_equal(s, String("hello \"world\""), "doubled-quote -> single")


def test_null_detection_pandas_defaults() raises:
    """T5: pandas default null tokens produce Arrow nulls."""
    var buf = _bytes(String(
        "id,name\n"
        "1,alice\n"
        ",NULL\n"
        "3,NA\n"
    ))
    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_rows(), 3)
    # id column has a null at row 1 (empty cell)
    ref id_col = rb.column_at(0)
    var id_arr = id_col.as_primitive[DType.int64]()
    assert_true(id_arr.is_null(1), "row 1 id is null")
    # name column: NULL at row 1, NA at row 2
    ref name_col = rb.column_at(1)
    var name_arr = name_col.as_string()
    assert_true(name_arr.is_null(1), "row 1 name is null (NULL token)")
    assert_true(name_arr.is_null(2), "row 2 name is null (NA token)")
    assert_false(name_arr.is_null(0), "row 0 name is NOT null")


def test_empty_csv() raises:
    """T6: empty input -> empty schema + empty batch."""
    var buf = _bytes(String(""))
    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_columns(), 0)
    assert_equal(rb.num_rows(), 0)


def test_no_header_generates_col_n_names() raises:
    """T7: has_header=False -> auto-generated col_N names."""
    var opts = CsvReadOptions()
    opts.has_header = False
    var buf = _bytes(String("1,2,3\n4,5,6\n"))
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_columns(), 3)
    assert_equal(rb.num_rows(), 2, "no header -> both rows are data")
    assert_equal(String(rb.schema.field_at(0).name), String("col_0"))
    assert_equal(String(rb.schema.field_at(1).name), String("col_1"))
    assert_equal(String(rb.schema.field_at(2).name), String("col_2"))


def main() raises:
    test_plain_csv_mixed_columns()
    test_type_inference_lattice()
    test_rfc4180_quoted_with_comma()
    test_rfc4180_doubled_quote_unescape()
    test_null_detection_pandas_defaults()
    test_empty_csv()
    test_no_header_generates_col_n_names()
    print("test_csv_reader_e2e: 7/7 PASS")
