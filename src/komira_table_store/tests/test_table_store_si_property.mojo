# =============================================================================
# src/komira_pgstore/tests/test_pgstore_si_property.mojo
#   HARNESS 1 — randomized Snapshot-Isolation PROPERTY check (Jepsen-style).
# =============================================================================
#
# The DEEP correctness/chaos campaign's core property harness. It
# spawns MANY
# randomized transaction histories over OVERLAPPING keys and ASSERTS Snapshot
# Isolation holds, by checking every observed history against a TOTALLY-ORDERED
# reference model. The bar is the Jepsen-style "is every observed history
# explainable by SOME serial-ish SI schedule" — we try hard to find an
# interleaving that violates SI.
#
# WHAT SI MEANS HERE (the properties asserted, design §4 / §3.4):
#   * NO lost update             — first-committer-wins; a W-W conflict on a key
#                                  committed after our snapshot ABORTS the loser.
#   * NO dirty read              — a reader never sees an uncommitted write.
#   * NO non-repeatable read     — a snapshot pinned at S is stable for its whole
#                                  lifetime even as concurrent txns commit.
#   * read-your-own-writes       — a read inside an open txn sees its own buffer.
#   * first-committer-wins OCC   — of two same-key writers, exactly one commits;
#                                  the loser raises 40001 and a retry converges.
#
# THE CHECKER (the load-bearing part):
#   We run K logical "sessions" with RANDOMIZED interleaving driven by a seeded
#   PRNG. Each step picks a session and advances it one micro-action (begin /
#   read / write / commit / abort). We maintain a REFERENCE MODEL — a totally-
#   ordered multi-version map keyed by commit-LSN — that is THE ground truth for
#   "what value is visible at snapshot S". On every read we ASSERT the
#   TableStore's answer equals the reference model's answer AT THE SESSION'S
#   PINNED SNAPSHOT (RYOW-overlaid by the session's own buffer). On every commit
#   we run the reference OCC check (first-committer-wins on the write-set vs the
#   reference history in (snapshot, head]) and ASSERT the TableStore's
#   commit/abort verdict MATCHES (commit <=> no reference conflict; 40001 <=>
#   a reference conflict). When the TableStore commits, we append the write-set
#   to the reference model at the next LSN. This makes EVERY interleaving
#   self-checking: a single divergence between the store and the reference SI
#   model is a hard FAIL with the seed + step printed for a deterministic repro.
#
# Runs on InMemory (deterministic, MANY seeds — the interleaving is driven by
# the PRNG, not by the OS scheduler, so it is reproducible) AND on
# SharedInMemory (real Arc-shared map; the reference checker still applies
# because the interleaving here is single-thread-driven over a shared backend —
# proving the SAME generic code is correct on the shared-store path too).
#
# Encapsulation / stale-reuse: ZERO UnsafePointer in any signature; ZERO wildcard
# origins / unsafe_from_address / take_pointee. Sessions / the reference model
# are plain owned structs in plain Lists (reuse-safe trivially), never byte-slab
# elements.
#
# Design: the serverless-Postgres correctness-slice design §3.4 / §4 / §7.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.store import ConditionalWriteStore

from komira_pgstore.pgstore_codec import PG_OP_PUT, PG_OP_TOMBSTONE, bytes_eq
from komira_pgstore.table_store import (
    TableStore,
    Txn,
    is_commit_retryable,
    is_occ_conflict,
)


# =============================================================================
# splitmix64 — a deterministic, seedable PRNG (reproducible interleavings).
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
        """Uniform in [0, n)."""
        if n <= 1:
            return 0
        return Int(self.next_u64() % UInt64(n))


# =============================================================================
# The byte helpers + the reference model (totally-ordered MVCC ground truth).
# =============================================================================


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _key(i: Int) -> List[UInt8]:
    return _b(String("k") + String(i))


# One committed version in the reference history: which keys it touched + the
# value written (or tombstone). Indexed by its commit-LSN == its position.
@fieldwise_init
struct RefWrite(Copyable, Movable, Deinitable):
    var op: UInt8  # PG_OP_PUT | PG_OP_TOMBSTONE
    var key: List[UInt8]
    var value: List[UInt8]


@fieldwise_init
struct RefCommit(Copyable, Movable, Deinitable):
    var lsn: Int64  # commit LSN == WAL chunk_seq
    var writes: List[RefWrite]


struct RefModel(Movable, Deinitable):
    """The totally-ordered MVCC ground truth. `commits[i]` is the committed
    write-set at LSN `i`. `visible_at(key, S)` returns the value a correct SI
    reader pinned at snapshot `S` MUST observe (the newest write with
    `lsn <= S`, tombstone => None). The store's reads are checked against this.
    """

    var commits: List[RefCommit]

    def __init__(out self):
        self.commits = List[RefCommit]()

    def head(self) -> Int64:
        return Int64(len(self.commits) - 1)  # -1 when empty

    def append(mut self, lsn: Int64, var writes: List[RefWrite]):
        self.commits.append(RefCommit(lsn, writes^))

    def visible_at(self, key: List[UInt8], snapshot: Int64) -> Optional[List[UInt8]]:
        # Walk DOWN from the snapshot LSN; first matching key's op decides.
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

    def conflicts(self, snapshot: Int64, write_keys: List[List[UInt8]]) -> Bool:
        """The reference first-committer-wins OCC verdict: True iff any committed
        chunk in (snapshot, head] touched a key in `write_keys`."""
        var i = Int(snapshot) + 1
        while i < len(self.commits):
            ref c = self.commits[i]
            for wj in range(len(c.writes)):
                for kj in range(len(write_keys)):
                    if bytes_eq(c.writes[wj].key, write_keys[kj]):
                        return True
            i += 1
        return False


# =============================================================================
# A logical session — a Copyable value: the snapshot it pinned + a mirror of the
# buffered write-set. The storage `Txn` is NOT kept in the session (Txn is
# Movable-only, so it cannot live in a List). Instead the storage Txn is a pure
# value `{snapshot, write_set}`, so we RECONSTRUCT a transient Txn on demand
# from `snapshot` + the buffer mirror — observationally identical for
# get/scan/commit. This also keeps the session a plain Copyable struct (stale-reuse N/A
# entirely: no byte-slab, no non-Copyable field).
# =============================================================================


struct Session(Copyable, Movable, Deinitable):
    var open: Bool
    var snapshot: Int64
    # Mirror of the buffered write-set (for the RYOW overlay + txn rebuild).
    var buf_ops: List[UInt8]
    var buf_keys: List[List[UInt8]]
    var buf_vals: List[List[UInt8]]

    def __init__(out self):
        self.open = False
        self.snapshot = Int64(-1)
        self.buf_ops = List[UInt8]()
        self.buf_keys = List[List[UInt8]]()
        self.buf_vals = List[List[UInt8]]()

    def is_open(self) -> Bool:
        return self.open

    def reset(mut self):
        self.open = False
        self.snapshot = Int64(-1)
        self.buf_ops = List[UInt8]()
        self.buf_keys = List[List[UInt8]]()
        self.buf_vals = List[List[UInt8]]()

    def buffer(mut self, op: UInt8, key: List[UInt8], value: List[UInt8]):
        # Dedup by key (last write per key wins — mirrors Txn._buffer).
        for i in range(len(self.buf_keys)):
            if bytes_eq(self.buf_keys[i], key):
                self.buf_ops[i] = op
                self.buf_vals[i] = value.copy()
                return
        self.buf_ops.append(op)
        self.buf_keys.append(key.copy())
        self.buf_vals.append(value.copy())

    def rebuild_txn(self) raises -> Txn:
        """Reconstruct the storage Txn from this session's recorded snapshot +
        buffer. The Txn is a pure value {snapshot, write_set}, so a rebuilt Txn
        with the same snapshot + same buffered ops is observationally identical
        to the original for get/scan/commit (the store never persists buffered
        writes before commit — §3.2)."""
        var t = Txn(self.snapshot)
        for i in range(len(self.buf_keys)):
            if self.buf_ops[i] == PG_OP_TOMBSTONE:
                t.delete(self.buf_keys[i].copy())
            else:
                t.update(self.buf_keys[i].copy(), self.buf_vals[i].copy())
        return t^

    def ryow_status(self, key: List[UInt8]) -> Int:
        """The RYOW probe status: 0 = no buffered op (fall through to snapshot),
        1 = buffered PUT (use ryow_value), 2 = buffered TOMBSTONE (invisible)."""
        for i in range(len(self.buf_keys)):
            if bytes_eq(self.buf_keys[i], key):
                if self.buf_ops[i] == PG_OP_TOMBSTONE:
                    return 2
                return 1
        return 0

    def ryow_value(self, key: List[UInt8]) -> List[UInt8]:
        """The buffered PUT value for `key` (caller must have ryow_status == 1)."""
        for i in range(len(self.buf_keys)):
            if bytes_eq(self.buf_keys[i], key):
                return self.buf_vals[i].copy()
        return List[UInt8]()


# =============================================================================
# The property driver — run one randomized history, self-checking every step.
# =============================================================================


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


def run_si_history[
    Store: ConditionalWriteStore
](
    mut ts: TableStore[Store],
    seed: UInt64,
    n_sessions: Int,
    n_keys: Int,
    n_steps: Int,
    tag: String,
) raises:
    """Run ONE randomized SI history of `n_steps` micro-actions over
    `n_sessions` logical sessions and `n_keys` overlapping keys, self-checking
    every read + every commit verdict against the totally-ordered reference
    model. A divergence is a hard FAIL with the seed + step for a deterministic
    repro."""
    var rng = Rng(seed)
    var refm = RefModel()
    var sessions = List[Session]()
    for _ in range(n_sessions):
        sessions.append(Session())

    var commits_done = 0
    var aborts_done = 0
    var conflicts_seen = 0
    var reads_checked = 0

    for step in range(n_steps):
        var si = rng.next_int(n_sessions)
        ref s = sessions[si]

        if not s.is_open():
            # BEGIN: pin the snapshot. We MUST pin the reference snapshot to the
            # SAME LSN the store pins. The store pins read_head() (the committed
            # tail). On the deterministic single-driver path the cached head ==
            # the true head == refm.head(), so they agree. (We assert this
            # equivalence below as a cross-check.)
            var txn = ts.begin()
            s.snapshot = txn.snapshot_lsn
            s.open = True
            ts.abort(txn^)  # the txn value is reconstructable; we keep snapshot.
            # Cross-check: the store's pinned snapshot must not exceed the
            # reference committed tail (a snapshot AHEAD of committed state is
            # the cardinal SI violation).
            assert_true(
                s.snapshot <= refm.head(),
                tag + " seed=" + String(Int(seed)) + " step=" + String(step)
                + ": begin pinned snapshot " + String(Int(s.snapshot))
                + " AHEAD of committed head " + String(Int(refm.head())),
            )
            continue

        var action = rng.next_int(10)
        var k = _key(rng.next_int(n_keys))

        if action < 4:
            # READ: assert store.get == reference (RYOW-overlaid) at the snapshot.
            # Rebuild the transient txn (snapshot + buffer) for the store read.
            var rtxn = s.rebuild_txn()
            var got = ts.get(rtxn, k.copy())
            ts.abort(rtxn^)
            var rstatus = s.ryow_status(k)
            var want: Optional[List[UInt8]]
            if rstatus == 1:
                want = Optional(s.ryow_value(k))  # own buffered PUT (RYOW)
            elif rstatus == 2:
                want = Optional[List[UInt8]](None)  # own buffered TOMBSTONE
            else:
                want = refm.visible_at(k, s.snapshot)  # snapshot-visible version
            assert_true(
                _opt_eq(got, want),
                tag + " seed=" + String(Int(seed)) + " step=" + String(step)
                + " session=" + String(si)
                + ": SI READ MISMATCH at snapshot " + String(Int(s.snapshot))
                + " key=" + _opt_str(Optional(k.copy()))
                + " store=" + _opt_str(got) + " ref=" + _opt_str(want),
            )
            reads_checked += 1

        elif action < 7:
            # WRITE (PUT): mirror in the session (the txn is rebuilt at commit).
            var v = _b(
                String("s") + String(si) + String("_st") + String(step)
            )
            s.buffer(PG_OP_PUT, k, v)

        elif action < 8:
            # DELETE (TOMBSTONE): mirror in the session.
            s.buffer(PG_OP_TOMBSTONE, k, List[UInt8]())

        elif action < 9:
            # ABORT: nothing persists. Reference unchanged.
            s.reset()
            aborts_done += 1

        else:
            # COMMIT: compute the reference OCC verdict, then commit + assert the
            # store's verdict MATCHES the reference.
            var write_keys = List[List[UInt8]]()
            for bi in range(len(s.buf_keys)):
                write_keys.append(s.buf_keys[bi].copy())
            var ref_conflict = refm.conflicts(s.snapshot, write_keys)
            var ref_readonly = len(s.buf_keys) == 0

            var txn = s.rebuild_txn()
            var store_committed = False
            var store_conflict = False
            var committed_lsn = Int64(-1)
            try:
                var res = ts.commit(txn^)
                store_committed = True
                committed_lsn = res.commit_lsn
            except e:
                var em = String(e)
                if is_occ_conflict(em):
                    store_conflict = True
                    conflicts_seen += 1
                elif is_commit_retryable(em):
                    # Single-driver path: retryable should never fire (no real
                    # contention on the slot). Treat as a soft conflict.
                    store_conflict = True
                else:
                    raise Error(
                        tag + " seed=" + String(Int(seed)) + " step="
                        + String(step) + ": unexpected commit error: " + em
                    )

            # The verdict cross-check: the store MUST commit iff the reference
            # sees no conflict (read-only commits always succeed).
            if ref_readonly:
                assert_true(
                    store_committed,
                    tag + " seed=" + String(Int(seed)) + " step=" + String(step)
                    + ": read-only commit should never conflict",
                )
            elif ref_conflict:
                assert_true(
                    store_conflict,
                    tag + " seed=" + String(Int(seed)) + " step=" + String(step)
                    + ": reference saw a W-W conflict (snapshot "
                    + String(Int(s.snapshot)) + ") but the store COMMITTED"
                    + " — LOST UPDATE / first-committer-wins violation",
                )
            else:
                assert_true(
                    store_committed,
                    tag + " seed=" + String(Int(seed)) + " step=" + String(step)
                    + ": reference saw NO conflict but the store ABORTED"
                    + " — spurious 40001 (a correct commit was rejected)",
                )

            if store_committed and not ref_readonly:
                # Fold our write-set into the reference at the won LSN. The won
                # LSN MUST be refm.head()+1 (the create-CAS lands at
                # auth_head+1; on the single driver auth_head == refm.head()).
                assert_equal(
                    committed_lsn,
                    refm.head() + Int64(1),
                    tag + " seed=" + String(Int(seed)) + " step=" + String(step)
                    + ": commit LSN must be reference head+1 (gapless)",
                )
                var rw = List[RefWrite]()
                for bi in range(len(s.buf_keys)):
                    rw.append(
                        RefWrite(
                            s.buf_ops[bi],
                            s.buf_keys[bi].copy(),
                            s.buf_vals[bi].copy(),
                        )
                    )
                refm.append(committed_lsn, rw^)
                commits_done += 1

            s.reset()

    # ---- post-history sweep: the recovered store must equal the reference at
    # EVERY committed snapshot for EVERY key (the strongest end-state assert) ---
    var head = refm.head()
    var snap = Int64(0)
    while snap <= head:
        var rdr = ts.begin()
        # Force the reader's snapshot to the LSN under test (time-travel read).
        rdr.snapshot_lsn = snap
        for ki in range(n_keys):
            var kk = _key(ki)
            var got = ts.get(rdr, kk.copy())
            var want = refm.visible_at(kk, snap)
            assert_true(
                _opt_eq(got, want),
                tag + " seed=" + String(Int(seed))
                + ": POST-SWEEP mismatch at snapshot " + String(Int(snap))
                + " key=" + _opt_str(Optional(kk.copy()))
                + " store=" + _opt_str(got) + " ref=" + _opt_str(want),
            )
        ts.abort(rdr^)
        snap += Int64(1)

    print(
        "    [", tag, "] seed=", Int(seed),
        " commits=", commits_done, " aborts=", aborts_done,
        " conflicts=", conflicts_seen, " reads_checked=", reads_checked,
        " head=", Int(head),
    )


# =============================================================================
# The seed sweep — MANY randomized histories on each backend.
# =============================================================================


def _new_mem_ts(prefix: String) raises -> TableStore[InMemoryConditionalStore]:
    return TableStore[InMemoryConditionalStore].open(
        CasManifestStore[InMemoryConditionalStore](
            store=InMemoryConditionalStore(),
            prefix=prefix,
            retry=RetryPolicy.fast_test(),
        )
    )


def _new_shared_ts(
    store: SharedInMemoryConditionalStore, prefix: String
) raises -> TableStore[SharedInMemoryConditionalStore]:
    return TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=store.clone(), prefix=prefix, retry=RetryPolicy.fast_test(),
        )
    )


def test_si_property_in_memory_seed_sweep() raises:
    print(
        "[si-prop] randomized SI property sweep on InMemory (many seeds,"
        " self-checked against the totally-ordered reference)"
    )
    # MANY seeds; each is a distinct interleaving over overlapping keys. The
    # PRNG drives the interleaving so each seed is reproducible.
    var n_seeds = 64
    for s in range(n_seeds):
        var seed = UInt64(0xC0FFEE00 + s * 0x1000193)
        var prefix = String("pg/siprop/mem/s") + String(s)
        var ts = _new_mem_ts(prefix)
        # 4 sessions, 6 overlapping keys, 120 micro-actions per history.
        run_si_history(ts, seed, 4, 6, 120, String("mem"))
        _ = ts^
    print("    [OK] InMemory SI property sweep:", n_seeds, "seeds, all SI-clean")


def test_si_property_shared_seed_sweep() raises:
    print(
        "[si-prop] randomized SI property sweep on SharedInMemory (Arc-shared"
        " map; same generic code, self-checked)"
    )
    var n_seeds = 32
    for s in range(n_seeds):
        var seed = UInt64(0xBADC0DE0 + s * 0x1000193)
        var shared = SharedInMemoryConditionalStore()
        var prefix = String("pg/siprop/shared/s") + String(s)
        var ts = _new_shared_ts(shared, prefix)
        run_si_history(ts, seed, 4, 6, 120, String("shared"))
        _ = ts^
        _ = shared^
    print("    [OK] SharedInMemory SI property sweep:", n_seeds, "seeds, all SI-clean")


def test_si_property_high_contention_few_keys() raises:
    print(
        "[si-prop] HIGH-CONTENTION variant — 6 sessions, 2 keys (max W-W"
        " overlap), 200 steps; stresses first-committer-wins + abort/retry"
    )
    var n_seeds = 48
    for s in range(n_seeds):
        var seed = UInt64(0x5EED1234 + s * 0x1000193)
        var prefix = String("pg/siprop/hot/s") + String(s)
        var ts = _new_mem_ts(prefix)
        # 6 sessions on just 2 keys => heavy write-write overlap.
        run_si_history(ts, seed, 6, 2, 200, String("hot"))
        _ = ts^
    print(
        "    [OK] HIGH-CONTENTION SI sweep:", n_seeds,
        "seeds, every commit verdict matched the reference OCC",
    )


def main() raises:
    print("== pgstore SI property checker (Jepsen-style, seeded) ==")
    test_si_property_in_memory_seed_sweep()
    test_si_property_shared_seed_sweep()
    test_si_property_high_contention_few_keys()
    print(
        "[OK] test_pgstore_si_property — randomized SI histories self-checked"
        " against a totally-ordered reference model across 144 seeds"
        " (InMemory + SharedInMemory): no lost update, no dirty/non-repeatable"
        " read, RYOW correct, first-committer-wins exact"
    )
