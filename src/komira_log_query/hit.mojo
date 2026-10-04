# =============================================================================
# komira_log_query/hit.mojo — the FORMAT-NEUTRAL value types a log read returns.
# =============================================================================
#
# ── WHY THESE NAME NO AT-REST FORMAT ────────────────────────────────────────
# A log in an object store can be laid out several ways: as search-index files
# (a term dictionary, posting lists, a docstore), or as time-partitioned files
# laid out for time-series queries, or both. The bytes a hit is decoded FROM
# differ by layout, so the READ SEAM is stated in terms every layout can
# satisfy: a timestamp, a relevance score, and the record as JSON. Nothing here
# mentions a posting list, a term dictionary, a docstore or a partition.
#
# WHAT CHANGES UNDER A NEW LAYOUT: the CONFORMER, the one place that names a
# format's own types. NOT this file, NOT `search_seam.mojo`, NOT `route.mojo`,
# NOT the service that mounts the route. Those see only the trait.
#
# ── `source_json` IS A CONTRACT, AND IT IS THE ONE THE ROUTE RENDERS ────────
# It is the record, encoded as a JSON object (for example message / level /
# module / timestamp plus a nested `args`). Every layout must produce that SHAPE,
# not the same bytes.
#
# ⚠ THE ROUTE DOES NOT PARSE IT and deliberately does not depend on its inner
# field names: it embeds it (see `route.mojo`'s embed-or-quote rule). A reader
# that started parsing `source_json` here would re-couple this package to one
# layout.
#
# Encapsulation: value types only — Int64 / Float64 / String / List. ZERO
# UnsafePointer in any signature, ZERO wildcard origin, ZERO unsafe_from_address.
# Plain stack/heap values, never a byte-slab element, so there is no stale-pointer
# hazard across destroy and recreate.
# =============================================================================


@fieldwise_init
struct ServiceLogQuery(Copyable, Movable, Deinitable):
    """ONE read of a service's log: a TIME WINDOW, an OPTIONAL term, and a page
    bound.

    ── ⭐ WHY THE WINDOW IS FIRST, AND WHY THE TERM IS OPTIONAL ───────────────
    ⛔ A SEAM THAT TAKES ONLY A TERM ENCODES A PROPERTY OF ONE AT-REST LAYOUT,
    NOT OF LOG READING. A search-index catalog whose entries carry no time range
    can bound a read only by a term. A time-partitioned layout prunes by time
    before a byte is fetched, and *"the last 200 lines"*, the most common log
    query there is, is then the PRIMARY query rather than an inexpressible one.
    ⇒ the bound is the WINDOW, and the term narrows within it.

    `t0_ns` / `t1_ns` are INCLUSIVE at both ends. A conformer over time
    partitions must state the same closed interval; a half-open bound at one
    layer drops rows only at partition edges, which is the least reproducible
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

    `timestamp_ns` is the record's wall clock in NANOSECONDS. It is carried OUT
    OF BAND from `source_json` on purpose: a conformer merging hits from several
    files and the route's ordering both need it as a number, and lifting it out
    of the blob would mean parsing JSON in the merge loop.

    `score` is the RELEVANCE of the match (for example BM25 from a text index).
    Surfaced because a reader searching for a phrase wants to know which hit
    actually matched it, and 0.0 from any conformer that has no notion of
    relevance. ⛔ It is NOT an ordering the route
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
    contract rather than the conformer's convenience. A person reading a
    service's log is asking "what happened, most recently" far more often than
    "what matched best", and a page ordered by relevance across several files
    presents interleaved times that look like corruption.

    ⚠ `total_matches` IS NOT `len(hits)` AND THE DIFFERENCE IS THE POINT. It is
    how many records matched across everything scanned; `hits` carries at most
    `limit` of them. Without it, a truncated page is indistinguishable from a
    complete one: the reader sees "3 matches" and stops looking, when there
    were nine thousand. The route renders both, always.

    `sources_scanned` is how many at-rest units (files) the conformer read. It is a MEASUREMENT, not an assertion: it makes
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
