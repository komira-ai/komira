# =============================================================================
# Tests for the parallel reader's per-stage timing instrumentation.
# =============================================================================
#
# `stage_timing=True` turns on per-stage timing in
# `komira_csv.parallel_reader.read_csv_bytes_to_batch_parallel` and prints
# one `[CSV_PHASE4_TIMING] ...` line per call. The instrumentation must not
# change the batch the reader returns.
#
#   T1  without `stage_timing` the parallel reader returns a valid batch
#       on a ~2 MiB mixed fixture (stdout is not captured).
#   T2  _PhaseTiming is default-constructible, copyable and storable in a
#       List.
#   T6  a fixture under 1 MiB takes the single-thread fallback, which the
#       instrumentation does not touch.
#
# One of four files split from a single stage-timing test so that each
# welded test finishes inside the coverage run's 450 s limit. Each file
# builds its own fixture.
# =============================================================================

from std.testing import assert_equal, assert_true

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
from komira_csv.parallel_reader import _PhaseTiming


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _gen_mixed_csv(n_rows: Int) -> List[UInt8]:
    """6-column INT64/FLOAT64/STRING/INT64/FLOAT64/INT64 CSV.

    Sized so n_rows = 25_000 produces ~2 MiB (above 1 MiB parallel
    threshold).
    """
    var s = String("id,score,label,count,ratio,total\n")
    var i = 0
    while i < n_rows:
        s += (
            String(i) + String(",")
            + String(Float64(i) * 1.5) + String(",row_")
            + String(i) + String(",")
            + String(i * 2) + String(",")
            + String(Float64(i) * 0.25) + String(",")
            + String(i * 10) + String("\n")
        )
        i = i + 1
    return _bytes(s)


def test_t1_timing_off_by_default() raises:
    # Without `stage_timing`, the path must run and return a valid
    # batch. We're not testing stdout capture (Mojo has no
    # portable way); we're testing that the un-instrumented branch is
    # reachable and correct on a real fixture.
    var data = _gen_mixed_csv(25_000)
    var bytes = Span(data)
    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch_parallel[Rfc4180](bytes, opts, 4)
    assert_equal(rb.num_rows(), 25_000, "T1 row count")
    assert_equal(rb.num_columns(), 6, "T1 col count")


def test_t2_phase_timing_struct_default_ctor() raises:
    var t = _PhaseTiming()
    assert_equal(t.scan_us, 0, "T2: scan_us default")
    assert_equal(t.materialize_us, 0, "T2: materialize_us default")
    assert_equal(t.build_int64_us, 0, "T2: build_int64_us default")
    assert_equal(t.build_float64_us, 0, "T2: build_float64_us default")
    assert_equal(t.build_string_us, 0, "T2: build_string_us default")
    assert_equal(t.build_date32_us, 0, "T2: build_date32_us default")
    assert_equal(t.build_bool_us, 0, "T2: build_bool_us default")

    # Field assignment + Copyable (implicit copy through assignment).
    t.scan_us = 42
    t.materialize_us = 17
    var u = t
    assert_equal(u.scan_us, 42, "T2: copy preserves scan_us")
    assert_equal(u.materialize_us, 17, "T2: copy preserves materialize_us")

    # List[_PhaseTiming] storage.
    var lst = List[_PhaseTiming]()
    lst.append(_PhaseTiming())
    lst.append(_PhaseTiming())
    assert_equal(len(lst), 2, "T2: List append OK")
    lst[0].scan_us = 100
    assert_equal(lst[0].scan_us, 100, "T2: List setitem field write")


def test_t6_small_fixture_single_thread_fallback() raises:
    # 500 rows of 60-byte rows ~30 KB << 1 MiB threshold.
    var data = _gen_mixed_csv(500)
    var bytes = Span(data)
    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch_parallel[Rfc4180](bytes, opts, 4)
    assert_equal(rb.num_rows(), 500, "T6: row count")
    assert_equal(rb.num_columns(), 6, "T6: col count")


def main() raises:
    test_t1_timing_off_by_default()
    test_t2_phase_timing_struct_default_ctor()
    test_t6_small_fixture_single_thread_fallback()
    print("test_phase_4_stage_breakdown_default_off: PASS")
