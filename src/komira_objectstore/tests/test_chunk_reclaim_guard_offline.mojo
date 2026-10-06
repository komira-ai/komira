# =============================================================================
# tests/test_chunk_reclaim_guard_offline.mojo
#   Reclamation never deletes or recreates a live chunk — OFFLINE
# =============================================================================
#
# `_LOG_START.log_start_seq` is the lowest live chunk. These cases pin the
# rules in chunk_reclaim_guard.mojo at the manifest layer:
#
#   (1) `reap` refuses a tombstoned chunk AT and ABOVE log_start_seq (a live
#       chunk carrying a stranded tombstone), and reaps one below it.
#       Catches: no refusal; `>` instead of `>=` (the chunk AT the floor).
#   (2) `reap` fails closed when `_LOG_START` cannot be read: it raises and
#       deletes nothing. Catches: a read error treated as "no log start".
#   (3) `rewrite_chunk_body` does not recreate a chunk reaped between its read
#       and its write; the error reads as absence (`is_not_found`). It reports
#       a concurrent rewrite as a precondition failure, and keeps that report
#       when the absence probe itself fails. Catches: an unconditional PUT.
#   (4) `SubLineageBaseFold.compact` advances `_base`'s log start BEFORE it
#       reaps, so the retired chunks are really deleted. Catches: the old
#       reap-then-advance order (the reap is refused and swallowed, the chunk
#       leaks, the index forgets it).
#   (5) A failed advance, tombstone write or reap during `compact` raises. A
#       failure before the advance leaves the in-memory index intact; one after
#       it leaves the index at the durable log start; a retry reclaims everything and
#       strands no marker, also after a reap that deleted the chunk but not
#       its marker, and after a restart (`reload_from_base`) that follows a
#       landed advance. Catches: the old swallow-and-drop; an advance before
#       the tombstones (chunks below the floor that nothing revisits); a
#       compact that does not sweep tombstones below the floor.
#   (6) `advance_log_start` refuses to move `_LOG_START` backwards, and a
#       compact with a lower watermark after a failure past the advance does
#       not try to. Catches: no regression check; a stale fold index.
#   (7) A read error on a LIVE chunk in a log-start walk is raised, never
#       taken for a reaped chunk (`_retire_folded_source`, `reload_from_base`).
#       Catches: the old catch-all `except: continue`.
#
# Faults are injected by `_FaultStore`, which wraps the shared in-memory store
# and keeps its rules as marker objects IN that store, so every clone (each
# manifest handle the fold makes) sees them.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    chunk_key,
    is_not_found,
    is_precondition,
    log_start_key,
    tombstone_key,
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
    BASE_SHARD_ID,
    REAPED_PAYLOAD_SENTINEL,
    SubLineageBaseFold,
    sublineage_prefix,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)


comptime _Inner = SharedInMemoryConditionalStore

# Rule prefixes; a rule is the marker object `<prefix><target key>`.
comptime _FAIL_GET = "__fault__/get/"
# The first GET of the target succeeds and arms `_FAIL_GET` for the rest:
# a tail recovery reads the chunk, the walk after it then fails.
comptime _FAIL_GET_AFTER_ONE = "__fault__/get_after_one/"
comptime _FAIL_HEAD = "__fault__/head/"
comptime _FAIL_PUT = "__fault__/put/"
comptime _FAIL_DELETE = "__fault__/delete/"
# One-shot hooks that run just before a PUT to the target key.
comptime _DELETE_BEFORE_PUT = "__hook__/delete_before_put/"
comptime _REWRITE_BEFORE_PUT = "__hook__/rewrite_before_put/"
comptime _FAIL_HEAD_BEFORE_PUT = "__hook__/fail_head_before_put/"


def _has(store: _Inner, key: String) -> Bool:
    try:
        _ = store.head(Path.parse(key))
        return True
    except:
        return False


def _arm(store: _Inner, rule: String, target: String) raises:
    _ = store.put(Path.parse(rule + target), List[UInt8]())


def _disarm(store: _Inner, rule: String, target: String) raises:
    store.delete(Path.parse(rule + target))


def _take_hook(store: _Inner, rule: String, target: String) raises -> Bool:
    if _has(store, rule + target):
        _disarm(store, rule, target)
        return True
    return False


struct _FaultStore(
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    """Delegates every verb to a shared in-memory store, failing the verbs a
    rule names. The injected error carries no absence or precondition token."""

    var _inner: _Inner

    def __init__(out self, var inner: _Inner):
        self._inner = inner^

    def clone(self) -> Self:
        return Self(self._inner.clone())

    def _fail_if(self, rule: String, path: Path) raises:
        if _has(self._inner, rule + path.raw()):
            raise Error("injected fault: transport error status=503 " + rule)

    def _before_put(self, path: Path) raises:
        var key = path.raw()
        if _take_hook(self._inner, _DELETE_BEFORE_PUT, key):
            self._inner.delete(path)  # a reaper lands between read and write
        if _take_hook(self._inner, _REWRITE_BEFORE_PUT, key):
            # A concurrent rewrite: same bytes, new etag.
            _ = self._inner.put(path, self._inner.get(path))
        if _take_hook(self._inner, _FAIL_HEAD_BEFORE_PUT, key):
            _arm(self._inner, _FAIL_HEAD, key)
        self._fail_if(_FAIL_PUT, path)

    def head(self, path: Path) raises -> ObjectMeta:
        self._fail_if(_FAIL_HEAD, path)
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    def _before_get(self, path: Path) raises:
        self._fail_if(_FAIL_GET, path)
        if _take_hook(self._inner, _FAIL_GET_AFTER_ONE, path.raw()):
            _arm(self._inner, _FAIL_GET, path.raw())

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        self._before_get(path)
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        self._before_get(path)
        return self._inner.get(path)

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        self._before_put(path)
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        self._before_put(path)
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self._before_put(path)
        return self._inner.put(path, bytes)

    def delete(self, path: Path) raises -> None:
        self._fail_if(_FAIL_DELETE, path)
        self._inner.delete(path)


comptime _PREFIX = "guard/topic/0"


def _manifest(
    inner: _Inner, prefix: String
) raises -> CasManifestStore[_FaultStore]:
    return CasManifestStore[_FaultStore](
        _FaultStore(inner.clone()), prefix, RetryPolicy.fast_test()
    )


def _body(tag: Int) -> List[UInt8]:
    var b = List[UInt8]()
    for i in range(8):
        b.append(UInt8((tag * 8 + i) % 251))
    return b^


def _chunk_present(inner: _Inner, prefix: String, seq: Int64) raises -> Bool:
    return _has(inner, chunk_key(prefix, seq).raw())


def _tomb_present(inner: _Inner, prefix: String, seq: Int64) raises -> Bool:
    return _has(inner, tombstone_key(prefix, seq).raw())


# =============================================================================
# (1) reap refuses at and above log_start_seq
# =============================================================================


def test_reap_refuses_at_and_above_log_start() raises:
    print("[test_reap_refuses_at_and_above_log_start] starting...")
    var inner = _Inner()
    var p = String(_PREFIX)
    var m = _manifest(inner, p)
    for c in range(3):
        _ = m.append(_body(c), Int64(10))
    for c in range(3):
        m.schedule_for_delete(Int64(c))

    # No _LOG_START yet: the floor is 0, so even chunk 0 is live.
    assert_equal(m.read_log_start_seq(), Int64(0), "absent pointer -> floor 0")
    var raised0 = False
    try:
        m.reap(Int64(0))
    except e:
        raised0 = True
        assert_true(String(e).find("at or above log_start_seq") >= 0, String(e))
    assert_true(raised0, "reap of chunk 0 under an absent log start refused")
    assert_true(_chunk_present(inner, p, Int64(0)), "chunk 0 kept")

    # Advance to seq 1: chunk 0 is below, chunk 1 is AT the floor.
    var ls = m.read_log_start()
    _ = m.advance_log_start(Int64(1), Int64(10), ls.etag)
    assert_equal(m.read_log_start_seq(), Int64(1), "floor is 1")

    var raised1 = False
    try:
        m.reap(Int64(1))
    except e:
        raised1 = True
        var msg = String(e)
        assert_true(msg.find("chunk 1 is at or above log_start_seq 1") >= 0, msg)
        assert_false(is_not_found(msg), "refusal never reads as absence")
        assert_false(is_precondition(msg), "refusal never reads as a lost race")
    assert_true(raised1, "reap of the chunk AT log_start_seq is refused")
    assert_true(_chunk_present(inner, p, Int64(1)), "chunk 1 kept")
    assert_true(_tomb_present(inner, p, Int64(1)), "chunk 1 marker kept")

    var raised2 = False
    try:
        m.reap(Int64(2))
    except e:
        raised2 = True
        _ = e
    assert_true(raised2, "reap of a chunk ABOVE log_start_seq is refused")
    assert_true(_chunk_present(inner, p, Int64(2)), "chunk 2 kept")

    m.reap(Int64(0))
    assert_false(_chunk_present(inner, p, Int64(0)), "chunk 0 below: reaped")
    assert_false(_tomb_present(inner, p, Int64(0)), "chunk 0 marker spent")
    _ = m^
    print("[test_reap_refuses_at_and_above_log_start] PASS")


# =============================================================================
# (2) reap fails closed on a _LOG_START read error
# =============================================================================


def test_reap_fails_closed_on_log_start_read_error() raises:
    print("[test_reap_fails_closed_on_log_start_read_error] starting...")
    var inner = _Inner()
    var p = String(_PREFIX)
    var m = _manifest(inner, p)
    for c in range(2):
        _ = m.append(_body(c), Int64(10))
    m.schedule_for_delete(Int64(0))
    var ls = m.read_log_start()
    _ = m.advance_log_start(Int64(1), Int64(10), ls.etag)

    _arm(inner, _FAIL_GET, log_start_key(p).raw())
    var raised = False
    try:
        m.reap(Int64(0))
    except e:
        raised = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised, "an unreadable log start fails the reap")
    assert_true(_chunk_present(inner, p, Int64(0)), "nothing deleted")
    assert_true(_tomb_present(inner, p, Int64(0)), "marker kept")
    var raised_read = False
    try:
        _ = m.read_log_start_seq()
    except e:
        raised_read = True
        _ = e
    assert_true(raised_read, "read_log_start_seq raises, never answers 0")

    _disarm(inner, _FAIL_GET, log_start_key(p).raw())
    m.reap(Int64(0))
    assert_false(_chunk_present(inner, p, Int64(0)), "reaped once readable")
    _ = m^
    print("[test_reap_fails_closed_on_log_start_read_error] PASS")


# =============================================================================
# (3) rewrite_chunk_body never recreates a reaped chunk
# =============================================================================


def test_rewrite_does_not_recreate_reaped_chunk() raises:
    print("[test_rewrite_does_not_recreate_reaped_chunk] starting...")
    var inner = _Inner()
    var p = String(_PREFIX)
    var m = _manifest(inner, p)
    for c in range(3):
        _ = m.append(_body(c), Int64(10))

    # A plain rewrite still works and keeps the record count.
    m.rewrite_chunk_body(Int64(0), _body(7))
    var got = m.read_chunk(Int64(0))
    assert_true(len(got) > 0, "rewritten chunk readable")

    # The reaper deletes chunk 1 between the rewrite's read and its write.
    _arm(inner, _DELETE_BEFORE_PUT, chunk_key(p, Int64(1)).raw())
    var raised = False
    try:
        m.rewrite_chunk_body(Int64(1), _body(8))
    except e:
        raised = True
        var msg = String(e)
        assert_true(is_not_found(msg), "a reaped target reads as absent: " + msg)
        assert_true(msg.find("was not recreated") >= 0, msg)
    assert_true(raised, "the rewrite of a reaped chunk raises")
    assert_false(
        _chunk_present(inner, p, Int64(1)), "the reaped chunk key stays gone"
    )

    # A concurrent rewrite lands between read and write: a precondition error,
    # the other writer's object stays.
    _arm(inner, _REWRITE_BEFORE_PUT, chunk_key(p, Int64(2)).raw())
    var raised2 = False
    try:
        m.rewrite_chunk_body(Int64(2), _body(9))
    except e:
        raised2 = True
        var msg = String(e)
        assert_true(is_precondition(msg), "a concurrent rewrite is a 412: " + msg)
        assert_false(is_not_found(msg), "and not absence: " + msg)
    assert_true(raised2, "the rewrite loses to the concurrent one")
    assert_true(_chunk_present(inner, p, Int64(2)), "chunk 2 still present")

    # Same race, and the absence probe (HEAD) itself fails: report the 412.
    _arm(inner, _REWRITE_BEFORE_PUT, chunk_key(p, Int64(2)).raw())
    _arm(inner, _FAIL_HEAD_BEFORE_PUT, chunk_key(p, Int64(2)).raw())
    var raised3 = False
    try:
        m.rewrite_chunk_body(Int64(2), _body(9))
    except e:
        raised3 = True
        var msg = String(e)
        assert_true(is_precondition(msg), "the original 412 is reported: " + msg)
        assert_false(is_not_found(msg), "an unproven absence is not absence")
    assert_true(raised3, "the rewrite fails")
    _disarm(inner, _FAIL_HEAD, chunk_key(p, Int64(2)).raw())

    # The conditional PUT fails for another reason: that error, unchanged.
    _arm(inner, _FAIL_PUT, chunk_key(p, Int64(2)).raw())
    var raised4 = False
    try:
        m.rewrite_chunk_body(Int64(2), _body(9))
    except e:
        raised4 = True
        var msg = String(e)
        assert_true(msg.find("injected fault") >= 0, msg)
        assert_false(is_not_found(msg), "a transport error is not absence")
    assert_true(raised4, "the failed PUT is reported")
    _disarm(inner, _FAIL_PUT, chunk_key(p, Int64(2)).raw())

    # A chunk that is already gone (never written, or reaped before the
    # rewrite read it): the etag HEAD reports absence, nothing is written.
    var raised5 = False
    try:
        m.rewrite_chunk_body(Int64(9), _body(9))
    except e:
        raised5 = True
        assert_true(is_not_found(String(e)), String(e))
    assert_true(raised5, "rewriting an absent chunk raises")
    assert_false(_chunk_present(inner, p, Int64(9)), "and creates nothing")
    _ = m^
    print("[test_rewrite_does_not_recreate_reaped_chunk] PASS")


# =============================================================================
# (4) + (5) SubLineageBaseFold.compact: advance first, index kept on failure
# =============================================================================


comptime _Fold = SubLineageBaseFold[_FaultStore]
comptime _PART = "guard-part"


def _one(a: Int64) -> List[Int64]:
    var l = List[Int64]()
    l.append(a)
    return l^


def _fold_six(inner: _Inner) raises -> _Fold:
    """Six one-record `_base` blocks, dense offsets 0..5 (payload == offset)."""
    var f = _Fold(_FaultStore(inner.clone()), String(_PART))
    var payload = Int64(0)
    for _k in range(3):
        _ = f.append_batch(String("a0"), _one(payload))
        payload += Int64(1)
        _ = f.run_once()
    for _k in range(3):
        _ = f.append_batch(String("b0"), _one(payload))
        payload += Int64(1)
        _ = f.run_once()
    assert_equal(f.live_base_chunk_count(), 6, "6 _base blocks")
    return f^


def _base_prefix() -> String:
    return sublineage_prefix(String(_PART), String(BASE_SHARD_ID))


def _assert_index_intact(f: _Fold, inner: _Inner, what: String) raises:
    assert_equal(f.live_base_chunk_count(), 6, what + ": index keeps 6 blocks")
    var r = f.resolve_offset(Int64(0))
    assert_true(r.found, what + ": offset 0 resolves")
    assert_equal(r.payload, Int64(0), what + ": offset 0 is its record")


def _assert_compacted(f: _Fold, inner: _Inner, what: String) raises:
    var bp = _base_prefix()
    assert_equal(f.live_base_chunk_count(), 2, what + ": 2 live blocks")
    for s in range(4):
        assert_false(
            _chunk_present(inner, bp, Int64(s)),
            what + ": retired _base chunk " + String(s) + " deleted",
        )
        assert_false(
            _tomb_present(inner, bp, Int64(s)),
            what + ": retired _base marker " + String(s) + " spent",
        )
    for s in range(4, 6):
        assert_true(
            _chunk_present(inner, bp, Int64(s)),
            what + ": live _base chunk " + String(s) + " kept",
        )
    var m = _manifest(inner, bp)
    assert_equal(m.read_log_start_seq(), Int64(4), what + ": log start at 4")
    _ = m^
    var r = f.resolve_offset(Int64(0))
    assert_equal(r.payload, REAPED_PAYLOAD_SENTINEL, what + ": 0 is REAPED")


def test_base_fold_advances_before_reap() raises:
    print("[test_base_fold_advances_before_reap] starting...")
    var inner = _Inner()
    var f = _fold_six(inner)
    var n = f.compact(Int64(4))
    assert_equal(n, 2, "compact reports 2 live blocks")
    _assert_compacted(f, inner, "advance-first")
    _ = f^
    print("[test_base_fold_advances_before_reap] PASS")


def test_base_fold_failed_advance_keeps_index() raises:
    print("[test_base_fold_failed_advance_keeps_index] starting...")
    var inner = _Inner()
    var f = _fold_six(inner)
    var lk = log_start_key(_base_prefix()).raw()
    _arm(inner, _FAIL_PUT, lk)
    var raised = False
    try:
        _ = f.compact(Int64(4))
    except e:
        raised = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised, "a failed advance raises")
    _assert_index_intact(f, inner, "failed advance")
    for s in range(6):
        assert_true(
            _chunk_present(inner, _base_prefix(), Int64(s)),
            "failed advance: nothing reaped",
        )
    _disarm(inner, _FAIL_PUT, lk)
    # A sweep-only compact leaves tombstones at or above the log start alone.
    _ = f.compact(Int64(0))
    for s in range(6):
        assert_true(
            _chunk_present(inner, _base_prefix(), Int64(s)),
            "sweep below the floor only: nothing reaped",
        )
    # A restart, then the retry.
    f.reload_from_base()
    _assert_index_intact(f, inner, "reload after failed advance")
    _ = f.compact(Int64(4))
    _assert_compacted(f, inner, "retry after failed advance")
    _ = f^
    print("[test_base_fold_failed_advance_keeps_index] PASS")


def _assert_index_follows_floor(f: _Fold, what: String) raises:
    """After a failure PAST the advance: the in-memory index mirrors the
    durable log start (4), as a restart would rebuild it."""
    assert_equal(f.live_base_chunk_count(), 2, what + ": index follows the floor")
    var r = f.resolve_offset(Int64(0))
    assert_equal(r.payload, REAPED_PAYLOAD_SENTINEL, what + ": 0 reads REAPED")


def test_base_fold_failed_reap_keeps_index() raises:
    print("[test_base_fold_failed_reap_keeps_index] starting...")
    var inner = _Inner()
    var f = _fold_six(inner)
    var ck = chunk_key(_base_prefix(), Int64(0)).raw()
    _arm(inner, _FAIL_DELETE, ck)
    var raised = False
    try:
        _ = f.compact(Int64(4))
    except e:
        raised = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised, "a failed reap raises")
    _assert_index_follows_floor(f, "failed reap")
    assert_true(_chunk_present(inner, _base_prefix(), Int64(0)), "chunk 0 kept")
    _disarm(inner, _FAIL_DELETE, ck)
    _ = f.compact(Int64(4))
    _assert_compacted(f, inner, "retry after failed reap")
    _ = f^
    print("[test_base_fold_failed_reap_keeps_index] PASS")


def test_base_fold_retry_after_half_reap() raises:
    print("[test_base_fold_retry_after_half_reap] starting...")
    var inner = _Inner()
    var f = _fold_six(inner)
    # The reap deletes chunk 0, then fails to drop its marker.
    var tk = tombstone_key(_base_prefix(), Int64(0)).raw()
    _arm(inner, _FAIL_DELETE, tk)
    var raised = False
    try:
        _ = f.compact(Int64(4))
    except e:
        raised = True
        _ = e
    assert_true(raised, "the half-done reap raises")
    _assert_index_follows_floor(f, "half reap")
    assert_false(_chunk_present(inner, _base_prefix(), Int64(0)), "chunk 0 gone")
    _disarm(inner, _FAIL_DELETE, tk)
    # The retry finds chunk 0 already gone, reaps the other three, and sweeps
    # chunk 0's leftover marker: no marker is stranded.
    _ = f.compact(Int64(4))
    _assert_compacted(f, inner, "retry after half reap")
    _ = f^
    print("[test_base_fold_retry_after_half_reap] PASS")


def test_base_fold_restart_after_advance_reclaims() raises:
    """The advance lands, the reap of chunk 1 fails (or the process dies),
    and the fold restarts: `reload_from_base` rebuilds from log start 4, so
    no retire pass revisits chunks 0..3. The next compact sweeps them."""
    print("[test_base_fold_restart_after_advance_reclaims] starting...")
    var inner = _Inner()
    var f = _fold_six(inner)
    var ck = chunk_key(_base_prefix(), Int64(1)).raw()
    _arm(inner, _FAIL_DELETE, ck)
    var raised = False
    try:
        _ = f.compact(Int64(4))
    except e:
        raised = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised, "the reap after the advance fails")
    _disarm(inner, _FAIL_DELETE, ck)
    f.reload_from_base()
    assert_equal(f.live_base_chunk_count(), 2, "restart: index from log start 4")
    _ = f.compact(Int64(4))
    _assert_compacted(f, inner, "restart after the advance")
    _ = f^
    print("[test_base_fold_restart_after_advance_reclaims] PASS")


def test_base_fold_restart_after_failed_tombstone_reclaims() raises:
    """The tombstone write for chunk 2 fails, then the fold restarts. The
    tombstones come BEFORE the advance, so the log start has not moved: the
    restart still sees all six blocks and the next compact retires 0..3.
    (Advancing first would leave chunks 2, 3 below the floor, untombstoned,
    and nothing would reap them.)"""
    print("[test_base_fold_restart_after_failed_tombstone_reclaims] starting...")
    var inner = _Inner()
    var f = _fold_six(inner)
    var tk = tombstone_key(_base_prefix(), Int64(2)).raw()
    _arm(inner, _FAIL_PUT, tk)
    var raised = False
    try:
        _ = f.compact(Int64(4))
    except e:
        raised = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised, "the tombstone write for chunk 2 fails")
    _disarm(inner, _FAIL_PUT, tk)
    f.reload_from_base()
    _assert_index_intact(f, inner, "restart after a failed tombstone")
    _ = f.compact(Int64(4))
    _assert_compacted(f, inner, "restart after a failed tombstone")
    _ = f^
    print("[test_base_fold_restart_after_failed_tombstone_reclaims] PASS")


def test_base_fold_failed_tombstone_keeps_index() raises:
    print("[test_base_fold_failed_tombstone_keeps_index] starting...")
    var inner = _Inner()
    var f = _fold_six(inner)
    var tk = tombstone_key(_base_prefix(), Int64(0)).raw()
    _arm(inner, _FAIL_PUT, tk)
    var raised = False
    try:
        _ = f.compact(Int64(4))
    except e:
        raised = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised, "a failed tombstone write raises")
    _assert_index_intact(f, inner, "failed tombstone")
    _disarm(inner, _FAIL_PUT, tk)
    _ = f.compact(Int64(4))
    _assert_compacted(f, inner, "retry after failed tombstone")
    _ = f^
    print("[test_base_fold_failed_tombstone_keeps_index] PASS")


# =============================================================================
# (6) a failure past the advance never lets _LOG_START move backwards
# =============================================================================


def test_advance_log_start_refuses_to_move_backwards() raises:
    print("[test_advance_log_start_refuses_to_move_backwards] starting...")
    var inner = _Inner()
    var p = String(_PREFIX)
    var m = _manifest(inner, p)
    for c in range(3):
        _ = m.append(_body(c), Int64(10))
    var ls = m.read_log_start()
    ls = m.advance_log_start(Int64(2), Int64(20), ls.etag)
    var cases = List[Int64]()
    cases.append(Int64(1))  # seq and offset behind
    cases.append(Int64(2))  # same seq, offset behind
    for i in range(len(cases)):
        var raised = False
        try:
            _ = m.advance_log_start(cases[i], Int64(15), ls.etag)
        except e:
            raised = True
            var msg = String(e)
            assert_true(msg.find("backwards") >= 0, msg)
            assert_true(is_precondition(msg), "reads as a lost race: " + msg)
        assert_true(raised, "a backwards advance is refused")
        var cur = m.read_log_start()
        assert_equal(cur.log_start_seq, Int64(2), "seq did not move")
        assert_equal(cur.log_start_offset, Int64(20), "offset did not move")
    # Forward, and to the same point, still work.
    ls = m.advance_log_start(Int64(2), Int64(20), m.read_log_start().etag)
    ls = m.advance_log_start(Int64(3), Int64(30), ls.etag)
    assert_equal(m.read_log_start_seq(), Int64(3), "forward advance lands")
    _ = m^
    print("[test_advance_log_start_refuses_to_move_backwards] PASS")


def test_base_fold_lower_watermark_after_failed_reap() raises:
    """The advance to 4 lands and the reap of chunk 1 fails. A compact with
    a lower watermark (3) must not move `_LOG_START` back to 3."""
    print("[test_base_fold_lower_watermark_after_failed_reap] starting...")
    var inner = _Inner()
    var f = _fold_six(inner)
    var ck = chunk_key(_base_prefix(), Int64(1)).raw()
    _arm(inner, _FAIL_DELETE, ck)
    var raised = False
    try:
        _ = f.compact(Int64(4))
    except e:
        raised = True
        _ = e
    assert_true(raised, "the reap after the advance fails")
    _disarm(inner, _FAIL_DELETE, ck)
    var n = f.compact(Int64(3))
    assert_equal(n, 2, "a lower watermark retires nothing")
    var m = _manifest(inner, _base_prefix())
    var ls = m.read_log_start()
    assert_equal(ls.log_start_seq, Int64(4), "log start seq stays 4")
    assert_equal(ls.log_start_offset, Int64(4), "log start offset stays 4")
    _ = m^
    _assert_compacted(f, inner, "lower watermark after a failed reap")
    _ = f^
    print("[test_base_fold_lower_watermark_after_failed_reap] PASS")


# =============================================================================
# (7) a read error on a LIVE chunk is never taken for a reaped one
# =============================================================================


def test_source_retire_raises_on_a_live_chunk_read_error() raises:
    """`_retire_folded_source` walks a source shard from its log start. A
    GET error on live chunk 1 must raise before any tombstone or advance; a
    catch-all would skip it, tombstone chunks 0 and 2 and renumber the log."""
    print("[test_source_retire_raises_on_a_live_chunk_read_error] starting...")
    var inner = _Inner()
    var f = _Fold(_FaultStore(inner.clone()), String(_PART))
    for k in range(3):
        _ = f.append_batch(String("a0"), _one(Int64(k)))
    var sp = sublineage_prefix(String(_PART), String("a0"))
    var ck = chunk_key(sp, Int64(1)).raw()
    # The tail recovery reads chunk 1; the walk's read of it then fails.
    _arm(inner, _FAIL_GET_AFTER_ONE, ck)
    var raised = False
    try:
        f._retire_folded_source(String("a0"), Int64(3))
    except e:
        raised = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised, "the read error is raised")
    _disarm(inner, _FAIL_GET, ck)
    var s = _manifest(inner, sp)
    assert_equal(len(s.tombstone_seqs()), 0, "nothing tombstoned")
    var ls = s.read_log_start()
    assert_equal(ls.log_start_seq, Int64(0), "log start seq did not move")
    assert_equal(ls.log_start_offset, Int64(0), "log start offset did not move")
    _ = s^
    _ = f^
    print("[test_source_retire_raises_on_a_live_chunk_read_error] PASS")


def test_reload_raises_on_a_live_base_chunk_read_error() raises:
    """`reload_from_base` rebuilds the index from the log start. A GET error
    (not absence) on live block 2 must raise: skipping it would shift every
    later dense base, and a compact over that index retires the wrong
    blocks."""
    print("[test_reload_raises_on_a_live_base_chunk_read_error] starting...")
    var inner = _Inner()
    var f = _fold_six(inner)
    var ck = chunk_key(_base_prefix(), Int64(2)).raw()
    # The tail recovery fails: raised (it used to rebuild an EMPTY index).
    _arm(inner, _FAIL_GET, ck)
    var raised0 = False
    try:
        f.reload_from_base()
    except e:
        raised0 = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised0, "a failed tail recovery is raised")
    _disarm(inner, _FAIL_GET, ck)
    # The tail recovery reads block 2; the walk's read of it then fails.
    _arm(inner, _FAIL_GET_AFTER_ONE, ck)
    var raised = False
    try:
        f.reload_from_base()
    except e:
        raised = True
        assert_true(String(e).find("injected fault") >= 0, String(e))
    assert_true(raised, "the walk's read error is raised")
    _disarm(inner, _FAIL_GET, ck)
    f.reload_from_base()
    _assert_index_intact(f, inner, "reload after the error")
    _ = f^
    print("[test_reload_raises_on_a_live_base_chunk_read_error] PASS")


def main() raises:
    test_reap_refuses_at_and_above_log_start()
    test_reap_fails_closed_on_log_start_read_error()
    test_rewrite_does_not_recreate_reaped_chunk()
    test_base_fold_advances_before_reap()
    test_base_fold_failed_advance_keeps_index()
    test_base_fold_failed_reap_keeps_index()
    test_base_fold_retry_after_half_reap()
    test_base_fold_restart_after_advance_reclaims()
    test_base_fold_restart_after_failed_tombstone_reclaims()
    test_base_fold_failed_tombstone_keeps_index()
    test_advance_log_start_refuses_to_move_backwards()
    test_base_fold_lower_watermark_after_failed_reap()
    test_source_retire_raises_on_a_live_chunk_read_error()
    test_reload_raises_on_a_live_base_chunk_read_error()
    print("[OK] test_chunk_reclaim_guard_offline — 14 cases passed")
