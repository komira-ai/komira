# =============================================================================
# test_log_index_failure_paths.mojo
#   Publish ordering, failure handling and corrupt-input handling of the log
#   index.
# =============================================================================
#
# What each case pins:
#   * a split is PUT before the metastore publish (a recording store logs the
#     order of its verbs);
#   * a failing split PUT publishes nothing, and a failing publish leaves only an
#     unreferenced object; in both cases the build task reports `failed` and does
#     not raise;
#   * `L0PostingIndex.deserialize` and `search_l0_split` raise on a truncated,
#     oversized, mis-versioned, non-ascending or disagreeing region;
#   * the term hash is FNV-1a 64 (fixed vectors), so the posting format is stable;
#   * `flush_all_pending_via_hook` over a failing store raises and leaves the
#     context home intact for `drop_installed_hook` (no double free);
#   * two hook installs over one store (a process restart) never overwrite each
#     other's published splits.
# =============================================================================

from std.memory import ArcPointer, OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_spsc_ring.spsc_ring import OVERFLOW_BLOCK

from komira_log import SharedEngine, LogRecordView
from komira_log.engine.calibration import CalibrationAnchor
from komira_log.engine.drain import drain_to_views
from komira_log.engine.emit import emit_record
from komira_log.engine.log_manager import LogManager
from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.site_dictionary import SiteDictionary
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_INFO
from komira_log.log_arg import ArgI64, ArgStr

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PerCoreAsyncRuntime, PLACEMENT_FIXED

from komira_hash import fnv1a_64

from komira_log_index import (
    LOG_INDEX_TEXT_FIELD,
    IdleIndexContext,
    L0BuildTask,
    L0PostingIndex,
    L0SegmentBuilder,
    drop_installed_hook,
    flush_all_pending_via_hook,
    install_native_index_idle_hook,
    log_index_schema,
    log_views_to_record_batch,
    search_l0_split,
)

from komira_objectstore import (
    CasManifestStore,
    CloneableConditionalWriteStore,
    CoalescePolicy,
    ConditionalWriteStore,
    ListResult,
    ObjectMeta,
    ObjectStore,
    RetryPolicy,
    SharedInMemoryConditionalStore,
    WritePrecondition,
)
from komira_objectstore.path import Path
from komira_log_index.idle_index_hook import _build_and_publish_split
from komira_search.analyzer import AnalyzerConfig
from komira_search.sink import SearchSink
from komira_search.split import SplitView
from komira_search.source import QueryIR
from komira_search_catalog import (
    SearchMetastore,
    list_live_splits_across_shards,
    make_shard_id,
    shard_manifest_prefix,
)


# -----------------------------------------------------------------------------
# A store that records the order of its write verbs and can be told to fail.
# -----------------------------------------------------------------------------


struct _State(Movable):
    var log: List[String]
    var fail_put: Bool
    var fail_conditional: Bool

    def __init__(out self):
        self.log = List[String]()
        self.fail_put = False
        self.fail_conditional = False


struct RecordingStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var _inner: SharedInMemoryConditionalStore
    var _st: ArcPointer[_State]

    def __init__(out self):
        self._inner = SharedInMemoryConditionalStore()
        self._st = ArcPointer[_State](_State())

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var st: ArcPointer[_State],
    ):
        self._inner = inner^
        self._st = st^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._st.copy())

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._st[].log.append(String("cond:") + path.raw())
        if self._st[].fail_conditional:
            raise Error("RecordingStore: injected conditional_put failure")
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.conditional_put(
            path, bytes, WritePrecondition.if_match(expected_version)
        )

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._st[].log.append(String("put:") + path.raw())
        if self._st[].fail_put:
            raise Error("RecordingStore: injected put failure")
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)

    def log(self) -> List[String]:
        return self._st[].log.copy()


# -----------------------------------------------------------------------------
# Fixtures.
# -----------------------------------------------------------------------------

comptime _META_ROOT: String = "index/logs/meta"
comptime _INDEX: String = "logs"


def _anchor() -> CalibrationAnchor:
    return CalibrationAnchor(
        tick0=UInt64(0),
        wall0_ns=UInt64(1_788_220_800) * UInt64(1_000_000_000),
        tick_hz=UInt64(1_000_000_000),
    )


def _login_views(n: Int) raises -> List[LogRecordView]:
    var d = SiteDictionary()
    d.register["request {} status {}", "komira_http_login"]()
    var ring = LogRecordRing(capacity=n + 8, overflow_policy=OVERFLOW_BLOCK)
    for i in range(n):
        _ = emit_record["request {} status {}", "komira_http_login"](
            ring, LEVEL_INFO, UInt64(100 + i), ArgStr(String("login")), ArgI64(200)
        )
    return drain_to_views(ring, d, _anchor())


def _l0_split_bytes(n: Int) raises -> List[UInt8]:
    var views = _login_views(n)
    var seg = L0SegmentBuilder(log_index_schema())
    seg.add_batch(log_views_to_record_batch(views))
    return seg.serialize_split_bytes(
        LOG_INDEX_TEXT_FIELD, InlineArray[UInt8, 16](fill=UInt8(7))
    )


def _query(term: String) -> QueryIR:
    return QueryIR(
        LOG_INDEX_TEXT_FIELD,
        term,
        1000,
        AnalyzerConfig.text(LOG_INDEX_TEXT_FIELD),
        0,
    )


def _task(
    store: RecordingStore, n: Int
) raises -> L0BuildTask[RecordingStore]:
    var shard = make_shard_id(String("nodeA"), 0, String("drain"))
    var manifest = CasManifestStore[RecordingStore](
        store.clone(),
        shard_manifest_prefix(String(_META_ROOT), shard),
        RetryPolicy.fast_test(),
    )
    var metastore = SearchMetastore[RecordingStore](manifest^, String(_INDEX))
    var uuid = InlineArray[UInt8, 16](fill=UInt8(0))
    uuid[8] = UInt8(1)
    return L0BuildTask[RecordingStore](
        _login_views(n),
        store.clone(),
        metastore^,
        String(_META_ROOT),
        String(_INDEX),
        uuid,
    )


def _live(store: RecordingStore) raises -> Int:
    return len(
        list_live_splits_across_shards(store, String(_META_ROOT), String(_INDEX))
    )


def _starts_with(s: String, prefix: String) -> Bool:
    return s.startswith(prefix)


def _count_prefix(log: List[String], prefix: String) -> Int:
    var c = 0
    for i in range(len(log)):
        if _starts_with(log[i], prefix):
            c += 1
    return c


# -----------------------------------------------------------------------------
# Build task: ordering and failure.
# -----------------------------------------------------------------------------


def test_split_is_put_before_it_is_published() raises:
    var store = RecordingStore()
    var task = _task(store, 8)
    var result = task.run()
    assert_true(result.published, "published")
    assert_false(result.failed, "not failed")
    var log = store.log()
    assert_true(len(log) >= 2, "a put and at least one conditional write")
    assert_true(
        _starts_with(log[0], "put:") and "/splits/" in log[0],
        "the first write is the split PUT: " + log[0],
    )
    assert_equal(_count_prefix(log, "put:"), 1, "exactly one split PUT")
    assert_true(_count_prefix(log, "cond:") >= 1, "the manifest is written after")
    assert_equal(_live(store), 1, "the split is live")


def test_idle_hook_puts_the_split_before_it_publishes() raises:
    """The idle hook's own build-and-publish path writes the split object
    before its summary reaches the manifest, like L0BuildTask: a crash between
    the two leaves an unreferenced object, never a summary naming a missing
    one."""
    var store = RecordingStore()
    var uuid = InlineArray[UInt8, 16](fill=UInt8(0))
    uuid[8] = UInt8(2)
    var n = _build_and_publish_split[RecordingStore](
        _login_views(8),
        UInt16(0),
        String("nodeA"),
        String(_META_ROOT),
        String(_INDEX),
        store,
        uuid^,
        RetryPolicy.fast_test(),
    )
    assert_equal(n, 8, "the hook published every view")
    var log = store.log()
    assert_true(len(log) >= 2, "a put and at least one conditional write")
    assert_true(
        _starts_with(log[0], "put:") and "/splits/" in log[0],
        "the hook's first write is the split PUT: " + log[0],
    )
    assert_equal(_count_prefix(log, "put:"), 1, "exactly one split PUT")
    assert_true(_count_prefix(log, "cond:") >= 1, "the manifest is written after")
    assert_equal(_live(store), 1, "the split is live")


def test_failed_put_publishes_nothing_and_does_not_raise() raises:
    var store = RecordingStore()
    store._st[].fail_put = True
    var task = _task(store, 8)
    var result = task.run()
    assert_true(result.failed, "failed flag set")
    assert_false(result.published, "not published")
    assert_equal(Int(result.docs), 8, "docs counts the lost batch")
    assert_equal(Int(result.bytes), 0, "no bytes on failure")
    assert_equal(
        _count_prefix(store.log(), "cond:"), 0, "no manifest write after a failed PUT"
    )
    assert_equal(_live(store), 0, "nothing is live")


def test_failed_publish_leaves_only_an_unreferenced_object() raises:
    var store = RecordingStore()
    store._st[].fail_conditional = True
    var task = _task(store, 8)
    var result = task.run()
    assert_true(result.failed, "failed flag set")
    assert_false(result.published, "not published")
    assert_equal(Int(result.docs), 8, "docs counts the lost batch")
    assert_equal(_count_prefix(store.log(), "put:"), 1, "the PUT happened first")
    store._st[].fail_conditional = False
    assert_equal(_live(store), 0, "nothing is live")


# -----------------------------------------------------------------------------
# Posting region: corrupt input.
# -----------------------------------------------------------------------------


def _posting(
    num_terms: Int,
    num_docs: Int,
    h: UInt64,
    deltas: List[Int],
    tfs: List[Int],
) -> List[UInt8]:
    """A one-term region: version, counts, hash, df, deltas, tfs (all values
    below 128 so each is a single ULEB128 byte)."""
    var b = List[UInt8]()
    b.append(UInt8(1))
    b.append(UInt8(num_terms))
    b.append(UInt8(num_docs))
    for i in range(8):
        b.append(UInt8(Int((h >> UInt64(8 * i)) & UInt64(0xFF))))
    b.append(UInt8(len(deltas)))
    for i in range(len(deltas)):
        b.append(UInt8(deltas[i]))
    for i in range(len(tfs)):
        b.append(UInt8(tfs[i]))
    return b^


def _deserialize_error(region: List[UInt8]) -> String:
    """The error text of deserializing `region`, or "" if it parsed."""
    try:
        _ = L0PostingIndex.deserialize(Span(region))
    except e:
        return String(e)
    return String("")


def test_deserialize_rejects_malformed_regions() raises:
    var empty = List[UInt8]()
    assert_true("empty region" in _deserialize_error(empty), "empty")

    var bad_version = List[UInt8]()
    bad_version.append(UInt8(2))
    assert_true(
        "unsupported version" in _deserialize_error(bad_version), "version"
    )

    var truncated_counts = List[UInt8]()
    truncated_counts.append(UInt8(1))
    truncated_counts.append(UInt8(1))
    assert_true(
        "truncated" in _deserialize_error(truncated_counts), "counts cut short"
    )

    var too_long = List[UInt8]()
    too_long.append(UInt8(1))
    for _ in range(10):
        too_long.append(UInt8(0x80))
    too_long.append(UInt8(0x01))
    assert_true("too long" in _deserialize_error(too_long), "11-byte ULEB128")

    var overrun = List[UInt8]()
    overrun.append(UInt8(1))
    overrun.append(UInt8(100))  # 100 terms
    overrun.append(UInt8(1))
    assert_true(
        "truncated" in _deserialize_error(overrun), "term count overruns region"
    )

    var h = UInt64(0x1122334455667788)
    var cut = _posting(1, 3, h, [0, 1], [1, 1])
    while len(cut) > 11:
        _ = cut.pop()
    assert_true("truncated" in _deserialize_error(cut), "cut inside a term hash")


def test_deserialize_rejects_non_ascending_ids_and_zero_tf() raises:
    var h = UInt64(0x1122334455667788)
    assert_true(
        "strictly ascending" in _deserialize_error(_posting(1, 3, h, [1, 0], [1, 1])),
        "a zero delta repeats a doc id",
    )
    assert_true(
        "tf below 1" in _deserialize_error(_posting(1, 3, h, [0, 1], [1, 0])),
        "a zero tf",
    )
    assert_true(
        "out of range" in _deserialize_error(_posting(1, 2, h, [0, 5], [1, 1])),
        "an id past num_docs",
    )


def test_deserialize_reads_a_well_formed_region() raises:
    var h = UInt64(0x1122334455667788)
    var idx = L0PostingIndex.deserialize(Span(_posting(1, 3, h, [0, 2], [4, 5])))
    assert_equal(idx.num_terms(), 1, "one term")
    assert_equal(idx.num_docs(), 3, "three docs")
    var ids = idx.doc_ids_for_hash(h)
    var tfs = idx.tfs_for_hash(h)
    assert_equal(len(ids), 2, "two postings")
    assert_equal(ids[0], 0, "first id")
    assert_equal(ids[1], 2, "second id")
    assert_equal(tfs[0], 4, "first tf")
    assert_equal(tfs[1], 5, "second tf")
    assert_equal(len(idx.doc_ids_for_hash(h + UInt64(1))), 0, "absent hash")
    assert_equal(len(idx.tfs_for_hash(h + UInt64(1))), 0, "absent hash tfs")


def test_term_hash_is_fnv1a_64() raises:
    assert_equal(fnv1a_64(String("").as_bytes()), UInt64(0xCBF29CE484222325))
    assert_equal(fnv1a_64(String("a").as_bytes()), UInt64(0xAF63DC4C8601EC8C))
    assert_equal(
        fnv1a_64(String("foobar").as_bytes()), UInt64(0x85944171F73967E8)
    )


def test_split_term_hash_matches_the_fixed_vector() raises:
    """The built split keys 'login' by the fixed FNV-1a hash, not merely by a
    hash both sides agree on."""
    var view = SplitView.parse(_l0_split_bytes(5))
    var idx = L0PostingIndex.deserialize(view.l0_posting_region())
    var ids = idx.doc_ids_for_hash(fnv1a_64(String("login").as_bytes()))
    assert_equal(len(ids), 5, "all five docs under the hash of 'login'")


# -----------------------------------------------------------------------------
# search_l0_split: corrupt input.
# -----------------------------------------------------------------------------


def _find(hay: List[UInt8], needle: Span[UInt8, _]) -> Int:
    var n = len(needle)
    for i in range(len(hay) - n + 1):
        var ok = True
        for j in range(n):
            if hay[i + j] != needle[j]:
                ok = False
                break
        if ok:
            return i
    return -1


def _search_error(var bytes: List[UInt8]) raises -> String:
    var view = SplitView.parse(bytes^)
    try:
        _ = search_l0_split(view, _query(String("login")))
    except e:
        return String(e)
    return String("")


def _with_region_byte(n_docs: Int, at: Int, value: Int) raises -> List[UInt8]:
    """A valid L0 split with one byte of its posting region replaced."""
    var bytes = _l0_split_bytes(n_docs)
    var region = List[UInt8]()
    var start = 0
    var view = SplitView.parse(bytes.copy())
    for b in view.l0_posting_region():
        region.append(b)
    start = _find(bytes, Span(region))
    assert_true(start >= 0, "the region is found inside the split")
    bytes[start + at] = UInt8(value)
    return bytes^


def test_search_rejects_an_unsupported_posting_version() raises:
    var err = _search_error(_with_region_byte(16, 0, 9))
    assert_true("unsupported version" in err, "got: " + err)


def test_search_rejects_a_posting_that_disagrees_with_the_split() raises:
    # region[2] is the single-byte num_docs; the split holds 16 docs.
    var err = _search_error(_with_region_byte(16, 2, 17))
    assert_true("disagree" in err, "got: " + err)


def test_search_rejects_a_split_without_an_l0_region() raises:
    var views = _login_views(8)
    var uuid = InlineArray[UInt8, 16](fill=UInt8(9))
    var sink = SearchSink(
        String("bucket"),
        String("prefix"),
        String(_INDEX),
        LOG_INDEX_TEXT_FIELD,
        uuid,
        String("_source"),
    )
    sink.init_sink(log_index_schema())
    sink.accept_batch(log_views_to_record_batch(views))
    sink.finish()
    var err = _search_error(sink.take_split_bytes())
    assert_true("empty region" in err, "got: " + err)


# -----------------------------------------------------------------------------
# Idle hook: the flush error path and restart safety.
# -----------------------------------------------------------------------------


def _make_engine(num_workers: Int) raises -> OwnedPointer[SharedEngine]:
    var eng = OwnedPointer[SharedEngine](
        value=SharedEngine(num_workers=num_workers, filter=EnvFilter())
    )
    eng[].register_site["login {} status {}", "komira_auth"]()
    LogManager._test_install_borrow(eng[])
    return eng^


def _emit_logins(mut eng: SharedEngine, n: Int):
    ref r = eng.ring(0)
    for i in range(n):
        _ = emit_record["login {} status {}", "komira_auth"](
            r, LEVEL_INFO, UInt64(1000 + i), ArgStr(String("login")), ArgI64(200)
        )


def _matches_across_splits(store: RecordingStore, term: String) raises -> Int:
    var live = list_live_splits_across_shards(
        store, String(_META_ROOT), String(_INDEX)
    )
    var total = 0
    for i in range(len(live)):
        var view = SplitView.parse(store.get(Path.parse(live[i].object_key)))
        total += search_l0_split(view, _query(term)).total_matches
    return total


def test_failed_final_flush_raises_and_leaves_the_home_intact() raises:
    var eng = _make_engine(1)
    var store = RecordingStore()
    store._st[].fail_put = True
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var hook = install_native_index_idle_hook(
        rt,
        IdleIndexContext[RecordingStore, origin_of(eng[])](
            store.clone(),
            String("nodeF"),
            String(_META_ROOT),
            String(_INDEX),
            eng[],
            RetryPolicy.fast_test(),
        ),
    )
    _emit_logins(eng[], 5)
    rt.shutdown()
    var raised = False
    try:
        _ = flush_all_pending_via_hook[RecordingStore, origin_of(eng[])](hook, 1)
    except e:
        raised = True
        assert_true("injected put failure" in String(e), "the store error surfaces")
    assert_true(raised, "a failing store makes the final flush raise")
    # The home must still be live: dropping it frees it exactly once.
    drop_installed_hook[RecordingStore, origin_of(eng[])](hook)
    LogManager._test_reset()


def _install_flush_drop(
    mut eng: OwnedPointer[SharedEngine], store: RecordingStore, n: Int
) raises:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_worker(NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK)
    var hook = install_native_index_idle_hook(
        rt,
        IdleIndexContext[RecordingStore, origin_of(eng[])](
            store.clone(),
            String("nodeR"),
            String(_META_ROOT),
            String(_INDEX),
            eng[],
            RetryPolicy.fast_test(),
        ),
    )
    _emit_logins(eng[], n)
    rt.shutdown()
    _ = flush_all_pending_via_hook[RecordingStore, origin_of(eng[])](hook, 1)
    drop_installed_hook[RecordingStore, origin_of(eng[])](hook)


def test_a_restart_over_the_same_store_keeps_earlier_splits() raises:
    var eng = _make_engine(1)
    var store = RecordingStore()
    _install_flush_drop(eng, store, 3)
    _install_flush_drop(eng, store, 4)
    assert_equal(_live(store), 2, "both installs published a split")
    assert_equal(
        _matches_across_splits(store, String("login")),
        7,
        "the second install did not overwrite the first install's object",
    )
    LogManager._test_reset()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
