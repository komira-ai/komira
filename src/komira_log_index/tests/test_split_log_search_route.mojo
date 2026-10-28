# =============================================================================
# test_split_log_search_route.mojo
#   `SplitIndexLogSearch` through the `komira_log_query` seam: a line indexed
#   into L0 splits comes back out, by its own text, through `service_log_response`.
# =============================================================================
#
# What this file keeps closed: splits an index writer publishes are only useful
# if a reader can turn them back into lines. These cases publish splits with the
# real writer (`L0BuildTask`, over a real transpose) and recover them through the
# shipped `ServiceLogSearch` conformer and the shipped HTTP handler, with no
# test-local knowledge of the split layout in the assertion path.
#
# Arrival is asserted by content, through the route. Every arrival case asserts
# that the response body contains the log line's own rendered message.
# `status == 200`, `"total":1` and a non-empty `hits` array are each satisfiable
# by a route that read a different index, matched a different record, or rendered
# a hit whose source is empty. The rendered text is not. (The route echoes `?q=`
# back in its response, so a bare `_contains(body, word)` is satisfied by the
# echo even over an empty hit list; the assertions key on the full
# `"message":"<the whole line>"` instead.)
#
# The reader and the writer are given the same `(meta_root, index)` constants,
# and one case shows a reader bound to a different meta root finds nothing: the
# layout is a caller-supplied parameter, not something the reader has an opinion
# about.
#
# Covered: the conformer, the erasure, the authorization policy, the argument
# refusals and the ordering contract. The path matcher and the rendered-JSON
# rules are in test_service_log_response_render.mojo. Not covered: that a service
# mounts the route; that belongs to whatever dispatches requests.
#
# Hermetic: no cloud, no dial, no thread. The store is
# `SharedInMemoryConditionalStore`, whose `clone()` shares state, which the
# per-shard manifest clone requires for a cross-handle read-back to mean anything.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec.types import HttpMethod, HttpRequest, HttpResponse

from komira_log import LogRecordView

from komira_log_index import (
    L0BuildTask,
    LOG_INDEX_SOURCE_FIELD,
    LOG_INDEX_TEXT_FIELD,
    SplitIndexLogSearch,
    log_index_schema,
    log_views_to_record_batch,
)
from komira_log_index.split_log_search import _in_window

from komira_log_query import (
    DenyLogReads,
    ErasedServiceLogSearch,
    HeaderTokenAccess,
    SERVICE_LOG_DEFAULT_LOOKBACK_MS,
    SERVICE_LOG_SINCE_PARAM,
    SERVICE_LOG_UNTIL_PARAM,
    ServiceLogHit,
    ServiceLogQuery,
    service_log_response,
)

from komira_objectstore import (
    CasManifestStore,
    RetryPolicy,
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path

from komira_search.sink import SearchSink
from komira_search_catalog import (
    SearchMetastore,
    make_shard_id,
    make_split_summary,
    shard_manifest_prefix,
)


comptime _META_ROOT: String = "index/logs/meta"
comptime _INDEX: String = "logs"
comptime _TOKEN: String = "operator-secret-token-for-the-tests"
comptime _PATH: String = "/logs"
comptime _HEADER: String = "x-log-read-token"
comptime _Store = SharedInMemoryConditionalStore
comptime _Reader = SplitIndexLogSearch[_Store]

comptime _BASE_MS: Int64 = 1788307200_000  # 2026-09-02T00:00:00Z, milliseconds


# ---------------------------------------------------------------------------
# Harness. The writer half publishes one split per call through the real
# `L0BuildTask`; the reader half is the shipped conformer, erased.
# ---------------------------------------------------------------------------


def _contains(haystack: String, needle: String) -> Bool:
    return _index_of(haystack, needle) >= 0 or needle.byte_length() == 0


def _index_of(haystack: String, needle: String) -> Int:
    """First byte offset of `needle` in `haystack`, or -1."""
    var h = haystack.as_bytes()
    var n = needle.as_bytes()
    if len(n) == 0 or len(n) > len(h):
        return -1
    for i in range(len(h) - len(n) + 1):
        var hit = True
        for j in range(len(n)):
            if h[i + j] != n[j]:
                hit = False
                break
        if hit:
            return i
    return -1


def _view(var message: String, wall_ms: Int64) -> LogRecordView:
    """A drain-shaped `LogRecordView`. `wall_ms` is the field the transpose
    multiplies by 1e6 to produce the TIMESTAMP_NS column."""
    return LogRecordView(
        UInt8(2),  # level
        UInt16(0),  # flags
        UInt32(7),  # site_id
        UInt32(3),  # module_id
        UInt64(0),  # raw ticks (unused by the transpose)
        UInt64(0xABCD),  # corr_id
        wall_ms,
        message^,
        String("route_test"),
        List[String](),
        List[String](),
    )


def _uuid(seq: Int) -> InlineArray[UInt8, 16]:
    var u = InlineArray[UInt8, 16](fill=UInt8(0))
    u[8] = UInt8(seq)
    return u^


def _metastore(store: _Store) raises -> SearchMetastore[_Store]:
    """A metastore over the one writer lineage every case publishes into."""
    var shard = make_shard_id(String("nodeA"), 0, String("drain"))
    var manifest = CasManifestStore[_Store](
        store.clone(),
        shard_manifest_prefix(String(_META_ROOT), shard),
        RetryPolicy.fast_test(),
    )
    return SearchMetastore[_Store](manifest^, String(_INDEX))


def _publish(
    store: _Store, var message: String, wall_ms: Int64, seq: Int
) raises:
    """Publish ONE L0 split holding ONE record, through the real build task.
    Calls on one store share a lineage, so a higher `seq` is a later publish."""
    var views = List[LogRecordView]()
    views.append(_view(message^, wall_ms))
    var task = L0BuildTask[_Store](
        views^,
        store.clone(),
        _metastore(store),
        String(_META_ROOT),
        String(_INDEX),
        _uuid(seq),
    )
    var result = task.run()
    assert_true(result.published, "harness: the split was published")
    assert_false(result.failed, "harness: the publish did not fail")


def _publish_optimized(
    store: _Store, var message: String, wall_ms: Int64, seq: Int
) raises:
    """Publish ONE OPTIMIZED (non-L0) split holding ONE record into the same
    lineage, so a reader sees both formats."""
    var views = List[LogRecordView]()
    views.append(_view(message^, wall_ms))
    var batch = log_views_to_record_batch(views)
    var uuid = _uuid(seq)
    var sink = SearchSink(
        String("bucket"),
        String("prefix"),
        String(_INDEX),
        LOG_INDEX_TEXT_FIELD,
        uuid,
        LOG_INDEX_SOURCE_FIELD,
    )
    sink.init_sink(log_index_schema())
    sink.accept_batch(batch^)
    sink.finish()
    var bytes = sink.take_split_bytes()
    var blen = Int64(len(bytes))
    var key = String(_META_ROOT) + String("/optimized-") + String(seq) + String(
        ".split"
    )
    _ = store.put(Path.parse(key), bytes)
    var metastore = _metastore(store)
    _ = metastore.publish(
        make_split_summary(
            uuid.copy(),
            Int64(1),
            blen,
            Int64(0),
            Int64(0),
            String(_INDEX),
            LOG_INDEX_TEXT_FIELD,
            key,
        )
    )


def _reader(store: _Store) raises -> ErasedServiceLogSearch:
    """The shipped conformer over the layout the writer used, erased: the exact
    value a dispatcher holds."""
    return ErasedServiceLogSearch.erase[_Reader](
        _Reader(store.clone(), String(_META_ROOT), String(_INDEX))
    )


def _req(var query_string: String, var token: String) -> HttpRequest:
    """`GET <path>?<query_string>` carrying `<token>` in the dedicated
    header. An empty token means the header is absent, not present-and-empty,
    which is a different case the route must also refuse."""
    var r = HttpRequest(HttpMethod.get(), String(_PATH))
    r.query_string = query_string^
    if token.byte_length() > 0:
        r.headers[String(_HEADER)] = token^
    return r^


def _body(resp: HttpResponse) -> String:
    var n = len(resp.body)
    if n == 0:
        return String("")
    var out = List[UInt8]()
    for i in range(n):
        out.append(resp.body[i])
    return String(unsafe_from_utf8=out)


comptime _NOW_NS: Int64 = 4_102_444_800_000_000_000
"""The `now_ns` every case passes: 2100-01-01T00:00:00Z, a constant. The handler
resolves the default window's upper bound from it, so a case that read the real
clock could only exercise the default-window branch by luck. Here every window
assertion is arithmetic."""


def _access(var token: String) -> HeaderTokenAccess:
    """The access hook that admits exactly the requests carrying `token` in the
    test header. An empty `token` is the unconfigured service: it admits nobody."""
    return HeaderTokenAccess(String(_HEADER), token^)


def _ask(
    store: _Store, var query_string: String, var token: String
) raises -> HttpResponse:
    """Drive the shipped handler over the shipped conformer.

    It appends `since_ms=0`, deliberately: the default 30-day window anchored at
    the far-future `_NOW_NS` would exclude every record these cases publish, and
    every arrival case would go red for a reason that has nothing to do with the
    code under test. The window behaviour itself is pinned by cases 12 and 13."""
    var qs = query_string^
    if qs.byte_length() > 0:
        qs += String("&")
    qs += String("since_ms=0")
    var search = Optional[ErasedServiceLogSearch](_reader(store))
    var req = _req(qs^, token^)
    return service_log_response(search, req, _access(String(_TOKEN)), _NOW_NS)


# =============================================================================
# CASE 1 — MARQUEE. A line indexed into a split is retrievable BY ITS OWN TEXT
# through the route.
# =============================================================================
def test_01_marquee_an_indexed_line_comes_back_through_the_route() raises:
    var store = _Store()
    var word = String("readroutemarqueeword")
    _publish(store, String("the deploy said ") + word.copy(), _BASE_MS, 1)

    var resp = _ask(store, String("q=") + word.copy(), String(_TOKEN))
    assert_equal(resp.status, Int32(200), "1: an authorized read returns 200")
    var body = _body(resp)
    # Assert on the rendered message, not on the search word alone: the route
    # echoes `?q=`, so a bare word match passes over an empty hit list.
    var rendered = String('"message":"the deploy said ') + word.copy() + String('"')
    assert_true(
        _contains(body, rendered),
        String(
            "1: the response must carry the line's own rendered text. Absent,"
            " the route read some other index, or rendered a hit whose source"
            " never made it out. body="
        )
        + body,
    )
    assert_true(
        _contains(body, String('"total":1')),
        String("1: exactly one record matched. body=") + body,
    )
    assert_true(
        _contains(body, String('"scanned":1')),
        String(
            "1: one live split was scanned. `scanned` is what separates 'the"
            " index is empty' from 'your term did not match', both of which are"
            " a zero-hit page. body="
        )
        + body,
    )


# =============================================================================
# CASE 2 — FAIL-CLOSED WHEN UNCONFIGURED. No expected token => 404, even for a
# caller presenting a token and a perfectly good query. A route that returns an
# operational log must not be open exactly when nobody configured it.
# =============================================================================
def test_02_unconfigured_token_refuses() raises:
    var store = _Store()
    _publish(store, String("unconfigured probe unconfiguredprobeword"), _BASE_MS, 1)

    var search = Optional[ErasedServiceLogSearch](_reader(store))
    var req = _req(String("q=unconfiguredprobeword"), String(_TOKEN))
    # The one argument that differs: no expected token configured.
    var resp = service_log_response(search, req, _access(String("")), _NOW_NS)
    assert_equal(
        resp.status,
        Int32(404),
        "2: an unconfigured route is off, not open",
    )
    assert_false(
        _contains(_body(resp), String("unconfiguredprobeword")),
        "2: and it leaks no record while refusing",
    )


# =============================================================================
# CASE 3 — THE REFUSALS ARE BYTE-IDENTICAL. Unconfigured, wrong token, absent
# token, a deny-everything hook and no reader wired must be indistinguishable on the wire. A
# distinguishable refusal tells an unauthenticated caller that this deployment
# has an operational-log surface.
# =============================================================================
def test_03_every_refusal_is_byte_identical() raises:
    var store = _Store()
    _publish(store, String("refusal probe refusalprobeword"), _BASE_MS, 1)

    # (a) unconfigured
    var s_a = Optional[ErasedServiceLogSearch](_reader(store))
    var r_a = service_log_response(
        s_a,
        _req(String("q=refusalprobeword"), String(_TOKEN)),
        _access(String("")),
        _NOW_NS,
    )
    # (b) wrong token presented
    var s_b = Optional[ErasedServiceLogSearch](_reader(store))
    var r_b = service_log_response(
        s_b,
        _req(String("q=refusalprobeword"), String("not-the-token")),
        _access(String(_TOKEN)),
        _NOW_NS,
    )
    # (c) no token presented at all
    var s_c = Optional[ErasedServiceLogSearch](_reader(store))
    var r_c = service_log_response(
        s_c,
        _req(String("q=refusalprobeword"), String("")),
        _access(String(_TOKEN)),
        _NOW_NS,
    )
    # (d) authorized, but no reader wired into the service
    var s_d = Optional[ErasedServiceLogSearch]()
    var r_d = service_log_response(
        s_d,
        _req(String("q=refusalprobeword"), String(_TOKEN)),
        _access(String(_TOKEN)),
        _NOW_NS,
    )

    # (e) the deny-everything hook
    var s_e = Optional[ErasedServiceLogSearch](_reader(store))
    var r_e = service_log_response(
        s_e,
        _req(String("q=refusalprobeword"), String(_TOKEN)),
        DenyLogReads(),
        _NOW_NS,
    )

    assert_equal(r_a.status, Int32(404), "3a: unconfigured -> 404")
    assert_equal(r_b.status, Int32(404), "3b: wrong token -> 404")
    assert_equal(r_c.status, Int32(404), "3c: absent token -> 404")
    assert_equal(r_d.status, Int32(404), "3d: unwired reader -> 404")
    assert_equal(r_e.status, Int32(404), "3e: deny-everything hook -> 404")

    var ba = _body(r_a)
    assert_equal(
        _body(r_b),
        ba,
        "3: wrong-token and unconfigured must be byte-identical; a"
        " distinguishable refusal is an existence oracle for the route",
    )
    assert_equal(_body(r_c), ba, "3: absent-token refusal is the same bytes")
    assert_equal(_body(r_d), ba, "3: unwired refusal is the same bytes")
    assert_equal(_body(r_e), ba, "3: deny-everything refusal is the same bytes")


# =============================================================================
# CASE 4 — AUTHORIZATION RUNS BEFORE ARGUMENT VALIDITY. An unauthorized caller
# with a malformed request gets the 404, not the 400; otherwise a bare request
# would answer 400 for a service that has this route and 404 for one that does
# not. An authorized caller does get the 400, because for them it is a real
# diagnosis.
#
# The 400 is raised by the wired conformer: `SplitIndexLogSearch` cannot answer a
# term-free window because `SplitSummary` carries no time range, and the route
# renders that sentence as a 400 rather than a 500 because it is a fact about the
# format, not a server fault. So this case pins both the ordering and the
# conformer-raise-to-400 mapping; case 12 pins the message.
# =============================================================================
def test_04_missing_q_is_400_only_for_an_authorized_caller() raises:
    var store = _Store()

    var s_auth = Optional[ErasedServiceLogSearch](_reader(store))
    var r_auth = service_log_response(
        s_auth, _req(String(""), String(_TOKEN)), _access(String(_TOKEN)), _NOW_NS
    )
    assert_equal(
        r_auth.status,
        Int32(400),
        "4: an authorized caller who omitted ?q= gets a real diagnosis",
    )

    var s_anon = Optional[ErasedServiceLogSearch](_reader(store))
    var r_anon = service_log_response(
        s_anon, _req(String(""), String("wrong")), _access(String(_TOKEN)), _NOW_NS
    )
    assert_equal(
        r_anon.status,
        Int32(404),
        "4: an unauthorized caller sees the refusal, never the 400; a 400"
        " here would confirm the route exists",
    )


# =============================================================================
# CASE 5 — NEWEST-FIRST ACROSS SPLITS, ON A TIMESTAMP TIE. Two splits, two
# publishes, both records stamped with the SAME millisecond (the log index's time
# resolution is one millisecond, so this is the normal case for a process logging
# at speed). The merge breaks the tie on the manifest publish sequence, so the
# later publish comes first. Both records share the query term, so relevance
# cannot be what orders them. Defect caught: a merge keyed on timestamp alone
# falls through to split-enumeration order and returns oldest-first.
# =============================================================================
def test_05_ties_in_time_are_broken_by_publish_order() raises:
    var store = _Store()
    var shared = String("orderingprobeword")
    _publish(store, shared.copy() + String(" older"), _BASE_MS, 1)
    _publish(store, shared.copy() + String(" newer"), _BASE_MS, 2)

    var resp = _ask(store, String("q=") + shared.copy(), String(_TOKEN))
    assert_equal(resp.status, Int32(200), "5: 200")
    var body = _body(resp)
    assert_true(
        _contains(body, String('"scanned":2')),
        String("5: two publishes made two splits. body=") + body,
    )
    assert_true(
        _contains(body, String('"total":2')),
        String("5: both records matched. body=") + body,
    )
    var i_newer = _index_of(body, String("newer"))
    var i_older = _index_of(body, String("older"))
    assert_true(i_newer >= 0, String("5: the newer line is present. body=") + body)
    assert_true(i_older >= 0, String("5: the older line is present. body=") + body)
    assert_true(
        i_newer < i_older,
        String(
            "5: the later publish must be rendered first on a timestamp tie."
            " body="
        )
        + body,
    )


# =============================================================================
# CASE 5b — THE TIMESTAMP OUTRANKS THE PUBLISH ORDER. The record that is newer in
# time is published FIRST (lower sequence). Defect caught: a merge that ordered by
# publish sequence alone would put the record that is older in time first.
# =============================================================================
def test_05b_the_timestamp_outranks_the_publish_order() raises:
    var store = _Store()
    var shared = String("timeoutranksprobeword")
    _publish(store, shared.copy() + String(" later"), _BASE_MS + Int64(5000), 1)
    _publish(store, shared.copy() + String(" earlier"), _BASE_MS, 2)

    var body = _body(_ask(store, String("q=") + shared.copy(), String(_TOKEN)))
    var i_later = _index_of(body, String("later"))
    var i_earlier = _index_of(body, String("earlier"))
    assert_true(i_later >= 0, String("5b: later present. body=") + body)
    assert_true(i_earlier >= 0, String("5b: earlier present. body=") + body)
    assert_true(
        i_later < i_earlier,
        String(
            "5b: the record newer in time comes first even though it was"
            " published first. body="
        )
        + body,
    )


# =============================================================================
# CASE 6 — `total` IS NOT `returned`, AND A TRUNCATED PAGE SAYS SO. Without it an
# operator reads "3 hits" off a `limit=1` page and stops looking. `scanned` is
# asserted too, so "one split held everything" cannot be mistaken for "the other
# splits were skipped".
# =============================================================================
def test_06_limit_truncates_the_page_but_not_the_total() raises:
    var store = _Store()
    var shared = String("limitprobeword")
    for i in range(3):
        _publish(
            store,
            shared.copy() + String(" line ") + String(i),
            _BASE_MS + Int64(i),
            i + 1,
        )

    var full = _body(_ask(store, String("q=") + shared.copy(), String(_TOKEN)))
    assert_true(
        _contains(full, String('"total":3')) and _contains(full, String('"returned":3')),
        String("6: unbounded, all three come back. body=") + full,
    )

    var capped = _body(
        _ask(store, String("q=") + shared.copy() + String("&limit=1"), String(_TOKEN))
    )
    assert_true(
        _contains(capped, String('"returned":1')),
        String("6: limit=1 returns one hit. body=") + capped,
    )
    assert_true(
        _contains(capped, String('"total":3')),
        String(
            "6: ...and still reports three matches. A truncated page that"
            " reported total=1 would be indistinguishable from a complete one."
            " body="
        )
        + capped,
    )
    assert_true(
        _contains(capped, String('"scanned":3')),
        String("6: all three splits were scanned to find them. body=") + capped,
    )
    # The one hit that survives the cap is the newest.
    assert_true(
        _contains(capped, String("line 2")),
        String("6: and the surviving hit is the newest. body=") + capped,
    )


# =============================================================================
# CASE 7 — `?q=` IS PERCENT-DECODED. An operator searching for `deploy failed`
# types a space; a non-decoding parser would search for the single token
# `deploy%20failed` and answer "no matches", indistinguishable from a real
# absence. The probe hex-encodes one leading byte, so the case turns on the
# decoder alone and not on multi-term analyzer semantics.
# =============================================================================
def test_07_the_query_param_is_percent_decoded() raises:
    var store = _Store()
    _publish(store, String("decode probe decodeprobeword"), _BASE_MS, 1)

    # `%64` is 'd': the same term, spelled through the decoder.
    var resp = _ask(store, String("q=%64ecodeprobeword"), String(_TOKEN))
    assert_equal(resp.status, Int32(200), "7: 200")
    var body = _body(resp)
    # The rendered message, not the term: the route echoes the decoded `?q=`, so
    # `_contains(body, "decodeprobeword")` would be true even with zero hits.
    assert_true(
        _contains(body, String('"message":"decode probe decodeprobeword"')),
        String(
            "7: a percent-escaped term must find the record. Undecoded, this"
            " searches for the literal token '%64ecodeprobeword' and answers"
            " zero, a silent wrong answer rather than an error. body="
        )
        + body,
    )


# =============================================================================
# CASE 8 — A ZERO-HIT ANSWER IS STILL AN ANSWER, and `scanned` makes it
# actionable: the index had content and the term simply did not match.
# =============================================================================
def test_08_no_match_over_a_populated_index_reports_what_it_scanned() raises:
    var store = _Store()
    _publish(store, String("present line presentprobeword"), _BASE_MS, 1)

    var body = _body(_ask(store, String("q=absentprobeword"), String(_TOKEN)))
    assert_true(
        _contains(body, String('"total":0')) and _contains(body, String('"returned":0')),
        String("8: nothing matched. body=") + body,
    )
    assert_true(
        _contains(body, String('"scanned":1')),
        String(
            "8: ...but a split was read. Without this an operator cannot tell"
            " 'my term is wrong' from 'nothing was ever published'. body="
        )
        + body,
    )


# =============================================================================
# CASE 9 — THE EMPTY INDEX. No splits: 200 with `scanned:0`, never a raise and
# never a 500. An operator asking about a service that has logged nothing yet
# must get an empty answer, not an error that reads like a fault.
# =============================================================================
def test_09_an_empty_index_answers_rather_than_faults() raises:
    var store = _Store()
    var resp = _ask(store, String("q=anything"), String(_TOKEN))
    assert_equal(resp.status, Int32(200), "9: an empty index is not a fault")
    var body = _body(resp)
    assert_true(
        _contains(body, String('"scanned":0')),
        String(
            "9: zero sources scanned, the honest 'nothing has been published'"
            " answer, distinguishable from case 8's 'scanned and unmatched'."
            " body="
        )
        + body,
    )


# =============================================================================
# CASE 12 — THE BOUND IS THE TIME WINDOW, NOT THE TERM, AND THIS CONFORMER SAYS
# WHY IT CANNOT SERVE A TERM-FREE ONE. The split catalog entry carries document
# ids and no time range, so a term is the only bound this format offers.
# =============================================================================
def test_12_the_window_filters_and_a_term_free_window_is_refused() raises:
    var store = _Store()
    var word = String("windowprobeword")
    _publish(store, String("window probe ") + word.copy(), _BASE_MS, 1)
    var want_ts = _BASE_MS * Int64(1_000_000)

    # An open window finds it, and tells us when it happened.
    var r0 = _reader(store)
    var open_page = r0.scan(ServiceLogQuery(Int64(0), _NOW_NS, word.copy(), 50))
    assert_equal(len(open_page.hits), 1, "12: an open window finds the record")
    var ts = open_page.hits[0].timestamp_ns
    assert_equal(
        ts, want_ts, "12: and it carries the record's millisecond, in ns"
    )

    # ---- (a) The window is inclusive at both ends. ----
    var r1 = _reader(store)
    var exact = r1.scan(ServiceLogQuery(ts, ts, word.copy(), 50))
    assert_equal(
        len(exact.hits), 1,
        "12a: `[ts, ts]`, a single-instant probe, keeps the record. A half-open"
        " bound at either end would drop exactly the record an operator is"
        " correlating against another system's timestamp.",
    )

    # ---- (b) A window after the record excludes it, and says what it did. ----
    var r2 = _reader(store)
    var after = r2.scan(
        ServiceLogQuery(ts + Int64(1), _NOW_NS, word.copy(), 50)
    )
    assert_equal(len(after.hits), 0, "12b: a window starting after it is empty")
    assert_true(
        after.sources_scanned > 0,
        "12b: `sources_scanned` is still non-zero; 'your window missed it' and"
        " 'nothing was ever published' are the same empty hit list and"
        " completely different problems",
    )
    assert_true(
        after.total_matches > 0,
        "12b: `total_matches` counts what the index matched, not what the"
        " window kept, so a windowed-out page still reports that the record"
        " exists",
    )

    # ---- (c) A window before the record excludes it too. ----
    var r3 = _reader(store)
    var before = r3.scan(ServiceLogQuery(Int64(0), ts - Int64(1), word.copy(), 50))
    assert_equal(len(before.hits), 0, "12c: a window ending before it is empty")

    # ---- (d) The term is optional at the seam, and this conformer refuses a
    # term-free window. The raise is the honest statement of a format
    # limitation, and its text is part of the contract: the route renders it to
    # the operator verbatim. ----
    var r4 = _reader(store)
    var raised = False
    var msg = String("")
    try:
        _ = r4.scan(ServiceLogQuery(Int64(0), _NOW_NS, String(""), 50))
    except e:
        raised = True
        msg = String(e)
    assert_true(
        raised,
        "12d: the split conformer refuses a term-free window rather than"
        " fanning out to every live split",
    )
    assert_true(
        _contains(msg, String("SplitSummary")),
        "12d: and the refusal names the structure that cannot do it. A bare"
        " 'not supported' would send an operator to the route, the token, or the"
        " store, the three places the problem is not.",
    )
    assert_true(
        _contains(msg, String("min_ts_ns")),
        "12d: and names what the replacement format carries instead",
    )


# =============================================================================
# CASE 13 — the window at the ROUTE, and the degraded-timestamp carve-out.
# =============================================================================
def test_13_the_route_renders_the_window_and_refuses_an_inverted_one() raises:
    var store = _Store()

    # ---- (a) An inverted window is refused, never silently reordered. ----
    var s_inv = Optional[ErasedServiceLogSearch](_reader(store))
    var r_inv = service_log_response(
        s_inv,
        _req(String("q=x&since_ms=2000&until_ms=1000"), String(_TOKEN)),
        _access(String(_TOKEN)),
        _NOW_NS,
    )
    assert_equal(
        r_inv.status, Int32(400),
        "13a: since > until is a 400. Swapping the bounds would answer a"
        " different question and look like it worked; an empty page would read"
        " as 'nothing was logged'.",
    )
    var inv_body = _body(r_inv)
    assert_true(
        _contains(inv_body, String(SERVICE_LOG_SINCE_PARAM))
        and _contains(inv_body, String(SERVICE_LOG_UNTIL_PARAM)),
        "13a: and it names both parameters, because the caller cannot tell"
        " which one they got wrong",
    )

    # ---- (b) The window is rendered even when defaulted. ----
    var s_def = Optional[ErasedServiceLogSearch](_reader(store))
    var r_def = service_log_response(
        s_def, _req(String("q=x"), String(_TOKEN)), _access(String(_TOKEN)), _NOW_NS
    )
    assert_equal(r_def.status, Int32(200), "13b: a defaulted window serves")
    var def_body = _body(r_def)
    var until_ms = _NOW_NS // Int64(1_000_000)
    assert_true(
        _contains(def_body, String('"until_ms":') + String(until_ms)),
        "13b: the defaulted upper bound is rendered: `now`, taken from the"
        " `now_ns` parameter rather than a clock read, which makes this"
        " assertion arithmetic instead of a race",
    )
    assert_true(
        _contains(
            def_body,
            String('"since_ms":')
            + String(until_ms - SERVICE_LOG_DEFAULT_LOOKBACK_MS),
        ),
        "13b: and so is the defaulted lower bound. Without both, an empty page"
        " is indistinguishable from 'your records are older than the window I"
        " silently chose for you'.",
    )

    # ---- (c) A degraded (zero) timestamp is never windowed out. ----
    # `_hits_of` sets `timestamp_ns = 0` when a split lost its `timestamp`
    # fast-field: a documented ordering degradation, deliberately not a lost hit.
    # Filtering on that zero would turn it into data loss. Driven directly
    # because no real split can be persuaded to lose its fast-field on demand.
    var hits = List[ServiceLogHit]()
    hits.append(ServiceLogHit(Int64(0), 1.0, String('{"m":"degraded"}')))
    hits.append(ServiceLogHit(Int64(500), 1.0, String('{"m":"inside"}')))
    hits.append(ServiceLogHit(Int64(5000), 1.0, String('{"m":"outside"}')))
    var kept = _in_window(hits^, Int64(100), Int64(1000))
    assert_equal(
        len(kept), 2,
        "13c: the in-window hit and the degraded zero survive; only the"
        " genuinely out-of-window hit is dropped",
    )
    assert_equal(
        kept[0].timestamp_ns, Int64(0),
        "13c: the zero is the one that survived; treating it as a real epoch"
        " timestamp would delete the record from every window an operator asks"
        " for",
    )
    assert_equal(kept[1].timestamp_ns, Int64(500), "13c: and the in-window one")


# =============================================================================
# CASE 14 — THE LAYOUT IS THE CALLER'S. A reader bound to a different meta root
# finds nothing in splits published under the writer's root; the matching root
# finds them. Defect caught: a reader that ignored its constructor argument (or
# re-typed the layout) would find the record under every binding or under none.
# The catalog partitions lineages by meta root, so that is the argument that
# decides where the reader looks; the index name labels the metastore handle.
# =============================================================================
def test_14_the_reader_honours_the_meta_root_it_was_given() raises:
    var store = _Store()
    var word = String("layoutprobeword")
    _publish(store, String("layout probe ") + word.copy(), _BASE_MS, 1)
    var q = ServiceLogQuery(Int64(0), _NOW_NS, word.copy(), 50)

    var same = _Reader(store.clone(), String(_META_ROOT), String(_INDEX))
    var p_same = same.scan(q)
    assert_equal(len(p_same.hits), 1, "14: the writer's root finds the record")
    assert_equal(p_same.sources_scanned, 1, "14: from one split")

    var other_root = _Reader(
        store.clone(), String("elsewhere/meta"), String(_INDEX)
    )
    var p_root = other_root.scan(q)
    assert_equal(len(p_root.hits), 0, "14: another meta root finds nothing")
    assert_equal(p_root.sources_scanned, 0, "14: and scans no split")


# =============================================================================
# CASE 15 — BOTH SPLIT FORMATS ARE ROUTED. An L0 split and an optimized split in
# the same lineage are both searched, and merged newest-first with a true total.
# Defect caught: reading an L0 split as an optimized one (or the reverse) returns
# zero hits from a split full of them.
# =============================================================================
def test_15_l0_and_optimized_splits_are_both_read_and_merged() raises:
    var store = _Store()
    var word = String("mixedformatprobeword")
    _publish(store, word.copy() + String(" fromlzero"), _BASE_MS, 1)
    _publish_optimized(
        store, word.copy() + String(" fromoptimized"), _BASE_MS + Int64(1000), 2
    )

    var r = _reader(store)
    var page = r.scan(ServiceLogQuery(Int64(0), _NOW_NS, word.copy(), 50))
    assert_equal(page.sources_scanned, 2, "15: both splits were scanned")
    assert_equal(page.total_matches, 2, "15: both records matched")
    assert_equal(len(page.hits), 2, "15: and both come back")
    assert_true(
        _contains(page.hits[0].source_json, String("fromoptimized")),
        "15: the optimized split's record is newer in time, so it is first",
    )
    assert_true(
        _contains(page.hits[1].source_json, String("fromlzero")),
        "15: and the L0 split's record follows",
    )
    assert_true(
        page.hits[0].timestamp_ns > page.hits[1].timestamp_ns,
        "15: with strictly descending timestamps",
    )


def main() raises:
    test_01_marquee_an_indexed_line_comes_back_through_the_route()
    test_02_unconfigured_token_refuses()
    test_03_every_refusal_is_byte_identical()
    test_04_missing_q_is_400_only_for_an_authorized_caller()
    test_05_ties_in_time_are_broken_by_publish_order()
    test_05b_the_timestamp_outranks_the_publish_order()
    test_06_limit_truncates_the_page_but_not_the_total()
    test_07_the_query_param_is_percent_decoded()
    test_08_no_match_over_a_populated_index_reports_what_it_scanned()
    test_09_an_empty_index_answers_rather_than_faults()
    test_12_the_window_filters_and_a_term_free_window_is_refused()
    test_13_the_route_renders_the_window_and_refuses_an_inverted_one()
    test_14_the_reader_honours_the_meta_root_it_was_given()
    test_15_l0_and_optimized_splits_are_both_read_and_merged()
    print("PASS test_split_log_search_route")
