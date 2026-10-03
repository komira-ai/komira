# =============================================================================
# komira_log_query/hit.mojo — the FORMAT-NEUTRAL value types a log read returns.
# =============================================================================
#
# ── WHY THESE ARE NOT `SearchResult` ────────────────────────────────────────
# `komira_search.SearchResult` is the AT-REST FORMAT's answer: a 3-column
# HitBatch (`_score` / `_id` / `_source`), a `SortKeyColumn` keyed by whichever
# fast-field the query sorted on, and an `AggResults`. Every one of those names a
# property of the SPLIT layout the log index happens to use TODAY.
#
# ⭐ AND THAT LAYOUT IS NOT THE ONLY ONE. Logs (like metrics) are also stored as
# time-partitioned files optimized for time-series queries, so the bytes these
# hits are decoded FROM differ by layout. The READ SEAM is therefore stated in
# terms a time-series layout can also satisfy: a timestamp, a relevance score,
# and the record as JSON. Nothing here mentions a split, a posting list, a
# term dictionary or a docstore.
#
# WHAT CHANGES UNDER A NEW LAYOUT, stated so nobody has to re-derive it:
#   * the CONFORMER (`komira_log_index.split_log_search.SplitIndexLogSearch` for
#     the split layout, `komira_telemetry_read` for the time-partitioned one).
#     Only a conformer names a format's own types.
#   * NOT this file, NOT `search_seam.mojo`, NOT `route.mojo`, NOT a service's
#     dispatch arm. Those see only the trait.
#
# ── `source_json` IS A CONTRACT, AND IT IS THE ONE THE ROUTE RENDERS ────────
# It is the record, encoded as a JSON object — for the split layout, byte-for-byte
# the split's `_source` blob (message / level / module / timestamp / corr_id /
# flags / site_id + a nested `args`). Another layout must produce the same SHAPE,
# not the same bytes.
#
# ⚠ THE ROUTE DOES NOT PARSE IT and deliberately does not depend on its inner
# field names — it embeds it (see `route.mojo`'s embed-or-quote rule). A reader
# that started parsing `source_json` here would re-couple this package to the
# layout the whole split exists to decouple from.
#
# Encapsulation: value types only — Int64 / Float64 / String / List. ZERO
# UnsafePointer in any signature, ZERO wildcard origin, ZERO unsafe_from_address.
# Plain stack/heap values, never a byte-slab element, so there is no stale-pointer
# hazard across destroy and recreate.
# =============================================================================


@fieldwise_init
struct ServiceLogQuery(Copyable, Movable, Deinitable):
    """ONE read of a service's own operational log: a TIME WINDOW, an OPTIONAL
    term, and a page bound.

    ── ⭐ WHY THE WINDOW IS FIRST, AND WHY THE TERM IS OPTIONAL ───────────────
    The at-rest layout has time-partitioned Parquet as the BASE artifact and the
    BM25 text index as an OPTIONAL SIDECAR beside it. This struct is that layout
    expressed at the read seam.

    ⛔ A SEAM THAT TAKES ONLY A TERM ENCODES A PROPERTY OF THE SPLIT FORMAT, NOT
    OF LOG READING. A split catalog entry (`SplitSummary`) carries
    `min_doc_id`/`max_doc_id` and NO TIME RANGE AT ALL, so for splits a term is
    the only bound available. The time-partitioned manifest entry carries
    `min_ts_ns`/`max_ts_ns`, a time range prunes before a byte is fetched, and
    *"the last 200 lines"* — the most common log query in the world — is the
    PRIMARY query rather than an inexpressible one.
    ⇒ the bound is where a customer's own direct query puts it: the WINDOW.

    `t0_ns` / `t1_ns` are INCLUSIVE at both ends, matching
    `TelemetrySegmentEntry.overlaps_time` and `utc_days_covering`. Three layers
    state the same closed interval and they must agree; a half-open bound at one
    of them drops rows only at partition edges, which is the least reproducible
    bug shape available.

    ⚠ `term` MAY BE EMPTY, and empty means MATCH EVERYTHING IN THE WINDOW — not
    "match nothing" and not "invalid". A conformer that cannot answer a term-free
    window must RAISE and say why; the route turns that into a 400 carrying the
    conformer's own sentence, because it is an honest statement about the
    deployed format and not a server fault.

    ⚠ `limit` STILL BOUNDS THE PAGE and a conformer must still honour it. The
    window bounds how much is SCANNED; the limit bounds how much is RETURNED, and
    on a service instance sized for HTTP both are needed."""

    var t0_ns: Int64
    var t1_ns: Int64
    var term: String
    var limit: Int

    def has_term(self) -> Bool:
        """True iff a full-text term was supplied. See `term` above — the FALSE
        case is a legitimate query, not a missing argument."""
        return self.term.byte_length() > 0


@fieldwise_init
struct ServiceLogHit(Copyable, Movable, Deinitable):
    """ONE log record recovered from the index.

    `timestamp_ns` is the record's wall clock in NANOSECONDS (the log index's
    `timestamp` column is `TIMESTAMP_NS`; the sink stamps `wall_ms * 1_000_000`).
    It is carried OUT OF BAND from `source_json` on purpose: the cross-split merge
    and the route's ordering both need it as a number, and lifting it out of the
    blob would mean parsing JSON in the merge loop.

    `score` is the RELEVANCE of the match — BM25 on an optimized split, summed
    term-frequency on an L0 split. Surfaced because an operator searching for a
    phrase wants to know which hit actually matched it, and dropped to 0.0 by any
    conformer that has no notion of relevance. ⛔ It is NOT an ordering the route
    promises; see `ServiceLogPage.hits`.

    `source_json` is the whole record as a JSON object. See the file header — its
    inner shape is the format's business, not this package's."""

    var timestamp_ns: Int64
    var score: Float64
    var source_json: String


struct ServiceLogPage(Movable, Deinitable):
    """One answer to one log query: the hits, plus the two numbers that make a
    short answer interpretable.

    ⭐ `hits` IS NEWEST-FIRST (`timestamp_ns` DESCENDING), and that is the seam's
    contract rather than the conformer's convenience. An operator reading an
    operational log is asking "what happened, most recently" far more often than
    "what matched best", and a page ordered by relevance across several splits
    presents interleaved times that look like corruption.

    ⚠ `total_matches` IS NOT `len(hits)` AND THE DIFFERENCE IS THE POINT. It is
    how many records matched across everything scanned; `hits` carries at most
    `limit` of them. Without it, a truncated page is indistinguishable from a
    complete one — the operator reads "3 matches" and stops looking, when there
    were nine thousand. The route renders both, always.

    `sources_scanned` is how many at-rest units the conformer read (for the
    split layout: live splits). It is a MEASUREMENT, not an assertion: it makes
    "no hits because nothing is published" distinguishable from "no hits
    because nothing matched", which are the same empty page and completely
    different problems.

    Movable-only (owns a List). No pointer field."""

    var hits: List[ServiceLogHit]
    var total_matches: Int
    var sources_scanned: Int

    def __init__(out self):
        """The EMPTY page — zero hits, zero matches, nothing scanned.

        The honest answer for a conformer that found no index at all, and
        distinguishable from a scanned-but-unmatched page only by
        `sources_scanned`, which is why that field exists."""
        self.hits = List[ServiceLogHit]()
        self.total_matches = 0
        self.sources_scanned = 0

    def __init__(
        out self,
        var hits: List[ServiceLogHit],
        total_matches: Int,
        sources_scanned: Int,
    ):
        self.hits = hits^
        self.total_matches = total_matches
        self.sources_scanned = sources_scanned
