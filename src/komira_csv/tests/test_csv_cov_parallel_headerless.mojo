# =============================================================================
# The parallel reader without a header row (over 1 MiB, four workers).
# =============================================================================
#
# Split from test_csv_cov_parallel_fallbacks so each test binary stays well
# under the coverage run's time limit. Values are checked against a closed
# form of the row index, not against the serial reader.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.schema import RecordBatch

from komira_csv import CsvReadOptions, Rfc4180
from komira_csv.parallel_reader import read_csv_bytes_to_batch_parallel


comptime _ROWS = 20000  # about 60 bytes per row: past the 1 MiB threshold
# Long rows: fewer of them to build and check for the same byte count.
comptime _PAD = "________________________________________________"


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for byte in s.as_bytes():
        out.append(byte)
    return out^


def _body(n: Int) -> String:
    """Rows `<i>,v<i><pad>`."""
    var s = String("")
    for i in range(n):
        s += String(i) + ",v" + String(i) + _PAD + "\n"
    return s^


def _check_rows(rb: RecordBatch, n: Int, label: String) raises:
    assert_equal(rb.num_rows(), n, label + ": rows")
    var k = rb.column_at(0).as_primitive[DType.int64]()
    var v = rb.column_as_string(1)
    for i in range(n):
        assert_equal(k.get(i), Int64(i), label + ": key")
    assert_equal(v.get(0), "v0" + _PAD, label + ": first string")
    assert_equal(v.get(n - 1), String("v") + String(n - 1) + _PAD, label + ": last string")


def test_headerless_parallel_read() raises:
    """With `has_header = False` over 1 MiB, every worker decodes data rows
    only and the columns are named `col_0`, `col_1`. Mutant: name the
    columns from 1 (red: `col_1`, `col_2`)."""
    var o = CsvReadOptions()
    o.has_header = False
    var data = _b(_body(_ROWS))
    var rb = read_csv_bytes_to_batch_parallel[Rfc4180](Span(data), o, 4)
    assert_equal(rb.schema.field_name(0), "col_0")
    assert_equal(rb.schema.field_name(1), "col_1")
    _check_rows(rb, _ROWS, "headerless")


def main() raises:
    test_headerless_parallel_read()
    print("test_csv_cov_parallel_headerless: 1 tests PASS")
