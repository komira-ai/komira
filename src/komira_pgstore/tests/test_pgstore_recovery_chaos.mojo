# =============================================================================
# tests/komira_pgstore/test_pgstore_recovery_chaos.mojo
#   HARNESS 2 — CRASH-RECOVERY under FAILURE INJECTION (the chaos pass).
# =============================================================================
#
# The DEEP correctness/chaos campaign's recovery harness. It
# commits a KNOWN txn
# sequence, injects failure/abort at MANY points, then RECOVERS (reopen the
# TableStore from the store; re-fold the WAL [log_start..authoritative head])
# and ASSERTS recovered state == the committed history EXACTLY (multi-version +
# tombstones), with NO committed txn lost and NO aborted/uncommitted write
# visible. Runs on LocalFs (real disk, O_EXCL, true crash-recovery) AND
# SharedInMemory (the Arc-shared map, bucket-is-truth).
#
# THE FAILURE-INJECTION POINTS (the load-bearing chaos surface):
#   (I1) crash BEFORE the create-CAS append — the txn never wrote a chunk. The
#        commit = ONE create (atomicity by construction), so a pre-append crash
#        leaves ZERO durable state of that txn. Recovery sees nothing of it.
#   (I2) DURABLE-BUT-UNACKED — the create-CAS WON (the chunk object is in the
#        bucket) but the process died before the caller observed the 200 AND
#        before the cached `_HEAD` advanced. The §5 contract: the object's
#        presence == its create-CAS won == it committed, so recovery (LIST,
#        bucket-is-truth) MUST recover it as committed. We forge this by writing
#        the chunk object directly + NOT advancing `_HEAD` (or advancing it
#        stale-low), then assert recovery sees the chunk.
#   (I3) STALE CACHED `_HEAD` — the cached `_HEAD` lags the true tail by N
#        chunks. A correctness reader (recovery / commit-OCC) uses
#        `read_head_authoritative` (LIST), so it MUST see the true tail despite
#        the lagging `_HEAD`. We forge a `_HEAD` pinned several slots BELOW the
#        true tail and assert recovery still finds every committed chunk.
#   (I4) TORN-CREATE window — a chunk object is present but its bytes are
#        zero/partial (the O_EXCL create won but the body is still landing).
#        Recovery MUST fail LOUD (a typed decode/truncation error), NEVER
#        silently truncate the tail or misparse — the create-CAS slot is the
#        sole arbiter and a torn body is a transient, not a committed state. We
#        forge a zero-length chunk at the tail and assert recovery raises.
#   (I5) MANY interleaved injection points across a long committed prefix — a
#        seeded sweep that, for every committed sequence position, drops the
#        in-RAM store mid-sequence + reopens, asserting the recovered MVCC view
#        equals the committed-so-far history exactly (multi-version time-travel
#        + tombstones).
#
# Encapsulation / stale-reuse: ZERO UnsafePointer in any signature; ZERO wildcard
# origins / unsafe_from_address / take_pointee. The forged WAL states are
# written through the store's typed `conditional_put` / `chunk_key` /
# `encode_chunk` surface; the reference history is plain owned Lists.
#
# Design: the serverless-Postgres correctness-slice design §5 (recovery) +
#   §2 (commit-chunk-as-one-create atomicity).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    ManifestHead,
    RetryPolicy,
    chunk_key,
    encode_chunk,
    encode_head,
    head_key,
)
from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition

from komira_pgstore.pgstore_codec import (
    PG_OP_PUT,
    PG_OP_TOMBSTONE,
    WriteOp,
    bytes_eq,
    encode_commit_chunk,
)
from komira_pgstore.table_store import TableStore, Txn
from komira_runtime_paths import test_tmpdir


def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into.

    `test_tmpdir()` is $TEST_TMPDIR, private to this run; it raises rather than
    falling back to a `/tmp` path that concurrent runs would share.
    """
    return test_tmpdir()


# =============================================================================
# PRNG + byte helpers (mirror the SI property harness).
# =============================================================================


struct Rng(Movable, Deinitable):
    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next_u64(mut self) -> UInt64:
        self.state += UInt64(0x9E3779B97F4A7C15)
        var z = self.state
        z = (z ^ (z >> UInt64(30))) * UInt64(0xBF58476D1CE4E5B9)
        z = (z ^ (z >> UInt64(27))) * UInt64(0x94D049BB133111EB)
        return z ^ (z >> UInt64(31))

    def next_int(mut self, n: Int) -> Int:
        if n <= 1:
            return 0
        return Int(self.next_u64() % UInt64(n))


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _key(i: Int) -> List[UInt8]:
    return _b(String("k") + String(i))


def _unique() -> String:
    from std.time import perf_counter_ns

    var x = UInt64(perf_counter_ns())
    x ^= x >> UInt64(33)
    x *= UInt64(0xFF51AFD7ED558CCD)
    x ^= x >> UInt64(33)
    var out = String("")
    var shift = 60
    while shift >= 0:
        var nib = Int((x >> UInt64(shift)) & UInt64(0xF))
        if nib < 10:
            out += chr(0x30 + nib)
        else:
            out += chr(0x61 + nib - 10)
        shift -= 4
    return out^


# =============================================================================
# A reference MVCC model identical to the SI harness's (committed ground truth).
# =============================================================================


@fieldwise_init
struct RefWrite(Copyable, Movable, Deinitable):
    var op: UInt8
    var key: List[UInt8]
    var value: List[UInt8]


@fieldwise_init
struct RefCommit(Copyable, Movable, Deinitable):
    var writes: List[RefWrite]


struct RefModel(Movable, Deinitable):
    var commits: List[RefCommit]

    def __init__(out self):
        self.commits = List[RefCommit]()

    def head(self) -> Int64:
        return Int64(len(self.commits) - 1)

    def append(mut self, var writes: List[RefWrite]):
        self.commits.append(RefCommit(writes^))

    def visible_at(self, key: List[UInt8], snapshot: Int64) -> Optional[List[UInt8]]:
        var s = Int(snapshot)
        if s >= len(self.commits):
            s = len(self.commits) - 1
        var i = s
        while i >= 0:
            ref c = self.commits[i]
            var j = len(c.writes) - 1
            while j >= 0:
                ref w = c.writes[j]
                if bytes_eq(w.key, key):
                    if w.op == PG_OP_TOMBSTONE:
                        return Optional[List[UInt8]](None)
                    return Optional(w.value.copy())
                j -= 1
            i -= 1
        return Optional[List[UInt8]](None)


def _opt_eq(a: Optional[List[UInt8]], b: Optional[List[UInt8]]) -> Bool:
    if Bool(a) != Bool(b):
        return False
    if not a:
        return True
    return bytes_eq(a.value(), b.value())


def _opt_str(a: Optional[List[UInt8]]) -> String:
    if not a:
        return String("<None>")
    var out = String("")
    var v = a.value().copy()
    for i in range(len(v)):
        out += chr(Int(v[i]))
    return out^


# =============================================================================
# Assert: a fresh-opened (recovered) store equals the reference at EVERY
# committed snapshot for EVERY key (multi-version time-travel + tombstones).
# =============================================================================


def _assert_recovered_eq_ref[
    Store: ConditionalWriteStore
](
    mut ts: TableStore[Store],
    refm: RefModel,
    n_keys: Int,
    tag: String,
) raises:
    var head = refm.head()
    var snap = Int64(0)
    while snap <= head:
        var rdr = ts.begin()
        rdr.snapshot_lsn = snap  # time-travel to the exact committed LSN
        for ki in range(n_keys):
            var kk = _key(ki)
            var got = ts.get(rdr, kk.copy())
            var want = refm.visible_at(kk, snap)
            assert_true(
                _opt_eq(got, want),
                tag + ": RECOVERY mismatch at snapshot " + String(Int(snap))
                + " key=" + _opt_str(Optional(kk.copy()))
                + " store=" + _opt_str(got) + " ref=" + _opt_str(want),
            )
        ts.abort(rdr^)
        snap += Int64(1)
    # The recovered head MUST equal the committed reference head (no committed
    # txn lost; no phantom chunk recovered).
    assert_equal(
        ts.wal_head_seq(), head,
        tag + ": recovered head must equal the committed reference head",
    )


# =============================================================================
# (I5) The seeded crash-at-every-position sweep — commit a known prefix, drop
#      the store at position P, reopen, assert recovery == committed-so-far.
# =============================================================================


def _commit_one[
    Store: ConditionalWriteStore
](mut ts: TableStore[Store], var ws: List[WriteOp]) raises -> Int64:
    """Commit a single multi-write txn (the buffered write-set) and return the
    won LSN. The caller mirrors the same write-set into the reference model."""
    var t = ts.begin()
    for i in range(len(ws)):
        ref w = ws[i]
        if w.op == PG_OP_TOMBSTONE:
            t.delete(w.key.copy())
        else:
            t.insert(w.key.copy(), w.row.copy())
    var r = ts.commit(t^)
    return r.commit_lsn


def _gen_write_set(mut rng: Rng, si: Int, n_keys: Int) -> List[WriteOp]:
    """A randomized 1-3-write txn over `n_keys` keys (PUT or TOMBSTONE)."""
    var nw = 1 + rng.next_int(3)
    var seen = List[Int]()
    var ws = List[WriteOp]()
    for _ in range(nw):
        var ki = rng.next_int(n_keys)
        var dup = False
        for s in range(len(seen)):
            if seen[s] == ki:
                dup = True
                break
        if dup:
            continue
        seen.append(ki)
        if rng.next_int(5) == 0:
            ws.append(WriteOp(PG_OP_TOMBSTONE, _key(ki), List[UInt8]()))
        else:
            var v = _b(String("v") + String(si) + String("_") + String(ki))
            ws.append(WriteOp(PG_OP_PUT, _key(ki), v^))
    if len(ws) == 0:
        ws.append(
            WriteOp(PG_OP_PUT, _key(0), _b(String("v") + String(si)))
        )
    return ws^


def test_recovery_crash_at_every_position_fs() raises:
    print(
        "[chaos-I5] LocalFs crash-at-every-position sweep — drop the store at"
        " each committed position + reopen, recovery == committed-so-far"
    )
    var n_seeds = 16
    var n_txns = 24
    var n_keys = 6
    for s in range(n_seeds):
        var seed = UInt64(0xDEAD0000 + s * 0x1000193)
        var root = (_scratch_dir() + String("/pg_chaos_fs_")) + _unique() + String("_") + String(s)
        var prefix = String("pg/chaos/i5")
        # seed the root dir once
        var seed_store = LocalFsConditionalStore(root.copy())
        _ = seed_store^

        var rng = Rng(seed)
        var refm = RefModel()

        # Commit the known sequence, ONE txn at a time, dropping + reopening the
        # store BETWEEN every commit (the "crash after commit P" model). Each
        # reopen is a true recovery off disk.
        var ti = 0
        while ti < n_txns:
            var ts = TableStore[LocalFsConditionalStore].open(
                CasManifestStore[LocalFsConditionalStore](
                    store=LocalFsConditionalStore(root.copy(), True),
                    prefix=prefix.copy(), retry=RetryPolicy.fast_test(),
                )
            )
            var ws = _gen_write_set(rng, ti, n_keys)
            var ws_mirror = ws.copy()
            _ = _commit_one(ts, ws^)
            # mirror into the reference
            var rw = List[RefWrite]()
            for wi in range(len(ws_mirror)):
                ref w = ws_mirror[wi]
                rw.append(RefWrite(w.op, w.key.copy(), w.row.copy()))
            refm.append(rw^)
            # DROP the store (let it destruct) — simulate a crash right after
            # this commit landed. The next loop iteration reopens off disk.
            _ = ts^

            # Reopen + assert recovery == committed-so-far (the chaos check).
            var rec = TableStore[LocalFsConditionalStore].open(
                CasManifestStore[LocalFsConditionalStore](
                    store=LocalFsConditionalStore(root.copy(), True),
                    prefix=prefix.copy(), retry=RetryPolicy.fast_test(),
                )
            )
            _assert_recovered_eq_ref(rec, refm, n_keys, String("i5-fs"))
            _ = rec^
            ti += 1
    print("    [OK] (I5) LocalFs:", n_seeds, "seeds x", n_txns, "crash positions, recovery exact")


def test_recovery_crash_at_every_position_shared() raises:
    print(
        "[chaos-I5] SharedInMemory crash-at-every-position sweep (Arc-map,"
        " bucket-is-truth) — recovery == committed-so-far at every position"
    )
    var n_seeds = 16
    var n_txns = 24
    var n_keys = 6
    for s in range(n_seeds):
        var seed = UInt64(0xBEEF0000 + s * 0x1000193)
        var shared = SharedInMemoryConditionalStore()
        var prefix = String("pg/chaos/i5_shared/s") + String(s)
        var rng = Rng(seed)
        var refm = RefModel()
        var ti = 0
        while ti < n_txns:
            var ts = TableStore[SharedInMemoryConditionalStore].open(
                CasManifestStore[SharedInMemoryConditionalStore](
                    store=shared.clone(), prefix=prefix.copy(),
                    retry=RetryPolicy.fast_test(),
                )
            )
            var ws = _gen_write_set(rng, ti, n_keys)
            var ws_mirror = ws.copy()
            _ = _commit_one(ts, ws^)
            var rw = List[RefWrite]()
            for wi in range(len(ws_mirror)):
                ref w = ws_mirror[wi]
                rw.append(RefWrite(w.op, w.key.copy(), w.row.copy()))
            refm.append(rw^)
            _ = ts^  # crash

            var rec = TableStore[SharedInMemoryConditionalStore].open(
                CasManifestStore[SharedInMemoryConditionalStore](
                    store=shared.clone(), prefix=prefix.copy(),
                    retry=RetryPolicy.fast_test(),
                )
            )
            _assert_recovered_eq_ref(rec, refm, n_keys, String("i5-shared"))
            _ = rec^
            ti += 1
        _ = shared^
    print("    [OK] (I5) SharedInMemory:", n_seeds, "seeds x", n_txns, "positions, recovery exact")


# =============================================================================
# Forging helpers — write a chunk object + (optionally stale) _HEAD directly,
# modelling a durable-but-unacked / stale-head / torn-create state.
# =============================================================================


def _forge_chunk_shared(
    store: SharedInMemoryConditionalStore,
    prefix: String,
    seq: Int64,
    var write_set: List[WriteOp],
) raises:
    """Write a real, well-formed commit chunk at `seq` directly (the create-CAS
    WON), bypassing the OCC loop. Does NOT advance `_HEAD` — the durable-but-
    unacked / stale-head shape."""
    var body = encode_commit_chunk(seq - Int64(1), write_set)
    var encoded = encode_chunk(body, Int64(len(write_set)))
    _ = store.conditional_put(
        chunk_key(prefix.copy(), seq),
        encoded,
        WritePrecondition.if_none_match_star(),
    )


def _force_head_shared(
    store: SharedInMemoryConditionalStore,
    prefix: String,
    chunk_seq: Int64,
    next_offset: Int64,
) raises:
    """Force the cached `_HEAD` object to a (possibly stale-low) value."""
    var hd = encode_head(ManifestHead(chunk_seq, next_offset, String("")))
    _ = store.conditional_put(head_key(prefix.copy()), hd, WritePrecondition.none())


# =============================================================================
# (I2) DURABLE-BUT-UNACKED — chunk object present, _HEAD never advanced.
#      Recovery (LIST, bucket-is-truth) MUST recover it as committed.
# =============================================================================


def test_recovery_durable_but_unacked_shared() raises:
    print(
        "[chaos-I2] durable-but-unacked: chunk present, _HEAD NOT advanced —"
        " recovery (bucket-is-truth) recovers it as committed"
    )
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/chaos/i2/") + _unique()
    var refm = RefModel()

    # Commit two txns normally (so _HEAD exists at seq 1).
    var ts = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var ws0 = List[WriteOp]()
    ws0.append(WriteOp(PG_OP_PUT, _key(0), _b("zero")))
    _ = _commit_one(ts, ws0.copy())
    var rw0 = List[RefWrite]()
    rw0.append(RefWrite(PG_OP_PUT, _key(0), _b("zero")))
    refm.append(rw0^)

    var ws1 = List[WriteOp]()
    ws1.append(WriteOp(PG_OP_PUT, _key(1), _b("one")))
    _ = _commit_one(ts, ws1.copy())
    var rw1 = List[RefWrite]()
    rw1.append(RefWrite(PG_OP_PUT, _key(1), _b("one")))
    refm.append(rw1^)
    _ = ts^

    # FORGE a durable-but-unacked chunk at seq 2 (k2='two'), WITHOUT advancing
    # `_HEAD` (it still points at seq 1). The crash struck after the create-CAS
    # 200 but before the head advance + before the caller observed the ack.
    var ws2 = List[WriteOp]()
    ws2.append(WriteOp(PG_OP_PUT, _key(2), _b("two")))
    _forge_chunk_shared(shared, prefix, Int64(2), ws2^)
    # The §5 outcome: the write IS durable, so recovery recovers it as committed.
    var rw2 = List[RefWrite]()
    rw2.append(RefWrite(PG_OP_PUT, _key(2), _b("two")))
    refm.append(rw2^)

    var rec = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    # head must be 2 (the durable-but-unacked chunk), NOT 1 (the stale _HEAD).
    assert_equal(
        rec.wal_head_seq(), Int64(2),
        "I2: recovery uses bucket-is-truth, recovers the unacked chunk (head=2)",
    )
    _assert_recovered_eq_ref(rec, refm, 3, String("i2"))
    _ = rec^
    _ = shared^
    print("    [OK] (I2) durable-but-unacked chunk recovered as committed")


# =============================================================================
# (I3) STALE CACHED _HEAD — _HEAD pinned several slots BELOW the true tail.
#      Recovery + commit-OCC use read_head_authoritative (LIST) -> true tail.
# =============================================================================


def test_recovery_stale_head_shared() raises:
    print(
        "[chaos-I3] stale cached _HEAD pinned BELOW the true tail — recovery"
        " (authoritative LIST) still finds every committed chunk"
    )
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/chaos/i3/") + _unique()
    var refm = RefModel()
    var n = 6

    var ts = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var total_recs = Int64(0)
    for i in range(n):
        var ws = List[WriteOp]()
        ws.append(WriteOp(PG_OP_PUT, _key(i), _b(String("v") + String(i))))
        _ = _commit_one(ts, ws.copy())
        var rw = List[RefWrite]()
        rw.append(RefWrite(PG_OP_PUT, _key(i), _b(String("v") + String(i))))
        refm.append(rw^)
        total_recs += Int64(1)
    _ = ts^

    # FORGE a stale-low `_HEAD` pinned at seq 1 (true tail is n-1=5). A reader
    # that trusted the cache would MISS chunks 2..5 (a silent isolation hole);
    # recovery uses authoritative LIST and must see all of them.
    _force_head_shared(shared, prefix, Int64(1), Int64(2))

    var rec = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    assert_equal(
        rec.wal_head_seq(), Int64(n - 1),
        "I3: authoritative recovery sees the true tail despite a stale-low _HEAD",
    )
    _assert_recovered_eq_ref(rec, refm, n, String("i3"))
    _ = rec^

    # ALSO: a commit OVER the stale-head store must land at the AUTHORITATIVE
    # head+1 (= n), not the stale-head+1 (= 2) — the OCC/create-CAS coupling
    # (§8) must not be fooled by the lagging cache.
    _force_head_shared(shared, prefix, Int64(1), Int64(2))  # re-stale it
    var ts2 = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var ws_new = List[WriteOp]()
    ws_new.append(WriteOp(PG_OP_PUT, _key(99), _b("new")))
    var lsn = _commit_one(ts2, ws_new^)
    assert_equal(
        lsn, Int64(n),
        "I3: commit over a stale-low _HEAD lands at AUTHORITATIVE head+1 (= n),"
        " not stale-head+1 — the OCC/create-CAS coupling holds",
    )
    _ = ts2^
    _ = shared^
    print("    [OK] (I3) stale-_HEAD recovery + commit-coupling both authoritative")


# =============================================================================
# (I4) TORN-CREATE window — a chunk object present but ZERO-length bytes.
#      Recovery MUST fail LOUD (a typed error), NEVER silently truncate.
# =============================================================================


def test_recovery_torn_create_fails_loud_shared() raises:
    print(
        "[chaos-I4] torn-create: a zero-length chunk at the tail — recovery"
        " MUST fail LOUD, never silently truncate / misparse"
    )
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/chaos/i4/") + _unique()

    # Commit two clean txns (seq 0,1; _HEAD at 1).
    var ts = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    for i in range(2):
        var ws = List[WriteOp]()
        ws.append(WriteOp(PG_OP_PUT, _key(i), _b(String("v") + String(i))))
        _ = _commit_one(ts, ws.copy())
    _ = ts^

    # FORGE a TORN chunk at seq 2: a present object with ZERO bytes (the O_EXCL
    # create won the slot but the body never landed). A LIST recovery that
    # replays cumulative record_counts hits this object and MUST fail loud
    # (decode of a zero-length chunk envelope raises), not silently truncate at
    # seq 1 or misparse garbage as a committed chunk.
    _ = shared.conditional_put(
        chunk_key(prefix.copy(), Int64(2)),
        List[UInt8](),  # ZERO-length torn body
        WritePrecondition.if_none_match_star(),
    )

    var raised = False
    try:
        var rec = TableStore[SharedInMemoryConditionalStore].open(
            CasManifestStore[SharedInMemoryConditionalStore](
                store=shared.clone(), prefix=prefix.copy(),
                retry=RetryPolicy.fast_test(),
            )
        )
        # If open() did NOT raise, recovery silently tolerated a torn chunk —
        # a correctness failure. Force the read to surface any silent truncation.
        _ = rec.wal_head_seq()
        _ = rec^
    except e:
        raised = True
        print("    recovery raised on torn chunk (fail-loud, correct): ", String(e))
    assert_true(
        raised,
        "I4: recovery MUST fail LOUD on a torn (zero-length) tail chunk —"
        " silently tolerating it would mis-derive the committed tail",
    )
    _ = shared^
    print("    [OK] (I4) torn-create recovery fails loud")


# =============================================================================
# (I1) crash BEFORE the create-CAS append — nothing durable; recovery is clean.
# =============================================================================


def test_recovery_pre_append_crash_shared() raises:
    print(
        "[chaos-I1] crash BEFORE the create-CAS append — the txn buffered but"
        " never committed; recovery shows NONE of its writes (no dirty state)"
    )
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/chaos/i1/") + _unique()
    var refm = RefModel()

    var ts = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    # commit one clean txn
    var ws = List[WriteOp]()
    ws.append(WriteOp(PG_OP_PUT, _key(0), _b("committed")))
    _ = _commit_one(ts, ws.copy())
    var rw = List[RefWrite]()
    rw.append(RefWrite(PG_OP_PUT, _key(0), _b("committed")))
    refm.append(rw^)

    # Now BEGIN + buffer a write, then crash (drop the store) WITHOUT commit.
    # The buffered write only ever lived in RAM (writes touch the store at
    # commit, §3.2) — so nothing of it is durable.
    var t = ts.begin()
    t.insert(_key(1), _b("never-committed"))
    # do NOT commit — drop the txn + the store (the crash).
    ts.abort(t^)
    _ = ts^

    var rec = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var rdr = rec.begin()
    var k1 = rec.get(rdr, _key(1))
    assert_true(
        not Bool(k1),
        "I1: an uncommitted (buffered-only) write MUST NOT be visible after"
        " recovery (no dirty/uncommitted state durable)",
    )
    var k0 = rec.get(rdr, _key(0))
    assert_true(
        Bool(k0) and bytes_eq(k0.value(), _b("committed")),
        "I1: the committed write IS durable + recovered",
    )
    rec.abort(rdr^)
    _assert_recovered_eq_ref(rec, refm, 2, String("i1"))
    _ = rec^
    _ = shared^
    print("    [OK] (I1) pre-append crash leaves no dirty state")


# =============================================================================
# main
# =============================================================================


def main() raises:
    print("== pgstore crash-recovery under failure injection (chaos) ==")
    test_recovery_pre_append_crash_shared()         # I1
    test_recovery_durable_but_unacked_shared()      # I2
    test_recovery_stale_head_shared()               # I3
    test_recovery_torn_create_fails_loud_shared()   # I4
    test_recovery_crash_at_every_position_shared()  # I5 (shared)
    test_recovery_crash_at_every_position_fs()      # I5 (LocalFs — true disk)
    print(
        "[OK] test_pgstore_recovery_chaos — crash-recovery under failure"
        " injection at 5 classes of points (pre-append / durable-but-unacked /"
        " stale-_HEAD / torn-create / crash-at-every-position): recovered state"
        " == committed history EXACTLY (multi-version + tombstones); no"
        " committed txn lost, no uncommitted write visible, torn-create fails"
        " loud — on SharedInMemory + LocalFs"
    )
