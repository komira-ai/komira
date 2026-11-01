# =============================================================================
# Tests for komira_csv header names that are not ASCII.
# =============================================================================
#
# A header name is the cell's bytes. `cell_to_string` once appended
# `chr(Int(byte))` per byte; `chr` takes a code point, so each byte of a
# UTF-8 sequence became its own Latin-1 code point and `café` (5 bytes)
# came back as `cafÃ©` (7 bytes). DuckDB names that column `café`.
#
#   T1  cell_to_string, no unescape: the 5 bytes of `café` come back as is.
#   T2  cell_to_string, RFC 4180 `""` collapse keeps the multi-byte bytes.
#   T3  cell_to_string, Posix `\X` collapse keeps the multi-byte bytes.
#   T4  read_csv_bytes_to_batch: unquoted and quoted non-ASCII header names.
#   T5  read_csv_bytes_to_batch[Posix]: an escaped non-ASCII header name.
#   T6  read_csv_bytes_to_schema: the schema-only path names them the same.
#   T7  read_csv_bytes_to_batch_parallel (4 workers, past the 1 MiB gate).
#   T8  a header byte sequence that is not UTF-8 becomes U+FFFD, so the
#       name is always a valid String.
# =============================================================================

from std.testing import assert_equal

from komira_csv import (
    CsvReadOptions,
    Posix,
    Rfc4180,
    cell_to_string,
    read_csv_bytes_to_batch,
    read_csv_bytes_to_batch_parallel,
)
from komira_csv.reader import read_csv_bytes_to_schema


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _assert_name(got: String, want: String, label: String) raises:
    # Byte length first: the old defect shows as 7 bytes for `café`.
    assert_equal(len(got.as_bytes()), len(want.as_bytes()), label + ": byte length")
    assert_equal(got, want, label)


def test_cell_to_string_plain() raises:
    """T1: no unescape, the bytes are copied."""
    var buf = _bytes(String("café"))
    var s = cell_to_string(Span(buf), False, True, UInt8(0x22), UInt8(0x5C))
    _assert_name(s, String("café"), "T1 plain")


def test_cell_to_string_double_quote() raises:
    """T2: `é""ß` -> `é"ß`."""
    var buf = _bytes(String('é""ß'))
    var s = cell_to_string(Span(buf), True, True, UInt8(0x22), UInt8(0x5C))
    _assert_name(s, String('é"ß'), "T2 doubled quote")


def test_cell_to_string_posix() raises:
    """T3: `\\é\\,ü` -> `é,ü` (an escaped multi-byte lead byte too)."""
    var buf = _bytes(String("\\é\\,ü"))
    var s = cell_to_string(Span(buf), True, False, UInt8(0x22), UInt8(0x5C))
    _assert_name(s, String("é,ü"), "T3 posix")


def test_batch_header_unquoted_and_quoted() raises:
    """T4: the reported repro plus a quoted name with a doubled quote."""
    var buf = _bytes(String('café,"naïve ""x""",日本\n1,2,3\n'))
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), CsvReadOptions())
    assert_equal(rb.num_columns(), 3)
    _assert_name(String(rb.schema.field_at(0).name), String("café"), "T4 unquoted")
    _assert_name(
        String(rb.schema.field_at(1).name), String('naïve "x"'), "T4 quoted"
    )
    _assert_name(String(rb.schema.field_at(2).name), String("日本"), "T4 CJK")


def test_batch_header_posix() raises:
    """T5: a Posix-escaped non-ASCII name."""
    var buf = _bytes(String('"a\\"ö",b\n1,2\n'))
    var rb = read_csv_bytes_to_batch[Posix](Span(buf), CsvReadOptions())
    assert_equal(rb.num_columns(), 2)
    _assert_name(String(rb.schema.field_at(0).name), String('a"ö'), "T5 posix")


def test_schema_header() raises:
    """T6: the schema-only reader names the columns the same way."""
    var buf = _bytes(String('café,"ü"\n1,2\n'))
    var schema = read_csv_bytes_to_schema[Rfc4180](Span(buf), CsvReadOptions())
    _assert_name(String(schema.field_at(0).name), String("café"), "T6 unquoted")
    _assert_name(String(schema.field_at(1).name), String("ü"), "T6 quoted")


def test_parallel_header() raises:
    """T7: 50_000 rows (~1 MiB) so the parallel reader takes 4 workers."""
    var s = String('café,"wert ü"\n')
    var i = 0
    while i < 50_000:
        s += String(i) + String(",") + String(i * 10) + String("\n")
        i = i + 1
    var buf = _bytes(s)
    var rb = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), CsvReadOptions(), n_workers=4
    )
    assert_equal(rb.num_rows(), 50_000)
    _assert_name(String(rb.schema.field_at(0).name), String("café"), "T7 unquoted")
    _assert_name(String(rb.schema.field_at(1).name), String("wert ü"), "T7 quoted")


def test_invalid_utf8_header() raises:
    """T8: a lone 0xFF byte cannot be copied into a String; it becomes U+FFFD."""
    var buf = List[UInt8]()
    buf.append(UInt8(0x61))  # 'a'
    buf.append(UInt8(0xFF))
    var s = cell_to_string(Span(buf), False, True, UInt8(0x22), UInt8(0x5C))
    _assert_name(s, String("a�"), "T8 invalid UTF-8")


def main() raises:
    test_cell_to_string_plain()
    test_cell_to_string_double_quote()
    test_cell_to_string_posix()
    test_batch_header_unquoted_and_quoted()
    test_batch_header_posix()
    test_schema_header()
    test_parallel_header()
    test_invalid_utf8_header()
    print("test_csv_header_non_ascii: 8/8 PASS")
