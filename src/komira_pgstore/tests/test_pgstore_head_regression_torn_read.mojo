# =============================================================================
# komira_pgstore/tests/test_pgstore_head_regression_torn_read.mojo
#   P0 CONCURRENCY BUG (found in production) — the
#   pgstore-on-GCS `_HEAD`-advance protocol corrupts under a 2nd / interrupted
#   writer, producing a torn read at a fresh open.
# =============================================================================
#
# THE PROD SYMPTOM. Running a 2nd writer (a seeding CLI) against the LIVE
# pgstore-on-GCS store corrupted it: a fresh API boot's `begin()` / open
# followed the durable `_HEAD` pointer to a chunk it does NOT fully point at,
# then `cas_manifest: truncated i64 at offset 0` — and every subsequent open
# (API boot) crash-looped. Killing a writer mid-commit left the same torn state.
#
# THE ROOT-CAUSE TWO-PART DEFECT (confirmed by reading the commit/advance call
# sites — `CasManifestStore._try_advance_head_fast` + `_recover_head_by_list`):
#
#   (A) `_HEAD`-REGRESSION ON THE BEST-EFFORT FAST ADVANCE. The winning commit
#       advances the cached `_HEAD` pointer with a ONE-CALL `If-Match(etag)`
#       fast path. That fast path writes `ManifestHead(candidate_seq, ...)`
#       conditioned ONLY on the `_HEAD` object's etag being unchanged since it
#       was read — it NEVER verifies the `_HEAD` it overwrites is actually at
#       `candidate_seq - 1`. So a writer whose `expected_head_etag` matches a
#       `_HEAD` already at a HIGHER seq regresses `_HEAD` BACKWARD to a lower
#       seq. `_HEAD` is "only a cache" for the AUTHORITATIVE (LIST) recovery —
#       but `begin()` and the warm-read path TRUST the cached `_HEAD` for the
#       snapshot, and a regressed `_HEAD.next_offset` mis-bases the offset map.
#       The slow path (`_try_advance_head_once`) correctly guards
#       `if chunk_seq <= cur_seq: return` — the fast path skipped that guard.
#
#   (B) A regressed / torn `_HEAD` (or a present-but-not-yet-durable chunk it
#       points at) makes a fresh `read_head()` decode a `_HEAD` whose
#       `chunk_seq` is below the true durable tail, so a `begin()` snapshot
#       pins a STALE-LOW LSN that silently MISSES committed rows — the prod
#       "2nd writer corrupted the store; fresh boots can't see the data".
#
# THE INVARIANT THE FIX ESTABLISHES (Delta/Iceberg-style, the same class as the
# cold-catalog-412 fix + the broker `_HEAD`-advance work): the chunk objects are
# written IMMUTABLY + FULLY DURABLE FIRST (content-addressed create-CAS), THEN a
# SINGLE atomic `_HEAD` advance that can ONLY MOVE FORWARD (monotone). The fast
# advance MUST verify the `_HEAD` it overwrites is at exactly `prev_seq` (not
# merely etag-current), so it can never regress the pointer below a concurrently-
# advanced tail. An interrupted writer leaves NO torn state — `_HEAD` simply
# never advanced past durable chunks, and a stale-low `_HEAD` is recovered by the
# authoritative LIST.
#
# THE FALSIFIERS (hermetic, no emulator, deterministic, NO threads):
#   T1 — drive the EXACT fast-advance regression through the public OCC commit
#        surface: a high `_HEAD` is in place; a writer whose advance carries a
#        matching-but-stale etag for a LOWER candidate must NOT regress `_HEAD`.
#        Pre-fix: the fast `If-Match` lands a LOWER seq -> `read_head()` returns
#        a chunk_seq BELOW the true durable tail. Post-fix: monotone — `_HEAD`
#        stays at the true tail.
#   T2 — end-to-end: TWO share-nothing handles over ONE prefix interleave
#        commits (the API + seeding CLI shape); a THIRD fresh handle opens and
#        its `begin()` snapshot MUST see EVERY committed row (no stale-low head
#        miss) and its open MUST NOT raise a torn-read.
#
#   PRE-FIX: T1's `read_head()` returns the regressed (lower) seq; T2's fresh
#            handle misses rows / the open raises a truncated decode.
#   POST-FIX: `_HEAD` is monotone; every fresh open sees the full durable tail.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    ManifestHead,
    RetryPolicy,
    chunk_key,
    decode_head,
    encode_chunk,
    encode_head,
    head_key,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition

from komira_pgstore.pgstore_codec import (
    PG_OP_PUT,
    WriteOp,
    encode_commit_chunk,
)
from komira_pgstore.table_store import TableStore, Txn


comptime _Store = SharedInMemoryConditionalStore


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _wal(backing: _Store, prefix: String) raises -> CasManifestStore[_Store]:
    return CasManifestStore[_Store](
        store=backing.clone(),
        prefix=prefix.copy(),
        retry=RetryPolicy.fast_test(),
    )


def _open_ts(backing: _Store, prefix: String) raises -> TableStore[_Store]:
    return TableStore[_Store].open(_wal(backing, prefix))


# =============================================================================
# T1 — the fast-advance `_HEAD`-regression falsifier (the (A) defect, direct).
# =============================================================================


def test_fast_head_advance_never_regresses() raises:
    """Forge the EXACT prod race at the `_HEAD`-advance call site: the durable
    `_HEAD` is already at a HIGH seq, while a writer WINS a LOWER (still-free)
    slot and its best-effort fast advance carries a matching etag — so the
    advance lands `ManifestHead(lower_seq, ...)`, REGRESSING `_HEAD` below the
    true durable tail. The monotone contract: the advance must NEVER move
    `_HEAD` backward.

    Reproduced deterministically: forge a WAL where the durable chunks are at
    slots 0 and 2 (slot 1 is left FREE) and `_HEAD` is already at the HIGH seq
    2 (etag e2). Then drive a single-slot append that WINS the free slot 1. Its
    create-CAS succeeds, then the fast `If-Match(e2)` advance fires with
    `candidate_seq = 1` — and pre-fix that LANDS, regressing `_HEAD` from seq 2
    to seq 1. A reader following the regressed `_HEAD` would pin a stale-low
    snapshot and silently miss slot 2's commit.

    (This is the (A) defect in isolation: the fast advance is gated ONLY on the
    `_HEAD` etag being current, never on `_HEAD` actually being at
    `candidate_seq - 1`, so a win at a slot BELOW the current head regresses it.)

    FAILS ON CURRENT CODE (`_try_advance_head_fast`): `read_head()` after the
    slot-1 win returns chunk_seq 1 (the regression). (Red before the fix.)"""
    var backing = _Store()
    var prefix = String("pg/head_regress_t1")
    var probe = backing.clone()

    # Forge the WAL: durable chunks at slots 0 and 2 (slot 1 left FREE), with the
    # durable `_HEAD` already at the HIGH seq 2 (the steady state after a sibling
    # advanced past a gap that a torn writer never filled).
    _forge_chunk(probe, prefix, Int64(0), Int64(0), "k0", "v0")
    _forge_chunk(probe, prefix, Int64(2), Int64(2), "k2", "v2")
    # `_HEAD` at seq 2, next_offset 3 — the true high tail.
    var hd = encode_head(ManifestHead(Int64(2), Int64(3), String("")))
    _ = probe.conditional_put(
        head_key(prefix.copy()), hd, WritePrecondition.none()
    )
    var raw0 = probe.get(head_key(prefix.copy()))
    assert_equal(decode_head(raw0).chunk_seq, Int64(2), "setup: _HEAD at seq 2")

    # A writer WINS the free slot 1 (its OCC would target auth_head+1, but the
    # single-slot verb lets us drive the exact regression: win slot 1, advance).
    var wal2 = _wal(backing, prefix)
    var body1 = encode_commit_chunk(Int64(0), _one_put("k1", "v1"))
    var maybe = wal2.try_append_at_seq(Int64(1), Int64(1), body1, Int64(1))
    assert_true(Bool(maybe), "slot 1 was free -> the append WINS it")

    # THE ASSERTION: the durable `_HEAD` must STILL be at seq 2 (monotone). Pre-
    # fix the winning slot-1 fast advance regressed `_HEAD` to seq 1.
    var raw1 = probe.get(head_key(prefix.copy()))
    var head1 = decode_head(raw1)
    assert_true(
        head1.chunk_seq >= Int64(2),
        "MONOTONE: a win at a slot BELOW the head must NOT regress _HEAD"
        " (got chunk_seq " + String(Int(head1.chunk_seq)) + ", expected >= 2)",
    )

    # And a fresh handle's begin() pins the TRUE tail (seq 2), not a regression.
    var fresh = TableStore[_Store].open(_wal(backing, prefix))
    var fh = fresh.begin()
    assert_equal(
        fh.snapshot_lsn,
        Int64(2),
        "a fresh begin() pins the TRUE tail (seq 2), not a regressed seq",
    )
    fresh.abort(fh^)
    _ = fresh^
    _ = backing^
    print("    [OK] T1: fast _HEAD advance is monotone — no regression")


def _one_put(k: String, v: String) -> List[WriteOp]:
    var ws = List[WriteOp]()
    ws.append(WriteOp(PG_OP_PUT, _b(k), _b(v)))
    return ws^


def _forge_chunk(
    store: _Store,
    prefix: String,
    seq: Int64,
    snapshot: Int64,
    k: String,
    v: String,
) raises:
    """Directly create a fully-durable commit chunk at `seq` (one PUT of k=v),
    bypassing the OCC loop — to forge a known WAL state for the regression
    falsifier. The chunk's create-CAS 'wins' (If-None-Match), exactly as a real
    committed chunk does."""
    var body = encode_commit_chunk(snapshot, _one_put(k, v))
    var encoded = encode_chunk(body, Int64(1))
    _ = store.conditional_put(
        chunk_key(prefix.copy(), seq),
        encoded,
        WritePrecondition.if_none_match_star(),
    )


# =============================================================================
# T2 — end-to-end: 2 interleaved writers + a fresh open sees every row.
# =============================================================================


def test_two_writers_fresh_open_sees_all_rows() raises:
    """The PROD shape: TWO share-nothing handles over ONE prefix (the API worker
    + a seeding CLI) interleave commits; a THIRD fresh handle then opens and
    its `begin()` snapshot MUST see EVERY committed row, and the open must NOT
    raise a torn read.

    The interleave is deterministic (single-threaded, alternating handles), so
    every commit lands at a known slot. After N*2 commits the authoritative tail
    is 2N-1; a fresh handle's `begin()` must pin exactly that (so it sees all
    rows), and reading each key back must return its committed value.

    FAILS ON CURRENT CODE: writer B's fast `_HEAD` advance can regress the
    pointer that writer A advanced (the (A) defect), so a fresh handle's cached
    `read_head()` pins a stale-low snapshot and MISSES the rows committed above
    it — exactly "the 2nd writer corrupted the store; fresh boots can't see the
    data". (Red before the fix.)"""
    var backing = _Store()
    var prefix = String("pg/head_regress_t2")

    # Two share-nothing handles (the API worker + the seeding CLI), each its own
    # TableStore over a clone of the same backing map / same prefix.
    var a = _open_ts(backing, prefix)
    var b = _open_ts(backing, prefix)

    comptime N = 6
    # Alternate A / B commits. A commits a0,a1,... ; B commits b0,b1,... The OCC
    # create-CAS serializes them onto a gapless slot sequence 0..2N-1.
    for i in range(N):
        var ta = a.begin()
        ta.insert(_b(String("a") + String(i)), _b(String("av") + String(i)))
        _ = a.commit(ta^)
        var tb = b.begin()
        tb.insert(_b(String("b") + String(i)), _b(String("bv") + String(i)))
        _ = b.commit(tb^)

    # A THIRD fresh handle opens (a cold API boot). Its begin() must pin the TRUE
    # authoritative tail; reading every committed key must return its value.
    var fresh = _open_ts(backing, prefix)
    var ft = fresh.begin()
    assert_equal(
        ft.snapshot_lsn,
        Int64(2 * N - 1),
        "fresh open pins the FULL durable tail (2N-1), no stale-low head miss",
    )
    for i in range(N):
        var ga = fresh.get(ft, _b(String("a") + String(i)))
        assert_true(
            Bool(ga),
            "fresh handle sees A's committed key a" + String(i),
        )
        var gb = fresh.get(ft, _b(String("b") + String(i)))
        assert_true(
            Bool(gb),
            "fresh handle sees B's committed key b" + String(i),
        )
    fresh.abort(ft^)

    # The authoritative head + cached head AGREE (no regression): a 4th handle's
    # cached read_head() equals the LIST-authoritative tail.
    var head_seq = fresh.wal_head_seq()
    assert_equal(
        head_seq,
        Int64(2 * N - 1),
        "authoritative WAL head is the full 2N-1 tail",
    )
    var probe = backing.clone()
    var raw = probe.get(head_key(prefix.copy()))
    var dh = decode_head(raw)
    assert_equal(
        dh.chunk_seq,
        Int64(2 * N - 1),
        "durable _HEAD == authoritative tail (cached head never regressed)",
    )

    _ = a^
    _ = b^
    _ = fresh^
    _ = backing^
    print(
        "    [OK] T2: 2 interleaved writers — a fresh open sees ALL rows,"
        " no _HEAD regression"
    )


# =============================================================================
# T3 — interrupted writer (chunk durable, `_HEAD` never advanced) leaves NO
#      torn state: a fresh open recovers the durable tail authoritatively.
# =============================================================================


def test_interrupted_writer_durable_chunk_no_torn_open() raises:
    """The killed-mid-commit shape (prod): a writer wins a chunk slot's create-
    CAS (the chunk is FULLY durable) but the process dies BEFORE the `_HEAD`
    advance. The §5 contract: the chunk's PRESENCE == it committed, so a fresh
    open's authoritative LIST recovery MUST recover it — and a stale-LOW (or
    absent) `_HEAD` must NEVER make the open raise a torn read.

    We forge it: commit 2 chunks normally (seq 0,1, `_HEAD`->1), then directly
    write a durable chunk at seq 2 WITHOUT advancing `_HEAD` (the interrupted-
    writer state). A fresh `open()` must replay [0..2] and a begin() must pin
    seq 2.

    FAILS ON A NAIVE CACHED-HEAD OPEN: an open that trusted the stale `_HEAD`
    (seq 1) would miss seq 2's row. (`open()` already uses the authoritative
    LIST — this guards that the interrupted-writer state stays recoverable and
    that the monotone-advance fix did not regress that recovery.)"""
    var backing = _Store()
    var prefix = String("pg/head_regress_t3")

    var ts = _open_ts(backing, prefix)
    for i in range(2):
        var t = ts.begin()
        t.insert(_b(String("k") + String(i)), _b(String("kv") + String(i)))
        _ = ts.commit(t^)

    # The durable `_HEAD` is at seq 1. Forge an INTERRUPTED writer: write a fully
    # durable chunk at seq 2 (its create-CAS "won") but DO NOT advance `_HEAD`.
    var probe = backing.clone()
    var body = encode_commit_chunk(Int64(1), _one_put("k2", "kv2"))
    var encoded = encode_chunk(body, Int64(1))
    _ = probe.conditional_put(
        chunk_key(prefix.copy(), Int64(2)),
        encoded,
        WritePrecondition.if_none_match_star(),
    )
    # `_HEAD` is deliberately LEFT at seq 1 (the interrupted-writer torn-ish
    # state: durable chunk, lagging pointer).
    var rawh = probe.get(head_key(prefix.copy()))
    var dh = decode_head(rawh)
    assert_equal(dh.chunk_seq, Int64(1), "setup: _HEAD lags at seq 1")

    # A fresh open recovers the AUTHORITATIVE tail (seq 2) — the interrupted
    # writer's durable chunk is committed by the bucket-is-truth contract.
    var fresh = _open_ts(backing, prefix)
    var ft = fresh.begin()
    assert_equal(
        ft.snapshot_lsn,
        Int64(2),
        "fresh open recovers the interrupted writer's durable chunk (seq 2)",
    )
    var g = fresh.get(ft, _b("k2"))
    assert_true(Bool(g), "the interrupted writer's row k2 is visible (committed)")
    fresh.abort(ft^)

    _ = ts^
    _ = fresh^
    _ = backing^
    print(
        "    [OK] T3: interrupted writer (durable chunk, lagging _HEAD) — fresh"
        " open recovers it, no torn read"
    )


def main() raises:
    print(
        "=== pgstore _HEAD-regression torn-read ==="
    )
    test_fast_head_advance_never_regresses()
    test_two_writers_fresh_open_sees_all_rows()
    test_interrupted_writer_durable_chunk_no_torn_open()
    print(
        "=== PROVEN: _HEAD advance is monotone; a 2nd / interrupted writer"
        " never corrupts the store; every fresh open sees the full tail ==="
    )
