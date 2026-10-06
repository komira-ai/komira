# =============================================================================
# tests/test_manifest_reaped_slot_guard_offline.mojo
#   A create that wins a REAPED chunk slot below `_LOG_START` is never reported
#   committed (komira-ai/komira#486).
# =============================================================================
#
# THE BUG. `CasManifestStore.reap` DELETEs chunk keys, and `If-None-Match`
# cannot tell a deleted key from one never written. A writer whose head is
# older than `_LOG_START` wins slot K below the log start and acknowledges it;
# every reader and replay starts at `_LOG_START`, so the records are lost.
#
# THE FIX (`manifest_slot_guard.mojo` + call sites in `cas_manifest.mojo`):
#   * after every winning create, GET `_LOG_START`; a win below it raises the
#     retryable `slot_reaped` error, invalidates the head cache, does not ack;
#   * the forward probe's 404 recovers the head by LIST, not the durable
#     `_HEAD`;
#   * the cold write path clamps a durable `_HEAD` below the log start to the
#     LIST-recovered head;
#   * `reap` refuses any chunk at or above `_LOG_START`.
#
# Each test below names the defect it catches and the mutant that turns it red.
# All run on the in-memory stores; no network.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)

from komira_objectstore.cas_manifest import (
    AsyncManifestAppendOp,
    CasManifestStore,
    IDEMPOTENT_COMMITTED,
    RetryPolicy,
    is_lease_fenced,
    is_not_found,
    is_precondition,
    is_retryable_contention,
)
from komira_objectstore.manifest_slot_guard import (
    is_slot_reaped,
    slot_reaped_error,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


comptime _Store = SharedInMemoryConditionalStore
comptime _Slow = SharedInMemorySlowCasStore
comptime _RPC = Int64(10)  # records per chunk, every test


def _body(tag: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(16):
        out.append(UInt8((i * 7 + tag) & 0xFF))
    return out^


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _mk[S: ConditionalWriteStore](var store: S, prefix: String) -> CasManifestStore[S]:
    return CasManifestStore[S](
        store=store^, prefix=prefix.copy(), retry=RetryPolicy.fast_test()
    )


def _retire[
    S: ConditionalWriteStore
](
    mut m: CasManifestStore[S],
    first: Int64,
    new_log_start_seq: Int64,
    skip_reap: Int64 = Int64(-1),
) raises:
    """What RetentionPass + ReapWorker do, in their order: tombstone
    `[first, new_log_start_seq)`, advance `_LOG_START` to
    `(new_log_start_seq, new_log_start_seq * _RPC)`, then reap each retired
    chunk (except `skip_reap`, which a test reaps itself later)."""
    var s = first
    while s < new_log_start_seq:
        m.schedule_for_delete_at(s, Int64(1))
        s += Int64(1)
    var ls = m.read_log_start()
    _ = m.advance_log_start(new_log_start_seq, new_log_start_seq * _RPC, ls.etag)
    s = first
    while s < new_log_start_seq:
        if s != skip_reap:
            m.reap(s)
        s += Int64(1)


def _count_in_live_range(
    mut m: CasManifestStore[_Store], body: List[UInt8]
) raises -> Int:
    """How many chunks in `[log_start_seq, tail]` carry `body`: what a reader
    that starts at the log start (every reader and replay) can see."""
    var ls = m.read_log_start()
    var head = m.read_head_authoritative()
    var n = 0
    var s = ls.log_start_seq
    while s <= head.chunk_seq:
        if _same(m.read_chunk(s), body):
            n += 1
        s += Int64(1)
    return n


# -----------------------------------------------------------------------------
# A wrapper store that plays the reaper at the worst moment: when a create of
# `trigger` loses (412), it deletes `trigger` before re-raising the 412, so the
# writer's forward probe of that slot 404s.
# -----------------------------------------------------------------------------
struct _ReapOnLostCreate(ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    var inner: _Store
    var trigger: String

    def __init__(out self, var inner: _Store, var trigger: String):
        self.inner = inner^
        self.trigger = trigger^

    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        try:
            return self.inner.conditional_put(path, bytes, precond)
        except e:
            if path.raw() == self.trigger:
                self.inner.delete(path)
            raise e^

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


# =============================================================================
# 1. THE BUG: a warm writer wins a reaped slot. Fails before the fix (S's
#    append returns committed at slot 2, below log_start 4).
#    Mutants: drop the post-win read; `<=` (no, see test 6); the clamp removed
#    (the retry would walk reaped slot 3 and raise again).
# =============================================================================
def test_warm_writer_reaped_slot_not_committed() raises:
    print("[reaped-slot] 1. warm writer wins a reaped slot -> slot_reaped")
    var store = _Store()
    var prefix = String("rs/warm")
    var s = _mk(store.clone(), prefix)  # writer S
    var n = _mk(store.clone(), prefix)  # writer N
    var r = _mk(store.clone(), prefix)  # retention + reaper
    _ = s.append(_body(0), _RPC)
    _ = s.append(_body(1), _RPC)  # S warm at chunk 1 (K-1, K = 2)
    for i in range(3):
        var w = n.append(_body(10 + i), _RPC)
        assert_equal(w.chunk_seq, Int64(2 + i), "N appends K..K+2")
    _retire(r, Int64(0), Int64(4))  # log_start = 4; chunks 0..3 reaped

    var body_s = _body(99)
    var raised = False
    var msg = String("")
    try:
        var won = s.append(body_s, _RPC)
        msg = (
            "DATA LOSS: S committed at chunk_seq "
            + String(won.chunk_seq)
            + " base "
            + String(won.base_offset)
            + ", below log_start_seq 4: acknowledged, never read"
        )
    except e:
        raised = True
        msg = String(e)
    print("  S append outcome: " + msg)
    assert_true(raised, msg)
    assert_true(is_slot_reaped(msg), "the refusal is slot_reaped: " + msg)
    assert_equal(
        _count_in_live_range(r, body_s), 0, "nothing of S's is in the live range yet"
    )

    # The retry re-derives the head (cache invalidated, clamp) and lands at K+3.
    var again = s.append(body_s, _RPC)
    assert_equal(again.chunk_seq, Int64(5), "S's retry lands at K+3")
    assert_equal(again.base_offset, Int64(50), "at the dense base after N's 40..49")
    assert_equal(
        _count_in_live_range(r, body_s),
        1,
        "a full read from log_start returns S's records exactly once",
    )
    print("  PASS")


# =============================================================================
# 2. COLD WRITER: a durable `_HEAD` below the log start is clamped (LIST
#    recovery), so a fresh writer lands at the tail on its first attempt.
#    Mutant: the clamp removed (the fresh writer aims at reaped slot 1, the
#    post-win guard raises slot_reaped).
# =============================================================================
def test_cold_head_below_log_start_is_clamped() raises:
    print("[reaped-slot] 2. cold _HEAD below log_start -> clamp to LIST head")
    var store = _Store()
    var prefix = String("rs/cold")
    var a = _mk(store.clone(), prefix)
    for i in range(5):
        _ = a.append(_body(i), _RPC)  # first append writes _HEAD, rest defer
    var r = _mk(store.clone(), prefix)
    assert_equal(
        r.read_durable_head().chunk_seq,
        Int64(0),
        "PRECONDITION: the durable _HEAD lags at chunk 0 (deferred advances)",
    )
    _retire(r, Int64(0), Int64(3))  # log_start = 3; chunks 0..2 reaped
    assert_equal(
        r.read_durable_head().chunk_seq,
        Int64(0),
        "read_durable_head is not clamped (a reader cannot ack; one GET)",
    )
    var c = _mk(store.clone(), prefix)  # cold
    var won = c.append(_body(77), _RPC)
    assert_equal(won.chunk_seq, Int64(5), "the cold writer lands at the tail")
    assert_equal(won.base_offset, Int64(50), "at the dense base")
    assert_equal(won.attempts, 1, "first attempt: the clamp aimed it right")
    print("  PASS")


# =============================================================================
# 3. FORWARD PROBE 404: the slot that just 412'd is reaped before the probe
#    reads it. The writer recovers by LIST and wins the tail on attempt 2.
#    Mutant: the probe-404 falls back to the durable `_HEAD` (chunk 2, below
#    log_start 4): the writer aims at reaped slot 3 and the guard raises.
# =============================================================================
def test_probe_404_recovers_by_list() raises:
    print("[reaped-slot] 3. probe 404 (slot reaped mid-probe) -> LIST")
    var store = _Store()
    var prefix = String("rs/probe")
    var trigger = String(prefix + "/manifest/00000000000000000002.chunk")
    var s = _mk(_ReapOnLostCreate(store.clone(), trigger.copy()), prefix)
    var n = _mk(store.clone(), prefix)
    var r = _mk(store.clone(), prefix)
    _ = s.append(_body(0), _RPC)
    _ = s.append(_body(1), _RPC)  # S warm at chunk 1
    for i in range(3):
        _ = n.append(_body(10 + i), _RPC)  # N: 2..4; durable _HEAD -> 2
    assert_equal(
        r.read_durable_head().chunk_seq,
        Int64(2),
        "PRECONDITION: the durable _HEAD sits at chunk 2, below log_start - 1",
    )
    # Retire 0..3 but leave chunk 2's key in place: the wrapper reaps it at the
    # moment S's create on it loses.
    _retire(r, Int64(0), Int64(4), skip_reap=Int64(2))
    var won = s.append(_body(55), _RPC)
    assert_equal(won.chunk_seq, Int64(5), "S lands at the tail")
    assert_equal(won.base_offset, Int64(50), "at the dense base")
    assert_equal(won.attempts, 2, "412 on slot 2, probe 404 -> LIST -> win")
    print("  PASS")


# =============================================================================
# 4. try_append_at_seq at a reaped slot raises slot_reaped; at the tail it wins.
#    Mutant: drop the post-win read (returns Some at the reaped slot).
# =============================================================================
def test_try_append_at_seq_reaped_slot() raises:
    print("[reaped-slot] 4. try_append_at_seq at a reaped slot -> slot_reaped")
    var store = _Store()
    var prefix = String("rs/occ")
    var a = _mk(store.clone(), prefix)
    for i in range(5):
        _ = a.append(_body(i), _RPC)
    _retire(a, Int64(0), Int64(3))
    var w = _mk(store.clone(), prefix)
    var raised = False
    var msg = String("")
    try:
        var res = w.try_append_at_seq(Int64(1), Int64(10), _body(42), _RPC)
        msg = "committed at a reaped slot: some=" + String(Bool(res))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised and is_slot_reaped(msg), msg)
    var ok = w.try_append_at_seq(Int64(5), Int64(50), _body(43), _RPC)
    assert_true(Bool(ok), "a create at the live tail commits")
    assert_equal(ok.value().chunk_seq, Int64(5), "at slot 5")
    print("  PASS")


def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


# =============================================================================
# 5. The poll-shaped op: `take` of a win at a reaped slot raises slot_reaped;
#    a win at the tail returns Some. Mutant: drop the post-win read in
#    apply_async_append_win.
# =============================================================================
def test_async_op_reaped_slot() raises:
    print("[reaped-slot] 5. AsyncManifestAppendOp win at a reaped slot")
    var reactor = _new_reactor()
    var wal = _mk(_Slow(slow_ticks=0), String("rs/async"))
    for i in range(5):
        _ = wal.append(_body(i), _RPC)
    _retire(wal, Int64(0), Int64(3))

    var op = AsyncManifestAppendOp[_Slow]()
    var p = op.start[NoopSink](wal, Int64(1), Int64(10), _body(8), _RPC, reactor)
    assert_true(p.is_ready(), "the create at the empty (reaped) slot completes")
    var raised = False
    var msg = String("")
    try:
        var res = op.take(wal)
        msg = "take returned committed at a reaped slot: some=" + String(Bool(res))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised and is_slot_reaped(msg), msg)

    var op2 = AsyncManifestAppendOp[_Slow]()
    var p2 = op2.start[NoopSink](wal, Int64(5), Int64(50), _body(9), _RPC, reactor)
    assert_true(p2.is_ready(), "the create at the tail completes")
    var res2 = op2.take(wal)
    assert_true(Bool(res2), "a win at the tail is committed")
    assert_equal(res2.value().chunk_seq, Int64(5), "at slot 5")
    print("  PASS")


# =============================================================================
# 6. BOUNDARY: a create at exactly `log_start_seq` is a live slot and commits
#    (warm writer through `_try_append_at`, and a cold writer whose LIST head
#    is `log_start_seq - 1`). Mutant: `<=` instead of `<`.
# =============================================================================
def test_win_at_log_start_commits() raises:
    print("[reaped-slot] 6. a win at exactly log_start_seq commits")
    var store = _Store()
    var prefix = String("rs/edge")
    var a = _mk(store.clone(), prefix)
    for i in range(3):
        _ = a.append(_body(i), _RPC)  # A warm at chunk 2
    var r = _mk(store.clone(), prefix)
    _retire(r, Int64(0), Int64(3))  # everything retired: log_start = 3 = tail+1
    var w = a.append(_body(30), _RPC)
    assert_equal(w.chunk_seq, Int64(3), "warm win at log_start_seq commits")
    _retire(r, Int64(3), Int64(4))  # log_start = 4 = tail+1 again
    var c = _mk(store.clone(), prefix)
    var w2 = c.append(_body(31), _RPC)
    assert_equal(w2.chunk_seq, Int64(4), "cold win at log_start_seq commits")
    assert_equal(w2.base_offset, Int64(40), "at the log-start offset")
    print("  PASS")


# =============================================================================
# 7. `reap` refuses a chunk at or above `_LOG_START` and leaves it readable;
#    below the log start it deletes. Mutant: `reap` without its guard.
# =============================================================================
def test_reap_refuses_live_chunk() raises:
    print("[reaped-slot] 7. reap refuses seq >= log_start_seq")
    var store = _Store()
    var m = _mk(store.clone(), String("rs/reap"))
    for i in range(3):
        _ = m.append(_body(i), _RPC)
    m.schedule_for_delete_at(Int64(1), Int64(1))
    var refused = False
    try:
        m.reap(Int64(1))  # log_start is 0: chunk 1 is live
    except e:
        refused = String(e).find("refused") >= 0
    assert_true(refused, "reap of a live chunk is refused")
    assert_true(_same(m.read_chunk(Int64(1)), _body(1)), "and it stays readable")

    var ls = m.read_log_start()
    _ = m.advance_log_start(Int64(1), Int64(10), ls.etag)
    var refused_at_boundary = False
    try:
        m.reap(Int64(1))  # chunk 1 == log_start_seq: still live
    except e:
        refused_at_boundary = String(e).find("refused") >= 0
    assert_true(refused_at_boundary, "reap at exactly log_start_seq is refused")

    ls = m.read_log_start()
    _ = m.advance_log_start(Int64(2), Int64(20), ls.etag)
    m.reap(Int64(1))  # now below the log start
    var gone = False
    try:
        _ = m.read_chunk(Int64(1))
    except e:
        gone = is_not_found(String(e))
    assert_true(gone, "below the log start the chunk is reaped")
    print("  PASS")


def _put_i64(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))


def _producer_body(producer_id: Int64, first_seq: Int64) -> List[UInt8]:
    """A body in the broker ManifestBody wire layout, so the exactly-once
    phantom scan can MATCH it: [rc i64][crc u32][key_len i64][key]
    [segment_bytes i64][ts i64][producer_id i64][epoch i64][first i64][last i64]."""
    var out = List[UInt8]()
    _put_i64(out, _RPC)
    for _ in range(4):
        out.append(UInt8(0))
    var key_s = String("seg/eos")
    var key = key_s.as_bytes()
    _put_i64(out, Int64(len(key)))
    for i in range(len(key)):
        out.append(key[i])
    _put_i64(out, Int64(100))
    _put_i64(out, Int64(1))
    _put_i64(out, producer_id)
    _put_i64(out, Int64(0))
    _put_i64(out, first_seq)
    _put_i64(out, first_seq + _RPC - Int64(1))
    return out^


# =============================================================================
# 8. EXACTLY-ONCE: `slot_reaped` inside append_idempotent. The orphan at the
#    reaped slot CARRIES the batch identity, yet the phantom scan (which starts
#    at log_start) does not report it committed: the staged sentinel is released
#    and the error surfaces as slot_reaped; the retry re-claims and COMMITS at
#    the tail. No change in append_idempotent was needed; this pins it.
# =============================================================================
def test_idempotent_slot_reaped_releases_sentinel() raises:
    print("[reaped-slot] 8. append_idempotent: slot_reaped releases the sentinel")
    var store = _Store()
    var prefix = String("rs/eos")
    var s = _mk(store.clone(), prefix)
    var n = _mk(store.clone(), prefix)
    var r = _mk(store.clone(), prefix)
    _ = s.append(_body(0), _RPC)
    _ = s.append(_body(1), _RPC)  # S warm at chunk 1
    for i in range(3):
        _ = n.append(_body(10 + i), _RPC)
    _retire(r, Int64(0), Int64(4))

    var pid = Int64(7)
    var first = Int64(0)
    var body = _producer_body(pid, first)
    var raised = False
    var msg = String("")
    try:
        var ir = s.append_idempotent(
            body, _RPC, pid, Int64(0), first, first + _RPC - Int64(1), Int64(0)
        )
        msg = (
            "append_idempotent returned outcome "
            + String(ir.outcome)
            + " at chunk "
            + String(ir.chunk_seq)
        )
    except e:
        raised = True
        msg = String(e)
    assert_true(raised and is_slot_reaped(msg), msg)
    assert_false(
        Bool(s.read_dedup_sentinel(pid, first)),
        "the staged sentinel was released (the retry re-claims cleanly)",
    )
    var again = s.append_idempotent(
        body, _RPC, pid, Int64(0), first, first + _RPC - Int64(1), Int64(0)
    )
    assert_equal(again.outcome, IDEMPOTENT_COMMITTED, "the retry COMMITS")
    assert_equal(again.chunk_seq, Int64(5), "at the tail, K+3")
    assert_equal(again.base_offset, Int64(50), "at the dense base")
    print("  PASS")


# =============================================================================
# 9. The error classifies as slot_reaped only: never a lost slot (412), a lease
#    fence, retry exhaustion or absence, and it carries no digit (a chunk key
#    spells its seq in decimal; `412` in a message reads as a lost slot).
# =============================================================================
def test_slot_reaped_error_classification() raises:
    print("[reaped-slot] 9. slot_reaped classification")
    var sites = List[String]()
    sites.append(String("append"))
    sites.append(String("apply_async_append_win"))
    for i in range(len(sites)):
        var msg = String(slot_reaped_error(sites[i]))
        assert_true(is_slot_reaped(msg), "is_slot_reaped: " + msg)
        assert_false(is_precondition(msg), "not a 412/precondition: " + msg)
        assert_false(is_lease_fenced(msg), "not a lease fence: " + msg)
        assert_false(is_retryable_contention(msg), "not exhaustion: " + msg)
        assert_false(is_not_found(msg), "not absence: " + msg)
        assert_false(msg.find("If-None-Match") >= 0, "no lost-slot token")
        assert_false(msg.find("If-Match") >= 0, "no lost-slot token")
        var bs = msg.as_bytes()
        for j in range(len(bs)):
            assert_false(
                bs[j] >= UInt8(ord("0")) and bs[j] <= UInt8(ord("9")),
                "no digit in the slot_reaped text: " + msg,
            )
    assert_false(is_slot_reaped(String("precondition (412)")), "a 412 is not it")
    print("  PASS")


def main() raises:
    test_warm_writer_reaped_slot_not_committed()
    test_cold_head_below_log_start_is_clamped()
    test_probe_404_recovers_by_list()
    test_try_append_at_seq_reaped_slot()
    test_async_op_reaped_slot()
    test_win_at_log_start_commits()
    test_reap_refuses_live_chunk()
    test_idempotent_slot_reaped_releases_sentinel()
    test_slot_reaped_error_classification()
    print("ALL reaped-slot guard tests PASSED")
