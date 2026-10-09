# =============================================================================
# tests/test_cov_consume_retention_unit.mojo
#   The consume core's error arms and drains, the compaction index's
#   decode refusals and fail-soft walk, the log cleaner's record extraction
#   and sidecar decoders on every body generation, and the retention pass
#   and reaper on their quiet and failing paths.
# =============================================================================
#
#   1. ConsumeCore: a non-404 chunk read error propagates out of
#      resolve_index and chunk_txn_tags; a 404 in chunk_txn_tags skips that
#      chunk; a footer claiming more rows than the manifest is refused;
#      read_from drains from 0 and from mid-log; num_chunks_cached.
#   2. CompactionIndex: decode_body refuses a short body and a short key;
#      an empty index has tail 0; a compacted entry that 404s is skipped,
#      any other error propagates.
#   3. Log cleaning: STRING keys and nullable INT64 values extract with
#      their tombstones; the sidecar readers report "not compacted" for a
#      legacy, a retention and a producer body, stop at a cut sidecar, and
#      refuse a body too short for its key length.
#   4. Retention: a pass with nothing out of policy changes nothing; the
#      reaper still reaps a chunk whose body 404s, and stops on any other
#      error reading a body.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_arrow.string_array import StringArray

from komira_broker.broker_core import BrokerCore
from komira_broker.compacted_index import (
    CompactedEntry,
    CompactionIndex,
    compacted_prefix,
)
from komira_broker.consume_core import ConsumeCore, SegmentRef
from komira_broker.log_compaction import (
    decode_compacted_survivor_offsets,
    encode_compacted_chunk_body,
    extract_clean_records,
    is_chunk_compacted,
)
from komira_broker.manifest_body import ManifestBody, encode_manifest_body
from komira_broker.retention import RetentionPolicy
from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy, chunk_key
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


comptime _PREFIX = "c/_meta/topics/t/0"


def _manifest(fs: _FaultStore, prefix: String) -> CasManifestStore[_FaultStore]:
    return CasManifestStore[_FaultStore](
        store=fs.clone(), prefix=prefix, retry=RetryPolicy.fast_test()
    )


def _core(fs: _FaultStore) -> BrokerCore[_FaultStore]:
    return BrokerCore[_FaultStore](
        segment_store=fs.clone(),
        manifest=_manifest(fs, _PREFIX),
        cluster=String("c"),
        topic=String("t"),
        partition=Int64(0),
        broker_id=String("b"),
    )


def _consumer(fs: _FaultStore) -> ConsumeCore[_FaultStore]:
    return ConsumeCore[_FaultStore](
        segment_store=fs.clone(),
        manifest=_manifest(fs, _PREFIX),
        cluster=String("c"),
        topic=String("t"),
        partition=Int64(0),
    )


def _batch(base_val: Int64, n: Int) raises -> RecordBatch:
    var schema = Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, base_val + Int64(i))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _three_chunks(fs: _FaultStore) raises:
    """Chunks 0, 1, 2 of 3, 4 and 5 rows, flushed at 1000, 2000, 3000 ms."""
    var core = _core(fs)
    var sizes = List[Int]()
    sizes.append(3)
    sizes.append(4)
    sizes.append(5)
    var v = Int64(0)
    for i in range(3):
        core.buffer_batch(_batch(v, sizes[i]), Int64(1000 * (i + 1)))
        _ = core.flush(Int64(1000 * (i + 1)))
        v += Int64(sizes[i])


def _prefix(b: List[UInt8], n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(b[i])
    return out^


# ---- 1. consume core ----------------------------------------------------------------


def test_consume_core_errors_and_drains() raises:
    var fs = _FaultStore()
    _three_chunks(fs)
    var c = _consumer(fs)
    # The cached _HEAD advances best-effort: it may lag, never lead.
    var cached = c.num_chunks_cached()
    assert_true(cached >= Int64(1) and cached <= c.num_chunks())
    var all = c.read_from(Int64(0))
    assert_equal(len(all), 3)
    assert_equal(all[2].base_offset, Int64(7))
    var tail = c.read_from(Int64(8))
    assert_equal(len(tail), 1)
    assert_equal(tail[0].chunk_seq, Int64(2))
    assert_equal(tail[0].record_count, Int64(5))
    assert_equal(len(c.read_from(Int64(12))), 0)
    # The authoritative head reads every chunk once; the walk's read of
    # chunk 1 is the second.
    var k1 = chunk_key(_PREFIX, Int64(1)).raw()
    fs.arm("get", k1, 1, 1, "boom: chunk 1")
    with assert_raises(contains="boom: chunk 1"):
        _ = c.resolve_index()
    fs.arm("get", k1, 1, 1, "boom: chunk 1")
    with assert_raises(contains="boom: chunk 1"):
        _ = c.chunk_txn_tags()
    fs.arm("get", k1, 1, 1, "not_found (404) injected")
    var tags = c.chunk_txn_tags()
    assert_equal(len(tags), 2)
    assert_equal(tags[0].chunk_seq, Int64(0))
    assert_equal(tags[1].chunk_seq, Int64(2))
    # A footer that claims more rows than the manifest span.
    var idx = c.resolve_index()
    var lying = SegmentRef(
        chunk_seq=idx[1].chunk_seq,
        base_offset=idx[1].base_offset,
        last_offset=idx[1].base_offset + Int64(2),
        record_count=Int64(3),
        object_key=String(idx[1].object_key),
        crc32=idx[1].crc32,
    )
    with assert_raises(contains="footer record_count 4 > manifest record_count 3 for chunk 1"):
        _ = c.read_segment(lying)
    # Fewer physical rows than the span (a compacted chunk) is accepted.
    var roomy = SegmentRef(
        chunk_seq=idx[1].chunk_seq,
        base_offset=idx[1].base_offset,
        last_offset=idx[1].base_offset + Int64(9),
        record_count=Int64(10),
        object_key=String(idx[1].object_key),
        crc32=idx[1].crc32,
    )
    assert_equal(c.read_segment(roomy).record_count, Int64(4))


# ---- 2. compaction index ------------------------------------------------------------


def test_compaction_index_decode_and_walk() raises:
    var e = CompactedEntry(
        chunk_seq=Int64(0), base_offset=Int64(0), last_offset=Int64(2),
        record_count=Int64(3), supersedes_lo=Int64(0), supersedes_hi=Int64(0),
        parquet_key=String("pq/a"),
    )
    var body = e.encode_body()
    assert_equal(CompactedEntry.decode_body(Int64(0), body).parquet_key, "pq/a")
    with assert_raises(contains="compacted index: truncated i64 at 40"):
        _ = CompactedEntry.decode_body(Int64(0), _prefix(body, 44))
    with assert_raises(contains="CompactedEntry.decode_body: truncated parquet_key"):
        _ = CompactedEntry.decode_body(Int64(0), _prefix(body, 50))
    var fs = _FaultStore()
    var ci = CompactionIndex[_FaultStore].build(
        fs.clone(), String(_PREFIX), RetryPolicy.fast_test()
    )
    assert_equal(ci.compacted_tail_offset(), Int64(0))
    _ = ci.append_compacted("pq/a", Int64(0), Int64(2), Int64(3), Int64(0), Int64(0))
    _ = ci.append_compacted("pq/b", Int64(3), Int64(6), Int64(4), Int64(1), Int64(1))
    _ = ci.append_compacted("pq/c", Int64(7), Int64(7), Int64(1), Int64(2), Int64(2))
    assert_equal(ci.compacted_tail_offset(), Int64(8))
    var k1 = chunk_key(compacted_prefix(_PREFIX), Int64(1)).raw()
    fs.arm("get", k1, 1, 1, "not_found (404) injected")
    var got = ci.resolve_compacted()
    assert_equal(len(got), 2)
    assert_equal(got[1].parquet_key, "pq/c")
    assert_equal(got[1].base_offset, Int64(7))
    fs.arm("get", k1, 1, 1, "boom: compacted read")
    with assert_raises(contains="boom: compacted read"):
        _ = ci.resolve_compacted()


# ---- 3. log cleaning ------------------------------------------------------------------


def test_extract_string_keys_int_values() raises:
    var schema = Schema(
        names=[String("k"), String("v")],
        arrow_types=[ArrowType.STRING.type_id, ArrowType.INT64.type_id],
        dtypes=[DType.uint8, DType.int64],
        nullables=[False, True],
    )
    var keys = List[String]()
    keys.append("a")
    keys.append("b")
    keys.append("a")
    var kcol = Column.from_string(StringArray.from_strings(keys))
    var vals = PrimitiveArray[DType.int64].allocate_nullable(3)
    vals.set(0, Int64(10))
    vals._set_null(1)
    vals.set(2, Int64(30))
    var batch = RecordBatch.from_typed_columns_2(
        schema^, kcol^, Column.from_primitive[DType.int64](vals^)
    )
    var recs = extract_clean_records(batch, 0, 1, Int64(100), Int64(4))
    assert_equal(len(recs), 3)
    assert_equal(recs[0].key, "a")
    assert_equal(recs[1].key, "b")
    assert_false(recs[0].is_tombstone)
    assert_true(recs[1].is_tombstone)
    assert_false(recs[2].is_tombstone)
    assert_equal(recs[2].abs_offset, Int64(102))
    assert_equal(recs[2].chunk_seq, Int64(4))


def test_sidecar_readers_on_every_body_generation() raises:
    var full = encode_manifest_body("seg", Int64(3), UInt32(1), Int64(10), Int64(5))
    # key "seg": legacy body ends at 23, retention at 39, producer at 71.
    var legacy = _prefix(full, 23)
    var retention = _prefix(full, 39)
    var producer = _prefix(full, 71)
    var bodies = List[List[UInt8]]()
    bodies.append(legacy^)
    bodies.append(retention^)
    bodies.append(producer^)
    bodies.append(full.copy())
    for i in range(len(bodies)):
        assert_false(is_chunk_compacted(bodies[i]))
        assert_equal(len(decode_compacted_survivor_offsets(bodies[i])), 0)
    var survivors = List[Int64]()
    survivors.append(Int64(4))
    survivors.append(Int64(9))
    var compacted = encode_compacted_chunk_body(
        ManifestBody.decode(full), "seg2", UInt32(2), survivors
    )
    assert_true(is_chunk_compacted(compacted))
    var both = decode_compacted_survivor_offsets(compacted)
    assert_equal(len(both), 2)
    assert_equal(both[1], Int64(9))
    # A sidecar cut inside its second offset yields the offsets fully present.
    var cut = _prefix(compacted, len(compacted) - 1)
    var one = decode_compacted_survivor_offsets(cut)
    assert_equal(len(one), 1)
    assert_equal(one[0], Int64(4))
    with assert_raises(contains="log_compaction: truncated i64 at 12"):
        _ = decode_compacted_survivor_offsets(_prefix(full, 10))
    with assert_raises(contains="log_compaction: truncated i64 at 12"):
        _ = is_chunk_compacted(_prefix(full, 10))


# ---- 4. retention ---------------------------------------------------------------------


def test_retention_quiet_pass_and_reap_errors() raises:
    var fs = _FaultStore()
    _three_chunks(fs)
    var core = _core(fs)
    # Disabled: nothing is out of policy, nothing moves.
    var quiet = core.retention_pass_on_partition(RetentionPolicy.disabled(), Int64(9000))
    assert_equal(quiet.tombstoned_count, Int64(0))
    assert_equal(quiet.new_log_start_seq, Int64(0))
    assert_false(quiet.advanced_log_start)
    # At t=2600 with 500 ms retention, chunks 0 (t=1000) and 1 (t=2000) are
    # out of policy; chunk 2 is the active chunk and always kept.
    var r = core.retention_pass_on_partition(RetentionPolicy.time_based(Int64(500)), Int64(2600))
    assert_equal(r.tombstoned_count, Int64(2))
    assert_equal(r.new_log_start_offset, Int64(7))
    # Reap: chunk 0's body 404s (a reaper that got there first): it is
    # still reaped, and chunk 1 with it.
    var k0 = chunk_key(_PREFIX, Int64(0)).raw()
    fs.arm("get", k0, 0, 1, "not_found (404) injected")
    var reaped = core.reap_partition(Int64(100_000), Int64(1000))
    assert_equal(reaped.reaped_count, Int64(2))
    # Chunk 3 makes chunk 2 retirable; any other error reading chunk 2's
    # body stops the reaper before it reaps chunk 2.
    core.buffer_batch(_batch(Int64(12), 1), Int64(4000))
    _ = core.flush(Int64(4000))
    var r3 = core.retention_pass_on_partition(RetentionPolicy.time_based(Int64(500)), Int64(3600))
    assert_equal(r3.tombstoned_count, Int64(1))
    var k2 = chunk_key(_PREFIX, Int64(2)).raw()
    fs.arm("get", k2, 0, -1, "boom: reap read")
    with assert_raises(contains="boom: reap read"):
        _ = core.reap_partition(Int64(100_000), Int64(1000))
    fs.disarm("get")
    var again = core.reap_partition(Int64(100_000), Int64(1000))
    assert_equal(again.reaped_count, Int64(1))
    var after = _consumer(fs)
    var left = after.resolve_index()
    assert_equal(len(left), 1)
    assert_equal(left[0].chunk_seq, Int64(3))
    assert_equal(left[0].base_offset, Int64(12))


def main() raises:
    test_consume_core_errors_and_drains()
    test_compaction_index_decode_and_walk()
    test_extract_string_keys_int_values()
    test_sidecar_readers_on_every_body_generation()
    test_retention_quiet_pass_and_reap_errors()
    print("[OK] test_cov_consume_retention_unit")
