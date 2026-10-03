# =============================================================================
# test_search_catalog_lifecycle.mojo
#   The retire / reap end of a split's life: what a reader may rely on while
#   the catalog deletes things.
# =============================================================================
#
#   1. test_store_error_naming_404_is_not_absence: a store error whose message
#      contains "404" only because the object key does (here the index name)
#      is a real failure. Replay must raise it, not skip the chunk as if it had
#      been reaped. A genuine not-found is still skipped.
#
# Everything runs against the in-memory stores, with no network. `_HookStore`
# wraps the shared in-memory store to stage the two interleavings a single
# thread cannot otherwise reach: a store error on one key, and a publish that
# lands at an exact point inside the reaper.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from komira_objectstore import (
    CasManifestStore,
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    RetryPolicy,
    SharedInMemoryConditionalStore,
    WritePrecondition,
    chunk_key,
    encode_chunk,
    decode_chunk_body,
)
from komira_objectstore.path import Path
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)

from komira_search_catalog.split_summary import (
    SplitSummary,
    decode_split_summary,
    encode_split_summary,
    make_merged_split_summary,
    make_split_summary,
)
from komira_search_catalog.metastore import (
    SearchMetastore,
    generation_across_shards,
    list_live_splits_across_shards,
    make_shard_id,
    reap_drained_shards,
    shard_manifest_prefix,
)


comptime _META: String = "index/logs/meta"
comptime _GRACE_MS = Int64(1000)


def _uuid(seed: Int) -> Array[UInt8, 16]:
    var u = Array[UInt8, 16](fill=UInt8(0))
    for i in range(16):
        u[i] = UInt8((seed * 7 + i * 13) & 0xFF)
    return u^


def _uuid_eq(a: Array[UInt8, 16], b: Array[UInt8, 16]) -> Bool:
    for i in range(16):
        if a[i] != b[i]:
            return False
    return True


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


def _lineage_meta[
    S: CloneableConditionalWriteStore
](store: S, lineage_prefix: String) raises -> SearchMetastore[S]:
    var manifest = CasManifestStore[S](
        store.clone(), lineage_prefix.copy(), RetryPolicy.fast_test()
    )
    return SearchMetastore[S](manifest^, String("logs"))


def _shard_meta[
    S: CloneableConditionalWriteStore
](store: S, shard_id: String) raises -> SearchMetastore[S]:
    return _lineage_meta(store, shard_manifest_prefix(_META, shard_id))


def _count_under(store: SharedInMemoryConditionalStore, prefix: String) raises -> Int:
    return len(store.list_with_delimiter(Path.parse(prefix + "/")).objects)


# -----------------------------------------------------------------------------
# _HookStore: the shared in-memory store plus two staged interleavings.
#
#   * LIST of exactly `list_trigger` first creates `inject_path` with
#     `inject_bytes` (If-None-Match, so it fires at most once), then lists.
#     The reaper's drained check LISTs `<shard>/tombstones/` as its last step,
#     so a trigger there lands a write after the check has looked at the
#     manifest.
#   * GET / ranged GET of exactly `fail_get_path` raises `fail_msg`.
#
# Every field is plain owned data; `clone()` copies them and shares the inner
# map, so the manifest handles the catalog builds over clones see the hooks.
# -----------------------------------------------------------------------------


struct _HookStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var _inner: SharedInMemoryConditionalStore
    var _list_trigger: String
    var _inject_path: String
    var _inject_bytes: List[UInt8]
    var _fail_get_path: String
    var _fail_msg: String

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var list_trigger: String,
        var inject_path: String,
        var inject_bytes: List[UInt8],
        var fail_get_path: String,
        var fail_msg: String,
    ):
        self._inner = inner^
        self._list_trigger = list_trigger^
        self._inject_path = inject_path^
        self._inject_bytes = inject_bytes^
        self._fail_get_path = fail_get_path^
        self._fail_msg = fail_msg^

    def clone(self) -> Self:
        return Self(
            self._inner.clone(),
            self._list_trigger.copy(),
            self._inject_path.copy(),
            self._inject_bytes.copy(),
            self._fail_get_path.copy(),
            self._fail_msg.copy(),
        )

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        if (
            self._list_trigger.byte_length() > 0
            and prefix.raw() == self._list_trigger
        ):
            try:
                _ = self._inner.conditional_put(
                    Path.parse(self._inject_path),
                    self._inject_bytes,
                    WritePrecondition.if_none_match_star(),
                )
            except e:
                if String(e).find("precondition") < 0:
                    raise e^
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
        if path.raw() == self._fail_get_path:
            raise Error(self._fail_msg)
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if path.raw() == self._fail_get_path:
            raise Error(self._fail_msg)
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


def _plain_hooks(inner: SharedInMemoryConditionalStore) -> _HookStore:
    return _HookStore(
        inner.clone(),
        String(""),
        String(""),
        List[UInt8](),
        String(""),
        String(""),
    )


# =============================================================================
# 1. A store error that names "404" is not absence.
# =============================================================================


def test_store_error_naming_404_is_not_absence() raises:
    # The index is called "run404", so every key of this lineage contains
    # "404". A permission failure on chunk 1 carries that key in its message,
    # exactly as the cloud conformers format it.
    var lineage = String("index/run404/meta")
    var inner = SharedInMemoryConditionalStore()
    var failing_key = chunk_key(lineage, Int64(1)).raw()
    var hooks = _HookStore(
        inner.clone(),
        String(""),
        String(""),
        List[UInt8](),
        failing_key.copy(),
        String("StoreError[PERMISSION_DENIED] GET mem://bucket/")
        + failing_key
        + " status=403 AccessDenied",
    )
    var meta = _lineage_meta(hooks, lineage)
    for i in range(3):
        _ = meta.publish(_summary(i, Int64(2)))

    # The writer's warm handle knows the head, so replay reads chunk 1 and
    # meets the error. Skipping it would return two splits and hide the third
    # from every query; the error must reach the caller instead.
    with assert_raises(contains="PERMISSION_DENIED"):
        _ = meta.list_live_splits()

    # A genuine not-found (the chunk was reaped after the head was read) is
    # still skipped.
    var ok = _lineage_meta(_plain_hooks(inner), lineage)
    for i in range(3):
        _ = ok.publish(_summary(10 + i, Int64(2)))
    inner.delete(chunk_key(lineage, Int64(4)))
    var live = ok.list_live_splits()
    assert_equal(len(live), 5, "a reaped chunk is skipped, the rest listed")

    _ = inner^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
