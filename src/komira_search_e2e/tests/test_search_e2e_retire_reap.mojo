# =============================================================================
# test_search_e2e_retire_reap.mojo
#   The end of a split's life on the local filesystem: retire, wait out the
#   grace period, reap, and read the lineage back cold.
# =============================================================================
#
# The three corpus splits are published into a `LocalFsConditionalStore`
# rooted in TEST_TMPDIR. Every "cold" read is a new store object over that
# directory and a fresh metastore handle.
#
#   1. test_retire_then_reap_after_the_grace_period: a query is RESOLVED
#      for execution through the catalog (it holds the catalog's generation,
#      which is the metastore's, and the split set recorded for it), then
#      compaction retires split 0's chunk at t=1000. A cold reader stops
#      listing it at once, and the metastore generation and the catalog's
#      (still equal) move up (the live set changed). A reap at
#      t=1000+grace-1 is refused: the chunk and the split object stay, and
#      the in-flight query, drained only now, returns exactly the pre-retire
#      rows over all three splits. At t=1000+grace the reap goes through and
#      the caller deletes the split object. A cold reader then accepts the
#      lineage: the metastore generation and the catalog's generation did
#      not go down, splits 1 and 2 are listed, split 0's object is gone, and
#      a new scan equals the baseline over splits 1 and 2. Chunk 0 is gone
#      too: it is the log start, which `reap_chunk` advances over and
#      deletes (a chunk above the log start would stay as a stub; see 2).
#      Defects caught: a reap that runs before the grace period has passed
#      (it deletes a split a running query still reads), a retire that leaves
#      the split live, a retire that does not move the metastore generation, a catalog that serves a running query a different
#      split set than it planned, a reap that leaves the split object behind,
#      a reap that leaves the lineage unreadable cold.
#   2. test_reap_a_middle_split_and_never_a_live_one: split 1 (a chunk above
#      the log start) is retired and reaped after the grace period: it leaves
#      the live list, its object is deleted, splits 0 and 2 stay and the scan
#      equals their baseline. The chunk file itself is not required to go
#      (`reap_chunk` rewrites it to a stub). Then the caller's reap helper is
#      run on live chunk 2, which was never retired: it must answer True and
#      delete nothing. Defect caught: a reap helper that reads the key of any
#      chunk holding a summary and deletes a LIVE split's object.
#   3. test_reap_every_split: the three splits are published each through a
#      fresh writer handle (so the durable `_HEAD` is current: `reap_chunk`
#      never advances the log start past the durable head's next slot, and a
#      warm writer defers that head), then all three chunks are retired and
#      reaped. A cold handle over a new store object lists no split, its
#      generation has not gone down, chunks 0..2 are gone (the log start
#      passed all of them), every split object is gone, and the scan returns
#      no row.
#      Defect caught: a reaped-out lineage that a cold reader cannot read, or
#      reads as a lower generation. NOT caught here: the generation floor
#      `reap_chunk` writes (`raise_generation_floor`). A cold reader of this
#      lineage recovers the head from the log start (`start_seq - 1`), so it
#      reports the same generation with or without the floor; the planted
#      mutant that drops the floor raise stays green on this file.
#      komira_search_catalog's lifecycle tests own the floor.
#   4. test_a_store_error_naming_404_is_not_absence: the index is named
#      `run404`, so every key in its lineage contains "404". A store that
#      refuses the read of chunk 1 with a permission error naming that key
#      (the shape a cloud store's error has) must make the writer's own read
#      of the live set (its head is known, so replay reads chunk 1), a cold
#      read, and the scan over a cold catalog fail with that error, never
#      answer with chunk 1's split silently missing. The same lineage read
#      through the plain store lists all three splits. Defect caught: a
#      not-found check that matches the digits "404" anywhere in the message.
#      Scope: the error is SYNTHETIC (a wrapper raises it), so this covers
#      the manifest's classifier, not `LocalFsConditionalStore`'s own error
#      mapping, which reports every failed open of a file as not found
#      whatever the cause.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)

from komira_objectstore import (
    CoalescePolicy,
    ListResult,
    LocalFsConditionalStore,
    ObjectMeta,
    RetryPolicy,
    WritePrecondition,
    chunk_key,
)
from komira_objectstore.cas_manifest import is_not_found
from komira_objectstore.path import Path
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)

from komira_scan_source.scan_binding import ScanBinding

from komira_search_scan.search_scan_kind import SearchScanResolver

from komira_runtime_paths import test_tmpdir

from komira_search_e2e.corpus import (
    INDEX_NAME,
    NUM_SPLITS,
    corpus_split,
    split_doc_count,
    split_uuid,
    uuid_eq,
)
from komira_search_e2e.catalog import (
    MetastoreSearchCatalog,
    cold_metastore,
    lineage_prefix,
    open_metastore,
    publish_split,
    reap_retired_split,
    split_object_key,
)
from komira_search_e2e.rows import (
    baseline_rows,
    drain_rows,
    resolve_scan,
    scan_rows,
)


comptime _GRACE_MS = Int64(60_000)
comptime _RETIRED_AT_MS = Int64(1_000)


def _absent(store: LocalFsConditionalStore, key: Path) raises -> Bool:
    """True iff `store` proves `key` has no object."""
    try:
        _ = store.get(key)
    except e:
        if is_not_found(String(e)):
            return True
        raise e^
    return False


def _publish_corpus(root: String, index: String) raises -> List[List[UInt8]]:
    var store = LocalFsConditionalStore(root)
    var writer = open_metastore(store, index, RetryPolicy.fast_test())
    var splits = List[List[UInt8]]()
    for s in range(NUM_SPLITS):
        splits.append(corpus_split(s))
        _ = publish_split(writer, store, index, s, splits[s], split_doc_count(s))
    return splits^


comptime _Catalog = MetastoreSearchCatalog[LocalFsConditionalStore]


def _resolver(
    root: String, index: String
) raises -> SearchScanResolver[_Catalog]:
    """A scan resolver over a cold catalog on a new store object."""
    return SearchScanResolver[_Catalog](
        _Catalog(LocalFsConditionalStore(root), index.copy())
    )


def _queries() -> List[String]:
    return [
        String("alpha"),
        String("alpha delta"),
        String("café"),
        String("Zürich"),
        String("東京"),
        String("nowhere"),
        String(""),
    ]


def _assert_rows(got: List[String], want: List[String], label: String) raises:
    assert_equal(len(got), len(want), label + ": row count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], label + ": row " + String(i))


def _assert_scan_equals(
    root: String, index: String, splits: List[List[UInt8]], what: String
) raises:
    """The scan over a cold catalog equals the baseline over `splits`, for
    every query the corpus table covers."""
    var rt = _resolver(root, index)
    var queries = _queries()
    for q in range(len(queries)):
        _assert_rows(
            scan_rows(rt, index, queries[q]).rows,
            baseline_rows(splits, queries[q]),
            what + String(" query '") + queries[q] + String("'"),
        )


def _catalog_generation(root: String, index: String) raises -> Int64:
    return _Catalog(LocalFsConditionalStore(root), index.copy()).generation(
        index
    )


def _two(splits: List[List[UInt8]], a: Int, b: Int) -> List[List[UInt8]]:
    var out = List[List[UInt8]]()
    out.append(splits[a].copy())
    out.append(splits[b].copy())
    return out^


def test_retire_then_reap_after_the_grace_period() raises:
    var root = test_tmpdir() + String("/retire_reap")
    var index = String(INDEX_NAME)
    var splits = _publish_corpus(root, index)
    _assert_scan_equals(root, index, splits, String("before retire"))

    var g_before = cold_metastore(LocalFsConditionalStore(root), index).generation()
    assert_equal(g_before, Int64(3), "three publishes")
    var c_before = _catalog_generation(root, index)
    assert_equal(c_before, g_before, "the catalog reports the metastore's")

    # In-flight queries resolved before the retire: each holds the catalog
    # generation and will plan and read its splits only later.
    var rt = _resolver(root, index)
    var queries = _queries()
    var in_flight = List[ScanBinding]()
    for q in range(len(queries)):
        in_flight.append(resolve_scan(rt, index, queries[q]))

    # Compaction retires split 0's chunk (slot 0).
    var compactor_store = LocalFsConditionalStore(root)
    var compactor = open_metastore(compactor_store, index, RetryPolicy.fast_test())
    compactor.retire_at(Int64(0), _RETIRED_AT_MS)

    var cold = cold_metastore(LocalFsConditionalStore(root), index)
    var live = cold.list_live_splits()
    assert_equal(len(live), 2, "the retired split leaves the live set at once")
    assert_true(uuid_eq(live[0].split_uuid, split_uuid(1)), "split 1 live")
    assert_true(uuid_eq(live[1].split_uuid, split_uuid(2)), "split 2 live")
    var g_retired = cold.generation()
    assert_true(
        g_retired > g_before,
        "the metastore generation did not move on the retire ("
        + String(g_before)
        + " -> "
        + String(g_retired)
        + ")",
    )
    var c_retired = _catalog_generation(root, index)
    assert_equal(c_retired, g_retired, "the catalog reports the metastore's")
    assert_true(
        c_retired > c_before,
        "the catalog generation did not move when the live set shrank ("
        + String(c_before)
        + " -> "
        + String(c_retired)
        + ")",
    )

    # Inside the grace period the reap must not run.
    var early = reap_retired_split(
        compactor,
        compactor_store,
        Int64(0),
        _RETIRED_AT_MS + _GRACE_MS - Int64(1),
        _GRACE_MS,
    )
    var reader_store = LocalFsConditionalStore(root)
    assert_false(
        _absent(reader_store, Path.parse(split_object_key(index, 0))),
        "split 0's object was deleted inside the grace period, under an"
        + " in-flight reader",
    )
    assert_false(early, "the reap ran before the grace period passed")
    assert_false(
        _absent(reader_store, chunk_key(lineage_prefix(index), Int64(0))),
        "chunk 0 was deleted inside the grace period",
    )

    # The in-flight queries, drained now, read what they planned: all three
    # splits, as before the retire.
    for q in range(len(queries)):
        var got = drain_rows(rt, in_flight[q])
        assert_equal(got.generation, c_before, "in-flight generation")
        _assert_rows(
            got.rows,
            baseline_rows(splits, queries[q]),
            String("in-flight query '") + queries[q] + String("'"),
        )

    # Once the grace period has passed, the reap goes through.
    assert_true(
        reap_retired_split(
            compactor,
            compactor_store,
            Int64(0),
            _RETIRED_AT_MS + _GRACE_MS,
            _GRACE_MS,
        ),
        "the reap after the grace period",
    )

    # A cold reader accepts the lineage.
    var after_store = LocalFsConditionalStore(root)
    var after = cold_metastore(after_store, index)
    var g_after = after.generation()
    assert_true(
        g_after >= g_retired,
        "the reap lowered the generation from "
        + String(g_retired)
        + " to "
        + String(g_after),
    )
    assert_true(
        _catalog_generation(root, index) >= c_retired,
        "the reap lowered the catalog generation",
    )
    var after_live = after.list_live_splits()
    assert_equal(len(after_live), 2, "splits 1 and 2 stay live")
    assert_true(uuid_eq(after_live[0].split_uuid, split_uuid(1)), "split 1")
    assert_true(uuid_eq(after_live[1].split_uuid, split_uuid(2)), "split 2")
    assert_true(
        _absent(after_store, chunk_key(lineage_prefix(index), Int64(0))),
        "chunk 0 (the log start) is still on disk after the reap",
    )
    assert_true(
        _absent(after_store, Path.parse(split_object_key(index, 0))),
        "split 0's object is still on disk after the reap",
    )
    assert_false(
        _absent(after_store, Path.parse(split_object_key(index, 1))),
        "split 1's object was deleted",
    )
    _assert_scan_equals(root, index, _two(splits, 1, 2), String("after reap"))


def test_reap_a_middle_split_and_never_a_live_one() raises:
    var root = test_tmpdir() + String("/reap_middle")
    var index = String(INDEX_NAME)
    var splits = _publish_corpus(root, index)
    var store = LocalFsConditionalStore(root)
    var compactor = open_metastore(store, index, RetryPolicy.fast_test())
    var g_before = cold_metastore(LocalFsConditionalStore(root), index).generation()

    compactor.retire_at(Int64(1), _RETIRED_AT_MS)
    assert_true(
        reap_retired_split(
            compactor, store, Int64(1), _RETIRED_AT_MS + _GRACE_MS, _GRACE_MS
        ),
        "the reap of split 1 after the grace period",
    )
    var cold_store = LocalFsConditionalStore(root)
    var cold = cold_metastore(cold_store, index)
    var live = cold.list_live_splits()
    assert_equal(len(live), 2, "splits 0 and 2 stay live")
    assert_true(uuid_eq(live[0].split_uuid, split_uuid(0)), "split 0")
    assert_true(uuid_eq(live[1].split_uuid, split_uuid(2)), "split 2")
    assert_true(cold.generation() >= g_before, "the reap lowered the generation")
    assert_true(
        _absent(cold_store, Path.parse(split_object_key(index, 1))),
        "split 1's object is still on disk after the reap",
    )
    _assert_scan_equals(root, index, _two(splits, 0, 2), String("after reap 1"))

    # The helper on a chunk that was never retired: True, nothing deleted.
    assert_true(
        reap_retired_split(
            compactor, store, Int64(2), _RETIRED_AT_MS + _GRACE_MS, _GRACE_MS
        ),
        "a reap of a never-retired chunk",
    )
    assert_false(
        _absent(cold_store, Path.parse(split_object_key(index, 2))),
        "the reap helper deleted live split 2's object",
    )
    var still = cold_metastore(LocalFsConditionalStore(root), index)
    assert_equal(len(still.list_live_splits()), 2, "split 2 is still listed")
    _assert_scan_equals(
        root, index, _two(splits, 0, 2), String("after the live-chunk reap")
    )


def test_reap_every_split() raises:
    var root = test_tmpdir() + String("/reap_every")
    var index = String(INDEX_NAME)
    # Each split through a FRESH writer handle: a warm handle defers the
    # durable `_HEAD` advance, and `reap_chunk` never moves the log start
    # past the durable head's next slot, so the chunks above it would stay
    # on disk as stubs. A cold append writes the durable head.
    for s in range(NUM_SPLITS):
        var w_store = LocalFsConditionalStore(root)
        var w = open_metastore(w_store, index, RetryPolicy.fast_test())
        _ = publish_split(w, w_store, index, s, corpus_split(s), split_doc_count(s))
    var g_before = cold_metastore(LocalFsConditionalStore(root), index).generation()
    var c_before = _catalog_generation(root, index)
    var store = LocalFsConditionalStore(root)
    var compactor = open_metastore(store, index, RetryPolicy.fast_test())
    for s in range(NUM_SPLITS):
        compactor.retire_at(Int64(s), _RETIRED_AT_MS)
    for s in range(NUM_SPLITS):
        assert_true(
            reap_retired_split(
                compactor,
                store,
                Int64(s),
                _RETIRED_AT_MS + _GRACE_MS,
                _GRACE_MS,
            ),
            "the reap of split " + String(s),
        )

    var cold_store = LocalFsConditionalStore(root)
    var cold = cold_metastore(cold_store, index)
    assert_equal(len(cold.list_live_splits()), 0, "no split is live")
    var g_after = cold.generation()
    assert_true(
        g_after >= g_before,
        "reaping every chunk lowered the generation from "
        + String(g_before)
        + " to "
        + String(g_after),
    )
    assert_true(
        _catalog_generation(root, index) >= c_before,
        "reaping every chunk lowered the catalog generation",
    )
    for s in range(NUM_SPLITS):
        assert_true(
            _absent(cold_store, chunk_key(lineage_prefix(index), Int64(s))),
            "chunk " + String(s) + " is still on disk",
        )
        assert_true(
            _absent(cold_store, Path.parse(split_object_key(index, s))),
            "split " + String(s) + "'s object is still on disk",
        )
    var queries = _queries()
    var rt = _resolver(root, index)
    for q in range(len(queries)):
        assert_equal(
            len(scan_rows(rt, index, queries[q]).rows),
            0,
            String("query '") + queries[q] + String("' over no split"),
        )


# -----------------------------------------------------------------------------
# _DenyOneKey: a LocalFsConditionalStore that refuses reads of one key with a
# permission error naming the key, as a cloud store formats it. Everything
# else goes to the files. Plain owned data; `clone()` copies it.
# -----------------------------------------------------------------------------


struct _DenyOneKey(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var _inner: LocalFsConditionalStore
    var _deny: String

    def __init__(out self, var inner: LocalFsConditionalStore, var deny: String):
        self._inner = inner^
        self._deny = deny^

    def clone(self) -> Self:
        return Self(self._inner.clone(), self._deny.copy())

    def _refuse(self, path: Path) raises:
        if path.raw() == self._deny:
            raise Error(
                String("StoreError[PERMISSION_DENIED] GET file://e2e/")
                + self._deny
                + String(" status=403 AccessDenied")
            )

    def head(self, path: Path) raises -> ObjectMeta:
        self._refuse(path)
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        self._refuse(path)
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        self._refuse(path)
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


def test_a_store_error_naming_404_is_not_absence() raises:
    var root = test_tmpdir() + String("/run404")
    var index = String("run404")
    var denied = chunk_key(lineage_prefix(index), Int64(1)).raw()

    # The writer publishes through the refusing store (a publish into its
    # own next slot reads no chunk), so its handle knows the head: its replay
    # reads chunk 1 directly and meets the error. Skipping it would answer
    # with two splits and hide split 1 from every query.
    var deny_store = _DenyOneKey(LocalFsConditionalStore(root), denied.copy())
    var writer = open_metastore(deny_store, index, RetryPolicy.fast_test())
    for s in range(NUM_SPLITS):
        _ = publish_split(
            writer, deny_store, index, s, corpus_split(s), split_doc_count(s)
        )
    with assert_raises(contains="PERMISSION_DENIED"):
        _ = writer.list_live_splits()

    var plain = cold_metastore(LocalFsConditionalStore(root), index)
    assert_equal(len(plain.list_live_splits()), 3, "the plain store lists 3")

    var cold = cold_metastore(
        _DenyOneKey(LocalFsConditionalStore(root), denied.copy()), index
    )
    with assert_raises(contains="PERMISSION_DENIED"):
        _ = cold.list_live_splits()

    var rt = SearchScanResolver[MetastoreSearchCatalog[_DenyOneKey]](
        MetastoreSearchCatalog[_DenyOneKey](
            _DenyOneKey(LocalFsConditionalStore(root), denied.copy()),
            index.copy(),
        )
    )
    with assert_raises(contains="PERMISSION_DENIED"):
        _ = scan_rows(rt, index, String("alpha"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
