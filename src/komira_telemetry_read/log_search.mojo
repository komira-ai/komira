# =============================================================================
# komira_telemetry_read.log_search: a `ServiceLogSearch` over the time-
#   partitioned Parquet base artifact.
# =============================================================================
#
# `TelemetryLogSearch` is the log-query seam (`komira_log_query.search_seam`)
# answered by the direct query path: its whole body is `plan_telemetry_scan`
# plus `read_telemetry_segments`, then a row-level filter and a sort. There is
# no bucket name, no service identity and no credential in it. Swap the store
# for another bucket's and it answers that bucket's question.
#
# -- WHAT THIS CONFORMER DOES DIFFERENTLY FROM A TEXT-INDEX ONE ---------------
# | | an analyzed text-index conformer | `TelemetryLogSearch` (base) |
# |---|---|---|
# | term-free window | cannot prune by time: a term-free read fans out to every live index | the primary query: the manifest entry's `min_ts_ns`/`max_ts_ns` prune before a byte is fetched |
# | term matching | BM25 over an analyzed index: stemming, tokenisation, relevance | SUBSTRING on the raw `message` (see below) |
# | `score` | a real relevance | always `0.0`: there is no notion of one here |
#
# THE TERM SEMANTICS DIFFER AT THE SAME SEAM. A query for `deploys` finds
# `deployed` through a stemming index and does NOT find it here (substring). A
# service that switches between conformers will see different hits for the same
# query. The substring is what a reader with a bucket gets from
# `WHERE message LIKE '%term%'` in DuckDB, and matching that exactly is worth
# more than matching a sidecar's analyzer; pulling an analyzer into this package
# would also drag a search engine into it.
#
# -- THE WINDOW IS THE MEMORY BOUND -------------------------------------------
# `scan` materialises every matching row in the window before it sorts and
# truncates to `limit`, because `total_matches` must be the TRUE count and the
# newest-first contract is global rather than per-object. So the window, not
# `limit`, bounds this conformer's footprint. `days_covering` refuses a span of
# more than `MAX_TELEMETRY_DAYS_PER_QUERY` partitions, which is the backstop.
#
# `Storage` is owned by value; every public signature takes and returns values.
# =============================================================================

from komira_arrow.record_batch import RecordBatch

from komira_objectstore.store import CloneableConditionalWriteStore

from komira_log_query.hit import (
    ServiceLogHit,
    ServiceLogPage,
    ServiceLogQuery,
)
from komira_log_query.search_seam import ServiceLogSearch

from komira_telemetry_store.keys import TELEMETRY_DATASET_LOGS

from komira_telemetry_read.scan_plan import plan_telemetry_scan
from komira_telemetry_read.segment_read import (
    TELEMETRY_LOG_TS_COLUMN,
    read_telemetry_segments,
)


comptime TELEMETRY_LOG_SOURCE_COLUMN: String = "_source"
"""The column holding the record as a JSON object (`ServiceLogHit.source_json`).

The log schema this search expects is `timestamp`, `_source`, `message`. The
store's log writer requires only `timestamp`, so `_source` and `message` are
this package's convention: a segment lacking either is refused at scan time
with a schema-mismatch error."""

comptime TELEMETRY_LOG_MESSAGE_COLUMN: String = "message"
"""The interpolated log line: what `q.term` is matched against."""


struct TelemetryLogSearch[Storage: CloneableConditionalWriteStore](
    ServiceLogSearch, Movable, Deinitable
):
    """A `ServiceLogSearch` over the time-partitioned Parquet base artifact.

    GENERIC OVER THE STORE, so the same code answers any bucket through whatever
    conformer its cloud has, and a test's bucket through
    `SharedInMemoryConditionalStore`. Nothing here names a transport, a
    credential or a signing scheme.

    NO BUCKET, NO PREFIX AND NO SERVICE NAME IS STORED ON THIS STRUCT. The key
    root is `telemetry/<dataset>/<YYYYMMDD>/...` and the dataset is the only
    parameter: the layout has no further dimension, so which data a search can
    see is decided by which store it is handed."""

    var _store: Self.Storage
    var _dataset: String

    def __init__(out self, var store: Self.Storage, var dataset: String):
        self._store = store^
        self._dataset = dataset^

    @staticmethod
    def app_log(var store: Self.Storage) -> TelemetryLogSearch[Self.Storage]:
        """The `logs` dataset binding: the binding of a store to the dataset."""
        return TelemetryLogSearch[Self.Storage](
            store^, String(TELEMETRY_DATASET_LOGS)
        )

    def scan(mut self, q: ServiceLogQuery) raises -> ServiceLogPage:
        """Plan, read, filter, sort.

        1. `plan_telemetry_scan`: day arithmetic, ONE shard-enumeration LIST per
           day, exact-GET manifest replay, prune on `min_ts_ns`/`max_ts_ns`.
        2. `read_telemetry_segments`: GET exactly the surviving keys, prune row
           groups on the footer zone map, decode.
        3. row-level filter: the window again (a surviving row group may hold
           rows outside it) and, if supplied, the term.
        4. newest-first, then truncate to `limit`.

        NO `except: pass`, ANYWHERE. A store fault RAISES and the caller sees the
        error. Folding either into a short page would
        produce the one answer an operator cannot act on: an empty result that
        means "the bucket is unreachable" but reads exactly like "nothing
        matched".

        `sources_scanned` IS THE OBJECTS ACTUALLY FETCHED, not the objects the
        catalog holds, so a window that pruned everything reports 0 and is
        distinguishable from a window that fetched three objects and matched
        nothing. Those are different problems with the same empty hit list."""
        var want = q.limit
        if want < 1:
            want = 1

        var plan = plan_telemetry_scan(
            self._store, self._dataset.copy(), q.t0_ns, q.t1_ns
        )
        var read = read_telemetry_segments(
            self._store, plan, String(TELEMETRY_LOG_TS_COLUMN)
        )
        ref batches = read[0]
        ref stats = read[1]

        var hits = List[ServiceLogHit]()
        for b in range(len(batches)):
            ref batch = batches[b]
            var ts_col = _col(batch, String(TELEMETRY_LOG_TS_COLUMN))
            var src_col = _col(batch, String(TELEMETRY_LOG_SOURCE_COLUMN))
            var msg_col = _col(batch, String(TELEMETRY_LOG_MESSAGE_COLUMN))
            if ts_col < 0 or src_col < 0:
                raise Error(
                    "TelemetryLogSearch: a decoded segment is missing the '"
                    + String(TELEMETRY_LOG_TS_COLUMN)
                    + "' or '"
                    + String(TELEMETRY_LOG_SOURCE_COLUMN)
                    + "' column. REFUSED rather than skipped: a segment silently"
                    " dropped for a schema mismatch is data loss that reports as"
                    " an empty page."
                )
            var ts_arr = batch.column_at(ts_col).as_primitive[DType.int64]()
            var src_arr = batch.column_at(src_col).as_string()
            for r in range(batch.num_rows()):
                var ts = Int64(ts_arr.get(r))
                # THE ROW-LEVEL WINDOW CHECK IS NOT REDUNDANT with the plan's.
                # The plan prunes whole OBJECTS and the zone map prunes whole ROW
                # GROUPS; a surviving row group can still hold rows outside the
                # window, and returning them would answer a wider question than
                # the one asked.
                if ts < q.t0_ns or ts > q.t1_ns:
                    continue
                if q.has_term():
                    if msg_col < 0:
                        raise Error(
                            "TelemetryLogSearch: a term was supplied but the"
                            " decoded segment has no '"
                            + String(TELEMETRY_LOG_MESSAGE_COLUMN)
                            + "' column to match it against"
                        )
                    var msg = batch.column_at(msg_col).as_string().get(r)
                    if msg.find(q.term) < 0:
                        continue
                # `score` is 0.0 - this conformer has no notion of relevance, and
                # `hit.mojo` states that a conformer without one reports zero
                # rather than inventing a number.
                hits.append(ServiceLogHit(ts, 0.0, src_arr.get(r)))

        var total = len(hits)
        _sort_newest_first(hits)
        var page = List[ServiceLogHit](capacity=want)
        for i in range(len(hits)):
            if len(page) >= want:
                break
            page.append(hits[i].copy())
        return ServiceLogPage(page^, total, stats.objects_fetched)


def _col(batch: RecordBatch, name: String) raises -> Int:
    for c in range(batch.num_columns()):
        if batch.schema.field_name(c) == name:
            return c
    return -1


def _sort_newest_first(mut hits: List[ServiceLogHit]):
    """`timestamp_ns` DESCENDING: the seam's ordering contract (`hit.mojo`).

    INSERTION SORT, AND IT IS STABLE, WHICH MATTERS HERE. Log timestamps can
    have millisecond resolution, so records emitted microseconds apart collide.
    A stable sort leaves colliding records in the order the segments were read
    (ascending by `min_ts_ns`, i.e. publish order), which is the only signal
    left once the timestamps tie. An unstable sort would reorder them
    differently on every read.

    COST: O(n^2) comparisons and copies in the worst case, over every row the
    window matched. Acceptable for the windows the planner admits in practice;
    a stable merge sort (or a running top-`limit` selection that keeps the
    true total) is the replacement, and it must keep the stability above.

    A manifest-sequence tie-break would be better information but is not
    available here: the catalog entry is per SEGMENT, not per row, so every row
    of one flush window shares it."""
    for i in range(1, len(hits)):
        var j = i
        while j > 0 and hits[j - 1].timestamp_ns < hits[j].timestamp_ns:
            var tmp = hits[j - 1].copy()
            hits[j - 1] = hits[j].copy()
            hits[j] = tmp^
            j -= 1
