# =============================================================================
# test_log_native_indexing_idle_hook_e2e.mojo
#   The production end to end for the per-worker installable idle-hook slot.
# =============================================================================
#
# WHAT THIS PROVES (searchable on land: a caller that writes and then
# immediately searches gets correct, NON-EMPTY results):
#
#   It drives the real path end to end:
#     1. construct a real SharedEngine and install it as the process-global
#        engine;
#     2. construct a real PerCoreAsyncRuntime and worker;
#     3. install the idle hook through the production setup path
#        (`install_native_index_idle_hook` -> `runtime.install_idle_hook` ->
#        `worker.set_idle_hook`);
#     4. emit real log records onto the real per-worker ring (`engine.ring(wid)`,
#        the same ring the ambient `log.info` facade lands records in);
#     5. fire the worker's own installed idle hook (`_fire_idle_hook`, the
#        method the worker's spin loop calls in an empty window):
#        drain_worker_to_records -> transpose -> build cheap L0 -> publish;
#     6. immediately run a real query through the read path (parse the split,
#        route on `has_l0_posting()` to `search_l0_split`, the per-split route of
#        a read fan-out) and assert correct NON-EMPTY results against an
#        independent brute-force oracle (selective, common, multi-site and
#        absent terms).
#
#   It deliberately does not construct L0BuildTask or the builder directly: the
#   only trigger is the worker's idle-hook fire. If the slot, the call site or
#   the install were not wired, no split would ever publish and the assertion
#   that one did would fail.
#
# THE CASES:
#   * SEARCHABLE ON LAND: a non-empty correct result set after the idle hook
#     fires (against the oracle), for several term classes.
#   * NO STARVE (bounded): one idle visit drains at most DRAIN_CAP records (one
#     cheap L0 build), so a batch larger than DRAIN_CAP publishes across MULTIPLE
#     idle windows, never one unbounded flush.
#   * AT MOST ONCE (graceful shutdown, zero loss): records emitted but not yet
#     idle-flushed are published by the final flush (`flush_all_pending`, called
#     after `runtime.shutdown()` joins all workers, so there is no SPSC race).
#     Every emitted record is searchable after the final flush.
#
# DETERMINISM: the test fires the installed hook directly on the test thread
# (which is worker 0's owning thread for SPSC purposes) with a hard iteration
# cap, so a regression that breaks the wiring fails rather than hangs.
#
# The test drives only the safe public surface (install_native_index_idle_hook
# and the read fan-out). No UnsafePointer here.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
)

from komira_spsc_ring.spsc_ring import OVERFLOW_BLOCK

from komira_log import SharedEngine
from komira_log.engine.log_manager import LogManager
from komira_log import LogRecordView
from komira_log.env_filter import EnvFilter
from komira_log.engine.emit import emit_record
from komira_log.levels import LEVEL_INFO, LEVEL_WARN, LEVEL_ERROR
from komira_log.log_arg import ArgI64, ArgStr

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PerCoreAsyncRuntime,
    PLACEMENT_FIXED,
)

from std.memory import OwnedPointer, UnsafePointer

from komira_log_index import (
    LOG_INDEX_TEXT_FIELD,
    IdleIndexContext,
    install_native_index_idle_hook,
    drop_installed_hook,
    flush_all_pending_via_hook,
    DRAIN_CAP,
    search_l0_split,
)

from komira_objectstore import (
    SharedInMemoryConditionalStore,
    RetryPolicy,
)
from komira_objectstore.path import Path
from komira_search_catalog import list_live_splits_across_shards

from komira_search.analyzer import AnalyzerConfig, analyze_text
from komira_search.split import SplitView
from komira_search.source import QueryIR, SearchResult


# -----------------------------------------------------------------------------
# Fixtures — the same OTLP-ish login + multi-site corpus the L1/L-READ suites use.
# -----------------------------------------------------------------------------

comptime _NODE_ID: String = "nodeE2E"
comptime _META_ROOT: String = "index/logs/meta"
comptime _INDEX: String = "logs"


def _all_filter() -> EnvFilter:
    var f = EnvFilter()
    return f^


def _make_engine_owned(num_workers: Int) raises -> OwnedPointer[SharedEngine]:
    """Build the engine in an OwnedPointer (a stable heap address) and install
    it as the process-global engine. The stable address matters: the installed
    hook reaches the engine through a handle baked in at install, and a by-value
    local could be moved to a different stack slot."""
    var eng = OwnedPointer[SharedEngine](
        value=SharedEngine(num_workers=num_workers, filter=_all_filter())
    )
    _register_sites(eng[])
    LogManager._test_install_borrow(eng[])
    return eng^


def _register_sites(mut eng: SharedEngine):
    """Register every (fmt, module) the e2e emits so the engine's drain can
    decode them (the facade registers each site at first emit; we pre-register
    for the direct-ring path)."""
    eng.register_site["request {} method {} status {}", "komira_http"]()
    eng.register_site[
        "query finished in {} ms scanned {} rows", "komira_engine"
    ]()
    eng.register_site["opened file {} size {} bytes", "komira_parquet"]()
    eng.register_site["retry {} reason {}", "komira_agent"]()
    eng.register_site["connection {} from {} closed", "komira_broker"]()
    eng.register_site["login {} status {}", "komira_auth"]()


def _emit_corpus(mut eng: SharedEngine, wid: Int, n: Int):
    """Emit `n` records cycling the 5 OTLP sites onto `engine.ring(wid)` — the
    SAME per-worker ring the ambient facade lands records in. Plus the
    'login' site so a SELECTIVE term has a known cardinality (every 6th record)."""
    ref r = eng.ring(wid)
    for i in range(n):
        var m = i % 6
        var c = UInt64(1000 + i)
        if m == 0:
            _ = emit_record["request {} method {} status {}", "komira_http"](
                r, LEVEL_INFO, c, ArgStr(String("/v1/query")), ArgStr(String("POST")), ArgI64(200)
            )
        elif m == 1:
            _ = emit_record[
                "query finished in {} ms scanned {} rows", "komira_engine"
            ](r, LEVEL_INFO, c, ArgI64(42), ArgI64(6001215))
        elif m == 2:
            _ = emit_record["opened file {} size {} bytes", "komira_parquet"](
                r, LEVEL_WARN, c, ArgStr(String("lineitem.parquet")), ArgI64(298000000)
            )
        elif m == 3:
            _ = emit_record["retry {} reason {}", "komira_agent"](
                r, LEVEL_ERROR, c, ArgI64(3), ArgStr(String("connection timeout to upstream"))
            )
        elif m == 4:
            _ = emit_record["connection {} from {} closed", "komira_broker"](
                r, LEVEL_INFO, c, ArgI64(7), ArgStr(String("192.0.2.42"))
            )
        else:
            _ = emit_record["login {} status {}", "komira_auth"](
                r, LEVEL_INFO, c, ArgStr(String("login")), ArgI64(200)
            )


def _match_query(term: String, top_k: Int = 4096) -> QueryIR:
    var q = QueryIR(
        LOG_INDEX_TEXT_FIELD,
        term,
        top_k,
        AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD),
        0,
    )
    return q^


# -----------------------------------------------------------------------------
# The read fan-out, a per-split route: enumerate the live
# splits across the index's drain sub-lineages, parse each split's footer, branch
# on has_l0_posting() -> search_l0_split, MERGE the per-split matches. Returns the
# UNION doc-message set so we can compare against the brute-force oracle.
# -----------------------------------------------------------------------------


def _search_across_published_splits(
    store: SharedInMemoryConditionalStore, term: String
) raises -> Int:
    """Run `term` through the LIVE read path across every published drain-role
    split and return the TOTAL match count (the union total_matches across all
    splits; each split is a per-window L0 split). Mirrors a read fan-out: list
    live splits -> per-split parse -> route on has_l0_posting() -> search_l0_split."""
    var live = list_live_splits_across_shards(store, _META_ROOT, _INDEX)
    var total = 0
    var query = _match_query(term)
    for i in range(len(live)):
        var key = live[i].object_key
        var bytes = store.get(Path.parse(key))
        var view = SplitView.parse(bytes^)
        # The route discriminator.
        if view.has_l0_posting():
            var res = search_l0_split(view, _match_query(term))
            total += res.total_matches
        # (No optimized splits here — the idle hook only ever writes L0 splits.)
    return total


def _oracle_term_count(n: Int, term: String) raises -> Int:
    """Independent brute-force oracle: count how many of the `n` emitted records'
    analyzed messages contain the analyzed `term`. Reconstructs the messages from
    the SAME 6-site cycle `_emit_corpus` uses (NO shared code with the indexer)."""
    var config = AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD)
    var qa = analyze_text(term, config)
    if qa.len() == 0:
        return 0
    var qterm = qa.tokens[0].term
    var count = 0
    for i in range(n):
        var m = i % 6
        var msg = String("")
        if m == 0:
            msg = String("request /v1/query method POST status 200")
        elif m == 1:
            msg = String("query finished in 42 ms scanned 6001215 rows")
        elif m == 2:
            msg = String("opened file lineitem.parquet size 298000000 bytes")
        elif m == 3:
            msg = String("retry 3 reason connection timeout to upstream")
        elif m == 4:
            msg = String("connection 7 from 192.0.2.42 closed")
        else:
            msg = String("login login status 200")
        var af = analyze_text(msg, config)
        for ti in range(af.len()):
            if af.tokens[ti].term == qterm:
                count += 1
                break
    return count


def _live_split_count(store: SharedInMemoryConditionalStore) raises -> Int:
    return len(list_live_splits_across_shards(store, _META_ROOT, _INDEX))


# =============================================================================
# THE GENUINE PRODUCTION e2e.
# =============================================================================


def test_searchable_on_land_via_live_idle_hook() raises:
    """The core gate: emit -> the LIVE worker idle-window hook fires -> the split
    publishes -> an IMMEDIATE query returns correct NON-EMPTY results vs oracle.

    The batch is small (<= DRAIN_CAP) so one idle window flushes it all, the
    write-then-immediately-search latency a caller sees.

    Choice of n (do not shrink it): the term-class
    assertions below cover a SELECTIVE term ('login', site m==5), a COMMON term
    ('status', sites m==0 and m==5), and a MULTI-SITE term ('connection', the
    broker site m==4 AND the retry site m==3's 'connection timeout'). `_emit_corpus`
    cycles the 6 OTLP sites by `i % 6`, so a record for EVERY site only exists once
    `n >= 6`. n MUST therefore be a multiple of 6 in [6, DRAIN_CAP] so each site is
    emitted a whole number of times and every term class has a known, nonzero
    cardinality. n=12 = two full cycles (each site emitted twice), still one idle
    window (12 <= DRAIN_CAP == 24). With n=2 only sites m==0 (request) and m==1
    (query-finished) are emitted, so 'login' and 'connection' would be absent
    and the `oracle_* > 0` assertions would fail for a reason that is not a
    product defect."""
    var n = 12  # two full 6-site cycles, <= DRAIN_CAP (24): one idle window.

    # ---- Real engine (stable heap address, see the helper). ----
    var eng = _make_engine_owned(1)

    # ---- REAL CAS store (the publish target; in-memory hermetic). ----
    var store = SharedInMemoryConditionalStore()

    # ---- REAL runtime + worker pool. ----
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)

    # ---- Production install path: the install consumes the context into a
    #      long-lived raw home and returns the pointer-free
    #      `InstalledIndexHook` the owner (here: the test) holds and frees after
    #      the join. The context carries the baked engine handle; the hook is
    #      pushed onto every worker. ----
    var hook = install_native_index_idle_hook(
        rt,
        IdleIndexContext[SharedInMemoryConditionalStore, origin_of(eng[])](
            store.clone(), _NODE_ID, _META_ROOT, _INDEX, eng[],
            RetryPolicy.fast_test(),
        ),
    )
    assert_true(
        rt.worker_at(0).has_idle_hook(),
        "hook installed on worker 0 via the production path",
    )

    # ---- Emit REAL records onto worker 0's ring (the same ring the facade
    #      lands records in). ----
    _emit_corpus(eng[], 0, n)

    # ---- Drive the worker's own installed idle-hook fire (the method the
    #      worker's spin loop calls) on this thread, which is worker 0's owning
    #      thread for SPSC purposes. This goes through the real `_idle_hook` slot
    #      and fire trampoline -> drain -> build -> publish, not a direct builder
    #      call. ----
    rt.worker_at(0)._fire_idle_hook()
    var published = _live_split_count(store) >= 1
    assert_true(
        published,
        "the installed idle-hook fire published a drain split (the wiring fired "
        "end to end through the slot and trampoline)",
    )

    rt.shutdown()
    # Free the context home AFTER the join, through the pointer-free
    # `drop_installed_hook` over the held `InstalledIndexHook`.
    drop_installed_hook[SharedInMemoryConditionalStore, origin_of(eng[])](hook)

    # ---- IMMEDIATE query through the LIVE read path: correct NON-EMPTY results
    #      vs the independent oracle, for multiple term classes. ----
    # Selective: 'login' (site m==5, every 6th record -> n/6 == 2 of 12).
    var got_login = _search_across_published_splits(store, String("login"))
    var oracle_login = _oracle_term_count(n, String("login"))
    assert_true(oracle_login > 0, "oracle: 'login' is present")
    assert_true(got_login > 0, "searchable-on-land: 'login' returns NON-EMPTY")
    assert_equal(got_login, oracle_login, "selective 'login' == oracle")

    # Common: 'status' (request + login sites).
    var got_status = _search_across_published_splits(store, String("status"))
    var oracle_status = _oracle_term_count(n, String("status"))
    assert_true(got_status > 0, "searchable-on-land: 'status' NON-EMPTY")
    assert_equal(got_status, oracle_status, "common 'status' == oracle")

    # Multi-site distinct: 'connection' (broker site + retry's 'connection').
    var got_conn = _search_across_published_splits(store, String("connection"))
    var oracle_conn = _oracle_term_count(n, String("connection"))
    assert_true(got_conn > 0, "searchable-on-land: 'connection' NON-EMPTY")
    assert_equal(got_conn, oracle_conn, "multi 'connection' == oracle")

    # Absent: a term that appears in NO message -> EMPTY (not a false positive).
    var got_absent = _search_across_published_splits(
        store, String("nonexistentxyz")
    )
    assert_equal(got_absent, 0, "absent term -> EMPTY result")

    # ---- Teardown the engine handle before the engine drops. ----
    LogManager._test_reset()
    # ctx_owned drops AFTER rt (declaration order -> reverse drop): rt already
    # shut down (explicit shutdown above), so its __del__ join is a no-op; the
    # context frees against bytes no worker can reach.


def test_no_starve_bounded_across_multiple_idle_windows() raises:
    """NO-STARVE gate: a batch LARGER than DRAIN_CAP is NOT flushed in one
    unbounded visit — each idle window drains at most DRAIN_CAP records (one
    cheap L0 build), so a > DRAIN_CAP batch publishes across MULTIPLE splits
    (multiple idle windows). This proves the hook is bounded (the worker-side
    no-starve guarantee) AND that the backlog still becomes fully searchable."""
    var n = DRAIN_CAP * 3 + 5  # 3+ windows worth -> >= 4 splits.

    var eng = _make_engine_owned(1)
    var store = SharedInMemoryConditionalStore()
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var hook = install_native_index_idle_hook(
        rt,
        IdleIndexContext[SharedInMemoryConditionalStore, origin_of(eng[])](
            store.clone(), _NODE_ID, _META_ROOT, _INDEX, eng[],
            RetryPolicy.fast_test(),
        ),
    )
    _emit_corpus(eng[], 0, n)

    # BOUNDED proof: fire the installed idle hook REPEATEDLY (each fire is one
    # idle window). Each fire drains at most DRAIN_CAP records (one cheap L0
    # build) -> one split per fire. A > DRAIN_CAP backlog therefore needs
    # ceil(n/DRAIN_CAP) fires -> that many splits. (A bug that drained the whole
    # ring in one visit would publish a SINGLE split with n docs.) Bounded: we
    # fire at most a hard cap of windows, then assert.
    var expected_min_splits = (n + DRAIN_CAP - 1) // DRAIN_CAP
    var fires = 0
    while fires < expected_min_splits + 4:  # hard cap (no unbounded loop).
        rt.worker_at(0)._fire_idle_hook()
        fires += 1
        if _live_split_count(store) >= expected_min_splits:
            break
    rt.shutdown()
    _ = flush_all_pending_via_hook[
        SharedInMemoryConditionalStore, origin_of(eng[])
    ](hook, 1)
    drop_installed_hook[SharedInMemoryConditionalStore, origin_of(eng[])](hook)

    var splits = _live_split_count(store)
    assert_true(
        splits >= expected_min_splits,
        String("no-starve: backlog published across >= ")
        + String(expected_min_splits)
        + " bounded splits (got "
        + String(splits)
        + ") — each idle visit drained at most DRAIN_CAP, never one unbounded flush",
    )

    # And the FULL backlog is searchable (no record lost across the windows).
    var got_login = _search_across_published_splits(store, String("login"))
    var oracle_login = _oracle_term_count(n, String("login"))
    assert_equal(
        got_login, oracle_login,
        "no-starve: the FULL >DRAIN_CAP backlog is searchable (union == oracle)",
    )
    LogManager._test_reset()


def test_at_most_once_graceful_final_flush_zero_loss() raises:
    """AT-MOST-ONCE gate: records that were NEVER idle-flushed (the worker was
    shut down immediately after a tiny run) are published by the graceful-
    shutdown FINAL flush (`flush_all_pending` AFTER join) -> ZERO loss. Every
    emitted record is searchable after the final flush."""
    var n = DRAIN_CAP * 2 + 7

    var eng = _make_engine_owned(1)
    var store = SharedInMemoryConditionalStore()
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var hook = install_native_index_idle_hook(
        rt,
        IdleIndexContext[SharedInMemoryConditionalStore, origin_of(eng[])](
            store.clone(), _NODE_ID, _META_ROOT, _INDEX, eng[],
            RetryPolicy.fast_test(),
        ),
    )
    _emit_corpus(eng[], 0, n)

    # Fire ONE idle window (drains at most DRAIN_CAP < n records) — the rest is
    # the UN-FLUSHED backlog a tool/worker leaves when it shuts down before
    # indexing everything.
    rt.worker_at(0)._fire_idle_hook()
    rt.shutdown()  # joins the worker -> no SPSC consumer running.

    # The graceful-shutdown FINAL flush drains every worker's REMAINING ring
    # (no race — workers joined) and publishes it. After this, ZERO loss.
    var flushed_final = flush_all_pending_via_hook[
        SharedInMemoryConditionalStore, origin_of(eng[])
    ](hook, 1)
    _ = flushed_final
    drop_installed_hook[SharedInMemoryConditionalStore, origin_of(eng[])](hook)

    # EVERY emitted record is searchable (union across all splits == oracle) —
    # nothing was lost on graceful shutdown.
    var got_login = _search_across_published_splits(store, String("login"))
    var oracle_login = _oracle_term_count(n, String("login"))
    assert_equal(
        got_login, oracle_login,
        "at-most-once: graceful final flush -> ZERO loss ('login' union == oracle)",
    )
    var got_request = _search_across_published_splits(store, String("request"))
    var oracle_request = _oracle_term_count(n, String("request"))
    assert_equal(
        got_request, oracle_request,
        "at-most-once: graceful final flush -> ZERO loss ('request' == oracle)",
    )
    LogManager._test_reset()


def main() raises:
    var suite = TestSuite()
    suite.test[test_searchable_on_land_via_live_idle_hook]()
    suite.test[test_no_starve_bounded_across_multiple_idle_windows]()
    suite.test[test_at_most_once_graceful_final_flush_zero_loss]()
    suite^.run()
