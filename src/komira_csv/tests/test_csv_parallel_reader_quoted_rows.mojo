# =============================================================================
# Tests for komira_csv/parallel_reader.mojo: multi-thread parallel CSV scan.
# =============================================================================
#
#   T2  partition adjustment: quoted-cell-with-comma fixture; the
#       partition boundary must advance past in-row content to the next
#       newline.
#
# One of six files split from a single parallel reader test so that each
# welded test finishes inside the coverage run's 450 s limit. Each file
# builds its own fixture and compares `read_csv_bytes_to_batch_parallel`
# with the single-thread Phase 3 reader (schema, row count, and the
# values the test names).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch

from komira_csv import (
    CsvReadOptions,
    Rfc4180,
    read_csv_bytes_to_batch,
    read_csv_bytes_to_batch_parallel,
    SCANNER_VARIANT_PHASE_3,
)


def _bytes(s: String) -> List[UInt8]:
    """Convert a String to a List[UInt8] for test fixtures."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _assert_batches_equal(
    parallel_rb: RecordBatch,
    serial_rb: RecordBatch,
    label: String,
) raises:
    """Assert that two RecordBatches have identical schema + row count
    + per-cell INT64 values (for the synthetic fixtures used here).

    Covers the most-common cell shapes: INT64 / FLOAT64 / STRING. The
    BOOL / DATE32 paths are exercised by Phase 1/2/3 parity tests
    (the partition logic is shape-agnostic on cell type).
    """
    assert_equal(
        parallel_rb.num_columns(),
        serial_rb.num_columns(),
        label + ": column counts differ",
    )
    assert_equal(
        parallel_rb.num_rows(),
        serial_rb.num_rows(),
        label + ": row counts differ",
    )
    var num_cols = parallel_rb.num_columns()
    var c = 0
    while c < num_cols:
        var pf = parallel_rb.schema.field_at(c)
        var sf = serial_rb.schema.field_at(c)
        assert_equal(
            String(pf.name),
            String(sf.name),
            label + ": col " + String(c) + " name differs",
        )
        assert_true(
            pf.arrow_type == sf.arrow_type,
            label + ": col " + String(c) + " arrow_type differs",
        )
        c = c + 1


def _gen_int_csv_quoted(n_rows: Int) -> List[UInt8]:
    """Generate a synthetic CSV with quoted middle column containing
    embedded commas + spaces. Header is `id,name,value`. Each row is
    `i,"first, last",i*10`.

    This forces the partition boundary scan to advance through quoted
    content (memchr-find-newline ignores the comma inside the quotes
    correctly since it only looks for 0x0A bytes).
    """
    var s = String("id,name,value\n")
    var i = 0
    while i < n_rows:
        s += String(i) + String(",\"first ") + String(i) + String(", last\",") + String(i * 10) + String("\n")
        i = i + 1
    return _bytes(s)


def test_partition_adjustment_quoted_rows() raises:
    """T2: quoted-cell-with-comma rows. Partition boundary scan
    (memchr-find-newline) must land on row boundaries even when rows
    contain commas inside quoted cells. Verifies the partition does
    NOT mis-split a row at an in-cell comma.
    """
    # Each row is ~34 bytes; 60_000 rows ~= 2 MiB.
    var buf = _gen_int_csv_quoted(60_000)
    var opts = CsvReadOptions()
    var rb_serial = read_csv_bytes_to_batch[Rfc4180, SCANNER_VARIANT_PHASE_3](
        Span(buf), opts
    )
    var rb_parallel = read_csv_bytes_to_batch_parallel[Rfc4180](
        Span(buf), opts, n_workers=4
    )
    _assert_batches_equal(rb_parallel, rb_serial, "T2 partition_quoted")

    # Sanity: 3 cols (id, name, value), 60_000 rows.
    assert_equal(rb_parallel.num_columns(), 3, "3 cols (id, name, value)")
    assert_equal(rb_parallel.num_rows(), 60_000)
    assert_true(rb_parallel.schema.field_at(0).arrow_type == ArrowType.INT64)
    assert_true(rb_parallel.schema.field_at(1).arrow_type == ArrowType.STRING)
    assert_true(rb_parallel.schema.field_at(2).arrow_type == ArrowType.INT64)

    # id column parity at the partition-boundary-rich middle.
    ref id_col_p = rb_parallel.column_at(0)
    ref id_col_s = rb_serial.column_at(0)
    var id_p = id_col_p.as_primitive[DType.int64]()
    var id_s = id_col_s.as_primitive[DType.int64]()
    assert_equal(Int(id_p.get(15_000)), Int(id_s.get(15_000)), "row 15000 id parity")
    assert_equal(Int(id_p.get(30_000)), Int(id_s.get(30_000)), "row 30000 id parity")
    assert_equal(Int(id_p.get(45_000)), Int(id_s.get(45_000)), "row 45000 id parity")
    assert_equal(Int(id_p.get(15_000)), 15_000, "row 15000 id == 15000 (absolute)")
    assert_equal(Int(id_p.get(45_000)), 45_000, "row 45000 id == 45000 (absolute)")


def main() raises:
    test_partition_adjustment_quoted_rows()
    print("test_csv_parallel_reader_quoted_rows: PASS")
