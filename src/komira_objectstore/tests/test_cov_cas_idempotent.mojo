# =============================================================================
# tests/test_cov_cas_idempotent.mojo
#   CasManifestStore.append_idempotent: every outcome of the exactly-once
#   protocol, including the retry of a committed batch.
# =============================================================================
#
# The chunk bodies here carry the producer trailer `_body_matches_producer_
# batch` reads (record_count i64, crc u32, key_len i64, key, 16-byte retention
# trailer, then producer_id, epoch, first_seq, last_seq), so the tail scan can
# recognise a batch. `_FaultStore` scripts backend faults (RAISE; AFTER: the
# write lands, then the call raises, a lost response; PREPUT: replace the
# object just before a GET, another writer acting in between).
#
# What each case catches:
#   * a retry of a committed batch that appends a second copy, or acks an
#     offset other than the one first committed (DUPLICATE must repeat it);
#   * a staged sentinel finalized wrongly: not healed to committed, or healed
#     when it vanished or was already committed;
#   * a staged claim with no durable chunk acked as DUPLICATE (must be
#     RETRYABLE), a vanished sentinel not RETRYABLE;
#   * a lost response on the chunk append re-raised (the client's retry would
#     double-write) instead of COMMITTED at the chunk that landed;
#   * the producer-epoch and lease fences writing anything;
#   * a non-412 store error swallowed anywhere in the protocol.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    DedupSentinel,
    IDEMPOTENT_COMMITTED,
    IDEMPOTENT_DUPLICATE,
    IDEMPOTENT_FENCED,
    IDEMPOTENT_LEASE_FENCED,
    IDEMPOTENT_RETRYABLE,
    RetryPolicy,
    dedup_sentinel_key,
    encode_dedup_sentinel,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


# ---- the fault-injecting backend ------------------------------------------

comptime V_PUT = 0
comptime V_GET = 1
comptime V_HEAD = 2

comptime M_RAISE = 0
comptime M_AFTER = 1
comptime M_PREPUT = 2


@fieldwise_init
struct _Rule(Copyable, Movable):
    var verb: Int
    var key_sub: String
    var mode: Int
    var msg: String
    var skip: Int
    var times: Int
    var payload: List[UInt8]


struct _Rules(Movable):
    var rules: List[_Rule]
    var fired: Int

    def __init__(out self):
        self.rules = List[_Rule]()
        self.fired = 0


struct _FaultStore(ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    var inner: SharedInMemoryConditionalStore
    var rules: ArcPointer[_Rules]

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var rules: ArcPointer[_Rules],
    ):
        self.inner = inner^
        self.rules = rules^

    def _match(self, verb: Int, key: String) -> Int:
        ref r = self.rules[]
        for i in range(len(r.rules)):
            ref rule = r.rules[i]
            if rule.verb != verb or rule.times == 0:
                continue
            if key.find(rule.key_sub) < 0:
                continue
            if rule.skip > 0:
                rule.skip -= 1
                return -1
            if rule.times > 0:
                rule.times -= 1
            r.fired += 1
            return i
        return -1

    def head(self, path: Path) raises -> ObjectMeta:
        var i = self._match(V_HEAD, path.raw())
        if i >= 0:
            raise Error(self.rules[].rules[i].msg + " key=" + path.raw())
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return CoalescePolicy.default()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        var i = self._match(V_PUT, path.raw())
        if i < 0:
            return self.inner.conditional_put(path, bytes, precond)
        if self.rules[].rules[i].mode == M_AFTER:
            _ = self.inner.conditional_put(path, bytes, precond)
        raise Error(self.rules[].rules[i].msg + " key=" + path.raw())

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.conditional_put(
            path, bytes, WritePrecondition.if_match(expected_version)
        )

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self.conditional_put(path, bytes, WritePrecondition.none())

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        var i = self._match(V_GET, path.raw())
        if i >= 0:
            if self.rules[].rules[i].mode == M_PREPUT:
                _ = self.inner.put(path, self.rules[].rules[i].payload.copy())
            else:
                raise Error(self.rules[].rules[i].msg + " key=" + path.raw())
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)


comptime TRANSPORT = "StoreError[TRANSPORT] connection reset status=503"
comptime GONE = "not_found (404) injected"


def _rule(verb: Int, key_sub: String, msg: String, times: Int = 1, skip: Int = 0, mode: Int = M_RAISE) -> _Rule:
    return _Rule(verb, key_sub, mode, msg, skip, times, List[UInt8]())


struct _Fixture(Movable):
    var shared: SharedInMemoryConditionalStore
    var rules: ArcPointer[_Rules]
    var m: CasManifestStore[_FaultStore]

    def __init__(out self, prefix: String):
        self.shared = SharedInMemoryConditionalStore()
        self.rules = ArcPointer[_Rules](_Rules())
        self.m = CasManifestStore[_FaultStore](
            store=_FaultStore(self.shared.clone(), self.rules.copy()),
            prefix=prefix,
            retry=RetryPolicy.fast_test(),
        )

    def add(mut self, var r: _Rule):
        self.rules[].rules.append(r^)

    def fired(self) -> Int:
        return self.rules[].fired

    def n_chunks(self) raises -> Int:
        return len(
            self.shared.list_with_delimiter(
                Path.parse(self.m.prefix() + "/manifest/")
            ).objects
        )

    def sentinel(self, pid: Int64, first: Int64) raises -> DedupSentinel:
        var s = self.m.read_dedup_sentinel(pid, first)
        if not s:
            raise Error("no sentinel for the batch")
        return s.value().copy()


# ---- bodies carrying the producer trailer ------------------------------------


def _put_i64(mut out: List[UInt8], v: Int64):
    for i in range(8):
        out.append(UInt8((Int(v) >> (8 * i)) & 0xFF))


def _batch_body(pid: Int64, epoch: Int64, first: Int64, last: Int64) -> List[UInt8]:
    var out = List[UInt8]()
    _put_i64(out, last - first + 1)  # record_count
    for _ in range(4):  # crc32
        out.append(UInt8(0))
    _put_i64(out, Int64(3))  # key_len
    out.append(UInt8(ord("k")))
    out.append(UInt8(ord("e")))
    out.append(UInt8(ord("y")))
    for _ in range(16):  # retention trailer
        out.append(UInt8(0))
    _put_i64(out, pid)
    _put_i64(out, epoch)
    _put_i64(out, first)
    _put_i64(out, last)
    return out^


def _append(
    mut m: CasManifestStore[_FaultStore], pid: Int64, first: Int64, n: Int64,
    epoch: Int64 = Int64(1), registered: Int64 = Int64(1),
    wl: Int64 = Int64(0), cl: Int64 = Int64(0),
) raises -> IdempotentAppendResultView:
    var r = m.append_idempotent(
        _batch_body(pid, epoch, first, first + n - 1), n, pid, epoch, first,
        first + n - 1, registered, wl, cl,
    )
    return IdempotentAppendResultView(
        r.outcome, r.chunk_seq, r.base_offset, r.last_offset
    )


@fieldwise_init
struct IdempotentAppendResultView(Copyable, Movable):
    var outcome: Int
    var chunk_seq: Int64
    var base_offset: Int64
    var last_offset: Int64


# ---- the retry of a committed batch ---------------------------------------------


def test_retry_of_committed_batch_is_duplicate() raises:
    var f = _Fixture(String("i/dup"))
    _ = _append(f.m, Int64(7), Int64(0), Int64(2))  # offsets 0..1 at slot 0
    var first = _append(f.m, Int64(7), Int64(2), Int64(3))  # 2..4 at slot 1
    assert_equal(first.outcome, IDEMPOTENT_COMMITTED)
    assert_equal(first.chunk_seq, Int64(1))
    # The hot path leaves the claim STAGED (no finalize write).
    assert_false(f.sentinel(Int64(7), Int64(2)).committed_chunk_seq >= Int64(0))
    # Retry: the claim 412s, the sentinel is staged, the tail scan finds the
    # batch's chunk: DUPLICATE at the SAME slot and offsets, no new chunk.
    var again = _append(f.m, Int64(7), Int64(2), Int64(3))
    assert_equal(again.outcome, IDEMPOTENT_DUPLICATE)
    assert_equal(again.chunk_seq, Int64(1))
    assert_equal(again.base_offset, Int64(2))
    assert_equal(again.last_offset, Int64(4))
    assert_equal(f.n_chunks(), 2)
    # The scan healed the sentinel forward to the committed location.
    var s = f.sentinel(Int64(7), Int64(2))
    assert_equal(s.committed_chunk_seq, Int64(1))
    assert_equal(s.base_offset, Int64(2))
    assert_equal(s.last_offset, Int64(4))
    assert_equal(s.producer_id, Int64(7))
    assert_equal(s.producer_epoch, Int64(1))
    assert_equal(s.first_seq, Int64(2))
    assert_equal(s.last_seq, Int64(4))
    assert_true(s.etag.byte_length() > 0)
    # A third retry reads the committed sentinel directly: same answer.
    var third = _append(f.m, Int64(7), Int64(2), Int64(3))
    assert_equal(third.outcome, IDEMPOTENT_DUPLICATE)
    assert_equal(third.chunk_seq, Int64(1))
    assert_equal(third.base_offset, Int64(2))
    assert_equal(third.last_offset, Int64(4))
    assert_equal(f.n_chunks(), 2)


def test_scan_skips_other_batches_and_short_bodies() raises:
    var f = _Fixture(String("i/scan"))
    _ = _append(f.m, Int64(1), Int64(0), Int64(2))  # slot 0: other producer
    # A body too short for the producer trailer (a non-idempotent writer's
    # chunk) never matches and is skipped.
    var short = List[UInt8]()
    for _ in range(24):
        short.append(UInt8(0))
    _ = f.m.append(short, Int64(0))  # slot 1: zero records
    _ = _append(f.m, Int64(2), Int64(0), Int64(1))  # slot 2: same first_seq, other pid
    _ = _append(f.m, Int64(1), Int64(5), Int64(1))  # slot 3: same pid, other first
    _ = _append(f.m, Int64(2), Int64(1), Int64(4))  # slot 4: the batch (offsets 4..7)
    _ = _append(f.m, Int64(3), Int64(0), Int64(1))  # slot 5: a later batch
    # The scan passes a short body and three near-misses (other pid, other
    # first_seq) and answers the batch's own slot and offsets.
    var again = _append(f.m, Int64(2), Int64(1), Int64(4))
    assert_equal(again.outcome, IDEMPOTENT_DUPLICATE)
    assert_equal(again.chunk_seq, Int64(4))
    assert_equal(again.base_offset, Int64(4))
    assert_equal(again.last_offset, Int64(7))
    assert_equal(f.n_chunks(), 6)


def test_staged_claim_without_chunk_is_retryable() raises:
    var f = _Fixture(String("i/stg"))
    # A claim staged by a writer that died before its chunk landed.
    _ = f.shared.put(
        dedup_sentinel_key(String("i/stg"), Int64(9), Int64(0)),
        encode_dedup_sentinel(DedupSentinel.staged(Int64(9), Int64(1), Int64(0), Int64(0))),
    )
    # Empty manifest: nothing to scan.
    var r1 = _append(f.m, Int64(9), Int64(0), Int64(1))
    assert_equal(r1.outcome, IDEMPOTENT_RETRYABLE)
    assert_equal(r1.chunk_seq, Int64(-1))
    assert_equal(r1.base_offset, Int64(-1))
    assert_equal(f.n_chunks(), 0)
    # Non-empty manifest of other batches: scanned, no match, still RETRYABLE.
    _ = _append(f.m, Int64(3), Int64(0), Int64(2))
    var r2 = _append(f.m, Int64(9), Int64(0), Int64(1))
    assert_equal(r2.outcome, IDEMPOTENT_RETRYABLE)
    assert_equal(f.n_chunks(), 1)
    # The claim is left as it was (staged), never healed to a guess.
    assert_false(f.sentinel(Int64(9), Int64(0)).committed_chunk_seq >= Int64(0))


def test_non_idempotent_producer_never_matches() raises:
    var f = _Fixture(String("i/neg"))
    _ = _append(f.m, Int64(-1), Int64(0), Int64(1))
    # producer_id -1 is the non-idempotent sentinel: its chunk never matches,
    # so a retry is RETRYABLE, never a DUPLICATE of some chunk.
    var again = _append(f.m, Int64(-1), Int64(0), Int64(1))
    assert_equal(again.outcome, IDEMPOTENT_RETRYABLE)


def test_fences_write_nothing() raises:
    var f = _Fixture(String("i/fence"))
    var z = _append(f.m, Int64(4), Int64(0), Int64(1), epoch=Int64(2), registered=Int64(3))
    assert_equal(z.outcome, IDEMPOTENT_FENCED)
    assert_equal(z.chunk_seq, Int64(-1))
    assert_equal(z.base_offset, Int64(-1))
    assert_equal(z.last_offset, Int64(-1))
    var l = _append(f.m, Int64(4), Int64(0), Int64(1), wl=Int64(5), cl=Int64(6))
    assert_equal(l.outcome, IDEMPOTENT_LEASE_FENCED)
    assert_equal(l.chunk_seq, Int64(-1))
    assert_equal(f.n_chunks(), 0)
    assert_false(Bool(f.m.read_dedup_sentinel(Int64(4), Int64(0))))
    # At the fence edges (equal epochs) the append is admitted.
    var ok = _append(f.m, Int64(4), Int64(0), Int64(1), epoch=Int64(3), registered=Int64(3), wl=Int64(6), cl=Int64(6))
    assert_equal(ok.outcome, IDEMPOTENT_COMMITTED)
    var neg = String("")
    try:
        _ = f.m.append_idempotent(
            _batch_body(Int64(4), Int64(3), Int64(1), Int64(1)), Int64(-1),
            Int64(4), Int64(3), Int64(1), Int64(1), Int64(3),
        )
    except e:
        neg = String(e)
    assert_equal(neg, String("CasManifestStore.append_idempotent: negative record_count"))


# ---- faults inside the protocol -------------------------------------------------


def test_vanished_sentinel_is_retryable() raises:
    var f = _Fixture(String("i/van"))
    _ = _append(f.m, Int64(5), Int64(0), Int64(1))
    # The claim 412s, then the sentinel is gone when read back (a reaper).
    f.add(_rule(V_GET, String("/_meta/dedup/"), String(GONE)))
    var r = _append(f.m, Int64(5), Int64(0), Int64(1))
    assert_equal(r.outcome, IDEMPOTENT_RETRYABLE)
    assert_equal(f.n_chunks(), 1)


def test_claim_transport_error_is_raised() raises:
    var f = _Fixture(String("i/claim"))
    f.add(_rule(V_PUT, String("/_meta/dedup/"), String(TRANSPORT)))
    var msg = String("")
    try:
        _ = _append(f.m, Int64(5), Int64(0), Int64(1))
    except e:
        msg = String(e)
    assert_true(msg.find("status=503") >= 0, msg)
    assert_equal(f.n_chunks(), 0)
    # A sentinel read error is raised by the public read too.
    _ = _append(f.m, Int64(5), Int64(0), Int64(1))
    f.add(_rule(V_GET, String("/_meta/dedup/"), String(TRANSPORT)))
    var rmsg = String("")
    try:
        _ = f.m.read_dedup_sentinel(Int64(5), Int64(0))
    except e:
        rmsg = String(e)
    assert_true(rmsg.find("status=503") >= 0, rmsg)
    # And by the retry's resolution: never a guessed outcome.
    f.add(_rule(V_GET, String("/_meta/dedup/"), String(TRANSPORT)))
    var amsg = String("")
    try:
        _ = _append(f.m, Int64(5), Int64(0), Int64(1))
    except e:
        amsg = String(e)
    assert_true(amsg.find("status=503") >= 0, amsg)


def test_lost_append_response_is_committed() raises:
    var f = _Fixture(String("i/phantom"))
    _ = _append(f.m, Int64(6), Int64(0), Int64(2))
    # The chunk create lands, its response is lost: COMMITTED at the chunk
    # that landed, not a raise (the client's retry would double-write).
    f.add(_rule(V_PUT, String("/manifest/"), String(TRANSPORT), mode=M_AFTER))
    var r = _append(f.m, Int64(6), Int64(2), Int64(3))
    assert_equal(r.outcome, IDEMPOTENT_COMMITTED)
    assert_equal(r.chunk_seq, Int64(1))
    assert_equal(r.base_offset, Int64(2))
    assert_equal(r.last_offset, Int64(4))
    assert_equal(f.n_chunks(), 2)
    # The claim was healed to the landed chunk.
    assert_equal(f.sentinel(Int64(6), Int64(2)).committed_chunk_seq, Int64(1))
    # A genuine failure (nothing landed) is raised and releases the claim.
    f.add(_rule(V_PUT, String("/manifest/"), String(TRANSPORT)))
    var msg = String("")
    try:
        _ = _append(f.m, Int64(6), Int64(5), Int64(1))
    except e:
        msg = String(e)
    assert_true(msg.find("status=503") >= 0, msg)
    assert_false(Bool(f.m.read_dedup_sentinel(Int64(6), Int64(5))))


def test_scan_transport_error_is_raised() raises:
    var f = _Fixture(String("i/scanerr"))
    _ = _append(f.m, Int64(8), Int64(0), Int64(1))
    _ = _append(f.m, Int64(8), Int64(1), Int64(1))
    f.add(_rule(V_GET, String("/manifest/"), String(TRANSPORT)))
    var msg = String("")
    try:
        _ = _append(f.m, Int64(8), Int64(1), Int64(1))
    except e:
        msg = String(e)
    assert_true(msg.find("status=503") >= 0, msg)


def test_finalize_is_best_effort() raises:
    # (a) The sentinel vanishes between the resolution read and the
    # finalize: DUPLICATE still answered, nothing re-created.
    var f = _Fixture(String("i/fin"))
    _ = _append(f.m, Int64(3), Int64(0), Int64(1))
    f.add(_rule(V_GET, String("/_meta/dedup/"), String(GONE), skip=1))
    var a = _append(f.m, Int64(3), Int64(0), Int64(1))
    assert_equal(a.outcome, IDEMPOTENT_DUPLICATE)
    assert_equal(a.chunk_seq, Int64(0))
    assert_false(f.sentinel(Int64(3), Int64(0)).committed_chunk_seq >= Int64(0))
    # (b) Another path committed it in between: the finalize writes nothing
    # (the committed body, with its own offsets, stands).
    var other = DedupSentinel(
        Int64(3), Int64(1), Int64(0), Int64(0), Int64(0), Int64(0), Int64(0), String("")
    )
    var preput = _rule(V_GET, String("/_meta/dedup/"), String(""), skip=1, mode=M_PREPUT)
    preput.payload = encode_dedup_sentinel(other)
    f.add(preput^)
    var puts_before = f.shared.n_put()
    var b = _append(f.m, Int64(3), Int64(0), Int64(1))
    assert_equal(b.outcome, IDEMPOTENT_DUPLICATE)
    # Two puts: the refused claim and the other path's commit. A finalize
    # write would be a third.
    assert_equal(f.shared.n_put() - puts_before, Int64(2))
    var s = f.sentinel(Int64(3), Int64(0))
    assert_equal(s.committed_chunk_seq, Int64(0))
    # (c) The finalize's read fails: swallowed, DUPLICATE still answered.
    var g = _Fixture(String("i/fin2"))
    _ = _append(g.m, Int64(3), Int64(0), Int64(1))
    g.add(_rule(V_GET, String("/_meta/dedup/"), String(TRANSPORT), skip=1))
    var c = _append(g.m, Int64(3), Int64(0), Int64(1))
    assert_equal(c.outcome, IDEMPOTENT_DUPLICATE)
    assert_equal(c.chunk_seq, Int64(0))
    assert_equal(g.fired(), 1)


def main() raises:
    test_retry_of_committed_batch_is_duplicate()
    test_scan_skips_other_batches_and_short_bodies()
    test_staged_claim_without_chunk_is_retryable()
    test_non_idempotent_producer_never_matches()
    test_fences_write_nothing()
    test_vanished_sentinel_is_retryable()
    test_claim_transport_error_is_raised()
    test_lost_append_response_is_committed()
    test_scan_transport_error_is_raised()
    test_finalize_is_best_effort()
    print("[test_cov_cas_idempotent] PASS")
