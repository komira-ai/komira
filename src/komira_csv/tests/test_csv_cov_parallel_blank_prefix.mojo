# =============================================================================
# The parallel reader when worker 0's inference prefix is all blank lines.
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


def test_blank_first_worker_falls_back() raises:
    """300 KB of blank lines before the header put worker 0's whole
    inference prefix on blank rows, so the read falls back to the serial
    reader (which skips them). Mutant: drop the empty-worker-0 fallback
    (red: row 0 of an empty cell index is read for the header)."""
    var text = String("")
    for _ in range(300000):
        text += "\n"
    text += "k,v\n" + _body(_ROWS)
    var data = _b(text)
    var rb = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(data), CsvReadOptions(), 4
    )
    assert_equal(rb.schema.field_name(1), "v")
    _check_rows(rb, _ROWS, "blank prefix")


def main() raises:
    test_blank_first_worker_falls_back()
    print("test_csv_cov_parallel_blank_prefix: 1 tests PASS")
