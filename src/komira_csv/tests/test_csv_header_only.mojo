# =============================================================================
# A file with a header and no records (komira-ai/komira#1128).
# =============================================================================
#
# DuckDB keeps the header's columns for `a,b\n`: two VARCHAR columns, zero
# rows. The readers must agree: the single-thread decode, the schema entry and
# the parallel reader all return the header's names, typed STRING (inference
# over zero rows), or the declared types when the caller declares them.
#
# What each test catches:
#   * test_header_only_batch / _crlf / _no_trailing_newline: the zero-row
#     early return in `read_csv_bytes_to_batch` that built an empty schema
#     (0 columns where 2 are expected).
#   * test_header_only_schema_entry: the same return in
#     `read_csv_bytes_to_schema` (0 fields).
#   * test_header_only_declared_types: a zero-row path that ignores
#     `declared_column_types` and stamps STRING.
#   * test_header_only_projection: a zero-row path that skips projection.
#   * test_parallel_header_then_blank_lines: the parallel concat's all-empty
#     branch, which added fields but no columns, so `RecordBatchBuilder.build`
#     raised "schema has 2 fields, but builder has 0 columns". The body is
#     more than 1 MiB of blank lines so the read is split across workers.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import RecordBatch

from komira_csv import (
    CsvReadOptions,
    Rfc4180,
    read_csv_bytes_to_batch,
    read_csv_bytes_to_batch_parallel,
)
from komira_csv.reader import read_csv_bytes_to_schema


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _assert_ab_strings(rb: RecordBatch, label: String) raises:
    assert_equal(rb.num_columns(), 2, label + ": columns")
    assert_equal(rb.num_rows(), 0, label + ": rows")
    assert_equal(rb.schema.field_at(0).name, String("a"), label)
    assert_equal(rb.schema.field_at(1).name, String("b"), label)
    for i in range(2):
        assert_true(
            rb.schema.field_at(i).arrow_type == ArrowType.STRING, label
        )
        assert_true(rb.column_at(i).arrow_type == ArrowType.STRING, label)
        assert_equal(rb.column_at(i).length(), 0, label)


def _read(data: String, opts: CsvReadOptions) raises -> RecordBatch:
    var buf = _bytes(data)
    return read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)


def test_header_only_batch() raises:
    _assert_ab_strings(_read(String("a,b\n"), CsvReadOptions()), "LF")


def test_header_only_crlf() raises:
    _assert_ab_strings(_read(String("a,b\r\n"), CsvReadOptions()), "CRLF")


def test_header_only_no_trailing_newline() raises:
    _assert_ab_strings(_read(String("a,b"), CsvReadOptions()), "no newline")


def test_header_only_then_blank_lines() raises:
    _assert_ab_strings(
        _read(String("a,b\n\n\n"), CsvReadOptions()), "blank lines"
    )


def test_header_only_schema_entry() raises:
    var buf = _bytes(String("a,b\n"))
    var schema = read_csv_bytes_to_schema[Rfc4180](Span(buf), CsvReadOptions())
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_at(0).name, String("a"))
    assert_equal(schema.field_at(1).name, String("b"))
    assert_true(schema.field_at(0).arrow_type == ArrowType.STRING)
    assert_true(schema.field_at(1).arrow_type == ArrowType.STRING)


def test_header_only_declared_types() raises:
    var opts = CsvReadOptions()
    opts.declared_column_types.append(ArrowType.INT64)
    opts.declared_column_types.append(ArrowType.BOOL)
    var rb = _read(String("a,b\n"), opts)
    assert_equal(rb.num_columns(), 2)
    assert_equal(rb.num_rows(), 0)
    assert_true(rb.schema.field_at(0).arrow_type == ArrowType.INT64)
    assert_true(rb.schema.field_at(1).arrow_type == ArrowType.BOOL)
    assert_true(rb.column_at(0).arrow_type == ArrowType.INT64)
    assert_true(rb.column_at(1).arrow_type == ArrowType.BOOL)


def test_header_only_projection() raises:
    var opts = CsvReadOptions()
    opts.with_projection(String("b"))
    var rb = _read(String("a,b\n"), opts)
    assert_equal(rb.num_columns(), 1)
    assert_equal(rb.num_rows(), 0)
    assert_equal(rb.schema.field_at(0).name, String("b"))


def test_parallel_header_then_blank_lines() raises:
    var buf = _bytes(String("a,b\n"))
    for _ in range(2 * 1024 * 1024):
        buf.append(UInt8(10))
    var rb = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), CsvReadOptions(), n_workers=4
    )
    _assert_ab_strings(rb, "parallel")
    var serial = read_csv_bytes_to_batch[Rfc4180](Span(buf), CsvReadOptions())
    _assert_ab_strings(serial, "serial over the same bytes")


def main() raises:
    test_header_only_batch()
    test_header_only_crlf()
    test_header_only_no_trailing_newline()
    test_header_only_then_blank_lines()
    test_header_only_schema_entry()
    test_header_only_declared_types()
    test_header_only_projection()
    test_parallel_header_then_blank_lines()
