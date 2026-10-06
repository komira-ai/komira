# =============================================================================
# tests/test_search_reap_chunk_race_offline.mojo
#   Two reapers racing on one chunk — OFFLINE
# =============================================================================
#
# `SearchMetastore.reap_chunk` replaces a retired chunk's body with a reaped
# stub through `CasManifestStore.rewrite_chunk_body`, which overwrites with
# If-Match on the etag it read (so it never recreates a chunk the reaper
# deleted). Two reapers may run on the same chunk; the second one's write then
# loses its precondition. That is the documented, idempotent race: the second
# reaper must carry on, not raise.
#
#   (1) The other reaper's stub lands between this reaper's read and its
#       write: the 412 is "another reaper got there first", the reap returns
#       True, and the chunk ends up reaped (stub reclaimed, marker spent).
#   (2) The other reaper got further and already deleted the chunk: the
#       rewrite reports absence, which `reap_chunk` already tolerated.
#   (3) The PUT loses its If-Match while the chunk is still there, and the
#       chunk is gone by the time this reaper re-reads it: it carries on.
#   (4) Something other than a stub replaced the chunk: the 412 is a real
#       conflict and is raised.
# Catches: a `reap_chunk` that raises on any 412 (case 1 red), or swallows
# every 412 (case 3 red).
#
# The interleaving is staged by `_RaceStore`: a one-shot hook, kept as a
# marker object in the shared in-memory store so every clone sees it, runs
# just before the next PUT to the target key.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore import (
    CasManifestStore,
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    RetryPolicy,
    SharedInMemoryConditionalStore,
    WritePrecondition,
    chunk_key,
    decode_chunk_record_count,
    encode_chunk,
    tombstone_key,
)
from komira_objectstore.cas_manifest import is_precondition
from komira_objectstore.path import Path
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)

from komira_search_catalog.split_summary import SplitSummary, make_split_summary
from komira_search_catalog.metastore import (
    SearchMetastore,
    make_shard_id,
    shard_manifest_prefix,
)


comptime _Inner = SharedInMemoryConditionalStore
comptime _META: String = "index/logs/meta"
comptime _GRACE_MS = Int64(1000)

# One-shot hooks run just before the next PUT to the target key.
comptime _STUB_BEFORE_PUT = "__hook__/stub_before_put/"
comptime _DELETE_BEFORE_PUT = "__hook__/delete_before_put/"
comptime _TOUCH_BEFORE_PUT = "__hook__/touch_before_put/"
# A non-stub rewrite lands before the PUT (so the PUT loses its If-Match),
# and the chunk is deleted just before the NEXT GET of it: after the
# manifest's absence probe (a HEAD) saw it present, before the reaper re-read.
comptime _TOUCH_THEN_GONE = "__hook__/touch_then_gone/"
comptime _GONE_BEFORE_GET = "__hook__/gone_before_get/"


def _has(store: _Inner, key: String) -> Bool:
    try:
        _ = store.head(Path.parse(key))
        return True
    except:
        return False


def _arm(store: _Inner, rule: String, target: String) raises:
    _ = store.put(Path.parse(rule + target), List[UInt8]())


def _take(store: _Inner, rule: String, target: String) raises -> Bool:
    if _has(store, rule + target):
        store.delete(Path.parse(rule + target))
        return True
    return False


struct _RaceStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var _inner: _Inner

    def __init__(out self, var inner: _Inner):
        self._inner = inner^

    def clone(self) -> Self:
        return Self(self._inner.clone())

    def _before_put(self, path: Path) raises:
        var key = path.raw()
        if _take(self._inner, _STUB_BEFORE_PUT, key):
            # The other reaper's stub rewrite: same record count, stub body.
            var rc = decode_chunk_record_count(self._inner.get(path))
            var stub = List[UInt8]()
            stub.append(UInt8(0))
            _ = self._inner.put(path, encode_chunk(stub, rc))
        if _take(self._inner, _DELETE_BEFORE_PUT, key):
            self._inner.delete(path)
        if _take(self._inner, _TOUCH_BEFORE_PUT, key):
            # A non-stub rewrite: same bytes, new etag.
            _ = self._inner.put(path, self._inner.get(path))
        if _take(self._inner, _TOUCH_THEN_GONE, key):
            _ = self._inner.put(path, self._inner.get(path))
            _arm(self._inner, _GONE_BEFORE_GET, key)

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if _take(self._inner, _GONE_BEFORE_GET, path.raw()):
            self._inner.delete(path)
        return self._inner.get(path)

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._before_put(path)
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._before_put(path)
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._before_put(path)
        return self._inner.put(path, bytes)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


def _uuid(seed: Int) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=UInt8(0))
    for i in range(16):
        u[i] = UInt8((seed * 7 + i * 13) & 0xFF)
    return u^


def _summary(seed: Int, doc_count: Int64) -> SplitSummary:
    return make_split_summary(
        _uuid(seed),
        doc_count,
        Int64(seed * 16 + 8),
        Int64(seed * 1000),
        Int64(seed * 1000 + Int(doc_count) - 1),
        String("logs"),
        String("body"),
        String("index/logs/splits/s-" + String(seed) + ".split"),
    )


def _writer(inner: _Inner, lineage: String) raises -> SearchMetastore[_RaceStore]:
    var manifest = CasManifestStore[_RaceStore](
        _RaceStore(inner.clone()), lineage.copy(), RetryPolicy.fast_test()
    )
    return SearchMetastore[_RaceStore](manifest^, String("logs"))


def _lineage(n: Int) raises -> String:
    return shard_manifest_prefix(_META, make_shard_id(String("node"), n))


def test_second_reaper_loses_to_a_stub_and_carries_on() raises:
    print("[test_second_reaper_loses_to_a_stub_and_carries_on] starting...")
    var inner = _Inner()
    var lineage = _lineage(1)
    var w = _writer(inner, lineage)
    for i in range(3):
        _ = w.publish(_summary(i, Int64(2)))
    w.retire_at(Int64(0), Int64(0))
    _arm(inner, _STUB_BEFORE_PUT, chunk_key(lineage, Int64(0)).raw())
    assert_true(
        w.reap_chunk(Int64(0), _GRACE_MS, _GRACE_MS),
        "the losing reaper reports the chunk reaped",
    )
    assert_false(
        _has(inner, _STUB_BEFORE_PUT + chunk_key(lineage, Int64(0)).raw()),
        "the race was staged",
    )
    assert_false(
        _has(inner, tombstone_key(lineage, Int64(0)).raw()), "marker spent"
    )
    assert_false(
        _has(inner, chunk_key(lineage, Int64(0)).raw()),
        "the stub at the log start was reclaimed",
    )
    _ = w^
    print("[test_second_reaper_loses_to_a_stub_and_carries_on] PASS")


def test_second_reaper_finds_the_chunk_gone() raises:
    print("[test_second_reaper_finds_the_chunk_gone] starting...")
    var inner = _Inner()
    var lineage = _lineage(2)
    var w = _writer(inner, lineage)
    for i in range(3):
        _ = w.publish(_summary(i, Int64(2)))
    w.retire_at(Int64(0), Int64(0))
    _arm(inner, _DELETE_BEFORE_PUT, chunk_key(lineage, Int64(0)).raw())
    assert_true(
        w.reap_chunk(Int64(0), _GRACE_MS, _GRACE_MS), "a gone chunk is reaped"
    )
    assert_false(
        _has(inner, chunk_key(lineage, Int64(0)).raw()), "and stays gone"
    )
    assert_false(
        _has(inner, tombstone_key(lineage, Int64(0)).raw()), "marker spent"
    )
    _ = w^
    print("[test_second_reaper_finds_the_chunk_gone] PASS")


def test_second_reaper_loses_the_put_then_finds_the_chunk_gone() raises:
    """The PUT loses its If-Match while the chunk is still there (so the
    manifest reports a 412, not absence), and the other reaper deletes the
    chunk before this one re-reads it: the reap carries on."""
    print("[test_second_reaper_loses_the_put_then_finds_the_chunk_gone] starting...")
    var inner = _Inner()
    var lineage = _lineage(4)
    var w = _writer(inner, lineage)
    for i in range(3):
        _ = w.publish(_summary(i, Int64(2)))
    w.retire_at(Int64(0), Int64(0))
    var ck = chunk_key(lineage, Int64(0)).raw()
    _arm(inner, _TOUCH_THEN_GONE, ck)
    assert_true(
        w.reap_chunk(Int64(0), _GRACE_MS, _GRACE_MS),
        "a 412 over a chunk that is then gone is reaped",
    )
    assert_false(_has(inner, _TOUCH_THEN_GONE + ck), "the 412 was staged")
    assert_false(_has(inner, _GONE_BEFORE_GET + ck), "the delete was staged")
    assert_false(_has(inner, ck), "the chunk stays gone")
    assert_false(
        _has(inner, tombstone_key(lineage, Int64(0)).raw()), "marker spent"
    )
    _ = w^
    print("[test_second_reaper_loses_the_put_then_finds_the_chunk_gone] PASS")


def test_a_non_stub_rewrite_is_a_real_conflict() raises:
    print("[test_a_non_stub_rewrite_is_a_real_conflict] starting...")
    var inner = _Inner()
    var lineage = _lineage(3)
    var w = _writer(inner, lineage)
    for i in range(3):
        _ = w.publish(_summary(i, Int64(2)))
    w.retire_at(Int64(0), Int64(0))
    _arm(inner, _TOUCH_BEFORE_PUT, chunk_key(lineage, Int64(0)).raw())
    var raised = False
    try:
        _ = w.reap_chunk(Int64(0), _GRACE_MS, _GRACE_MS)
    except e:
        raised = True
        assert_true(is_precondition(String(e)), String(e))
    assert_true(raised, "a 412 over a non-stub chunk is raised")
    assert_true(
        _has(inner, chunk_key(lineage, Int64(0)).raw()), "the chunk is kept"
    )
    assert_true(
        _has(inner, tombstone_key(lineage, Int64(0)).raw()), "and its marker"
    )
    _ = w^
    print("[test_a_non_stub_rewrite_is_a_real_conflict] PASS")


def main() raises:
    test_second_reaper_loses_to_a_stub_and_carries_on()
    test_second_reaper_finds_the_chunk_gone()
    test_second_reaper_loses_the_put_then_finds_the_chunk_gone()
    test_a_non_stub_rewrite_is_a_real_conflict()
    print("[OK] test_search_reap_chunk_race_offline — 4 cases passed")
