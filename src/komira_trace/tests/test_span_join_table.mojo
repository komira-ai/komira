# =============================================================================
# test_span_join_table.mojo -- the join table counts what it touches
# =============================================================================
#
# `Tracer.join_probes()` is only as honest as the table that counts. This test
# pins the table's own counting, so test_drain_join_scales.mojo can rely on it:
#
#   - `close` is one probe, whether or not the span id has a record;
#   - `record_at` is one probe per call, so a scan over n records is n probes;
#   - `add_open`, `count` and `take_records` are not probes;
#   - the first record per span id is the one `close` patches.

from std.testing import assert_equal

from komira_trace.span_join_table import SpanJoinTable
from komira_trace.span_record import (
    SpanRecord,
    SPAN_STATUS_CLOSED,
    SPAN_STATUS_OPEN,
)


def _open(id: Int) -> SpanRecord:
    var rec = SpanRecord()
    rec.span_id = UInt64(id)
    rec.status = SPAN_STATUS_OPEN
    return rec^


def test_close_is_one_probe() raises:
    var t = SpanJoinTable()
    for i in range(5):
        t.add_open(_open(i + 1))
    assert_equal(t.count(), 5, "five records")
    assert_equal(t.probes(), 0, "adding records is not a probe")
    t.close(UInt64(3), UInt64(900))
    assert_equal(t.probes(), 1, "a hit is one probe")
    t.close(UInt64(99), UInt64(901))
    assert_equal(t.probes(), 2, "a miss is one probe")
    var recs = t.take_records()
    assert_equal(t.probes(), 2, "taking the records is not a probe")
    assert_equal(len(recs), 5, "all records returned")
    assert_equal(recs[2].status, SPAN_STATUS_CLOSED, "span 3 closed")
    assert_equal(recs[2].end_ns, UInt64(900), "span 3 end stamped")
    assert_equal(recs[0].status, SPAN_STATUS_OPEN, "span 1 still open")
    print("  test_close_is_one_probe PASS")


def test_record_reads_are_counted() raises:
    var t = SpanJoinTable()
    for i in range(8):
        t.add_open(_open(i + 1))
    # A per-CLOSE scan: every record compared is read through record_at.
    for want in range(8):
        for i in range(t.count()):
            if t.record_at(i).span_id == UInt64(want + 1):
                break
    # Closing span k reads k records: 1 + 2 + ... + 8.
    assert_equal(t.probes(), 36, "each record read is one probe")
    print("  test_record_reads_are_counted PASS")


def test_first_record_per_span_id_wins() raises:
    var t = SpanJoinTable()
    t.add_open(_open(7))
    t.add_open(_open(7))
    t.close(UInt64(7), UInt64(5))
    var recs = t.take_records()
    assert_equal(recs[0].status, SPAN_STATUS_CLOSED, "first duplicate closed")
    assert_equal(recs[1].status, SPAN_STATUS_OPEN, "second duplicate untouched")
    print("  test_first_record_per_span_id_wins PASS")


def main() raises:
    print("test_span_join_table")
    print("====================")
    test_close_is_one_probe()
    test_record_reads_are_counted()
    test_first_record_per_span_id_wins()
    print()
    print("ALL TESTS PASS")
