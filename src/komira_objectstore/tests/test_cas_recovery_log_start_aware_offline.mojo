# =============================================================================
# tests/test_cas_recovery_log_start_aware_offline.mojo
#   Log-start-aware recovery — the crash-recovery
#   silent-offset-renumber guard.
# =============================================================================
#
# REGRESSION for the silent offset renumber / data corruption on crash-recovery
# AFTER retention.
#
# THE BUG (pre-fix `_recover_head_by_list`):
#   LIST recovery replayed `read_chunk(0..top)` cumulative record_counts to
#   derive `next_offset`, starting at seq=0 / next_off=0 and FAIL-SOFT `break`ing
#   on the FIRST 404 — and it was `_LOG_START`-UNAWARE (unlike the consume path).
#   After retention reaps the prefix `[0..k]`, those chunk objects are GONE, so
#   `read_chunk(0)` 404s → the replay `break`s immediately → recovery returns
#   `next_offset = 0` for a partition whose true live tail is at (say) offset 50.
#   The next append then claims a high slot with `base_offset = 0` → it RENUMBERS
#   on top of committed offsets (DATA CORRUPTION). This matters MORE now that the
# stale-`_HEAD` fix escalates to `_recover_head_by_list` as the
#   AUTHORITATIVE tail under contention.
#
# THE FIX (cas_manifest.mojo):
#   `_recover_head_by_list` seeds the replay from `_LOG_START` (mirroring the
#   log_start-aware consume path): start seq = `log_start_seq`, start offset =
#   `log_start_offset` (the absolute base of the first SURVIVING chunk), then
#   replay cumulative record_counts over `[log_start_seq .. top]`.
#     * a 404 BELOW `log_start_seq` is never read (benign reaped prefix);
#     * a 404 AT-OR-ABOVE `log_start_seq` is a real missing COMMITTED chunk →
#       FAIL LOUD (torn lineage, refuse to renumber);
#     * the recovered HEAD carries the real top-chunk etag rather than "".
#
# This test reproduces the corruption DETERMINISTICALLY offline (no MinIO, no
# concurrency, no `_HEAD` cache):
#   (1) commit N chunks, advance `_LOG_START` past a prefix, DELETE the reaped
#       chunk objects (the retention reaper's effect), then recover via
#       `read_head_authoritative()` (which calls `_recover_head_by_list`) and
#       append. Assert the new records get offsets ABOVE the surviving tail (NO
#       renumber; committed offsets intact). WITHOUT the fix this returns
#       next_offset=0 and the append renumbers at base 0.
#   (2) a synthetic 404 AT-OR-ABOVE log_start (a hole in the SURVIVING range)
#       fails LOUD instead of silently truncating the tail.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    ManifestHead,
    RetryPolicy,
    chunk_key,
    decode_chunk_record_count,
    head_key,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)


comptime _Store = SharedInMemoryConditionalStore


def _body(tag: Int, n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((i + tag) & 0xFF))
    return out^


def _make_manifest(
    store: _Store, prefix: String
) raises -> CasManifestStore[_Store]:
    return CasManifestStore[_Store](
        store=store.clone(),
        prefix=prefix.copy(),
        retry=RetryPolicy.fast_test(),
    )


# -----------------------------------------------------------------------------
# TEST 1 — recovery after retention does NOT renumber committed offsets.
#
# Commit 5 chunks of 10 records each → seqs 0..4, base offsets
# [0..9],[10..19],[20..29],[30..39],[40..49], true next_offset = 50.
# Reap the prefix [0,1,2] (delete the chunk objects + advance `_LOG_START` to
# seq=3, offset=30 — exactly what RetentionPass + ReapWorker do). Then a fresh
# manifest handle recovers the tail by LIST (`read_head_authoritative`) and
# appends. The new chunk MUST land at seq=5 with base 50 (NOT base 0).
# -----------------------------------------------------------------------------
def _test_recovery_after_retention_no_renumber() raises:
    print(
        "[recovery-log-start] TEST 1 — LIST recovery after retention does NOT"
        " renumber committed offsets"
    )
    var store = _Store()
    var prefix = String("recov/p0")
    var rpc = Int64(10)  # records per chunk

    var manifest = _make_manifest(store, prefix)

    # Commit 5 chunks. After this: chunks 0..4 exist; true tail is
    # (chunk_seq=4, next_offset=50).
    var N = 5
    for i in range(N):
        var r = manifest.append(_body(i, 16), rpc)
        assert_equal(r.chunk_seq, Int64(i), "chunk i committed at slot i")
        assert_equal(
            r.base_offset, Int64(i) * rpc, "base offset == i*rpc (running sum)"
        )

    # Retention: reap the prefix [0,1,2]. The reaper DELETES the chunk objects
    # and the retention pass advances `_LOG_START` to (seq=3, offset=30). We
    # drive both directly at the manifest level (the layer the bug lives in).
    var k = Int64(3)  # first SURVIVING seq
    var log_start_off = k * rpc  # absolute base of the first survivor = 30
    # advance_log_start: first-ever advance creates via If-None-Match (empty
    # expected etag).
    var ls = manifest.advance_log_start(k, log_start_off, String(""))
    assert_equal(ls.log_start_seq, k, "log_start_seq advanced to 3")
    assert_equal(
        ls.log_start_offset, log_start_off, "log_start_offset advanced to 30"
    )
    # Reap: delete the reaped chunk objects [0,1,2] from the bucket.
    for s in range(Int(k)):
        store.delete(chunk_key(prefix, Int64(s)))

    # Also DELETE the cached `_HEAD` to FORCE LIST recovery (model a crash where
    # the pointer cache is gone / a fresh process with no cache). Even without
    # this, `read_head_authoritative` bypasses the cache, but deleting it makes
    # the scenario unambiguous and also exercises the absent-_HEAD path.
    store.delete(head_key(prefix))

    # A FRESH manifest handle over the SAME backing data (the "restart").
    var m2 = _make_manifest(store, prefix)

    # AUTHORITATIVE recovery: this calls `_recover_head_by_list`. WITHOUT the
    # fix it returns next_offset=0 (replay break on read_chunk(0) 404, and
    # log_start-unaware). WITH the fix it seeds from `_LOG_START` (start at
    # seq=3 / offset=30) and replays survivors → (chunk_seq=4, next_offset=50).
    var head = m2.read_head_authoritative()
    assert_equal(
        head.chunk_seq, Int64(4), "recovered tail seq = 4 (highest survivor)"
    )
    assert_equal(
        head.next_offset,
        Int64(50),
        "recovered next_offset = 50 (log_start_offset 30 + survivors 10+10)"
        " — NOT 0 (no renumber)",
    )
    # The recovered HEAD carries the real top-chunk etag (non-empty).
    assert_true(
        head.etag_of_last_chunk.byte_length() > 0,
        "recovered HEAD carries the real top-chunk etag, not empty",
    )

    # Now append through the recovered handle. The new records MUST occupy the
    # range ABOVE the surviving tail: seq=5, base=50, last=59. WITHOUT the fix
    # this append would claim base_offset=0 and RENUMBER over committed offsets.
    var ap = m2.append(_body(99, 16), rpc)
    assert_equal(ap.chunk_seq, Int64(5), "new chunk lands at seq 5")
    assert_equal(
        ap.base_offset,
        Int64(50),
        "new records get offsets ABOVE the surviving tail (50..59) — committed"
        " offsets intact, NO renumber",
    )
    assert_equal(ap.last_offset, Int64(59), "last offset = 59")

    # Offset-log invariant: the SURVIVING chunks [3,4,5] each present with the
    # expected record_count, cumulative base offsets contiguous from log_start.
    var running = log_start_off
    for s in range(Int(k), 6):
        var c = store.get(chunk_key(prefix, Int64(s)))
        var rc = decode_chunk_record_count(c)
        assert_equal(rc, rpc, "survivor/new chunk has the expected rc")
        running += rc
    assert_equal(
        running,
        Int64(60),
        "cumulative record_count over survivors+new == 60 (no gap/no dup/no"
        " loss relative to log_start)",
    )

    _ = m2^
    _ = manifest^
    _ = store^
    print(
        "      OK — recovery seeded from _LOG_START; committed offsets intact,"
        " no renumber"
    )


# -----------------------------------------------------------------------------
# TEST 2 — a 404 AT-OR-ABOVE log_start (a hole in the SURVIVING range) fails
# LOUD instead of silently truncating the tail.
#
# Commit 5 chunks, advance `_LOG_START` to seq=2/offset=20, then DELETE a
# SURVIVING chunk (seq=3 — at/above log_start) to simulate a torn lineage.
# Recovery MUST raise, not return a mis-derived tail.
# -----------------------------------------------------------------------------
def _test_missing_committed_chunk_fails_loud() raises:
    print(
        "[recovery-log-start] TEST 2 — a missing COMMITTED chunk (404 >="
        " log_start) fails LOUD"
    )
    var store = _Store()
    var prefix = String("recov/p1")
    var rpc = Int64(10)

    var manifest = _make_manifest(store, prefix)
    var N = 5
    for i in range(N):
        _ = manifest.append(_body(i, 16), rpc)

    # Advance log_start to seq=2/offset=20 and reap [0,1] (benign prefix).
    var k = Int64(2)
    _ = manifest.advance_log_start(k, k * rpc, String(""))
    for s in range(Int(k)):
        store.delete(chunk_key(prefix, Int64(s)))

    # Now corrupt the SURVIVING range: delete chunk 3 (>= log_start_seq=2) WITH
    # chunk 4 still present beyond it → a genuine hole in committed data.
    store.delete(chunk_key(prefix, Int64(3)))
    store.delete(head_key(prefix))

    var m2 = _make_manifest(store, prefix)
    var raised = False
    try:
        _ = m2.read_head_authoritative()
    except e:
        raised = True
        var msg = String(e)
        assert_true(
            msg.find("MISSING committed") >= 0,
            "fail-loud message names the missing committed chunk",
        )
        assert_true(
            msg.find("refusing to renumber") >= 0,
            "fail-loud message refuses to renumber",
        )
    assert_true(
        raised,
        "recovery MUST raise on a 404 at/above log_start (torn lineage), not"
        " silently truncate the tail",
    )
    _ = m2^
    _ = manifest^
    _ = store^
    print("      OK — torn surviving lineage fails loud (no silent truncate)")


# -----------------------------------------------------------------------------
# TEST 3 — recovery with NO `_LOG_START` (never-truncated partition) is
# unchanged: replay from seq 0 / offset 0. Guards against the fix regressing
# the common case.
# -----------------------------------------------------------------------------
def _test_recovery_never_truncated_unchanged() raises:
    print(
        "[recovery-log-start] TEST 3 — recovery on a never-truncated partition"
        " (no _LOG_START) is unchanged"
    )
    var store = _Store()
    var prefix = String("recov/p2")
    var rpc = Int64(10)

    var manifest = _make_manifest(store, prefix)
    var N = 4
    for i in range(N):
        _ = manifest.append(_body(i, 16), rpc)

    # No advance_log_start, no reap. Just drop the _HEAD cache and recover.
    store.delete(head_key(prefix))
    var m2 = _make_manifest(store, prefix)
    var head = m2.read_head_authoritative()
    assert_equal(head.chunk_seq, Int64(3), "tail seq = 3")
    assert_equal(
        head.next_offset, Int64(40), "next_offset = 40 (full replay from 0)"
    )
    var ap = m2.append(_body(7, 16), rpc)
    assert_equal(ap.chunk_seq, Int64(4), "append lands at seq 4")
    assert_equal(ap.base_offset, Int64(40), "base offset = 40 (no regression)")
    _ = m2^
    _ = manifest^
    _ = store^
    print("      OK — never-truncated recovery replays from 0 (unchanged)")


def main() raises:
    print(
        "[log-start-aware recovery] crash-recovery silent-renumber"
        " regression (offline, deterministic)"
    )
    _test_recovery_after_retention_no_renumber()
    _test_missing_committed_chunk_fails_loud()
    _test_recovery_never_truncated_unchanged()
    print(
        "[OK] test_cas_recovery_log_start_aware_offline — LIST recovery is"
        " _LOG_START-aware; reaped prefix is benign, a hole in the surviving"
        " range fails loud, committed offsets never renumber"
    )
