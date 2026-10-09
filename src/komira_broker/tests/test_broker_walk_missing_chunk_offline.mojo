# =============================================================================
# tests/test_broker_walk_missing_chunk_offline.mojo
#   A manifest walk that cannot read a chunk never keeps numbering the chunks
#   after it from its old running offset (komira-ai/komira#1073 and #504).
# =============================================================================
#
# Every offset-bearing walk seeds a running offset from the `_LOG_START` it
# read and adds each chunk's record_count. A chunk that reads as not_found
# has an unknown record_count, so continuing would give every later chunk an
# offset too low by that count. Two cases, both driven through a store that
# fails one GET of one chunk:
#
#   * REAPED: retention advanced `_LOG_START` past the chunk and a reaper
#     deleted it after the walk read `_LOG_START` (the `@reap:` rule below
#     moves `_LOG_START` and deletes the chunk inside the GET). A read walk
#     restarts from the new `_LOG_START`, so the survivors keep their true
#     offsets. Catches: a walk that skips the chunk with `seq += 1`.
#   * MISSING: the chunk reads as not_found while `_LOG_START` stays below it
#     (a torn lineage). Every walk raises. Catches: the same skip, which
#     returns renumbered offsets with no error.
#
# A restart keeps nothing from the pass before it: a chunk read before the
# reap may sit below the new `_LOG_START` too.
#
# Walks covered: ConsumeCore.resolve_index; the sub-lineage resolver's `_base`
# walks (plain, tagged, and the un-cached one) and block walks (plain and
# tagged); SegmentBaseInputs.walk_shard_chunks (the capture the cached replay
# reads) and _base_folded_prefix; SegmentBaseFold's materialize walk and the
# migration's materialize walk, which write as they go and so raise on any
# missing chunk, reaped or not.
#
# Each test runs on its own; main reports every failure, then fails.
# =============================================================================

from std.testing import assert_equal, assert_raises

from komira_broker.consume_core import ConsumeCore, SegmentRef
from komira_broker.manifest_body import encode_manifest_body
from komira_broker.partition_assignment import sublineage_prefix
from komira_broker.sublineage_base_inputs import SegmentBaseInputs
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
from komira_objectstore.sublineage_base_fold import FoldBlockAssignment
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
# fails every one) and the error message. A message `@reap:<src>|<dst>` is a
# reaper landing inside this call: it copies the object at <src> over <dst>
# (the new `_LOG_START`), deletes the path, and raises not_found. Clones share
# the map, so a test arms a rule through any handle.

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
        if msg.startswith("@reap:"):
            var spec = String(msg[byte=6 : msg.byte_length()])
            var bar = spec.find("|")
            var src = String(spec[byte=0:bar])
            var dst = String(spec[byte=bar + 1 : spec.byte_length()])
            _ = self.inner.put(Path.parse(dst), self.inner.get(Path.parse(src)))
            self.inner.delete(path)
            raise Error("not_found (404): reaped " + raw)
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
# Fixtures
# =============================================================================

comptime _PART = "c/_meta/topics/t/0"
comptime _MISSING = "not_found (404) injected"
comptime _TORN = "is missing at or above _LOG_START seq"


def _m(fs: _FaultStore, prefix: String) -> CasManifestStore[_FaultStore]:
    return CasManifestStore[_FaultStore](
        store=fs.clone(), prefix=prefix, retry=RetryPolicy.fast_test()
    )


def _shard() -> String:
    return sublineage_prefix(_PART, "w0")


def _base() -> String:
    return sublineage_prefix(_PART, "_base")


def _chunk(prefix: String, seq: Int) raises -> String:
    return chunk_key(prefix, Int64(seq)).raw()


def _three_chunks(fs: _FaultStore, prefix: String) raises:
    """Chunks k1, k2, k3 of 3, 4 and 5 records at `prefix`: offsets 0, 3, 7."""
    var m = _m(fs, prefix)
    _ = m.append(encode_manifest_body("k1", Int64(3), UInt32(7), Int64(100), Int64(1)), Int64(3))
    _ = m.append(encode_manifest_body("k2", Int64(4), UInt32(7), Int64(100), Int64(1)), Int64(4))
    _ = m.append(encode_manifest_body("k3", Int64(5), UInt32(7), Int64(100), Int64(1)), Int64(5))


def _arm_reap_chunk0(fs: _FaultStore, prefix: String, skip: Int) raises:
    """The GET of chunk 0 after `skip` earlier ones finds it reaped: the
    reaper moved `prefix`'s `_LOG_START` to (seq 1, offset 3) and deleted it."""
    var staged = encode_log_start(LogStart(Int64(3), Int64(1), String("")))
    _ = fs.inner.put(Path.parse("stage/ls"), staged)
    fs.arm(
        "get", _chunk(prefix, 0), skip, 1,
        "@reap:stage/ls|" + log_start_key(prefix).raw(),
    )


def _arm_reap_chunk1(fs: _FaultStore, prefix: String, skip: Int) raises:
    """The GET of chunk 1 after `skip` earlier ones finds it reaped, after the
    walk already read chunk 0: `_LOG_START` moved to (seq 2, offset 7), so
    chunk 0 (read) and chunk 1 are both below it now."""
    var staged = encode_log_start(LogStart(Int64(7), Int64(2), String("")))
    _ = fs.inner.put(Path.parse("stage/ls2"), staged)
    fs.arm(
        "get", _chunk(prefix, 1), skip, 1,
        "@reap:stage/ls2|" + log_start_key(prefix).raw(),
    )


def _assert_only_k3(refs: List[SegmentRef], base: Int64) raises:
    """k1 was read before the reap but sits below the new `_LOG_START`: a
    restarted walk keeps nothing from its first pass."""
    assert_equal(len(refs), 1)
    assert_equal(refs[0].object_key, "k3")
    assert_equal(refs[0].base_offset, base)
    assert_equal(refs[0].last_offset, base + Int64(4))


def _folded_base(fs: _FaultStore) raises:
    """Shard w0 holds k1, k2, k3, all folded: `_base` chunks 0..2 at 0, 3, 7."""
    _three_chunks(fs, _shard())
    var fold = SegmentBaseFold[_FaultStore](fs.clone(), _PART)
    assert_equal(fold.run_once(Int64(5000)).records_folded, Int64(12))


def _assert_survivors(refs: List[SegmentRef], first_base: Int64) raises:
    """k2 then k3, k2 at `first_base`, k3 right after its 4 records."""
    assert_equal(len(refs), 2)
    assert_equal(refs[0].object_key, "k2")
    assert_equal(refs[0].base_offset, first_base)
    assert_equal(refs[0].last_offset, first_base + Int64(3))
    assert_equal(refs[1].object_key, "k3")
    assert_equal(refs[1].base_offset, first_base + Int64(4))
    assert_equal(refs[1].last_offset, first_base + Int64(8))


def _segs(tagged: List[SubLineageTaggedSegment]) -> List[SegmentRef]:
    var out = List[SegmentRef]()
    for i in range(len(tagged)):
        out.append(tagged[i].seg.copy())
    return out^


# =============================================================================
# ConsumeCore.resolve_index (the legacy single-manifest walk)
# =============================================================================


def _core(fs: _FaultStore) -> ConsumeCore[_FaultStore]:
    return ConsumeCore[_FaultStore](
        fs.clone(), _m(fs, _PART), String("c"), String("t"), Int64(0)
    )


def test_consume_core_restarts_after_reap() raises:
    var fs = _FaultStore()
    _three_chunks(fs, _PART)
    # The authoritative head reads chunk 0 once; the walk's read is the second.
    _arm_reap_chunk0(fs, _PART, 1)
    var c = _core(fs)
    _assert_survivors(c.resolve_index(), Int64(3))


def test_consume_core_missing_chunk_raises() raises:
    var fs = _FaultStore()
    _three_chunks(fs, _PART)
    fs.arm("get", _chunk(_PART, 0), 1, 1, _MISSING)
    var c = _core(fs)
    with assert_raises(contains=_TORN):
        _ = c.resolve_index()
    # The chunk reads again: the walk is whole.
    assert_equal(len(c.resolve_index()), 3)


# =============================================================================
# SubLineageConsumeResolver: the `_base` walks
# =============================================================================


def test_base_walks_restart_after_reap() raises:
    # resolve_index: the `_base` head reads chunk 0 once, the walk second.
    var fs = _FaultStore()
    _folded_base(fs)
    _arm_reap_chunk0(fs, _base(), 1)
    var r = SubLineageConsumeResolver[_FaultStore](fs.clone(), _PART)
    _assert_survivors(r.resolve_index(), Int64(3))
    # resolve_index_tagged, on a fresh store.
    var ft = _FaultStore()
    _folded_base(ft)
    _arm_reap_chunk0(ft, _base(), 1)
    var rt = SubLineageConsumeResolver[_FaultStore](ft.clone(), _PART)
    _assert_survivors(_segs(rt.resolve_index_tagged()), Int64(3))
    # The un-cached resolve's `_base` walk, on a fresh store.
    var fu = _FaultStore()
    _folded_base(fu)
    _arm_reap_chunk0(fu, _base(), 1)
    var ru = SubLineageConsumeResolver[_FaultStore](fu.clone(), _PART)
    _assert_survivors(ru.resolve_index_uncached(), Int64(3))


def test_base_walks_missing_chunk_raise() raises:
    var fs = _FaultStore()
    _folded_base(fs)
    var r = SubLineageConsumeResolver[_FaultStore](fs.clone(), _PART)
    fs.arm("get", _chunk(_base(), 0), 1, 1, _MISSING)
    with assert_raises(contains=_TORN):
        _ = r.resolve_index()
    fs.arm("get", _chunk(_base(), 0), 1, 1, _MISSING)
    with assert_raises(contains=_TORN):
        _ = r.resolve_index_tagged()
    fs.arm("get", _chunk(_base(), 0), 1, 1, _MISSING)
    with assert_raises(contains=_TORN):
        _ = r._resolve_base_index()
    assert_equal(len(r.resolve_index()), 3)


# =============================================================================
# SubLineageConsumeResolver: the block walks (one block over shard w0)
# =============================================================================


def _block() -> FoldBlockAssignment:
    """Shard w0's source-local [0, 12) at dense 100."""
    return FoldBlockAssignment(String("w0"), Int64(0), Int64(100), Int64(12))


def test_block_walks_restart_after_reap() raises:
    # Dense offset = 100 + source-local offset: k2 at 103, k3 at 107.
    var fs = _FaultStore()
    _three_chunks(fs, _shard())
    var r = SubLineageConsumeResolver[_FaultStore](fs.clone(), _PART)
    _arm_reap_chunk0(fs, _shard(), 1)
    var idx = List[SegmentRef]()
    r._append_block_segments(idx, _block())
    _assert_survivors(idx, Int64(103))
    var ft = _FaultStore()
    _three_chunks(ft, _shard())
    var rt = SubLineageConsumeResolver[_FaultStore](ft.clone(), _PART)
    _arm_reap_chunk0(ft, _shard(), 1)
    var tidx = List[SubLineageTaggedSegment]()
    rt._append_block_segments_tagged(tidx, _block())
    _assert_survivors(_segs(tidx), Int64(103))


def test_block_walks_missing_chunk_raise() raises:
    var fs = _FaultStore()
    _three_chunks(fs, _shard())
    var r = SubLineageConsumeResolver[_FaultStore](fs.clone(), _PART)
    fs.arm("get", _chunk(_shard(), 0), 1, 1, _MISSING)
    var idx = List[SegmentRef]()
    with assert_raises(contains=_TORN):
        r._append_block_segments(idx, _block())
    fs.arm("get", _chunk(_shard(), 0), 1, 1, _MISSING)
    var tidx = List[SubLineageTaggedSegment]()
    with assert_raises(contains=_TORN):
        r._append_block_segments_tagged(tidx, _block())


# =============================================================================
# SegmentBaseInputs: the shard capture and the folded-prefix walk
# =============================================================================


def test_shard_capture_restarts_after_reap() raises:
    # The capture's `_LOG_START` seeds the cached replay: it must be the one
    # its chunk list starts at.
    var fs = _FaultStore()
    _three_chunks(fs, _shard())
    var inputs = SegmentBaseInputs[_FaultStore](fs.clone(), _PART)
    _arm_reap_chunk0(fs, _shard(), 1)
    var cap = inputs.walk_shard_chunks("w0")
    assert_equal(cap.log_start_offset, Int64(3))
    assert_equal(cap.log_start_seq, Int64(1))
    assert_equal(len(cap.chunks), 2)
    assert_equal(cap.chunks[0].object_key, "k2")
    assert_equal(cap.chunks[1].object_key, "k3")


def test_shard_capture_missing_chunk_raises() raises:
    var fs = _FaultStore()
    _three_chunks(fs, _shard())
    var inputs = SegmentBaseInputs[_FaultStore](fs.clone(), _PART)
    fs.arm("get", _chunk(_shard(), 1), 1, 1, _MISSING)
    with assert_raises(contains=_TORN):
        _ = inputs.walk_shard_chunks("w0")


def _all_keys() -> List[String]:
    var keys = List[String]()
    keys.append("k1")
    keys.append("k2")
    keys.append("k3")
    return keys^


def test_folded_prefix_restarts_after_reap() raises:
    # Every chunk is in `_base`, so the prefix ends at the shard's end, 12.
    var fs = _FaultStore()
    _three_chunks(fs, _shard())
    var inputs = SegmentBaseInputs[_FaultStore](fs.clone(), _PART)
    var sh = _m(fs, _shard())
    _arm_reap_chunk0(fs, _shard(), 1)
    assert_equal(inputs._base_folded_prefix(sh, _all_keys()), Int64(12))


def test_folded_prefix_missing_chunk_raises() raises:
    var fs = _FaultStore()
    _three_chunks(fs, _shard())
    var inputs = SegmentBaseInputs[_FaultStore](fs.clone(), _PART)
    var sh = _m(fs, _shard())
    fs.arm("get", _chunk(_shard(), 0), 1, 1, _MISSING)
    with assert_raises(contains=_TORN):
        _ = inputs._base_folded_prefix(sh, _all_keys())


# =============================================================================
# A restart drops what the walk read before it (the reap took chunks 0 and 1)
# =============================================================================


def test_consume_core_restart_drops_first_pass() raises:
    var fs = _FaultStore()
    _three_chunks(fs, _PART)
    _arm_reap_chunk1(fs, _PART, 1)
    var c = _core(fs)
    _assert_only_k3(c.resolve_index(), Int64(7))


def test_base_walk_restart_drops_first_pass() raises:
    # The `_base` key capture is restarted too: it holds k3 only.
    var fs = _FaultStore()
    _folded_base(fs)
    _arm_reap_chunk1(fs, _base(), 1)
    var r = SubLineageConsumeResolver[_FaultStore](fs.clone(), _PART)
    var keys = List[String]()
    keys.append("earlier")
    _assert_only_k3(r._resolve_base_index_capturing(keys), Int64(7))
    assert_equal(len(keys), 2)
    assert_equal(keys[0], "earlier")
    assert_equal(keys[1], "k3")


def test_block_walk_restart_drops_first_pass() raises:
    # Entries another block appended before this walk stay.
    var fs = _FaultStore()
    _three_chunks(fs, _shard())
    var r = SubLineageConsumeResolver[_FaultStore](fs.clone(), _PART)
    _arm_reap_chunk1(fs, _shard(), 1)
    var idx = List[SegmentRef]()
    idx.append(
        SegmentRef(
            chunk_seq=Int64(9), base_offset=Int64(90), last_offset=Int64(99),
            record_count=Int64(10), object_key=String("other"), crc32=UInt32(0),
        )
    )
    r._append_block_segments(idx, _block())
    assert_equal(len(idx), 2)
    assert_equal(idx[0].object_key, "other")
    assert_equal(idx[1].object_key, "k3")
    assert_equal(idx[1].base_offset, Int64(107))


def test_shard_capture_restart_drops_first_pass() raises:
    var fs = _FaultStore()
    _three_chunks(fs, _shard())
    var inputs = SegmentBaseInputs[_FaultStore](fs.clone(), _PART)
    _arm_reap_chunk1(fs, _shard(), 1)
    var cap = inputs.walk_shard_chunks("w0")
    assert_equal(cap.log_start_offset, Int64(7))
    assert_equal(len(cap.chunks), 1)
    assert_equal(cap.chunks[0].object_key, "k3")


# =============================================================================
# The writing walks: the segment fold and the migration
# =============================================================================


def test_fold_materialize_missing_chunk_raises() raises:
    # Chunk 1's reads in run_once: the snapshot head, the folded-prefix head
    # (its walk stops at chunk 0, not in `_base`), the materialize head, then
    # the materialize walk.
    var fs = _FaultStore()
    _three_chunks(fs, _shard())
    var fold = SegmentBaseFold[_FaultStore](fs.clone(), _PART)
    fs.arm("get", _chunk(_shard(), 1), 3, 1, _MISSING)
    with assert_raises(contains=_MISSING):
        _ = fold.run_once(Int64(5000))
    # Nothing after k1 reached `_base`, and the next round folds the rest at
    # their own offsets.
    assert_equal(fold.run_once(Int64(6000)).records_folded, Int64(9))
    var r = SubLineageConsumeResolver[_FaultStore](fs.clone(), _PART)
    var refs = r.resolve_index()
    assert_equal(len(refs), 3)
    assert_equal(refs[1].object_key, "k2")
    assert_equal(refs[1].base_offset, Int64(3))
    assert_equal(refs[2].object_key, "k3")
    assert_equal(refs[2].base_offset, Int64(7))


def test_migration_missing_legacy_chunk_raises() raises:
    # komira-ai/komira#504. Chunk 1's reads: the legacy head, then the walk.
    var fs = _FaultStore()
    _three_chunks(fs, _PART)
    var mig = SubLineageMigration[_FaultStore](fs.clone(), _PART)
    fs.arm("get", _chunk(_PART, 1), 1, 1, _MISSING)
    with assert_raises(contains=_MISSING):
        _ = mig.migrate_partition(Int64(100))
    # Only k1 was migrated; the resumed migration records k2 and k3 at
    # their own offsets.
    assert_equal(mig._base_next_dense(), Int64(3))
    var st = mig.migrate_partition(Int64(200))
    assert_equal(st.records_migrated, Int64(9))
    var r = SubLineageConsumeResolver[_FaultStore](fs.clone(), _PART)
    var refs = r.resolve_index()
    assert_equal(len(refs), 3)
    assert_equal(refs[1].object_key, "k2")
    assert_equal(refs[1].base_offset, Int64(3))
    assert_equal(refs[2].object_key, "k3")
    assert_equal(refs[2].base_offset, Int64(7))


# =============================================================================
# main: run every test, report each failure, then fail.
# =============================================================================


def main() raises:
    var failed = 0
    try:
        test_consume_core_restarts_after_reap()
    except e:
        failed += 1
        print("[FAIL] test_consume_core_restarts_after_reap: " + String(e))
    try:
        test_consume_core_missing_chunk_raises()
    except e:
        failed += 1
        print("[FAIL] test_consume_core_missing_chunk_raises: " + String(e))
    try:
        test_base_walks_restart_after_reap()
    except e:
        failed += 1
        print("[FAIL] test_base_walks_restart_after_reap: " + String(e))
    try:
        test_base_walks_missing_chunk_raise()
    except e:
        failed += 1
        print("[FAIL] test_base_walks_missing_chunk_raise: " + String(e))
    try:
        test_block_walks_restart_after_reap()
    except e:
        failed += 1
        print("[FAIL] test_block_walks_restart_after_reap: " + String(e))
    try:
        test_block_walks_missing_chunk_raise()
    except e:
        failed += 1
        print("[FAIL] test_block_walks_missing_chunk_raise: " + String(e))
    try:
        test_shard_capture_restarts_after_reap()
    except e:
        failed += 1
        print("[FAIL] test_shard_capture_restarts_after_reap: " + String(e))
    try:
        test_shard_capture_missing_chunk_raises()
    except e:
        failed += 1
        print("[FAIL] test_shard_capture_missing_chunk_raises: " + String(e))
    try:
        test_folded_prefix_restarts_after_reap()
    except e:
        failed += 1
        print("[FAIL] test_folded_prefix_restarts_after_reap: " + String(e))
    try:
        test_folded_prefix_missing_chunk_raises()
    except e:
        failed += 1
        print("[FAIL] test_folded_prefix_missing_chunk_raises: " + String(e))
    try:
        test_consume_core_restart_drops_first_pass()
    except e:
        failed += 1
        print("[FAIL] test_consume_core_restart_drops_first_pass: " + String(e))
    try:
        test_base_walk_restart_drops_first_pass()
    except e:
        failed += 1
        print("[FAIL] test_base_walk_restart_drops_first_pass: " + String(e))
    try:
        test_block_walk_restart_drops_first_pass()
    except e:
        failed += 1
        print("[FAIL] test_block_walk_restart_drops_first_pass: " + String(e))
    try:
        test_shard_capture_restart_drops_first_pass()
    except e:
        failed += 1
        print("[FAIL] test_shard_capture_restart_drops_first_pass: " + String(e))
    try:
        test_fold_materialize_missing_chunk_raises()
    except e:
        failed += 1
        print("[FAIL] test_fold_materialize_missing_chunk_raises: " + String(e))
    try:
        test_migration_missing_legacy_chunk_raises()
    except e:
        failed += 1
        print("[FAIL] test_migration_missing_legacy_chunk_raises: " + String(e))
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("[OK] test_broker_walk_missing_chunk_offline")
