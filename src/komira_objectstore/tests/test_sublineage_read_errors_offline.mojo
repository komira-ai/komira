# =============================================================================
# tests/test_sublineage_read_errors_offline.mojo
#   A store error reading a shard's head or `_LOG_START` is raised, never read
#   as an absent shard (komira-ai/komira#1104).
# =============================================================================
#
# `read_head_authoritative` reports an absent or fully reaped manifest as a
# head (`chunk_seq == -1`, or just below `_LOG_START`) and `read_log_start`
# reports an absent `_LOG_START` as zero, so neither raises for a shard that
# has nothing live: an error from either is a real store failure or a torn
# lineage. Each reader below must raise it rather than drop the shard:
#   * `ShardedLineage.snapshot` and `SubLineageBaseFold.snapshot` (a snapshot
#     that omits a live shard plans a fold without that shard's tail);
#   * `SubLineageBaseFold.bound_stats` (the shard counted as no live tail);
#   * `SubLineageBaseFold.fold`, through `_retire_folded_source` (the block
#     materialized, the source never retired, no error);
#   * `SubLineageBaseFold.reload_from_base` (the shard's folded watermark left
#     at what `_base` alone records, so the next fold can fold records again).
#
# The store fails ONE LIST of shard `w`'s manifest (the authoritative head)
# or one GET of its `_LOG_START`, with a 503-shaped message, so a later read
# of the same object cannot mask an arm that swallowed it. The last test pins
# the other half of the contract: with no fault the shard is there, and a
# partition with no shards reads as empty.
#
# Each test runs on its own; main reports every failure, then fails.
# =============================================================================

from std.testing import assert_equal, assert_raises

from komira_objectstore.cas_manifest import log_start_key
from komira_objectstore.path import Path
from komira_objectstore.sharded_lineage import ShardedLineage
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.sublineage_base_fold import (
    SubLineageBaseFold,
    sublineage_prefix,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

# =============================================================================
# _FaultStore: a shared in-memory store that fails one verb on demand.
# =============================================================================
#
# A rule per verb (get, list) lives in the shared map under `__fault__/<verb>/`:
# the path substring it matches, how many matching calls to let through first
# (skip), how many to fail after that (count) and the error message. Clones
# share the map, so a test arms a rule through any handle.

comptime _FK = "__fault__/"
comptime _PART = "t/0"
comptime _ERR = "StoreError[TRANSPORT] status=503 injected"


def _bytes_to_string(raw: List[UInt8]) -> String:
    var s = String("")
    for i in range(len(raw)):
        s += chr(Int(raw[i]))
    return s^


struct _FaultStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var inner: SharedInMemoryConditionalStore

    def __init__(out self):
        self.inner = SharedInMemoryConditionalStore()

    def __init__(out self, var inner: SharedInMemoryConditionalStore):
        self.inner = inner^

    def clone(self) -> Self:
        return Self(self.inner.clone())

    def _set(self, k: String, v: String) raises:
        var b = List[UInt8]()
        for x in v.as_bytes():
            b.append(x)
        _ = self.inner.put(Path.parse(_FK + k), b)

    def _get(self, k: String) -> Optional[String]:
        try:
            return Optional[String](
                _bytes_to_string(self.inner.get(Path.parse(_FK + k)))
            )
        except e:
            _ = e
            return Optional[String](None)

    def arm(self, verb: String, sub: String, skip: Int) raises:
        """Fail the first matching `verb` call after `skip` of them, once."""
        self._set(verb + "/sub", sub)
        self._set(verb + "/skip", String(skip))
        self._set(verb + "/count", String(1))

    def _check(self, verb: String, path: Path) raises:
        var cnt = self._get(verb + "/count")
        if not cnt or Int(cnt.value()) == 0:
            return
        var raw = path.raw()
        if raw.startswith(_FK) or raw.find(self._get(verb + "/sub").value()) < 0:
            return
        var skip = Int(self._get(verb + "/skip").value())
        if skip > 0:
            self._set(verb + "/skip", String(skip - 1))
            return
        self._set(verb + "/count", String(0))
        raise Error(_ERR)

    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        self._check("list", prefix)
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        self._check("get", path)
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)


comptime _Fold = SubLineageBaseFold[_FaultStore]


def _w_list() -> String:
    """The LIST prefix of shard `w`'s manifest (its authoritative head)."""
    return sublineage_prefix(_PART, "w") + "/manifest/"


def _one(v: Int64) -> List[Int64]:
    var l = List[Int64]()
    l.append(v)
    return l^


def _fold_with_shard_w(fs: _FaultStore) raises -> _Fold:
    """Shard `w` holds one record, not folded yet."""
    var f = _Fold(fs.clone(), _PART)
    _ = f.append_batch(String("w"), _one(Int64(7)))
    return f^


def test_sharded_lineage_snapshot_head_error_raises() raises:
    var fs = _FaultStore()
    _ = _fold_with_shard_w(fs)
    var k = ShardedLineage[_FaultStore](fs.clone(), _PART)
    assert_equal(len(k.snapshot()), 1)
    fs.arm("list", _w_list(), 0)
    with assert_raises(contains=_ERR):
        _ = k.snapshot()


def test_fold_snapshot_head_error_raises() raises:
    var fs = _FaultStore()
    var f = _fold_with_shard_w(fs)
    assert_equal(len(f.snapshot()), 1)
    fs.arm("list", _w_list(), 0)
    with assert_raises(contains=_ERR):
        _ = f.snapshot()


def test_bound_stats_head_error_raises() raises:
    var fs = _FaultStore()
    var f = _fold_with_shard_w(fs)
    assert_equal(f.bound_stats().live_tail_shards, 1)
    fs.arm("list", _w_list(), 0)
    with assert_raises(contains=_ERR):
        _ = f.bound_stats()


def test_retire_head_error_raises() raises:
    # In `fold`, shard `w`'s manifest is LISTed twice: once by the source
    # read (`_read_source_range`), then by `_retire_folded_source`. Skip the
    # first, so the read that fails is the retire's.
    var fs = _FaultStore()
    var f = _fold_with_shard_w(fs)
    var snap = f.snapshot()
    fs.arm("list", _w_list(), 1)
    with assert_raises(contains=_ERR):
        _ = f.fold(snap^)


def test_reload_log_start_error_raises() raises:
    var fs = _FaultStore()
    var f = _fold_with_shard_w(fs)
    assert_equal(f.run_once().records_folded, Int64(1))
    f.reload_from_base()
    fs.arm("get", log_start_key(sublineage_prefix(_PART, "w")).raw(), 0)
    with assert_raises(contains=_ERR):
        f.reload_from_base()


def test_no_fault_reads_the_shard_and_empty_reads_empty() raises:
    var fs = _FaultStore()
    var empty = _Fold(fs.clone(), _PART)
    assert_equal(len(empty.snapshot()), 0)
    assert_equal(empty.bound_stats().live_tail_shards, 0)
    empty.reload_from_base()
    assert_equal(len(ShardedLineage[_FaultStore](fs.clone(), _PART).snapshot()), 0)
    var f = _fold_with_shard_w(fs)
    var snap = f.snapshot()
    assert_equal(len(snap), 1)
    assert_equal(snap[0].snap_record_total, Int64(1))
    assert_equal(f.fold(snap^).records_folded, Int64(1))
    f.reload_from_base()
    assert_equal(f.bound_stats().live_tail_shards, 0)


def main() raises:
    var failed = 0
    try:
        test_sharded_lineage_snapshot_head_error_raises()
    except e:
        failed += 1
        print("[FAIL] test_sharded_lineage_snapshot_head_error_raises: " + String(e))
    try:
        test_fold_snapshot_head_error_raises()
    except e:
        failed += 1
        print("[FAIL] test_fold_snapshot_head_error_raises: " + String(e))
    try:
        test_bound_stats_head_error_raises()
    except e:
        failed += 1
        print("[FAIL] test_bound_stats_head_error_raises: " + String(e))
    try:
        test_retire_head_error_raises()
    except e:
        failed += 1
        print("[FAIL] test_retire_head_error_raises: " + String(e))
    try:
        test_no_fault_reads_the_shard_and_empty_reads_empty()
    except e:
        failed += 1
        print(
            "[FAIL] test_no_fault_reads_the_shard_and_empty_reads_empty: "
            + String(e)
        )
    # Last: if a failed `_LOG_START` read ever released the process-wide CAS
    # gate twice again (komira-ai/komira#1087), later gated writes in this
    # process would block; running this leg last lets the others report first.
    try:
        test_reload_log_start_error_raises()
    except e:
        failed += 1
        print("[FAIL] test_reload_log_start_error_raises: " + String(e))
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("ALL sub-lineage read-error tests PASSED")
