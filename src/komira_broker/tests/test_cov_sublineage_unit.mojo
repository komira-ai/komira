# =============================================================================
# tests/test_cov_sublineage_unit.mojo
#   The sub-lineage readers and writers under store errors and concurrent
#   writers: the consume resolver's walks, the shared fold inputs, the
#   segment fold's torn-append guard, and the migration's resume, torn-state
#   and concurrent-seed paths.
# =============================================================================
#
#   1. A non-404 chunk read error propagates out of every walk: the `_base`
#      walks (plain and tagged), the block walks (plain and tagged), the
#      shard capture and the folded-prefix walk.
#   2. The `_base` key walk skips a chunk that 404s (it keeps no offsets).
#   3. A block or watermark for a shard the cache never captured contributes
#      nothing, and a shard with no manifest captures no chunks and a 0
#      folded prefix.
#   4. SegmentBaseFold: a concurrent `_base` append that takes the fold's
#      slot is refused as a torn fold; should_fold delegates the cadence.
#   5. SubLineageMigration: a migration that failed after its first chunk
#      resumes and skips the chunk already in `_base`; a `_base` whose next
#      offset falls inside a legacy chunk, and a concurrent `_base` append,
#      are refused as torn; a concurrent seed of `_base`'s log start is
#      accepted.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_broker.consume_core import SegmentRef
from komira_broker.manifest_body import encode_manifest_body
from komira_broker.partition_assignment import sublineage_prefix
from komira_broker.sublineage_base_inputs import (
    FoldedCountsCache,
    SegmentBaseInputs,
    _CachedShard,
    _base_folded_prefix_cached,
)
from komira_broker.sublineage_consume import (
    SubLineageConsumeResolver,
    SubLineageTaggedSegment,
)
from komira_broker.sublineage_migration import SubLineageMigration
from komira_broker.sublineage_segment_fold import SegmentBaseFold
from komira_objectstore.cas_manifest import (
    CasManifestStore,
    LogStart,
    RetryPolicy,
    chunk_key,
    encode_log_start,
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
from komira_objectstore.sublineage_base_fold import (
    FoldBlockAssignment,
    ShardSnapshot,
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
# A rule per verb (get, head, put, cput, cas, range, list, delete) lives in the
# shared map under `__fault__/<verb>/...`: the path substring it matches, how
# many matching calls to let through first (skip), how many to fail after that
# (count; -1 fails every one) and the error message. A message
# `@copy:<key>` raises nothing: it copies the object at <key> over the path
# first, a concurrent writer landing just before this call. Clones share the
# map, so a test arms a rule through any handle.

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
        if msg.startswith("@copy:"):
            var src = String(msg[byte=6 : msg.byte_length()])
            _ = self.inner.put(path, self.inner.get(Path.parse(src)))
            return
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


comptime _PART = "c/_meta/topics/t/0"


def _m(fs: _FaultStore, prefix: String) -> CasManifestStore[_FaultStore]:
    return CasManifestStore[_FaultStore](
        store=fs.clone(), prefix=prefix, retry=RetryPolicy.fast_test()
    )


def _shard_prefix(sid: String) -> String:
    return sublineage_prefix(_PART, sid)


def _base_prefix() -> String:
    return sublineage_prefix(_PART, "_base")


def _data(mut m: CasManifestStore[_FaultStore], key: String, n: Int64) raises:
    _ = m.append(encode_manifest_body(key, n, UInt32(7), Int64(100), Int64(1000)), n)


def _chunk(prefix: String, seq: Int) raises -> String:
    return chunk_key(prefix, Int64(seq)).raw()


def _folded_shard(fs: _FaultStore) raises:
    """Shard w0: k1..k3 (10 rows each) folded into `_base`, then k4, k5 as
    the un-folded tail (shard seqs 3 and 4)."""
    var sh = _m(fs, _shard_prefix("w0"))
    _data(sh, "k1", Int64(10))
    _data(sh, "k2", Int64(10))
    _data(sh, "k3", Int64(10))
    var fold = SegmentBaseFold[_FaultStore](fs.clone(), _PART)
    var st = fold.run_once(Int64(5000))
    assert_equal(st.records_folded, Int64(30))
    _data(sh, "k4", Int64(10))
    _data(sh, "k5", Int64(10))


# ---- 1-3. consume resolver and fold inputs ------------------------------------------


def test_walks_propagate_store_errors() raises:
    var fs = _FaultStore()
    _folded_shard(fs)
    var r = SubLineageConsumeResolver[_FaultStore](fs.clone(), _PART)
    var refs = r.resolve_index()
    assert_equal(len(refs), 5)
    assert_equal(refs[4].base_offset, Int64(40))
    # The authoritative head reads each chunk once; the walk's read is the
    # second.
    var b1 = _chunk(_base_prefix(), 1)
    fs.arm("get", b1, 1, 1, "boom: base chunk")
    with assert_raises(contains="boom: base chunk"):
        _ = r._resolve_base_index()
    fs.arm("get", b1, 1, 1, "boom: base chunk")
    var sink = List[String]()
    with assert_raises(contains="boom: base chunk"):
        _ = r._resolve_base_index_tagged_capturing(sink)
    # The `_base` key walk keeps no offsets: a 404 there is skipped.
    var inputs = SegmentBaseInputs[_FaultStore](fs.clone(), _PART)
    fs.arm("get", b1, 1, 1, "not_found (404) injected")
    var keys = inputs.walk_base_object_keys()
    assert_equal(len(keys), 2)
    assert_equal(keys[0], "k1")
    assert_equal(keys[1], "k3")
    fs.arm("get", b1, 1, 1, "boom: base keys")
    with assert_raises(contains="boom: base keys"):
        _ = inputs.walk_base_object_keys()
    # The shard tail: blocks from the serve plan, walked directly.
    var fold = SegmentBaseFold[_FaultStore](fs.clone(), _PART)
    var plan = fold.serve_plan()
    assert_equal(len(plan), 1)
    var s3 = _chunk(_shard_prefix("w0"), 3)
    fs.arm("get", s3, 1, 1, "boom: shard chunk")
    var idx = List[SegmentRef]()
    with assert_raises(contains="boom: shard chunk"):
        r._append_block_segments(idx, plan[0])
    fs.arm("get", s3, 1, 1, "boom: shard chunk")
    var tidx = List[SubLineageTaggedSegment]()
    with assert_raises(contains="boom: shard chunk"):
        r._append_block_segments_tagged(tidx, plan[0])
    fs.arm("get", s3, 1, 1, "boom: shard chunk")
    with assert_raises(contains="boom: shard chunk"):
        _ = inputs.walk_shard_chunks("w0")
    var snap = inputs.snapshot()
    fs.arm("get", s3, 1, 1, "boom: shard chunk")
    with assert_raises(contains="boom: shard chunk"):
        _ = inputs.folded_counts(snap)
    fs.disarm("get")
    assert_equal(len(r.resolve_index()), 5)


def test_uncaptured_and_absent_shards_contribute_nothing() raises:
    var fs = _FaultStore()
    _folded_shard(fs)
    var r = SubLineageConsumeResolver[_FaultStore](fs.clone(), _PART)
    var empty = FoldedCountsCache(List[String](), List[_CachedShard]())
    var blk = FoldBlockAssignment(String("gone"), Int64(0), Int64(30), Int64(10))
    var idx = List[SegmentRef]()
    r._append_block_segments_cached(idx, blk, empty)
    assert_equal(len(idx), 0)
    var tidx = List[SubLineageTaggedSegment]()
    r._append_block_segments_tagged_cached(tidx, blk, empty)
    assert_equal(len(tidx), 0)
    # A snapshot shard the cache lacks reads watermark 0 from the cache.
    var inputs = SegmentBaseInputs[_FaultStore](fs.clone(), _PART)
    var snap = List[ShardSnapshot]()
    snap.append(ShardSnapshot(String("gone"), Int64(2), Int64(20)))
    var wm = inputs.folded_counts_cached(snap, empty)
    assert_equal(len(wm), 1)
    assert_equal(wm[0].folded_count, Int64(0))
    # A shard with no manifest captures no chunks, so no folded prefix.
    var absent = inputs.walk_shard_chunks("w9")
    assert_equal(len(absent.chunks), 0)
    var keys = List[String]()
    keys.append("k1")
    assert_equal(_base_folded_prefix_cached(absent, keys), Int64(0))


# ---- 4. the segment fold ---------------------------------------------------------------


def test_fold_refuses_torn_base_append() raises:
    var fs = _FaultStore()
    var sh = _m(fs, _shard_prefix("w0"))
    _data(sh, "k1", Int64(10))
    _data(sh, "k2", Int64(10))
    var fold = SegmentBaseFold[_FaultStore](fs.clone(), _PART)
    assert_true(fold.should_fold(0, Int64(0), Int64(1000)))
    assert_false(fold.should_fold(5, Int64(0), Int64(1000)))
    # Another writer lands `_base` slot 0 just before the fold's append.
    fs.arm(
        "cput", _chunk(_base_prefix(), 0), 0, 1,
        "@copy:" + _chunk(_shard_prefix("w0"), 0),
    )
    with assert_raises(contains="!= fold high-water 0 (torn fold)"):
        _ = fold.run_once(Int64(5000))


# ---- 5. migration -------------------------------------------------------------------------


def _legacy(fs: _FaultStore) raises:
    """The legacy single manifest at the partition prefix: k1..k3, 3 rows each."""
    var lg = _m(fs, _PART)
    _data(lg, "k1", Int64(3))
    _data(lg, "k2", Int64(3))
    _data(lg, "k3", Int64(3))


def test_migration_resume_and_torn_states() raises:
    # A run that fails after migrating chunk 0 resumes past it.
    var fs = _FaultStore()
    _legacy(fs)
    var mig = SubLineageMigration[_FaultStore](fs.clone(), _PART)
    fs.arm("get", _chunk(_PART, 1), 1, 1, "boom: legacy chunk 1")
    with assert_raises(contains="boom: legacy chunk 1"):
        _ = mig.migrate_partition(Int64(100))
    var st = mig.migrate_partition(Int64(200))
    assert_equal(st.base_offset_start, Int64(3))
    assert_equal(st.records_migrated, Int64(6))
    assert_equal(st.base_chunks_appended, 2)
    var r = SubLineageConsumeResolver[_FaultStore](fs.clone(), _PART)
    var refs = r.resolve_index()
    assert_equal(len(refs), 3)
    assert_equal(refs[2].base_offset, Int64(6))
    assert_equal(refs[2].object_key, "k3")

    # A `_base` whose next offset (2) falls inside legacy chunk 0 ([0, 3)).
    var ft = _FaultStore()
    _legacy(ft)
    var b = _m(ft, _base_prefix())
    _data(b, "x", Int64(2))
    var mt = SubLineageMigration[_FaultStore](ft.clone(), _PART)
    with assert_raises(contains="source chunk dense base 0 != expected dense 2"):
        _ = mt.migrate_partition(Int64(100))

    # Another writer lands `_base` slot 0 just before the migration's append.
    var fc = _FaultStore()
    _legacy(fc)
    fc.arm("cput", _chunk(_base_prefix(), 0), 0, 1, "@copy:" + _chunk(_PART, 0))
    var mc = SubLineageMigration[_FaultStore](fc.clone(), _PART)
    with assert_raises(contains="`_base` base_offset 3 != expected dense 0"):
        _ = mc.migrate_partition(Int64(100))


def test_migration_accepts_concurrent_seed() raises:
    # Legacy whose first chunk was retired: log start (seq 1, offset 3).
    var fs = _FaultStore()
    _legacy(fs)
    var lg = _m(fs, _PART)
    _ = lg.advance_log_start(Int64(1), Int64(3), String(""))
    # Another migrator seeds `_base`'s log start (same values) first.
    var staged = encode_log_start(LogStart(Int64(3), Int64(0), String("")))
    _ = fs.inner.put(Path.parse("stage/ls"), staged)
    fs.arm("cput", log_start_key(_base_prefix()).raw(), 0, 1, "@copy:stage/ls")
    var mig = SubLineageMigration[_FaultStore](fs.clone(), _PART)
    var st = mig.migrate_partition(Int64(100))
    assert_equal(st.base_offset_start, Int64(3))
    assert_equal(st.records_migrated, Int64(6))
    var r = SubLineageConsumeResolver[_FaultStore](fs.clone(), _PART)
    var refs = r.resolve_index()
    assert_equal(len(refs), 2)
    assert_equal(refs[0].base_offset, Int64(3))
    assert_equal(refs[1].base_offset, Int64(6))


def main() raises:
    test_walks_propagate_store_errors()
    test_uncaptured_and_absent_shards_contribute_nothing()
    test_fold_refuses_torn_base_append()
    test_migration_resume_and_torn_states()
    test_migration_accepts_concurrent_seed()
    print("[OK] test_cov_sublineage_unit")
