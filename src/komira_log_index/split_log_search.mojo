# =============================================================================
# komira_log_index.split_log_search — log search over L0 splits, answering the
#   `komira_log_query` search seam.
# =============================================================================
#
# `komira_log_query` states the read seam in terms any layout can satisfy (a
# timestamp, a score, the record as JSON) and names nothing below it. This file
# is the one place in the read path that knows the split format: `SplitView`,
# `SearchCore`, `search_l0_split`, `QueryIR` and the cross-shard live-split
# listing all appear here and nowhere above.
#
# The layout is supplied by the caller. A reader is constructed with a
# `(meta_root, index)` pair and no default: the writer that published the splits
# (`L0BuildTask`, the idle hook) takes the same two values, and a reader that
# re-typed them could agree with the writer until one side was edited and then
# find nothing, which reads exactly like "nothing was logged". The caller binds
# the pair once and hands it to both.
#
# Both split formats are routed. A writer may publish an optimized split (BM25)
# or an L0 split (the cheap-drain posting), and the discriminator is
# `SplitView.has_l0_posting()`, a footer slot and not a front magic. Reading an
# L0 split as an optimized one returns zero hits from a split full of them, so
# `scan` branches on it per split.
#
# There is no `except: pass`. A store fault or a corrupt split raises, and the
# route turns it into an error response that names it. Folding either into a
# short page would produce an empty result that means "the bucket is
# unreachable" but reads exactly like "your term did not match".
#
# Encapsulation: no pointer in any signature; `Storage` is moved in and owned by
# value.
# =============================================================================

from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.path import Path

from komira_search.analyzer import AnalyzerConfig
from komira_search.source import (
    MISSING_LAST,
    QueryIR,
    SORT_DESC,
    SORT_MODE_I64,
    SearchCore,
    SearchResult,
)
from komira_search.split import SplitView

from komira_search_catalog import list_live_splits_across_shards_with_seq

from komira_log_query.hit import (
    ServiceLogHit,
    ServiceLogPage,
    ServiceLogQuery,
)
from komira_log_query.search_seam import ServiceLogSearch

from komira_log_index.l0_read import search_l0_split
from komira_log_index.transpose import (
    LOG_INDEX_TEXT_FIELD,
    LOG_INDEX_TIMESTAMP_FIELD,
)


struct SplitIndexLogSearch[Storage: CloneableConditionalWriteStore](
    ServiceLogSearch, Movable, Deinitable
):
    """A `ServiceLogSearch` over the object-store split index that
    `L0BuildTask` and the idle hook publish into.

    Generic over the store, which is what makes it deployable: nothing here
    names a transport, a credential or a signing scheme. A deployment hands in
    its own `CloneableConditionalWriteStore`; tests hand in the in-memory one.

    Construct with the `(meta_root, index)` pair the writer was given."""

    var _store: Self.Storage
    var _meta_root: String
    var _index: String

    def __init__(
        out self, var store: Self.Storage, var meta_root: String, var index: String
    ):
        """Bind this reader to `<meta_root>` / `<index>` in `store`.

        The caller supplies the layout and must supply the same values the
        writer used; there is no default, so the two cannot drift apart by one
        side keeping its own copy. The catalog partitions lineages by
        `meta_root`; `index` names the metastore handle the replay is made
        through."""
        self._store = store^
        self._meta_root = meta_root^
        self._index = index^

    def scan(mut self, q: ServiceLogQuery) raises -> ServiceLogPage:
        """Enumerate every live split, run the full-text query against each,
        merge the pages newest-first, and drop hits outside the window.

        A term is required, and the raise below is the honest statement of why.
        The catalog entry a split reader replays (`SplitSummary`) carries
        `min_doc_id` / `max_doc_id`, which are document ids, and its one slot
        that could hold a time range (`minmax_sketch`) is reserved and empty. So
        a time range prunes nothing here, and a term-free window would fan out to
        every live split in the index and materialise every record. The
        time-partitioned Parquet format answers that query instead: its manifest
        entry carries `min_ts_ns` / `max_ts_ns`, the window prunes before a byte
        is fetched, and `komira_telemetry_read.TelemetryLogSearch` is the
        conformer over it.

        The window is still honoured, as a filter and not a prune: every live
        split is still fetched and searched, and the window only decides which
        hits survive. `sources_scanned` reports the fan-out so that cost is
        visible rather than inferred.

        A hit with `timestamp_ns == 0` is kept, never filtered out. `_hits_of`
        degrades a hit's timestamp to 0 when the split lost its `timestamp`
        fast-field, which is a degraded ordering and deliberately not a lost hit.
        Filtering on that zero would turn the degradation into data loss.

        The four steps:
          1. `list_live_splits_across_shards_with_seq`: the cross-shard live
             set, with the input-uuid skip applied over the union. Not a bucket
             LIST, which would read compacted-away splits and double-count. The
             `_with_seq` variant, because the per-shard `chunk_seq` it keeps is
             the ordering tie-break (see `_merge_newest_first`).
          2. per split: a plain object GET. `SearchCore` takes owned bytes and
             knows nothing about a transport, so this is the whole fetch.
          3. per split: route on `has_l0_posting()`, then query with a
             `timestamp` DESC fast-field sort so each page arrives newest-first
             and carries its typed sort key.
          4. a k-way merge over the per-split pages by that key.

        `total_matches` is the sum across splits: the true number of matching
        records, of which at most `limit` are returned. The splits are disjoint
        doc sets (a split is published to exactly one lineage), so the sum does
        not double-count. It counts pre-window matches: what the index matched,
        not what the window kept."""
        if not q.has_term():
            raise Error(
                "the split-index log reader cannot answer a time-range query"
                " with no search term: its catalog entry (SplitSummary) carries"
                " min_doc_id/max_doc_id and no time range at all (the"
                " minmax_sketch slot is reserved and empty), so a window prunes"
                " nothing and a term-free read would fetch every live split."
                " Supply a term, or read the time-partitioned at-rest format,"
                " whose manifest entry carries min_ts_ns/max_ts_ns."
            )
        var query = q.term.copy()
        var want = q.limit
        if want < 1:
            want = 1

        var live = list_live_splits_across_shards_with_seq(
            self._store, self._meta_root, self._index
        )
        var n_splits = len(live)
        if n_splits == 0:
            return ServiceLogPage()

        # Per-split pages, each already newest-first (step 3), paired with the
        # publish sequence that breaks a timestamp tie.
        var pages = List[List[ServiceLogHit]]()
        var seqs = List[Int64]()
        var total = 0
        for i in range(n_splits):
            var bytes = self._store.get(
                Path.parse(live[i].summary.object_key)
            )
            var view = SplitView.parse(bytes^)
            var ir = self._query_for(query, want)
            var res: SearchResult
            # The move happens in exactly one arm: `search_l0_split` borrows the
            # view, `SearchCore.from_view` consumes it.
            if view.has_l0_posting():
                res = search_l0_split(view, ir)
            else:
                var core = SearchCore.from_view(view^)
                res = core.search(ir)
            total += res.total_matches
            pages.append(_hits_of(res^))
            seqs.append(live[i].chunk_seq)

        return ServiceLogPage(
            _in_window(
                _merge_newest_first(pages^, seqs^, want), q.t0_ns, q.t1_ns
            ),
            total,
            n_splits,
        )

    def _query_for(self, query: String, limit: Int) raises -> QueryIR:
        """The `QueryIR` this reader issues: a MATCH on the log index's text
        field, sorted by `timestamp` descending.

        The sort is the point, not a nicety. `timestamp` is `TIMESTAMP_NS`,
        which the search sink classifies as a date field with i64 storage, so the
        sort resolves to `SORT_MODE_I64` and the result carries a typed
        `sort_keys.key_i64` column parallel to the rows. Without it the pages
        come back BM25-ordered and a cross-split merge interleaves times.

        `MISSING_LAST`: a record with no timestamp sorts to the end rather than
        the front, so a malformed row cannot masquerade as the newest line."""
        return QueryIR(
            String(LOG_INDEX_TEXT_FIELD),
            query,
            limit,
            AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD),
            0,
            None,
            String(LOG_INDEX_TIMESTAMP_FIELD),
            SORT_DESC,
            MISSING_LAST,
            0,
        )


def _hits_of(var res: SearchResult) raises -> List[ServiceLogHit]:
    """One split's `SearchResult` -> `ServiceLogHit`s, in the order the split
    returned them (newest-first, given the sort above).

    The HitBatch is the 3-column `_score` / `_id` / `_source` shape
    (`komira_search.source.hit_schema`); `_source` is the log record's JSON blob,
    passed through verbatim: this reader never parses it.

    Timestamp fallback: the typed key column is used only when it is actually an
    I64 column of the right length. If a split lost the `timestamp` fast-field,
    every hit's `timestamp_ns` degrades to 0 and the merge below degenerates to
    split order, a degraded ordering and never a lost hit or a crash. Raising
    would take down a log read for a cosmetic reason; folding it to silence would
    be worse, so the zero is visible in the rendered JSON."""
    var batch = res.take_batch()
    var keys = res.take_sort_keys()
    var rows = batch.num_rows()
    var typed = (
        keys.mode == SORT_MODE_I64
        and len(keys.key_i64) == rows
        and len(keys.missing) == rows
    )
    var scores = batch.column_at(0).as_primitive[DType.float64]()
    var sources = batch.column_at(2).as_string()
    var out = List[ServiceLogHit](capacity=rows)
    for r in range(rows):
        var ts = Int64(0)
        if typed and not keys.missing[r]:
            ts = keys.key_i64[r]
        out.append(ServiceLogHit(ts, scores.get(r), sources.get(r)))
    return out^


def _in_window(
    var hits: List[ServiceLogHit], t0_ns: Int64, t1_ns: Int64
) -> List[ServiceLogHit]:
    """Drop hits outside `[t0_ns, t1_ns]` (inclusive at both ends).

    A hit with `timestamp_ns == 0` is always kept. See `scan`'s docstring: the
    zero is `_hits_of`'s degraded marker for a split that lost its `timestamp`
    fast-field, not a real epoch timestamp. Treating it as one would delete the
    record from every window that does not contain 1970.

    Filtered after the merge, not before it, so the merge's newest-first ordering
    and its `chunk_seq` tie-break are unaffected. The page may therefore come
    back shorter than `limit` even when more matching records exist inside the
    window; `total_matches` is the pre-window count."""
    var out = List[ServiceLogHit](capacity=len(hits))
    for i in range(len(hits)):
        var ts = hits[i].timestamp_ns
        if ts == Int64(0) or (ts >= t0_ns and ts <= t1_ns):
            out.append(hits[i].copy())
    return out^


def _merge_newest_first(
    var pages: List[List[ServiceLogHit]],
    var seqs: List[Int64],
    limit: Int,
) raises -> List[ServiceLogHit]:
    """K-way merge of per-split pages into one list, newest first, truncated to
    `limit`. The key is `(timestamp_ns, chunk_seq)`, both descending.

    Why there is a second key: the log index's timestamp resolution is one
    millisecond, not one nanosecond. The column is `TIMESTAMP_NS` and
    `ServiceLogHit.timestamp_ns` is nanoseconds, but the value is
    `LogRecordView.wall_ms * 1_000_000` (see `transpose.mojo`), so the low six
    digits are always zero and two records emitted in the same millisecond are
    indistinguishable in time. That is the common case for a process logging at
    speed. With a pure timestamp key the tie falls through to split-enumeration
    order and the page comes back oldest-first.

    `chunk_seq` is the manifest publish sequence, monotone per shard lineage. A
    writer publishes at most one split per flush, so a higher `chunk_seq` means a
    strictly later batch of records, which is the information the millisecond
    floor threw away.

    Residual: `chunk_seq` is monotone within a shard lineage, not across shards.
    Writers that share one node id share one lineage and the comparison is total;
    with a per-writer node id, cross-shard ties are orderable only by wall clock
    again, at millisecond resolution.

    The algorithm relies on each page already being descending, which is what
    the `timestamp` DESC sort in `_query_for` produces (the split's top-k heap
    drains descending and the page slice preserves that order). Concatenate and
    sort would be O(S*L*log(S*L)) over data that arrives sorted; this is O(L*S).
    If that assumption ever breaks the result is a mis-ordered page, never a lost
    or duplicated hit: every element is taken from exactly one cursor and every
    cursor advances exactly once per take."""
    var s = len(pages)
    var cursors = List[Int](length=s, fill=0)
    var out = List[ServiceLogHit](capacity=limit)
    while len(out) < limit:
        var best = -1
        var best_ts = Int64(0)
        var best_seq = Int64(0)
        for i in range(s):
            var c = cursors[i]
            if c >= len(pages[i]):
                continue
            var ts = pages[i][c].timestamp_ns
            var sq = seqs[i]
            var wins = False
            if best < 0:
                wins = True
            elif ts > best_ts:
                wins = True
            elif ts == best_ts and sq > best_seq:
                # THE TIE-BREAK. Same millisecond -> the later PUBLISH wins.
                wins = True
            if wins:
                best = i
                best_ts = ts
                best_seq = sq
        if best < 0:
            break  # every cursor exhausted
        out.append(pages[best][cursors[best]].copy())
        cursors[best] = cursors[best] + 1
    return out^
