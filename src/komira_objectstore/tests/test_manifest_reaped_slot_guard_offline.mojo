# =============================================================================
# tests/test_manifest_reaped_slot_guard_offline.mojo
#   A create that wins a REAPED chunk slot below `_LOG_START` is never reported
#   committed (komira-ai/komira#486). The guard is opt-in
#   (`enable_reaped_slot_guard`); `manifest_slot_guard.mojo` states the rules.
# =============================================================================
#
# Each test names the defect it catches and the mutant that turns it red:
#   1  warm writer wins a reaped slot ......... drop the post-win read
#   2  cold `_HEAD` below the log start ....... drop the write-path clamp
#   3  probe reads a leaked chunk below the
#      log start (different record count) ..... probe trusts a below-floor chunk
#   4  probe 404 (slot reaped mid-probe) ...... 404 falls back to durable _HEAD
#   5  try_append_at_seq at a reaped slot ..... drop the post-win read; check
#                                               after the _HEAD advance
#   (6, the poll-shaped op, is in test_manifest_reaped_slot_async_offline.mojo)
#   7  a win at exactly log_start commits ..... `<=` instead of `<`
#   8  legit win retired before the read ... .. pins the documented duplicate
#   9  _LOG_START unreadable (sync) .......... fail open on a read error
#   10 an unguarded manifest pays nothing ..... opt-in ignored
#   11 exactly-once: slot_reaped releases the
#      sentinel and the retry commits once
#   12 classification of both refusals
# All run on the in-memory stores; no network.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    IDEMPOTENT_COMMITTED,
    LogStart,
    RetryPolicy,
    chunk_key,
    encode_chunk,
    encode_log_start,
    is_lease_fenced,
    is_not_found,
    is_precondition,
    is_retryable_contention,
    log_start_key,
)
from komira_objectstore.manifest_slot_guard import (
    is_log_start_unread,
    is_slot_reaped,
    log_start_unread_error,
    slot_reaped_error,
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


comptime _Store = SharedInMemoryConditionalStore
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


def _mk[
    S: ConditionalWriteStore
](var store: S, prefix: String, guard: Bool = True) -> CasManifestStore[S]:
    var m = CasManifestStore[S](
        store=store^, prefix=prefix.copy(), retry=RetryPolicy.fast_test()
    )
    if guard:
        m.enable_reaped_slot_guard()
    return m^


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
    chunk (except `skip_reap`, left for a test to reap itself)."""
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


def _durable_head_seq(store: _Store, prefix: String) raises -> Int64:
    var r = _mk(store.clone(), prefix, guard=False)
    return r.read_durable_head().chunk_seq


# -----------------------------------------------------------------------------
# Test stores. Each wraps the shared in-memory store and changes one verb.
# -----------------------------------------------------------------------------
struct _FaultStore(ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    """MODE 0 (reap on lost create): when a create of `key` loses (412), delete
    `key` before re-raising the 412, so the writer's probe of that slot 404s.
    MODE 1 (retire after win): when a create of `key` WINS, another writer
    commits the next slot and retention advances `_LOG_START` past `key`'s slot,
    before the create returns (a legitimate win retired before its check). MODE 2 (unreadable log
    start): while the object `<flag>` exists, a GET of `_LOG_START` fails."""

    var inner: _Store
    var mode: Int
    var key: String
    var aux: String  # MODE 1: the next chunk key; MODE 2: the flag key
    var ls_key: String
    var next_seq: Int64

    def __init__(
        out self,
        var inner: _Store,
        mode: Int,
        var key: String,
        var aux: String,
        var ls_key: String,
        next_seq: Int64 = Int64(0),
    ):
        self.inner = inner^
        self.mode = mode
        self.key = key^
        self.aux = aux^
        self.ls_key = ls_key^
        self.next_seq = next_seq

    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        var meta: ObjectMeta
        try:
            meta = self.inner.conditional_put(path, bytes, precond)
        except e:
            if self.mode == 0 and path.raw() == self.key:
                self.inner.delete(path)
            raise e^
        if self.mode == 1 and path.raw() == self.key:
            var nk = Path.parse(self.aux)
            if not self._present(nk):
                _ = self.inner.put(nk, encode_chunk(_body(200), _RPC))
                _ = self.inner.put(
                    Path.parse(self.ls_key),
                    encode_log_start(
                        LogStart(self.next_seq * _RPC, self.next_seq, String(""))
                    ),
                )
        return meta^

    def _present(self, p: Path) -> Bool:
        try:
            _ = self.inner.head(p)
            return True
        except:
            return False

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
        if (
            self.mode == 2
            and path.raw() == self.ls_key
            and self._present(Path.parse(self.aux))
        ):
            raise Error(
                "simulated GET failure status=503 on _LOG_START (412 in a cause"
                " must not read as a lost slot)"
            )
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)


def _chunk(prefix: String, seq: Int64) raises -> String:
    return chunk_key(prefix, seq).raw()


def _ls(prefix: String) raises -> String:
    return log_start_key(prefix).raw()


# =============================================================================
# 1. THE BUG: a warm writer wins a reaped slot. Before the fix S's append
#    returns committed at slot 2, below log_start 4.
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
        _count_in_live_range(r, body_s), 0, "nothing of S's is in the live range"
    )
    # The cache was invalidated: read_head goes to the durable _HEAD (chunk 2,
    # N's cold win), not S's cached chunk 1.
    assert_equal(s.read_head().chunk_seq, Int64(2), "S's head cache is cold")

    # The retry re-derives the head (clamp to LIST) and lands at K+3.
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
#    Mutant: drop the clamp (the writer aims at reaped slot 1 -> slot_reaped).
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
        _durable_head_seq(store, prefix),
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
# 3. The forward probe reads a LEAKED chunk below the log start (a refused
#    win whose record count, 3, differs from the retired original's 10). W is
#    warm at chunk 2 = log_start - 2. Mutant: the probe trusts it (W walks
#    3 -> 4 with next_offset 33 -> 43 and acks [43, 52] over N's [40, 49]).
# =============================================================================
def test_probe_below_log_start_recovers_by_list() raises:
    print("[reaped-slot] 3. probe of a leaked chunk below log_start -> LIST")
    var store = _Store()
    var prefix = String("rs/leak")
    var w = _mk(store.clone(), prefix)
    var n = _mk(store.clone(), prefix)
    var x = _mk(store.clone(), prefix)
    var r = _mk(store.clone(), prefix)
    for i in range(3):
        _ = w.append(_body(i), _RPC)  # W warm at chunk 2, next_offset 30
    for i in range(2):
        _ = n.append(_body(10 + i), _RPC)  # N: chunks 3, 4 = [30, 49]
    _retire(r, Int64(0), Int64(4))  # log_start (4, 40); chunks 0..3 reaped
    # A stale writer X wins reaped slot 3 with a 3-record chunk: refused, and
    # the chunk is left behind below the log start.
    var leaked = False
    try:
        _ = x.try_append_at_seq(Int64(3), Int64(30), _body(66), Int64(3))
    except e:
        leaked = is_slot_reaped(String(e))
    assert_true(leaked, "PRECONDITION: X's win at slot 3 was refused")
    assert_true(_same(r.read_chunk(Int64(3)), _body(66)), "X's chunk is left at 3")
    var won = w.append(_body(77), _RPC)
    assert_equal(won.chunk_seq, Int64(5), "W lands at the tail")
    assert_equal(
        won.base_offset,
        Int64(50),
        "W's base is 50, after N's [40, 49]; a probe through the leaked chunk"
        " gives 43",
    )
    print("  PASS")


# =============================================================================
# 4. PROBE 404: the slot that just 412'd is reaped before the probe reads it.
#    The guarded writer recovers by LIST and wins the tail on attempt 2.
#    Mutant: the 404 falls back to the durable `_HEAD` (chunk 2, below
#    log_start 4): the writer aims at reaped slot 3 and the guard raises.
# =============================================================================
def test_probe_404_recovers_by_list() raises:
    print("[reaped-slot] 4. probe 404 (slot reaped mid-probe) -> LIST")
    var store = _Store()
    var prefix = String("rs/probe")
    var s = _mk(
        _FaultStore(store.clone(), 0, _chunk(prefix, Int64(2)), String(""), _ls(prefix)),
        prefix,
    )
    var n = _mk(store.clone(), prefix)
    var r = _mk(store.clone(), prefix)
    _ = s.append(_body(0), _RPC)
    _ = s.append(_body(1), _RPC)  # S warm at chunk 1
    for i in range(3):
        _ = n.append(_body(10 + i), _RPC)  # N: 2..4; durable _HEAD -> 2
    assert_equal(
        _durable_head_seq(store, prefix),
        Int64(2),
        "PRECONDITION: the durable _HEAD sits at chunk 2, below log_start - 1",
    )
    # Retire 0..3 but leave chunk 2's key: the wrapper reaps it when S's create
    # on it loses.
    _retire(r, Int64(0), Int64(4), skip_reap=Int64(2))
    var won = s.append(_body(55), _RPC)
    assert_equal(won.chunk_seq, Int64(5), "S lands at the tail")
    assert_equal(won.base_offset, Int64(50), "at the dense base")
    assert_equal(won.attempts, 2, "412 on slot 2, probe 404 -> LIST -> win")
    print("  PASS")


# =============================================================================
# 5. try_append_at_seq at a reaped slot raises slot_reaped and does not advance
#    the durable `_HEAD` (it does on a live win); at the tail it wins.
#    Mutants: drop the post-win read; the check after the `_HEAD` advance.
# =============================================================================
def test_try_append_at_seq_reaped_slot() raises:
    print("[reaped-slot] 5. try_append_at_seq at a reaped slot -> slot_reaped")
    var store = _Store()
    var prefix = String("rs/occ")
    var a = _mk(store.clone(), prefix)
    for i in range(5):
        _ = a.append(_body(i), _RPC)  # durable _HEAD stays at 0
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
    assert_equal(
        _durable_head_seq(store, prefix),
        Int64(0),
        "the refused win did not advance the durable _HEAD to slot 1",
    )
    var ok = w.try_append_at_seq(Int64(5), Int64(50), _body(43), _RPC)
    assert_true(Bool(ok), "a create at the live tail commits")
    assert_equal(ok.value().chunk_seq, Int64(5), "at slot 5")
    assert_equal(_durable_head_seq(store, prefix), Int64(5), "and advances _HEAD")
    print("  PASS")


# =============================================================================
# 7. BOUNDARY: a create at exactly `log_start_seq` is live and commits (warm
#    writer, and a cold writer whose LIST head is `log_start_seq - 1`).
#    Mutant: `<=` instead of `<`.
# =============================================================================
def test_win_at_log_start_commits() raises:
    print("[reaped-slot] 7. a win at exactly log_start_seq commits")
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
# 8. PINNED (the race the guard does not resolve): W wins live slot 2 (log_start 0), then, before W's post-win
#    read, another writer commits slot 3 and retention advances the log start
#    to 3. The read cannot tell this from a reaped slot (chunk 2 is present and
#    carries W's own etag in both cases; see manifest_slot_guard.mojo), so W
#    refuses. Under append_idempotent the phantom scan starts at log_start 3,
#    misses chunk 2, releases the sentinel, and the retry COMMITS A SECOND COPY.
#    This test pins that documented duplicate; if it changes, update the header.
# =============================================================================
def test_legit_win_retired_before_check_is_refused_duplicate() raises:
    print("[reaped-slot] 8. legit win retired before the check (duplicate)")
    var store = _Store()
    var prefix = String("rs/f4")
    var w = _mk(
        _FaultStore(
            store.clone(),
            1,
            _chunk(prefix, Int64(2)),
            _chunk(prefix, Int64(3)),
            _ls(prefix),
            Int64(3),
        ),
        prefix,
    )
    _ = w.append(_body(0), _RPC)
    _ = w.append(_body(1), _RPC)  # W warm at chunk 1; log_start 0
    var pid = Int64(9)
    var body = _producer_body(pid, Int64(0))
    var raised = False
    var msg = String("")
    try:
        _ = w.append_idempotent(body, _RPC, pid, Int64(0), Int64(0), _RPC - 1, Int64(0))
        msg = "acked"
    except e:
        raised = True
        msg = String(e)
    assert_true(raised and is_slot_reaped(msg), "refused as slot_reaped: " + msg)
    var r = _mk(store.clone(), prefix, guard=False)
    assert_true(_same(r.read_chunk(Int64(2)), body), "copy 1 stays at slot 2")
    var again = w.append_idempotent(
        body, _RPC, pid, Int64(0), Int64(0), _RPC - 1, Int64(0)
    )
    assert_equal(again.outcome, IDEMPOTENT_COMMITTED, "the retry commits again")
    assert_equal(again.chunk_seq, Int64(4), "copy 2 at the tail: the duplicate")
    print("  PASS (duplicate pinned)")


# =============================================================================
# 9. The post-win `_LOG_START` read fails. FAIL CLOSED: no ack, the
#    `log_start_unread` error (not slot_reaped), the head cache invalidated.
#    Mutant: fail open (ack on a read error). The async op: the second file.
# =============================================================================
def test_log_start_read_failure_fails_closed() raises:
    print("[reaped-slot] 9. _LOG_START unreadable after the win -> no ack")
    var store = _Store()
    var prefix = String("rs/f5")
    var flag = String("rs/f5-fault-armed")
    var w = _mk(
        _FaultStore(store.clone(), 2, String(""), flag.copy(), _ls(prefix)), prefix
    )
    _ = w.append(_body(0), _RPC)  # cold: writes _HEAD 0
    _ = w.append(_body(1), _RPC)  # W warm at chunk 1
    _ = store.put(Path.parse(flag), _body(0))  # arm
    var raised = False
    var msg = String("")
    try:
        var won = w.append(_body(2), _RPC)
        msg = "ACKED at " + String(won.chunk_seq) + " with _LOG_START unread"
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, msg)
    assert_true(is_log_start_unread(msg), "fail-closed refusal: " + msg)
    assert_false(is_slot_reaped(msg), "not slot_reaped (the outcome is unknown)")
    assert_equal(w.read_head().chunk_seq, Int64(0), "W's head cache is cold")
    store.delete(Path.parse(flag))  # disarm
    var again = w.append(_body(2), _RPC)
    assert_equal(again.chunk_seq, Int64(3), "the retry lands after the unacked win")
    print("  PASS")


# =============================================================================
# 10. An UNGUARDED manifest pays nothing and behaves as before: a warm ack
#     is 0 GETs (a guarded one is exactly 1, the `_LOG_START` body), and its
#     probe-404 still falls back to the durable `_HEAD`. Mutant: the guard runs
#     whatever the opt-in says.
# =============================================================================
def test_unguarded_manifest_pays_nothing() raises:
    print("[reaped-slot] 10. an unguarded manifest issues no extra GET")
    var store = _Store()
    var u = _mk(store.clone(), String("rs/f6u"), guard=False)
    var g = _mk(store.clone(), String("rs/f6g"))
    assert_false(u.reaped_slot_guard_enabled(), "default off")
    assert_true(g.reaped_slot_guard_enabled(), "opted in")
    _ = u.append(_body(0), _RPC)
    _ = g.append(_body(0), _RPC)
    store.reset_op_counts()
    _ = u.append(_body(1), _RPC)
    assert_equal(store.n_get(), Int64(0), "unguarded warm ack: 0 GET")
    assert_equal(store.n_head(), Int64(0), "unguarded warm ack: 0 HEAD")
    store.reset_op_counts()
    _ = g.append(_body(1), _RPC)
    assert_equal(store.n_get(), Int64(1), "guarded warm ack: 1 GET (_LOG_START)")
    assert_equal(store.n_head(), Int64(0), "guarded warm ack: no HEAD")

    # The unguarded probe-404 path is unchanged: it re-reads the durable _HEAD.
    var prefix = String("rs/f6p")
    var s = _mk(
        _FaultStore(store.clone(), 0, _chunk(prefix, Int64(1)), String(""), _ls(prefix)),
        prefix,
        guard=False,
    )
    var n = _mk(store.clone(), prefix, guard=False)
    _ = s.append(_body(0), _RPC)  # S warm at chunk 0, durable _HEAD 0
    _ = n.append(_body(1), _RPC)  # N wins 1 (S's next slot)
    var won = s.append(_body(2), _RPC)  # 412 on 1 -> deleted -> probe 404
    assert_equal(won.attempts, 2, "412, then the durable-_HEAD fallback wins")
    assert_equal(
        won.chunk_seq,
        Int64(2),
        "at slot 2, after the durable _HEAD (1); a LIST would aim at deleted 1",
    )
    print("  PASS")


# =============================================================================
# 11. EXACTLY-ONCE: `slot_reaped` inside append_idempotent. The orphan at the
#     reaped slot carries the batch identity, yet the phantom scan (which starts
#     at log_start) does not report it committed: the sentinel is released and
#     the error surfaces; the retry re-claims and COMMITS once, at the tail.
# =============================================================================
def test_idempotent_slot_reaped_releases_sentinel() raises:
    print("[reaped-slot] 11. append_idempotent: slot_reaped releases the sentinel")
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
        msg = "outcome " + String(ir.outcome) + " at chunk " + String(ir.chunk_seq)
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
    assert_equal(
        _count_in_live_range(r, body), 1, "exactly one copy in the live range"
    )
    print("  PASS")


# =============================================================================
# 12. Classification: slot_reaped is never a lost slot, a fence, exhaustion or
#     absence, and carries no digit; log_start_unread is told apart from it.
# =============================================================================
def test_refusal_classification() raises:
    print("[reaped-slot] 12. slot_reaped / log_start_unread classification")
    var sites = List[String]()
    sites.append(String("append"))
    sites.append(String("apply_async_append_win"))
    sites.append(String("async_append"))
    for i in range(len(sites)):
        var msg = String(slot_reaped_error(sites[i]))
        assert_true(is_slot_reaped(msg), "is_slot_reaped: " + msg)
        assert_false(is_log_start_unread(msg), "not log_start_unread: " + msg)
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
    var u = String(log_start_unread_error(String("append"), String("boom")))
    assert_true(is_log_start_unread(u), u)
    assert_false(is_slot_reaped(u), u)
    assert_true(u.find("boom") >= 0, "the cause is kept for the operator")
    assert_false(is_slot_reaped(String("precondition (412)")), "a 412 is not it")
    print("  PASS")


def main() raises:
    test_warm_writer_reaped_slot_not_committed()
    test_cold_head_below_log_start_is_clamped()
    test_probe_below_log_start_recovers_by_list()
    test_probe_404_recovers_by_list()
    test_try_append_at_seq_reaped_slot()
    test_win_at_log_start_commits()
    test_legit_win_retired_before_check_is_refused_duplicate()
    test_log_start_read_failure_fails_closed()
    test_unguarded_manifest_pays_nothing()
    test_idempotent_slot_reaped_releases_sentinel()
    test_refusal_classification()
    print("ALL reaped-slot guard tests PASSED")
