# =============================================================================
# tests/test_cov_cas_api.mojo
#   CasManifestStore's argument refusals, the deferred `_HEAD` cadence, the
#   sidecar / catalog verbs, and AsyncManifestAppendOp's take arms.
# =============================================================================
#
# What each case catches:
#   * a negative record_count / slot, or a stale writer lease, that is
#     accepted (an offset handed to a displaced writer) instead of refused
#     before any write;
#   * the deferred `_HEAD` advance never persisted (a cold reader then lags
#     the writer forever) or persisted every append (the cadence lost);
#   * read_head_fresh trusting a stale durable `_HEAD` on a cold handle;
#   * the sidecar verbs reading / writing the wrong key, the catalog CAS not
#     honouring its etag;
#   * AsyncManifestAppendOp.take mapping a deferred 412 to a raise (or a win)
#     instead of None, or swallowing a non-412 error.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)

from komira_objectstore.cas_manifest import (
    AsyncManifestAppendOp,
    CatalogSidecar,
    CasManifestStore,
    LIFECYCLE_PUBLISHED,
    LIFECYCLE_SCHEDULED_FOR_DELETE,
    LIFECYCLE_STAGED,
    ManifestHead,
    RetryPolicy,
    decode_chunk_body,
    decode_head,
    encode_chunk,
    head_key,
    is_lease_fenced,
    lifecycle_name,
)
from komira_objectstore.delimiter_faithful_conditional_store import (
    DelimiterFaithfulConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)
from komira_objectstore.store import (
    AsyncCasStore,
    CasOpProgress,
    CasReadResult,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


def _body(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((i * 7) & 0xFF))
    return out^


def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _manifest(shared: SharedInMemoryConditionalStore, prefix: String) -> CasManifestStore[SharedInMemoryConditionalStore]:
    return CasManifestStore[SharedInMemoryConditionalStore](
        store=shared.clone(), prefix=prefix, retry=RetryPolicy.fast_test()
    )


def _n_objects(shared: SharedInMemoryConditionalStore) raises -> Int:
    return len(shared.list_with_delimiter(Path.parse(String(""))).objects)


# ---- refusals before any write ------------------------------------------------


def test_refusals_write_nothing() raises:
    var shared = SharedInMemoryConditionalStore()
    var m = _manifest(shared, String("a/ref"))
    var msgs = List[String]()
    try:
        _ = m.append(_body(4), Int64(-1))
    except e:
        msgs.append(String(e))
    try:
        _ = m.append(_body(4), Int64(1), Int64(2), Int64(3))
    except e:
        msgs.append(String(e))
    try:
        _ = m.try_append_at_seq(Int64(0), Int64(0), _body(4), Int64(-1))
    except e:
        msgs.append(String(e))
    try:
        _ = m.try_append_at_seq(Int64(-1), Int64(0), _body(4), Int64(1))
    except e:
        msgs.append(String(e))
    try:
        _ = m.try_append_at_seq(Int64(0), Int64(0), _body(4), Int64(1), Int64(4), Int64(5))
    except e:
        msgs.append(String(e))
    try:
        _ = m.async_append_build_chunk(Int64(0), _body(4), Int64(-1))
    except e:
        msgs.append(String(e))
    try:
        _ = m.async_append_build_chunk(Int64(-2), _body(4), Int64(1))
    except e:
        msgs.append(String(e))
    assert_equal(len(msgs), 7)
    assert_equal(msgs[0], String("CasManifestStore.append: negative record_count"))
    assert_true(msgs[1].find("lease_fenced") >= 0, msgs[1])
    assert_true(msgs[1].find("writer_lease_epoch 2 < current_lease_epoch 3") >= 0, msgs[1])
    assert_true(msgs[1].find("prefix=a/ref") >= 0, msgs[1])
    assert_true(is_lease_fenced(msgs[1]))
    assert_equal(msgs[2], String("CasManifestStore.try_append_at_seq: negative record_count"))
    assert_equal(msgs[3], String("CasManifestStore.try_append_at_seq: negative candidate_seq"))
    assert_true(msgs[4].find("lease_fenced") >= 0, msgs[4])
    assert_true(msgs[4].find("writer_lease_epoch 4 < current_lease_epoch 5") >= 0, msgs[4])
    assert_true(is_lease_fenced(msgs[4]))
    assert_equal(msgs[5], String("CasManifestStore.async_append_build_chunk: negative record_count"))
    assert_equal(msgs[6], String("CasManifestStore.async_append_build_chunk: negative candidate_seq"))
    assert_equal(_n_objects(shared), 0)
    # The lease edges admit: equal epochs, and a zero record count.
    var r = m.append(_body(4), Int64(0), Int64(3), Int64(3))
    assert_equal(r.chunk_seq, Int64(0))
    var w = m.try_append_at_seq(Int64(1), Int64(0), _body(4), Int64(1), Int64(5), Int64(5))
    assert_true(Bool(w))
    var built = m.async_append_build_chunk(Int64(0), _body(4), Int64(0))
    assert_true(built[0].raw().find("a/ref/manifest/") >= 0)


def test_decode_chunk_body_refuses_truncation() raises:
    var c = encode_chunk(_body(10), Int64(3))
    assert_equal(len(decode_chunk_body(c)), 10)
    # Drop the last body byte: the length field now overruns the chunk.
    _ = c.pop()
    var msg = String("")
    try:
        _ = decode_chunk_body(c)
    except e:
        msg = String(e)
    assert_equal(msg, String("cas_manifest: chunk body length exceeds chunk size"))


# ---- the deferred `_HEAD` advance ------------------------------------------------


def test_deferred_head_cadence() raises:
    var shared = SharedInMemoryConditionalStore()
    var m = _manifest(shared, String("a/cad"))
    for _ in range(65):
        _ = m.append(_body(2), Int64(1))
    # The cold first append advanced `_HEAD` to 0; the 64 warm appends since
    # deferred theirs.
    var hk = head_key(String("a/cad"))
    assert_equal(decode_head(shared.get(hk)).chunk_seq, Int64(0))
    # The 66th append starts with 64 deferred advances: it persists the tail
    # (slot 64, next offset 65) before appending.
    var r = m.append(_body(2), Int64(1))
    assert_equal(r.chunk_seq, Int64(65))
    var h = decode_head(shared.get(hk))
    assert_equal(h.chunk_seq, Int64(64))
    assert_equal(h.next_offset, Int64(65))
    # And the cadence restarts: the next 63 appends leave `_HEAD` at 64.
    for _ in range(63):
        _ = m.append(_body(2), Int64(1))
    assert_equal(decode_head(shared.get(hk)).chunk_seq, Int64(64))
    # A cold handle: read_head trusts the lagging `_HEAD`, read_head_fresh
    # goes to the bucket; a warm handle answers from its own cache.
    var cold = _manifest(shared, String("a/cad"))
    assert_equal(cold.read_head().chunk_seq, Int64(64))
    assert_equal(cold.read_head_fresh().chunk_seq, Int64(128))
    assert_equal(cold.read_head_fresh().next_offset, Int64(129))
    assert_equal(m.read_head_fresh().chunk_seq, Int64(128))
    assert_equal(m.read_head_fresh().next_offset, Int64(129))


# ---- sidecar and catalog verbs ----------------------------------------------------


def test_sidecar_and_catalog() raises:
    var shared = SharedInMemoryConditionalStore()
    var m = _manifest(shared, String("a/side"))
    m.put_object(String("a/side.avro"), _body(5))
    assert_equal(len(m.get_object(String("a/side.avro"))), 5)
    assert_equal(m.get_object(String("a/side.avro"))[1], UInt8(7))
    assert_equal(m.object_size(String("a/side.avro")), Int64(5))
    # The catalog: absent, created, CAS-advanced, a stale etag refused.
    var c0 = m.read_catalog_sidecar()
    assert_false(c0.present)
    assert_equal(len(c0.blob), 0)
    assert_equal(c0.etag, String(""))
    var abs = CatalogSidecar.absent()
    assert_false(abs.present)
    var c1 = m.cas_catalog_sidecar(_body(3), String(""))
    assert_true(c1.present)
    assert_true(c1.etag.byte_length() > 0)
    var r1 = m.read_catalog_sidecar()
    assert_true(r1.present)
    assert_equal(len(r1.blob), 3)
    assert_equal(r1.etag, c1.etag)
    var c2 = m.cas_catalog_sidecar(_body(4), c1.etag)
    assert_true(c2.etag != c1.etag)
    var stale = String("")
    try:
        _ = m.cas_catalog_sidecar(_body(6), c1.etag)
    except e:
        stale = String(e)
    assert_true(stale.find("precondition") >= 0, stale)
    var dup = String("")
    try:
        _ = m.cas_catalog_sidecar(_body(6), String(""))
    except e:
        dup = String(e)
    assert_true(dup.find("precondition") >= 0, dup)
    assert_equal(len(m.read_catalog_sidecar().blob), 4)
    # The gate was released on the refusals: a write-locked verb runs.
    _ = m.advance_log_start(Int64(0), Int64(0), String(""))


def test_discover_shard_ids_both_listing_shapes() raises:
    # Flat keys (an in-memory backend ignores the delimiter).
    var shared = SharedInMemoryConditionalStore()
    var m = _manifest(shared, String("a/flat"))
    assert_equal(len(m.discover_shard_ids(String("idx/meta"))), 0)
    _ = shared.put(Path.parse(String("idx/meta/_lineage/w1/manifest/0.chunk")), _body(1))
    _ = shared.put(Path.parse(String("idx/meta/_lineage/w1/_HEAD")), _body(1))
    _ = shared.put(Path.parse(String("idx/meta/_lineage/_base/_HEAD")), _body(1))
    _ = shared.put(Path.parse(String("idx/meta/_lineage/w2/_HEAD")), _body(1))
    var ids = m.discover_shard_ids(String("idx/meta"))
    assert_equal(len(ids), 3)
    assert_equal(ids[0], String("w1"))
    assert_equal(ids[1], String("_base"))
    assert_equal(ids[2], String("w2"))
    # Common prefixes (a delimiter-honouring backend).
    var df = DelimiterFaithfulConditionalStore()
    var dm = CasManifestStore[DelimiterFaithfulConditionalStore](
        store=df.clone(), prefix=String("a/df")
    )
    _ = df.put(Path.parse(String("idx/meta/_lineage/s1/_HEAD")), _body(1))
    _ = df.put(Path.parse(String("idx/meta/_lineage/s2/manifest/x")), _body(1))
    var dids = dm.discover_shard_ids(String("idx/meta"))
    assert_equal(len(dids), 2)
    assert_equal(dids[0], String("s1"))
    assert_equal(dids[1], String("s2"))


def test_value_helpers() raises:
    var e = ManifestHead.empty()
    assert_equal(e.chunk_seq, Int64(-1))
    assert_equal(e.next_offset, Int64(0))
    assert_equal(e.etag_of_last_chunk, String(""))
    var d = RetryPolicy.default()
    assert_equal(d.base_us, Int64(5_000))
    assert_equal(d.cap_us, Int64(250_000))
    assert_equal(d.max_retries, 8)
    var b = RetryPolicy.broker_contention()
    assert_equal(b.base_us, Int64(500))
    assert_equal(b.cap_us, Int64(100_000))
    assert_equal(b.max_retries, 40)
    assert_equal(lifecycle_name(LIFECYCLE_STAGED), String("Staged"))
    assert_equal(lifecycle_name(LIFECYCLE_PUBLISHED), String("Published"))
    assert_equal(lifecycle_name(LIFECYCLE_SCHEDULED_FOR_DELETE), String("ScheduledForDelete"))
    assert_equal(lifecycle_name(UInt8(9)), String("Unknown"))


# ---- AsyncManifestAppendOp.take --------------------------------------------------


struct _Deferred412Store(AsyncCasStore, ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    """A parkable conformer that reports a lost create only at `cas_put_take`
    (the shape `take`'s defense-in-depth arm is for)."""

    var inner: SharedInMemorySlowCasStore
    var defer_412: Bool

    def __init__(out self, var inner: SharedInMemorySlowCasStore):
        self.inner = inner^
        self.defer_412 = False

    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
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
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)

    def read_start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, path: Path, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self.inner.read_start[S](path, reactor)

    def read_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self.inner.read_poll[S](reactor)

    def read_take(mut self) raises -> CasReadResult:
        return self.inner.read_take()

    def cas_put_start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self,
        path: Path,
        var bytes: List[UInt8],
        expected_etag: String,
        mut reactor: Reactor[S],
    ) raises -> CasOpProgress:
        if self.defer_412:
            # Report READY without writing; the loss surfaces at take.
            return CasOpProgress.ready()
        return self.inner.cas_put_start[S](path, bytes^, expected_etag, reactor)

    def cas_put_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self.inner.cas_put_poll[S](reactor)

    def cas_put_take(mut self) raises -> ObjectMeta:
        if self.defer_412:
            raise Error("precondition (412) — slot taken (reported at take)")
        return self.inner.cas_put_take()


def test_async_take_arms() raises:
    var reactor = _new_reactor()
    var slow = SharedInMemorySlowCasStore(slow_ticks=0)
    var wal = CasManifestStore[_Deferred412Store](
        store=_Deferred412Store(slow.clone()), prefix=String("a/async")
    )
    # A clean win: take returns the slot and advances `_HEAD`.
    var op = AsyncManifestAppendOp[_Deferred412Store]()
    assert_true(op.start[NoopSink](wal, Int64(0), Int64(0), _body(3), Int64(2), reactor).is_ready())
    var won = op.take(wal)
    assert_true(Bool(won))
    assert_equal(won.value().chunk_seq, Int64(0))
    assert_equal(won.value().last_offset, Int64(1))
    # A 412 reported only at take: None (lost), not a raise, not a win.
    wal.store_mut().defer_412 = True
    var lost = AsyncManifestAppendOp[_Deferred412Store]()
    assert_true(lost.start[NoopSink](wal, Int64(1), Int64(2), _body(3), Int64(1), reactor).is_ready())
    var r = lost.take(wal)
    assert_false(Bool(r))
    wal.store_mut().defer_412 = False
    # A resumed op whose conformer holds no result: take raises the
    # conformer's error (not a 412), it is not read as a lost slot.
    var resumed = AsyncManifestAppendOp[_Deferred412Store].resume_inflight(
        Int64(1), Int64(2), Int64(1)
    )
    var msg = String("")
    try:
        _ = resumed.take(wal)
    except e:
        msg = String(e)
    assert_true(msg.find("put not ready") >= 0, msg)
    # A resumed op over a completed create finishes it.
    _ = wal.store_mut().inner.cas_put_start[NoopSink](
        Path.parse(String("a/async/manifest/00000000000000000001.chunk")),
        encode_chunk(_body(3), Int64(1)), String(""), reactor,
    )
    var resumed2 = AsyncManifestAppendOp[_Deferred412Store].resume_inflight(
        Int64(1), Int64(2), Int64(1)
    )
    var r2 = resumed2.take(wal)
    assert_true(Bool(r2))
    assert_equal(r2.value().chunk_seq, Int64(1))
    assert_equal(r2.value().base_offset, Int64(2))
    assert_equal(r2.value().last_offset, Int64(2))
    assert_equal(wal.read_head_authoritative().chunk_seq, Int64(1))


def main() raises:
    test_refusals_write_nothing()
    test_decode_chunk_body_refuses_truncation()
    test_deferred_head_cadence()
    test_sidecar_and_catalog()
    test_discover_shard_ids_both_listing_shapes()
    test_value_helpers()
    test_async_take_arms()
    print("[test_cov_cas_api] PASS")
