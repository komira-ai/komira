# =============================================================================
# tests/test_broker_lineage_read_errors_offline.mojo
#   A store error reading a lineage's head or `_LOG_START` is raised, never
#   read as an empty lineage (komira-ai/komira#1074 and #505).
# =============================================================================
#
# `read_head_authoritative` reports an absent manifest as `chunk_seq == -1`
# and `read_log_start` reports an absent `_LOG_START` as zero, so an absent
# lineage never raises: an error from either read is a real store failure
# (or a torn lineage). Each reader below must raise it rather than answer
# "no `_base`", "dense high-water 0", "no keys", "folded prefix 0", "shard
# absent", "nothing to migrate" or "0 live chunks". The store fails ONE
# LIST of one manifest (the authoritative head) or one GET of a shard's
# `_LOG_START`, with a 503-shaped message: the first such read of the call,
# so a later read of the same object cannot mask an arm that swallowed it.
#
# Catches, for each reader: a `try`/`except` around the head or `_LOG_START`
# read that returns the empty answer. The last test pins the other half of
# the contract: a lineage that does not exist still reads as empty.
#
# Each test runs on its own; main reports every failure, then fails.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises

from komira_broker.consume_core import SegmentRef
from komira_broker.manifest_body import encode_manifest_body
from komira_broker.partition_assignment import sublineage_prefix
from komira_broker.sublineage_base_inputs import SegmentBaseInputs
from komira_broker.sublineage_consume import SubLineageConsumeResolver
from komira_broker.sublineage_migration import SubLineageMigration
from komira_broker.sublineage_segment_fold import SegmentBaseFold
from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    log_start_key,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import (
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
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
# A rule per verb (get, list, ...) lives in the shared map under
# `__fault__/<verb>/...`: the path substring it matches, how many matching
# calls to let through first (skip), how many to fail after that (count; -1
# fails every one) and the error message. Clones share the map, so a test
# arms a rule through any handle.

comptime _FK = "__fault__/"


def _bytes_to_string(raw: List[UInt8]) -> String:
    var s = String("")
    for i in range(len(raw)):
        s += chr(Int(raw[i]))
    return s^


struct _FaultStore(CloneableConditionalWriteStore, ConditionalWriteStore, ObjectStore, Movable, Deinitable):
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

    def arm(
        self, verb: String, sub: String, skip: Int, count: Int, msg: String
    ) raises:
        self._set(verb + "/sub", sub)
        self._set(verb + "/skip", String(skip))
        self._set(verb + "/msg", msg)
        self._set(verb + "/count", String(count))

    def disarm(self, verb: String) raises:
        self._set(verb + "/count", "0")

    def _check(self, verb: String, path: Path) raises:
        var cnt = self._get(verb + "/count")
        if not cnt:
            return
        var c = Int(cnt.value())
        if c == 0:
            return
        var raw = path.raw()
        if raw.startswith(_FK):
            return
        if raw.find(self._get(verb + "/sub").value()) < 0:
            return
        var skip = Int(self._get(verb + "/skip").value())
        if skip > 0:
            self._set(verb + "/skip", String(skip - 1))
            return
        if c > 0:
            self._set(verb + "/count", String(c - 1))
        var msg = self._get(verb + "/msg").value()
        raise Error(msg)

    def head(self, path: Path) raises -> ObjectMeta:
        self._check("head", path)
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        self._check("list", prefix)
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._check("cput", path)
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._check("cas", path)
        return self.inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._check("put", path)
        return self.inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        self._check("range", path)
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        self._check("get", path)
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._check("delete", path)
        self.inner.delete(path)


# =============================================================================
# =============================================================================
# Fixtures
# =============================================================================

comptime _PART = "c/_meta/topics/t/0"
comptime _ERR = "503 SlowDown injected"


def _m(fs: _FaultStore, prefix: String) -> CasManifestStore[_FaultStore]:
    return CasManifestStore[_FaultStore](
        store=fs.clone(), prefix=prefix, retry=RetryPolicy.fast_test()
    )


def _shard() -> String:
    return sublineage_prefix(_PART, "w0")


def _base() -> String:
    return sublineage_prefix(_PART, "_base")


def _list_of(prefix: String) -> String:
    """The LIST prefix of `prefix`'s manifest (the authoritative head)."""
    return prefix + "/manifest/"


def _data(mut m: CasManifestStore[_FaultStore], key: String, n: Int64) raises:
    _ = m.append(encode_manifest_body(key, n, UInt32(7), Int64(100), Int64(1)), n)


def _w0_k1_k2_folded_k3_live(fs: _FaultStore) raises:
    """Shard w0: k1, k2 (10 records each) folded into `_base`, k3 live."""
    var sh = _m(fs, _shard())
    _data(sh, "k1", Int64(10))
    _data(sh, "k2", Int64(10))
    var fold = SegmentBaseFold[_FaultStore](fs.clone(), _PART)
    assert_equal(fold.run_once(Int64(5000)).records_folded, Int64(20))
    _data(sh, "k3", Int64(10))


def _assert_k1_k2_k3(refs: List[SegmentRef]) raises:
    assert_equal(len(refs), 3)
    assert_equal(refs[0].object_key, "k1")
    assert_equal(refs[0].base_offset, Int64(0))
    assert_equal(refs[1].object_key, "k2")
    assert_equal(refs[1].base_offset, Int64(10))
    assert_equal(refs[2].object_key, "k3")
    assert_equal(refs[2].base_offset, Int64(20))


def _legacy_migrated(fs: _FaultStore) raises:
    """A legacy manifest k1..k3 (3 records each), fully migrated to `_base`."""
    var lg = _m(fs, _PART)
    _data(lg, "k1", Int64(3))
    _data(lg, "k2", Int64(3))
    _data(lg, "k3", Int64(3))
    var mig = SubLineageMigration[_FaultStore](fs.clone(), _PART)
    assert_equal(mig.migrate_partition(Int64(100)).records_migrated, Int64(9))


# =============================================================================
# SubLineageConsumeResolver (komira-ai/komira#1074)
# =============================================================================


def test_resolver_base_head_error_raises() raises:
    var fs = _FaultStore()
    _w0_k1_k2_folded_k3_live(fs)
    var r = SubLineageConsumeResolver[_FaultStore](fs.clone(), _PART)
    _assert_k1_k2_k3(r.resolve_index())
    fs.arm("list", _list_of(_base()), 0, 1, _ERR)
    with assert_raises(contains=_ERR):
        _ = r.has_base()
    fs.arm("list", _list_of(_base()), 0, 1, _ERR)
    with assert_raises(contains=_ERR):
        _ = r.resolve_index()
    fs.arm("list", _list_of(_base()), 0, 1, _ERR)
    with assert_raises(contains=_ERR):
        _ = r.resolve_index_tagged()
    _assert_k1_k2_k3(r.resolve_index())


# =============================================================================
# SegmentBaseInputs (komira-ai/komira#1074)
# =============================================================================


def test_inputs_base_head_error_raises() raises:
    var fs = _FaultStore()
    _w0_k1_k2_folded_k3_live(fs)
    var inputs = SegmentBaseInputs[_FaultStore](fs.clone(), _PART)
    var snap = inputs.snapshot()
    fs.arm("list", _list_of(_base()), 0, 1, _ERR)
    with assert_raises(contains=_ERR):
        _ = inputs.base_next_dense()
    fs.arm("list", _list_of(_base()), 0, 1, _ERR)
    with assert_raises(contains=_ERR):
        _ = inputs.walk_base_object_keys()
    fs.arm("list", _list_of(_base()), 0, 1, _ERR)
    with assert_raises(contains=_ERR):
        _ = inputs.folded_counts(snap)


def test_inputs_shard_reads_raise() raises:
    var fs = _FaultStore()
    _w0_k1_k2_folded_k3_live(fs)
    var inputs = SegmentBaseInputs[_FaultStore](fs.clone(), _PART)
    var snap = inputs.snapshot()
    var keys = inputs.walk_base_object_keys()
    var sh = _m(fs, _shard())
    fs.arm("list", _list_of(_shard()), 0, 1, _ERR)
    with assert_raises(contains=_ERR):
        _ = inputs.walk_shard_chunks("w0")
    fs.arm("list", _list_of(_shard()), 0, 1, _ERR)
    with assert_raises(contains=_ERR):
        _ = inputs._base_folded_prefix(sh, keys)
    var wm = inputs.folded_counts(snap)
    assert_equal(wm[0].folded_count, Int64(20))


def test_folded_counts_log_start_error_raises() raises:
    # RUNS LAST, and nothing follows the raise: a non-404 error inside
    # `CasManifestStore.read_log_start` (komira_objectstore) releases the
    # process-wide CAS gate twice, after which a later gated read or write
    # can block forever. The shard's own `_LOG_START` read is the first GET
    # of that key in folded_counts (`_base`'s is a different key).
    var fs = _FaultStore()
    _w0_k1_k2_folded_k3_live(fs)
    var inputs = SegmentBaseInputs[_FaultStore](fs.clone(), _PART)
    var snap = inputs.snapshot()
    fs.arm("get", log_start_key(_shard()).raw(), 0, 1, _ERR)
    with assert_raises(contains=_ERR):
        _ = inputs.folded_counts(snap)


# =============================================================================
# SegmentBaseFold.bound_stats (komira-ai/komira#1074)
# =============================================================================


def test_fold_bound_stats_base_head_error_raises() raises:
    var fs = _FaultStore()
    _w0_k1_k2_folded_k3_live(fs)
    var fold = SegmentBaseFold[_FaultStore](fs.clone(), _PART)
    assert_equal(fold.bound_stats().live_base_chunks, 2)
    fs.arm("list", _list_of(_base()), 0, 1, _ERR)
    with assert_raises(contains=_ERR):
        _ = fold.bound_stats()


# =============================================================================
# SubLineageMigration (komira-ai/komira#505 and #1074)
# =============================================================================


def test_migration_base_head_error_raises() raises:
    # komira-ai/komira#505: an error reading `_base`'s head is not "`_base`
    # empty", so the migration never re-records at dense offset 0.
    var fs = _FaultStore()
    _legacy_migrated(fs)
    var mig = SubLineageMigration[_FaultStore](fs.clone(), _PART)
    assert_equal(mig._base_next_dense(), Int64(9))
    fs.arm("list", _list_of(_base()), 0, 1, _ERR)
    with assert_raises(contains=_ERR):
        _ = mig._base_next_dense()
    fs.arm("list", _list_of(_base()), 0, 1, _ERR)
    with assert_raises(contains=_ERR):
        _ = mig.has_base()
    fs.arm("list", _list_of(_base()), 0, 1, _ERR)
    with assert_raises(contains=_ERR):
        _ = mig.migrate_partition(Int64(200))
    # Nothing was written: `_base` still ends at 9 and serves k1..k3 once.
    assert_equal(mig._base_next_dense(), Int64(9))
    var r = SubLineageConsumeResolver[_FaultStore](fs.clone(), _PART)
    assert_equal(len(r.resolve_index()), 3)


def test_migration_legacy_head_error_raises() raises:
    var fs = _FaultStore()
    var lg = _m(fs, _PART)
    _data(lg, "k1", Int64(3))
    var mig = SubLineageMigration[_FaultStore](fs.clone(), _PART)
    fs.arm("list", _list_of(_PART), 0, 1, _ERR)
    with assert_raises(contains=_ERR):
        _ = mig.migrate_partition(Int64(100))
    assert_equal(mig.migrate_partition(Int64(200)).records_migrated, Int64(3))


# =============================================================================
# The other half: a lineage that does not exist reads as empty.
# =============================================================================


def test_absent_lineages_read_empty() raises:
    var fs = _FaultStore()
    var r = SubLineageConsumeResolver[_FaultStore](fs.clone(), _PART)
    assert_false(r.has_base())
    assert_equal(len(r.resolve_index()), 0)
    assert_equal(len(r.resolve_index_tagged()), 0)
    var inputs = SegmentBaseInputs[_FaultStore](fs.clone(), _PART)
    assert_equal(inputs.base_next_dense(), Int64(0))
    assert_equal(len(inputs.walk_base_object_keys()), 0)
    var cap = inputs.walk_shard_chunks("w9")
    assert_equal(len(cap.chunks), 0)
    assert_equal(cap.log_start_offset, Int64(0))
    var no_keys = List[String]()
    assert_equal(
        inputs._base_folded_prefix(_m(fs, sublineage_prefix(_PART, "w9")), no_keys),
        Int64(0),
    )
    var fold = SegmentBaseFold[_FaultStore](fs.clone(), _PART)
    assert_equal(fold.bound_stats().live_base_chunks, 0)
    var mig = SubLineageMigration[_FaultStore](fs.clone(), _PART)
    assert_false(mig.has_base())
    assert_equal(mig._base_next_dense(), Int64(0))
    var st = mig.migrate_partition(Int64(100))
    assert_equal(st.records_migrated, Int64(0))
    assert_false(st.already_migrated)


# =============================================================================
# main: run every test, report each failure, then fail.
# =============================================================================


def main() raises:
    var failed = 0
    try:
        test_resolver_base_head_error_raises()
    except e:
        failed += 1
        print("[FAIL] test_resolver_base_head_error_raises: " + String(e))
    try:
        test_inputs_base_head_error_raises()
    except e:
        failed += 1
        print("[FAIL] test_inputs_base_head_error_raises: " + String(e))
    try:
        test_inputs_shard_reads_raise()
    except e:
        failed += 1
        print("[FAIL] test_inputs_shard_reads_raise: " + String(e))
    try:
        test_fold_bound_stats_base_head_error_raises()
    except e:
        failed += 1
        print("[FAIL] test_fold_bound_stats_base_head_error_raises: " + String(e))
    try:
        test_migration_base_head_error_raises()
    except e:
        failed += 1
        print("[FAIL] test_migration_base_head_error_raises: " + String(e))
    try:
        test_migration_legacy_head_error_raises()
    except e:
        failed += 1
        print("[FAIL] test_migration_legacy_head_error_raises: " + String(e))
    try:
        test_absent_lineages_read_empty()
    except e:
        failed += 1
        print("[FAIL] test_absent_lineages_read_empty: " + String(e))
    # Last: see its comment (the CAS gate after a `_LOG_START` read error).
    try:
        test_folded_counts_log_start_error_raises()
    except e:
        failed += 1
        print("[FAIL] test_folded_counts_log_start_error_raises: " + String(e))
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("[OK] test_broker_lineage_read_errors_offline")
