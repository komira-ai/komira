# =============================================================================
# tests/test_cov_broker_core_unit.mojo
#   BrokerCore: the segment footer and topic-config codecs, the flush
#   triggers, every empty-buffer refusal, the segment re-key budget, the
#   per-producer sequence cache and the exactly-once outcomes, on both the
#   consolidated manifest and a sub-lineage.
# =============================================================================
#
#   1. SegmentFooter.decode refuses a short object, a bad magic and an
#      unknown version; the u32/i64 readers refuse a short read;
#      encode_segment / assemble_segment_from_frames refuse an empty buffer.
#   2. BrokerTopicConfig: quotes and backslashes in names round-trip, two
#      partition-by keys, copy(), and each malformed document is refused
#      with its own message.
#   3. produce: a young buffer below the byte trigger is not flushed; a
#      buffer at FLUSH_BYTES is; an empty buffer never asks for a flush.
#   4. Every flush verb refuses an empty buffer; the segment PUT gives up
#      after eight colliding keys.
#   5. The sequence cache ignores a negative producer, never moves back,
#      and answers a non-authoritative recover; an empty manifest recovers -1.
#   6. flush_with_producer_exactly_once: DUPLICATE returns the recorded
#      offsets, FENCED and RETRYABLE write nothing.
#   7. Sub-lineage: an empty shard id is refused; recover scans the shard's
#      own lineage, skips a chunk that 404s, and propagates any other error.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_collections.slab import Slab

from komira_broker.broker_core import (
    BrokerCore,
    BrokerTopicConfig,
    EO_COMMITTED,
    EO_DUPLICATE,
    EO_FENCED,
    EO_RETRYABLE,
    FLUSH_BYTES,
    SegmentFooter,
    _bytes_find,
    _get_i64_le,
    _get_u32_le,
    assemble_segment_from_frames,
    encode_segment,
)
from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    chunk_key,
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


comptime _PRE = "precondition (412) injected"
comptime _PREFIX = "c/_meta/topics/t/0"


def _schema() -> Schema:
    return Schema(
        names=[String("val")],
        arrow_types=[ArrowType.INT64.type_id],
        dtypes=[DType.int64],
        nullables=[False],
    )


def _batch(base_val: Int64, n: Int) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        p.store[width=1](i, base_val + Int64(i))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(_schema(), col^)


def _core(fs: _FaultStore) raises -> BrokerCore[_FaultStore]:
    var manifest = CasManifestStore[_FaultStore](
        store=fs.clone(), prefix=String(_PREFIX), retry=RetryPolicy.fast_test()
    )
    return BrokerCore[_FaultStore](
        segment_store=fs.clone(),
        manifest=manifest^,
        cluster=String("c"),
        topic=String("t"),
        partition=Int64(0),
        broker_id=String("b0"),
    )


def _enable_shard(mut core: BrokerCore[_FaultStore], fs: _FaultStore, shard: String) raises:
    var sub = CasManifestStore[_FaultStore](
        store=fs.clone(),
        prefix=core.sublineage_prefix_for(shard),
        retry=RetryPolicy.fast_test(),
    )
    core.enable_sublineage_write(shard, sub^)


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


# ---- 1. segment codec refusals ------------------------------------------------


def test_segment_footer_refusals() raises:
    var good = SegmentFooter(Int64(1), Int64(2), Int64(3), UInt32(4)).encode()
    var back = SegmentFooter.decode(good)
    assert_equal(back.record_count, Int64(3))
    var short = List[UInt8]()
    for i in range(39):
        short.append(good[i])
    with assert_raises(contains="object too small (39 bytes)"):
        _ = SegmentFooter.decode(short)
    var bad_magic = good.copy()
    bad_magic[0] = UInt8(0)
    with assert_raises(contains="SegmentFooter.decode: bad magic 0x"):
        _ = SegmentFooter.decode(bad_magic)
    var bad_ver = good.copy()
    bad_ver[4] = UInt8(2)
    with assert_raises(contains="unsupported footer version 2"):
        _ = SegmentFooter.decode(bad_ver)
    with assert_raises(contains="encode_segment: empty batch buffer"):
        _ = encode_segment(Slab[RecordBatch](), Int64(0))
    with assert_raises(contains="assemble_segment_from_frames: empty frame list"):
        _ = assemble_segment_from_frames(
            _schema(), List[List[UInt8]](), Int64(0), Int64(0)
        )
    # The footer readers' own bounds checks (decode checks the length first,
    # so they are driven directly): an exact fit reads, one byte short raises.
    var raw = List[UInt8]()
    for k in range(8):
        raw.append(UInt8(k + 1))
    assert_equal(_get_u32_le(raw, 4), UInt32(0x08070605))
    assert_equal(_get_i64_le(raw, 0), Int64(0x0807060504030201))
    with assert_raises(contains="segment footer: truncated u32 at 5"):
        _ = _get_u32_le(raw, 5)
    with assert_raises(contains="segment footer: truncated i64 at 1"):
        _ = _get_i64_le(raw, 1)


# ---- 2. topic config ----------------------------------------------------------


def test_topic_config_round_trip_and_copy() raises:
    var pb = List[String]()
    pb.append(String('a"b'))
    pb.append(String("c\\d"))
    var cfg = BrokerTopicConfig(
        num_partitions=3, partition_by=pb^, schema=_schema(), retention_ms=Int64(5)
    )
    var c2 = cfg.copy()
    assert_equal(c2.num_partitions, 3)
    assert_equal(c2.retention_ms, Int64(5))
    assert_equal(len(c2.partition_by), 2)
    var enc = cfg.encode()
    var dec = BrokerTopicConfig.decode(enc)
    assert_equal(dec.num_partitions, 3)
    assert_equal(len(dec.partition_by), 2)
    assert_equal(dec.partition_by[0], 'a"b')
    assert_equal(dec.partition_by[1], "c\\d")
    assert_equal(dec.schema.num_columns(), 1)
    assert_equal(dec.schema.field_name(0), "val")
    assert_equal(dec.retention_ms, Int64(5))


def _int64_id() -> String:
    return String(Int(ArrowType.INT64.type_id))


def test_topic_config_malformed() raises:
    var col = '{"name":"x","arrow_type":' + _int64_id() + ',"nullable":false}'
    # Spaces before an integer and around the partition-by items are skipped;
    # a non-string item ends the list.
    var spaced = BrokerTopicConfig.decode(
        _bytes_of(
            '{"num_partitions":  4,"partition_by":[ "a" , "b"],"schema":['
            + col + "]}"
        )
    )
    assert_equal(spaced.num_partitions, 4)
    assert_equal(len(spaced.partition_by), 2)
    assert_equal(spaced.partition_by[1], "b")
    var bare = BrokerTopicConfig.decode(
        _bytes_of('{"num_partitions":1,"partition_by":["a",7],"schema":[' + col + "]}")
    )
    assert_equal(len(bare.partition_by), 1)
    with assert_raises(contains="missing 'num_partitions' field"):
        _ = BrokerTopicConfig.decode(_bytes_of('{"partition_by":[],"schema":[]}'))
    with assert_raises(contains="missing 'partition_by' field"):
        _ = BrokerTopicConfig.decode(_bytes_of('{"num_partitions":1,"schema":[]}'))
    with assert_raises(contains="missing 'schema' field"):
        _ = BrokerTopicConfig.decode(
            _bytes_of('{"num_partitions":1,"partition_by":[]}')
        )
    with assert_raises(contains="column missing 'arrow_type'"):
        _ = BrokerTopicConfig.decode(
            _bytes_of(
                '{"num_partitions":1,"partition_by":[],"schema":[{"name":"x","nullable":false}]}'
            )
        )
    with assert_raises(contains="column missing 'nullable'"):
        _ = BrokerTopicConfig.decode(
            _bytes_of(
                '{"num_partitions":1,"partition_by":[],"schema":[{"name":"x","arrow_type":'
                + _int64_id() + "}]}"
            )
        )
    with assert_raises(contains="BrokerTopicConfig.decode: expected integer at"):
        _ = BrokerTopicConfig.decode(
            _bytes_of('{"num_partitions":x,"partition_by":[],"schema":[]}')
        )
    # The byte search: an empty needle matches where the search starts.
    assert_equal(_bytes_find(_bytes_of("abc"), List[UInt8](), 2), 2)


# ---- 3. produce triggers --------------------------------------------------------


def test_produce_triggers() raises:
    var fs = _FaultStore()
    var core = _core(fs)
    # Young and small: buffered, not flushed.
    assert_false(core.produce(_batch(0, 4), Int64(1000)))
    assert_false(core.produce(_batch(4, 4), Int64(1100)))
    assert_equal(core.buffered_batches(), 2)
    # The estimate is 8 bytes a row plus 256 a batch: the two small batches
    # hold 2 * 288 bytes. A third batch that brings the buffer to exactly
    # FLUSH_BYTES flushes at once, still young.
    var rows = (FLUSH_BYTES - 2 * 288 - 256) // 8
    var r = core.produce(_batch(8, rows), Int64(1100))
    assert_true(r)
    assert_equal(r.value().record_count, Int64(8 + rows))
    assert_equal(core.buffered_batches(), 0)
    # An empty buffer never asks for a flush, however late the clock.
    assert_false(core._should_flush(Int64.MAX))


# ---- 4. empty-buffer refusals and the re-key budget -------------------------------


def test_empty_buffer_refusals() raises:
    var fs = _FaultStore()
    var core = _core(fs)
    with assert_raises(contains="BrokerCore.flush: empty buffer"):
        _ = core.flush(Int64(1))
    assert_false(core.flush_if_buffered(Int64(1)))
    with assert_raises(contains="flush_with_producer: empty buffer"):
        _ = core.flush_with_producer(Int64(1), Int64(1), Int64(0), Int64(0), Int64(0))
    with assert_raises(contains="flush_with_producer_exactly_once: empty buffer"):
        _ = core.flush_with_producer_exactly_once(
            Int64(1), Int64(1), Int64(0), Int64(0), Int64(0), Int64(0)
        )
    with assert_raises(contains="flush_with_producer_txn: empty buffer"):
        _ = core.flush_with_producer_txn(
            Int64(1), Int64(1), Int64(0), Int64(0), Int64(0), "x"
        )


def test_segment_rekey_budget() raises:
    var fs = _FaultStore()
    var core = _core(fs)
    # Seven collisions: the eighth key lands.
    fs.arm("cput", "/segments/", 0, 7, _PRE)
    core.buffer_batch(_batch(0, 2), Int64(5))
    var r = core.flush(Int64(5))
    assert_true(r.segment_key.endswith("-8.seg"))
    # Eight collisions: no key lands, nothing is committed.
    fs.arm("cput", "/segments/", 0, 8, _PRE)
    core.buffer_batch(_batch(2, 2), Int64(6))
    with assert_raises(contains="exhausted segment-key re-key attempts"):
        _ = core.flush(Int64(6))
    fs.disarm("cput")
    core.buffer_batch(_batch(4, 2), Int64(7))
    var r2 = core.flush(Int64(7))
    assert_equal(r2.base_offset, Int64(2))
    assert_equal(r2.chunk_seq, Int64(1))


# ---- 5. the per-producer sequence cache ---------------------------------------------


def test_sequence_cache() raises:
    var fs = _FaultStore()
    var core = _core(fs)
    # Nothing committed, nothing cached: -1 from the (empty) manifest.
    assert_equal(core.recover_last_committed_seq(Int64(3)), Int64(-1))
    core.note_committed_seq(Int64(-1), Int64(5))
    assert_false(core.producer_seq_is_cached(Int64(-1)))
    core.note_committed_seq(Int64(7), Int64(5))
    core.note_committed_seq(Int64(8), Int64(1))
    core.note_committed_seq(Int64(7), Int64(3))
    assert_true(core.producer_seq_is_cached(Int64(7)))
    assert_equal(core.recover_last_committed_seq(Int64(7)), Int64(5))
    core.note_committed_seq(Int64(7), Int64(9))
    assert_equal(core.recover_last_committed_seq(Int64(7)), Int64(9))
    assert_equal(core.recover_last_committed_seq(Int64(8)), Int64(1))
    # Authoritative skips the cache and reads the (empty) manifest.
    assert_equal(
        core.recover_last_committed_seq(Int64(7), authoritative=True), Int64(-1)
    )


# ---- 6. exactly-once outcomes -------------------------------------------------------


def test_exactly_once_outcomes() raises:
    var fs = _FaultStore()
    var core = _core(fs)
    core.buffer_batch(_batch(0, 3), Int64(10))
    var c = core.flush_with_producer_exactly_once(
        Int64(10), Int64(4), Int64(1), Int64(0), Int64(2), Int64(1)
    )
    assert_equal(c.outcome, EO_COMMITTED)
    # The same batch again: DUPLICATE with the recorded offsets.
    var other = _core(fs)
    core.buffer_batch(_batch(0, 3), Int64(11))
    var d = core.flush_with_producer_exactly_once(
        Int64(11), Int64(4), Int64(1), Int64(0), Int64(2), Int64(1)
    )
    assert_equal(d.outcome, EO_DUPLICATE)
    assert_equal(d.base_offset, Int64(0))
    assert_equal(d.last_offset, Int64(2))
    assert_equal(d.chunk_seq, c.chunk_seq)
    # A duplicate seen by a core that never cached the producer seeds it.
    other.buffer_batch(_batch(0, 3), Int64(12))
    var d2 = other.flush_with_producer_exactly_once(
        Int64(12), Int64(4), Int64(1), Int64(0), Int64(2), Int64(1)
    )
    assert_equal(d2.outcome, EO_DUPLICATE)
    assert_true(other.producer_seq_is_cached(Int64(4)))
    assert_equal(other.recover_last_committed_seq(Int64(4)), Int64(2))
    # A zombie epoch: FENCED, no offsets.
    core.buffer_batch(_batch(3, 1), Int64(13))
    var f = core.flush_with_producer_exactly_once(
        Int64(13), Int64(4), Int64(0), Int64(3), Int64(3), Int64(1)
    )
    assert_equal(f.outcome, EO_FENCED)
    assert_equal(f.base_offset, Int64(-1))
    assert_equal(f.chunk_seq, Int64(-1))
    # A lost claim with no claim behind it: RETRYABLE, no offsets.
    fs.arm("cput", "/_meta/dedup/", 0, 1, _PRE)
    core.buffer_batch(_batch(3, 1), Int64(14))
    var r = core.flush_with_producer_exactly_once(
        Int64(14), Int64(4), Int64(1), Int64(3), Int64(3), Int64(1)
    )
    assert_equal(r.outcome, EO_RETRYABLE)
    assert_equal(r.base_offset, Int64(-1))
    assert_equal(r.record_count, Int64(0))
    # Only the first batch was ever committed.
    assert_equal(
        core.recover_last_committed_seq(Int64(4), authoritative=True), Int64(2)
    )


# ---- 7. sub-lineage -------------------------------------------------------------------


def test_sublineage_recover() raises:
    var fs = _FaultStore()
    var core = _core(fs)
    with assert_raises(contains="shard_id must be non-empty"):
        _enable_shard(core, fs, "")
    assert_false(core.sublineage_write_enabled())
    _enable_shard(core, fs, "s1")
    # Empty shard lineage.
    assert_equal(
        core.recover_last_committed_seq(Int64(1), authoritative=True), Int64(-1)
    )
    core.buffer_batch(_batch(0, 2), Int64(1))
    var a = core.flush_with_producer_exactly_once(
        Int64(1), Int64(1), Int64(0), Int64(0), Int64(1), Int64(0)
    )
    assert_equal(a.outcome, EO_COMMITTED)
    core.buffer_batch(_batch(2, 2), Int64(2))
    var b = core.flush_with_producer_exactly_once(
        Int64(2), Int64(2), Int64(0), Int64(0), Int64(1), Int64(0)
    )
    assert_equal(b.outcome, EO_COMMITTED)
    assert_equal(b.chunk_seq, Int64(1))
    var sub_prefix = core.sublineage_prefix_for("s1")
    # Nothing landed on the consolidated manifest.
    assert_equal(
        len(fs.inner.list_with_delimiter(Path.parse(_PREFIX + "/manifest/")).objects),
        0,
    )
    # Found in the shard lineage (authoritative and cache-cold reads).
    assert_equal(
        core.recover_last_committed_seq(Int64(1), authoritative=True), Int64(1)
    )
    # A cache-cold core reads the _HEAD object (advanced best-effort, so it
    # may lag): chunk 0 is below any head it can read.
    var cold = _core(fs)
    _enable_shard(cold, fs, "s1")
    assert_equal(cold.recover_last_committed_seq(Int64(1)), Int64(1))
    assert_equal(cold.recover_last_committed_seq(Int64(9)), Int64(-1))
    # A chunk that 404s mid-walk is skipped; the walk goes on below it. The
    # authoritative head (a LIST that reads each chunk once) passes first.
    var top = chunk_key(sub_prefix, Int64(1)).raw()
    fs.arm("get", top, 1, 1, "not_found (404) injected")
    assert_equal(
        core.recover_last_committed_seq(Int64(1), authoritative=True), Int64(1)
    )
    fs.arm("get", top, 1, 1, "boom: chunk read")
    with assert_raises(contains="boom: chunk read"):
        _ = core.recover_last_committed_seq(Int64(1), authoritative=True)


def main() raises:
    test_segment_footer_refusals()
    test_topic_config_round_trip_and_copy()
    test_topic_config_malformed()
    test_produce_triggers()
    test_empty_buffer_refusals()
    test_segment_rekey_budget()
    test_sequence_cache()
    test_exactly_once_outcomes()
    test_sublineage_recover()
    print("[OK] test_cov_broker_core_unit")
