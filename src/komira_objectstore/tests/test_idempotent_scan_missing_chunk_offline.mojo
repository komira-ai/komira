# =============================================================================
# tests/test_idempotent_scan_missing_chunk_offline.mojo
#   A retried idempotent batch is never acknowledged at a shifted offset
#   (komira-ai/komira#1088).
# =============================================================================
#
# A retried `append_idempotent` whose dedup sentinel is still staged resolves
# through the phantom scan (`_scan_tail_for_batch`): it replays record counts
# from `_LOG_START` to the batch's chunk and acknowledges DUPLICATE at that
# chunk's base offset. A chunk the scan cannot read (404) has an unknown
# record count, so the scan cannot keep its running offset: every later chunk
# would be numbered too low by the missing count.
#
# The scan tells the two reasons a chunk at or above the `_LOG_START` it read
# can 404 apart by reading `_LOG_START` again:
#   * retention advanced `_LOG_START` past the chunk and a reaper deleted it
#     after the scan's first read: restart from the new pointer (test 2);
#   * otherwise the chunk is missing from the live range (a torn lineage):
#     refuse, as `_recover_head_by_list` does (test 1).
#
# Test 3 is the control: with nothing missing the retry acknowledges the
# committed offsets, so a scan that refused every retry fails too.
#
# Tests 4 to 6 pin the edges of that rule:
#   * 4: the reaper lags the pointer: `_LOG_START` jumps to chunk 3 while
#     chunk 2 (below it) still exists. The scan must restart AT the new
#     pointer; stepping one chunk past the 404 would count chunk 2 again and
#     ack batch 3 at offset 4.
#   * 5: a chunk GET that fails with a 503 is a store error, not a missing
#     chunk: it must reach the caller unchanged, not become a refusal.
#   * 6: the chunk missing is the one `_LOG_START` names. Restarting there
#     would read the same 404 forever, so the scan must refuse. The watchdog
#     `alarm` turns that loop into a failed test instead of a hung build.
#
# Each batch is one record from producer 1, so batch `k` commits at chunk
# `k`, offset `k`.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true

from komira_objectstore.cas_manifest import (
    IDEMPOTENT_COMMITTED,
    IDEMPOTENT_DUPLICATE,
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
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

comptime _PID = Int64(1)
comptime _ERR_503 = "StoreError[UNAVAILABLE] status=503 injected"
# Seconds before the watchdog kills a scan that never returns. A scan here
# takes microseconds; the margin covers coverage builds.
comptime _WATCHDOG_S = 60


def _put_i64(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))


def _batch_body(first_seq: Int64) -> List[UInt8]:
    """A one-record body in the broker ManifestBody wire layout, so the
    phantom scan can match it: [rc i64][crc u32][key_len i64][key]
    [segment_bytes i64][ts i64][producer_id i64][epoch i64][first i64][last i64]."""
    var out = List[UInt8]()
    _put_i64(out, Int64(1))
    for _ in range(4):
        out.append(UInt8(0))
    var key = String("seg/eos").as_bytes()
    _put_i64(out, Int64(len(key)))
    for i in range(len(key)):
        out.append(key[i])
    _put_i64(out, Int64(100))
    _put_i64(out, Int64(1))
    _put_i64(out, _PID)
    _put_i64(out, Int64(1))
    _put_i64(out, first_seq)
    _put_i64(out, first_seq)
    return out^


struct _ReapOnRead(ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    """The first GET of chunk `race_seq` (while `<flag>` is absent) plays a
    retention pass that lands between the scan's `_LOG_START` read and its
    chunk read: `_LOG_START` moves to (`start_seq`, `start_seq`), chunks
    `0 .. reap_below - 1` are deleted, and the GET then 404s, as it would on a
    real store. With `fail_msg` set, every GET of chunk `race_seq` raises it
    instead and nothing moves. Every other call goes to the shared inner
    store."""

    var inner: SharedInMemoryConditionalStore
    var prefix: String
    var race_key: String
    var flag: String
    var start_seq: Int64
    var reap_below: Int64
    var fail_msg: String

    def __init__(
        out self,
        var inner: SharedInMemoryConditionalStore,
        var prefix: String,
        race_seq: Int64 = Int64(1),
        start_seq: Int64 = Int64(2),
        reap_below: Int64 = Int64(2),
        var fail_msg: String = String(""),
    ) raises:
        self.inner = inner^
        self.race_key = chunk_key(prefix, race_seq).raw()
        self.flag = prefix + "/test-race-armed"
        self.prefix = prefix^
        self.start_seq = start_seq
        self.reap_below = reap_below
        self.fail_msg = fail_msg^

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
        if path.raw() == self.race_key and self.fail_msg.byte_length() > 0:
            raise Error(self.fail_msg)
        if path.raw() == self.race_key and self._armed():
            _ = self.inner.put(Path.parse(self.flag), List[UInt8]())
            _ = self.inner.put(
                log_start_key(self.prefix),
                encode_log_start(
                    LogStart(self.start_seq, self.start_seq, String(""))
                ),
            )
            for k in range(Int(self.reap_below)):
                self.inner.delete(chunk_key(self.prefix, Int64(k)))
        return self.inner.get(path)

    def _armed(self) -> Bool:
        try:
            _ = self.inner.head(Path.parse(self.flag))
            return False
        except e:
            _ = e
            return True

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)


def _append3[
    S: ConditionalWriteStore
](mut m: CasManifestStore[S], n: Int = 3) raises:
    for k in range(n):
        var r = m.append_idempotent(
            _batch_body(Int64(k)), Int64(1), _PID, Int64(1), Int64(k),
            Int64(k), Int64(1),
        )
        assert_equal(r.outcome, IDEMPOTENT_COMMITTED)
        assert_equal(r.chunk_seq, Int64(k))
        assert_equal(r.base_offset, Int64(k))


def _describe(outcome: Int, seq: Int64, base: Int64) -> String:
    return (
        "outcome=" + String(outcome) + " chunk_seq=" + String(seq)
        + " base_offset=" + String(base)
    )


def test_missing_live_chunk_is_refused() raises:
    print("[scan] chunk 1 missing at/above _LOG_START -> refuse, never shift")
    var shared = SharedInMemoryConditionalStore()
    var p = String("eo/torn")
    var m = CasManifestStore[SharedInMemoryConditionalStore](
        store=shared.clone(), prefix=p, retry=RetryPolicy.fast_test()
    )
    _append3(m)
    shared.delete(chunk_key(p, Int64(1)))
    var msg = String("")
    try:
        var d = m.append_idempotent(
            _batch_body(Int64(2)), Int64(1), _PID, Int64(1), Int64(2),
            Int64(2), Int64(1),
        )
        msg = "acked " + _describe(d.outcome, d.chunk_seq, d.base_offset)
    except e:
        msg = String(e)
    assert_true(
        msg.find("MISSING committed chunk at seq 1") >= 0
        and msg.find("torn manifest lineage") >= 0,
        "expected a torn-lineage refusal naming chunk 1, got: " + msg,
    )
    print("  PASS")


def test_chunk_reaped_during_scan_restarts() raises:
    print("[scan] chunk 1 reaped after the scan read _LOG_START -> restart")
    var shared = SharedInMemoryConditionalStore()
    var p = String("eo/reaped")
    var plain = CasManifestStore[SharedInMemoryConditionalStore](
        store=shared.clone(), prefix=p, retry=RetryPolicy.fast_test()
    )
    _append3(plain)
    var m = CasManifestStore[_ReapOnRead](
        store=_ReapOnRead(shared.clone(), p), prefix=p,
        retry=RetryPolicy.fast_test(),
    )
    var d = m.append_idempotent(
        _batch_body(Int64(2)), Int64(1), _PID, Int64(1), Int64(2), Int64(2),
        Int64(1),
    )
    var got = _describe(d.outcome, d.chunk_seq, d.base_offset)
    assert_equal(d.outcome, IDEMPOTENT_DUPLICATE, got)
    assert_equal(d.chunk_seq, Int64(2), got)
    assert_equal(d.base_offset, Int64(2), "committed at offset 2: " + got)
    assert_equal(d.last_offset, Int64(2), got)
    # The race really ran (so the restart arm was taken).
    assert_equal(m.read_log_start().log_start_seq, Int64(2))
    print("  PASS")


def test_intact_lineage_acks_committed_offsets() raises:
    print("[scan] nothing missing -> DUPLICATE at the committed offsets")
    var shared = SharedInMemoryConditionalStore()
    var p = String("eo/intact")
    var m = CasManifestStore[SharedInMemoryConditionalStore](
        store=shared.clone(), prefix=p, retry=RetryPolicy.fast_test()
    )
    _append3(m)
    var d = m.append_idempotent(
        _batch_body(Int64(2)), Int64(1), _PID, Int64(1), Int64(2), Int64(2),
        Int64(1),
    )
    var got = _describe(d.outcome, d.chunk_seq, d.base_offset)
    assert_equal(d.outcome, IDEMPOTENT_DUPLICATE, got)
    assert_equal(d.chunk_seq, Int64(2), got)
    assert_equal(d.base_offset, Int64(2), got)
    print("  PASS")


def _retry[
    S: ConditionalWriteStore
](mut m: CasManifestStore[S], k: Int64) raises -> String:
    """Retries batch `k`; describes the ack, or returns the error text."""
    try:
        var d = m.append_idempotent(
            _batch_body(k), Int64(1), _PID, Int64(1), k, k, Int64(1)
        )
        return "acked " + _describe(d.outcome, d.chunk_seq, d.base_offset)
    except e:
        return String(e)


def test_lagging_reaper_restarts_at_the_new_start() raises:
    print("[scan] _LOG_START jumps to 3, chunk 2 still there -> restart at 3")
    var shared = SharedInMemoryConditionalStore()
    var p = String("eo/lag")
    var plain = CasManifestStore[SharedInMemoryConditionalStore](
        store=shared.clone(), prefix=p, retry=RetryPolicy.fast_test()
    )
    _append3(plain, 4)
    var m = CasManifestStore[_ReapOnRead](
        store=_ReapOnRead(
            shared.clone(), p, race_seq=Int64(1), start_seq=Int64(3),
            reap_below=Int64(2),
        ),
        prefix=p,
        retry=RetryPolicy.fast_test(),
    )
    var d = m.append_idempotent(
        _batch_body(Int64(3)), Int64(1), _PID, Int64(1), Int64(3), Int64(3),
        Int64(1),
    )
    var got = _describe(d.outcome, d.chunk_seq, d.base_offset)
    assert_equal(d.outcome, IDEMPOTENT_DUPLICATE, got)
    assert_equal(d.chunk_seq, Int64(3), got)
    assert_equal(d.base_offset, Int64(3), "committed at offset 3: " + got)
    assert_equal(d.last_offset, Int64(3), got)
    # The race ran, and it left chunk 2 below the new start (the lag).
    assert_equal(m.read_log_start().log_start_seq, Int64(3))
    _ = shared.get(chunk_key(p, Int64(2)))
    print("  PASS")


def test_chunk_read_store_error_propagates() raises:
    print("[scan] a 503 on a chunk GET reaches the caller unchanged")
    var shared = SharedInMemoryConditionalStore()
    var p = String("eo/unavailable")
    var plain = CasManifestStore[SharedInMemoryConditionalStore](
        store=shared.clone(), prefix=p, retry=RetryPolicy.fast_test()
    )
    _append3(plain)
    var m = CasManifestStore[_ReapOnRead](
        store=_ReapOnRead(
            shared.clone(), p, race_seq=Int64(1), fail_msg=String(_ERR_503)
        ),
        prefix=p,
        retry=RetryPolicy.fast_test(),
    )
    var msg = _retry(m, Int64(2))
    assert_equal(msg, String(_ERR_503))
    print("  PASS")


def test_missing_chunk_at_log_start_is_refused() raises:
    print("[scan] the chunk _LOG_START names is missing -> refuse, no loop")
    var shared = SharedInMemoryConditionalStore()
    var p = String("eo/torn-start")
    var m = CasManifestStore[SharedInMemoryConditionalStore](
        store=shared.clone(), prefix=p, retry=RetryPolicy.fast_test()
    )
    _append3(m)
    shared.delete(chunk_key(p, Int64(0)))
    # SIGALRM's default action ends the process: a scan that restarts at the
    # same missing chunk forever fails here instead of hanging the build.
    _ = external_call["alarm", UInt32](UInt32(_WATCHDOG_S))
    var msg = _retry(m, Int64(2))
    _ = external_call["alarm", UInt32](UInt32(0))
    assert_true(
        msg.find("MISSING committed chunk at seq 0") >= 0
        and msg.find("torn manifest lineage") >= 0,
        "expected a torn-lineage refusal naming chunk 0, got: " + msg,
    )
    print("  PASS")


def main() raises:
    var failed = 0
    try:
        test_missing_live_chunk_is_refused()
    except e:
        failed += 1
        print("[FAIL] test_missing_live_chunk_is_refused: " + String(e))
    try:
        test_chunk_reaped_during_scan_restarts()
    except e:
        failed += 1
        print("[FAIL] test_chunk_reaped_during_scan_restarts: " + String(e))
    try:
        test_intact_lineage_acks_committed_offsets()
    except e:
        failed += 1
        print("[FAIL] test_intact_lineage_acks_committed_offsets: " + String(e))
    try:
        test_lagging_reaper_restarts_at_the_new_start()
    except e:
        failed += 1
        print(
            "[FAIL] test_lagging_reaper_restarts_at_the_new_start: "
            + String(e)
        )
    try:
        test_chunk_read_store_error_propagates()
    except e:
        failed += 1
        print("[FAIL] test_chunk_read_store_error_propagates: " + String(e))
    try:
        test_missing_chunk_at_log_start_is_refused()
    except e:
        failed += 1
        print("[FAIL] test_missing_chunk_at_log_start_is_refused: " + String(e))
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("ALL idempotent scan tests PASSED")
