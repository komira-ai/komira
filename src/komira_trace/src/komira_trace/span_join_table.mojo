# =============================================================================
# span_join_table.mojo -- the drain's OPEN/CLOSE join table
# =============================================================================
#
# `SpanJoinTable` holds the span records a drain builds from OPEN packets and
# resolves each CLOSE packet to its record. The records are reachable only
# through two members, and each counts what it touches in `probes()`:
#
#   - `close(span_id, ts_ns)` does one index lookup: one probe;
#   - `record_at(i)` reads one record by position: one probe per call.
#
# A join written against this table that compares records one by one has to go
# through `record_at`, so its comparisons are counted by the table, not by the
# join's own bookkeeping. `take_records()` hands the records back without
# counting (it is the drain's output step, not part of the join).

from std.collections import Dict

from komira_trace.span_record import (
    SpanRecord,
    SPAN_STATUS_CLOSED,
)


struct SpanJoinTable(Movable):
    var _records: List[SpanRecord]
    var _index: Dict[UInt64, Int]
    var _probes: Int

    def __init__(out self):
        self._records = List[SpanRecord]()
        self._index = Dict[UInt64, Int]()
        self._probes = 0

    def add_open(mut self, var rec: SpanRecord):
        """Appends an OPEN record. The index keeps the FIRST record per span
        id, so a duplicate id leaves later records unreachable by `close`."""
        if rec.span_id not in self._index:
            self._index[rec.span_id] = len(self._records)
        self._records.append(rec^)

    def count(self) -> Int:
        return len(self._records)

    def close(mut self, span_id: UInt64, ts_ns: UInt64):
        """Marks the first record with `span_id` closed at `ts_ns`; a span id
        with no record is ignored. One probe."""
        self._probes += 1
        var hit = self._index.get(span_id)
        if hit:
            var j = hit.value()
            self._records[j].end_ns = ts_ns
            self._records[j].status = SPAN_STATUS_CLOSED

    def record_at(mut self, i: Int) -> SpanRecord:
        """A copy of record `i`. One probe."""
        self._probes += 1
        return self._records[i].copy()

    def probes(self) -> Int:
        """Probes made so far: `close` calls plus `record_at` calls."""
        return self._probes

    def take_records(mut self) -> List[SpanRecord]:
        """Moves the records out, in OPEN order."""
        var out = List[SpanRecord]()
        swap(out, self._records)
        return out^
