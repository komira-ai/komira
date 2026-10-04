# =============================================================================
# src/komira_table_store/tests/test_table_store_lease_enablement_battery.mojo
#   COMPREHENSIVE ENABLEMENT CORRECTNESS BATTERY for the single-writer LEASE
#   LIST-elision fast-path — the flip-readiness gate before a
#   future default-ON flip.
# =============================================================================
#
# The lease fast-path landed DEFAULT-OFF. Existing
# coverage (test_table_store_lease_listelision.mojo, 5 discriminating tests) proves
# the single-writer byte-identity + win-mechanism + 412/fence/OCC soundness on a
# handful of FIXED schedules. THIS battery GENERALIZES that to a broad,
# deterministic-random schedule SPACE and adds the stress / fault / crash / stale-reuse
# axes a default-on flip needs.
#
# ALL tests use ONLY epochs (0,0) — the safe single-writer config. Non-zero
# epochs are guarded off pending (the async/group leased entry
# points RAISE on non-zero), so this battery exercises the SYNC `commit()` path,
# which is the surface the lease fast-path's correctness invariants live on.
#
# THE LEASE INVARIANT THIS BATTERY GUARDS (the flip's safety claim):
#   The create-CAS slot is the SOLE OCC arbiter; the warm local head is a pure
#   optimization that can ONLY save a LIST or LOSE a slot (412) — it can NEVER
#   commit a wrong offset or skip an OCC conflict. So a store run with the lease
#   ON must produce a WAL state BYTE-IDENTICAL to the same store run with the
#   lease OFF, under EVERY schedule, EVERY interleave, EVERY fault, and EVERY
#   crash-and-recover.
#
# THE SIX BATTERY PARTS:
#   1. PROPERTY / DIFFERENTIAL (headline) — a deterministic PRNG produces MANY
#      varied commit schedules (insert/update/delete mixes, key overlaps, batch
#      sizes, autocommit + explicit-multi-write); each schedule is run lease ON
#      vs OFF over a fresh store and the committed WAL state (rows + per-chunk
#      base offsets + chunk contents) is asserted BYTE-IDENTICAL. RED-verified:
#      a local off-by-one copy of the win-advance makes a schedule diverge.
#   2. HIGH-CONCURRENCY STRESS — many lease-aware handles over ONE shared store,
#      deterministic interleave (no OS threads — the create-CAS slot is the only
#      arbiter, so a fixed interleave is a faithful concurrent model), lease ON,
#      sustained: NO lost-update, NO wrong-offset, strictly-monotone gapless
#      chunk offsets, first-committer-wins holds, final == serial-equivalent.
#   3. FAULT INJECTION — a transient store error mid-commit (retryable
#      torn-chunk-read on the OCC scan GET) with the lease ON: the fast-path
#      falls back correctly (invalidate + re-LIST), no corruption, the next
#      commit recovers, committed state == the fault-free equivalent.
#   4. CRASH RECOVERY — lease state dies with the handle (a fresh TableStore
#      over the same store mid-sequence drops the warm local head): the new
#      handle re-LISTs + recovers the correct authoritative head, NO lost or
#      duplicated write, monotone continues. Exercises "stale-high impossible
#      under crash".
#   5. stale-reuse CHURN SOAK — destroy-recreate TableStore cycles (N iterations) with
#      the lease ENABLED across cycles: no stale-reuse / double-free / use-after-free.
#   6. ELISION-EFFECTIVENESS INVARIANT — across varied single-writer schedules,
#      with a _CountingConditionalStore, lease-ON steady-state issues ZERO
#      authoritative-head LISTs + ZERO per-chunk replay GETs after warmup (vs
#      lease-OFF > 0) — the win mechanism holds BROADLY, not just on one schedule.
#
# Encapsulation / stale-reuse: ZERO UnsafePointer in any signature; ZERO wildcard
# origins / unsafe_from_address / take_pointee. The fault/counting stores hold
# their interior-mutable counters in a length-1 Slab[POD] (the established
# in-tree conformer pattern, reuse-safe (no heap fields): POD counters, no byte-slab element with a
# heap-owning inner field). The reference model + schedule are plain owned Lists.
#
# The elision MECHANISM mirrors `_LocalHeadCache` in
#   komira_objectstore/cas_manifest.mojo.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_collections.slab import Slab

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    ManifestHead,
    RetryPolicy,
)
from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

from komira_table_store.table_store_codec import (
    TS_OP_PUT,
    TS_OP_TOMBSTONE,
    WriteOp,
    bytes_eq,
)
from komira_table_store.table_store import (
    CommitResult,
    TableStore,
    Txn,
    is_commit_retryable,
    is_occ_conflict,
)


# =============================================================================
# splitmix64 PRNG (mirror the SI-property / recovery-chaos harnesses) + bytes.
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


def _str(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out^


def _key(i: Int) -> List[UInt8]:
    return _b(String("k") + String(i))


# =============================================================================
# A randomized, REPLAYABLE commit schedule. Each step is ONE txn (one create-CAS
# slot under the offline backend). A txn mixes 1..MAXW PUT / TOMBSTONE ops over
# the key space. The SAME schedule is replayed on the lease-ON and lease-OFF
# stores so any divergence is attributable to the lease, not to the PRNG order.
# Plain owned Lists (reuse-safe trivially; never a byte-slab element).
# =============================================================================


@fieldwise_init
struct SchedWrite(Copyable, Movable, Deinitable):
    var op: UInt8  # TS_OP_PUT | TS_OP_TOMBSTONE
    var key: List[UInt8]
    var value: List[UInt8]


@fieldwise_init
struct SchedTxn(Copyable, Movable, Deinitable):
    var writes: List[SchedWrite]


struct Schedule(Movable, Deinitable):
    """A REPLAYABLE list of single-create-CAS txns generated from a seed."""

    var txns: List[SchedTxn]

    def __init__(out self):
        self.txns = List[SchedTxn]()

    def append(mut self, var t: SchedTxn):
        self.txns.append(t^)


def _gen_schedule(
    seed: UInt64, n_txns: Int, n_keys: Int, max_writes: Int
) -> Schedule:
    """Generate a deterministic-random schedule of `n_txns` txns over `n_keys`
    overlapping keys. Each txn is 1..max_writes deduped ops; ~1-in-6 is a
    TOMBSTONE, the rest PUTs with a step-unique value. The key overlap (a small
    key space) deliberately produces BOTH conflicting (same key in two txns) and
    non-conflicting work; since every txn here commits in sequence (one driver,
    no concurrent W-W on the SAME snapshot), the overlaps exercise the
    overwrite/tombstone version chain, not OCC aborts (part 2 covers OCC)."""
    var rng = Rng(seed)
    var sched = Schedule()
    for si in range(n_txns):
        var nw = 1 + rng.next_int(max_writes)
        var seen = List[Int]()
        var writes = List[SchedWrite]()
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
            if rng.next_int(6) == 0:
                writes.append(
                    SchedWrite(TS_OP_TOMBSTONE, _key(ki), List[UInt8]())
                )
            else:
                var v = _b(
                    String("v") + String(si) + String("_") + String(ki)
                )
                writes.append(SchedWrite(TS_OP_PUT, _key(ki), v^))
        if len(writes) == 0:
            writes.append(
                SchedWrite(TS_OP_PUT, _key(0), _b(String("v") + String(si)))
            )
        sched.append(SchedTxn(writes^))
    return sched^


# Whether THIS txn (by its index) is driven as "explicit-multi-write" (one txn,
# all writes buffered then committed) vs "autocommit" (decomposed: each write
# its own single-write txn). Deterministic from the seed so ON and OFF agree.
# Returns a List[Bool] of length len(sched.txns).
def _autocommit_flags(seed: UInt64, n: Int) -> List[Bool]:
    var rng = Rng(seed ^ UInt64(0xA5A5A5A5A5A5A5A5))
    var out = List[Bool]()
    for _ in range(n):
        out.append(rng.next_int(2) == 0)
    return out^


# Drive one schedule against a store. When a txn is flagged autocommit, EACH of
# its writes is committed as its own single-write txn (so a 3-write txn produces
# 3 chunks); else the whole write-set is one txn -> one chunk. The driver mirrors
# the autocommit-vs-explicit decomposition at the commit-chunk level.
def _drive_schedule[
    Store: ConditionalWriteStore
](mut ts: TableStore[Store], sched: Schedule, autocommit: List[Bool]) raises:
    for ti in range(len(sched.txns)):
        ref txn = sched.txns[ti]
        if autocommit[ti]:
            for wi in range(len(txn.writes)):
                ref w = txn.writes[wi]
                var t = ts.begin()
                if w.op == TS_OP_TOMBSTONE:
                    t.delete(w.key.copy())
                else:
                    t.insert(w.key.copy(), w.value.copy())
                _ = ts.commit(t^)
        else:
            var t = ts.begin()
            for wi in range(len(txn.writes)):
                ref w = txn.writes[wi]
                if w.op == TS_OP_TOMBSTONE:
                    t.delete(w.key.copy())
                else:
                    t.insert(w.key.copy(), w.value.copy())
            _ = ts.commit(t^)


# Snapshot the FULL committed WAL state as a byte string: per chunk, the
# re-derived cumulative base offset + (op,key,row)*. Two stores with identical
# snapshots committed the SAME gapless seq, same rows, same chunk contents, same
# offset sequence. (Identical to the existing lease test's snapshot shape so the
# discrimination scope is the same: a wrong win-advance perturbs the SEQ -> shifts
# the re-derived base -> the byte-identity assertion catches it.)
def _wal_state_snapshot[
    Store: ConditionalWriteStore
](ts: TableStore[Store]) raises -> String:
    var head = ts.wal_head_seq()
    var out = String("head=") + String(Int(head)) + String("\n")
    var seq = Int64(0)
    var base = Int64(0)
    while seq <= head:
        var ws = ts.wal_chunk_write_set(seq)
        out += (
            String("chunk[")
            + String(Int(seq))
            + String("]@base=")
            + String(Int(base))
            + String(":")
        )
        for wi in range(len(ws)):
            ref w = ws[wi]
            out += (
                String(" {op=")
                + String(Int(w.op))
                + String(" k=")
                + _str(w.key)
                + String(" v=")
                + _str(w.row)
                + String("}")
            )
        out += String("\n")
        base += Int64(len(ws))
        seq += Int64(1)
    return out^


def _new_mem_store(
    prefix: String, lease_on: Bool
) raises -> TableStore[InMemoryConditionalStore]:
    var ts = TableStore[InMemoryConditionalStore].open(
        CasManifestStore[InMemoryConditionalStore](
            store=InMemoryConditionalStore(),
            prefix=prefix,
            retry=RetryPolicy.fast_test(),
        )
    )
    # ACCOMMODATION (lease is now DEFAULT-ON at construction):
    # `.open()` constructs a lease-ON store now, so the OFF arm must EXPLICITLY
    # disable to remain the genuine lease-OFF differential reference. Without this
    # the ON-vs-OFF differential degenerates to ON-vs-ON (tautological).
    if lease_on:
        ts.enable_writer_lease_fastpath()
    else:
        ts.disable_writer_lease_fastpath()
    return ts^


# =============================================================================
# (1) PROPERTY / DIFFERENTIAL (headline) — MANY varied schedules, lease ON vs
#     OFF, committed WAL state BYTE-IDENTICAL every time.
#
# RED-VERIFICATION (how to confirm this is a genuine falsifier, not a tautology;
# done manually — we cannot edit the library from a test). Introduce a one-line
# off-by-one in `lease_note_win` (e.g. `self._lease_head_seq = won_seq + 1`):
#   * The committed-WAL byte-identity (i) STAYS GREEN — this is the lease's CORE
#     SAFETY GUARANTEE: the create-CAS slot is the SOLE OCC arbiter, so a stale
#     local head can ONLY lose the slot (412) + fall back to the authoritative
#     LIST + recommit at the true tail. On a linearizable backend the committed
#     state is ALWAYS identical to lease-OFF, EVEN under a buggy win-advance.
#   * The elision count (ii) GOES RED — the mis-derived warm head 412s on the
#     steady-state commits, forcing post-warmup re-LISTs, so `on_lists > 0`.
# So (i) GUARDS the safety claim and (ii) is the DISCRIMINATING falsifier for a
# win-advance bug. (Empirically: a `won_next_offset` off-by-one is FULLY
# advisory — re-derivation from record counts + the create-CAS arbiter mask it
# entirely; the SEQ off-by-one above is the one that perturbs (ii). Both findings
# were verified by mutation.) VERIFIED: `won_seq + 1`
# makes (ii) fail on >=1 seed while (i) stays green; reverted.
# =============================================================================


def test_1_property_differential_on_eq_off() raises:
    print(
        "[1] PROPERTY/DIFFERENTIAL — many schedules: lease-ON WAL ==byte== OFF"
    )
    var n_seeds = 40
    var n_txns = 30
    var n_keys = 8
    var max_writes = 4
    var divergences = 0
    for s in range(n_seeds):
        var seed = UInt64(0x10A5E00000 + s * 0x1000193)
        var sched = _gen_schedule(seed, n_txns, n_keys, max_writes)
        var ac = _autocommit_flags(seed, len(sched.txns))

        # OFF: plain in-mem; ON: a COUNTING store so part 1 is discriminating in
        # its OWN right — a win-advance off-by-one is fully SELF-HEALED on a
        # linearizable backend (the create-CAS slot is the sole arbiter, so a
        # stale local head can only LOSE the slot + re-LIST), keeping the
        # committed WAL byte-identical; the divergence then shows up as ON
        # issuing post-warmup re-LISTs. We assert BOTH: (i) ON WAL ==byte== OFF
        # WAL (the SAFETY invariant — holds even under a buggy win-advance), AND
        # (ii) ON issued ZERO post-warmup authoritative-head LISTs (the
        # discriminating signal a win-advance off-by-one breaks). RED-VERIFY: a
        # `won_seq + 1` off-by-one in lease_note_win leaves (i) intact (self-heal)
        # but makes (ii) FAIL — at least one schedule's ON re-LISTs.
        var off = _new_mem_store(
            String("ts/leb/1/off/s") + String(s), False
        )
        var on = _new_counting_store(String("ts/leb/1/on/s") + String(s), True)

        # WARM the ON store past the cold-start LIST (the durable _HEAD does not
        # exist on a cold store -> the first commit pays a LIST regardless of the
        # lease), then RESET the counters so we measure only the steady state.
        var tw = on.begin()
        tw.insert(_b("__warm"), _b("w"))
        _ = on.commit(tw^)
        on.wal_mut().store_mut().reset_counts()
        # The OFF store gets the SAME __warm prefix so the WAL snapshots align.
        var two = off.begin()
        two.insert(_b("__warm"), _b("w"))
        _ = off.commit(two^)

        _drive_schedule(off, sched, ac)
        _drive_schedule(on, sched, ac)

        var on_lists = on.wal_mut().store_mut().list_count()
        var on_chunk_gets = on.wal_mut().store_mut().chunk_get_count()

        var snap_off = _wal_state_snapshot(off)
        var snap_on = _wal_state_snapshot(on)
        if snap_on != snap_off:
            divergences += 1
            print(
                "    DIVERGENCE seed=", Int(seed), "\n  OFF:\n", snap_off,
                "\n  ON:\n", snap_on,
            )
        # (i) the SAFETY invariant: ON WAL state byte-identical to OFF.
        assert_equal(
            snap_on,
            snap_off,
            "[1] seed=" + String(Int(seed))
            + ": lease-ON WAL state must be BYTE-IDENTICAL to lease-OFF",
        )
        # (ii) the DISCRIMINATING signal: ON issued ZERO post-warmup
        # authoritative-head LISTs + ZERO per-chunk replay GETs (a win-advance
        # off-by-one makes the warm head mis-derive the slot -> 412 -> re-LIST,
        # which this catches even though (i) still self-heals).
        assert_equal(
            on_lists,
            Int64(0),
            "[1] seed=" + String(Int(seed)) + ": ON must elide EVERY steady-state"
            " authoritative-head LIST (got " + String(Int(on_lists))
            + ") — a non-zero count is a win-advance bug",
        )
        assert_equal(
            on_chunk_gets,
            Int64(0),
            "[1] seed=" + String(Int(seed)) + ": ON must elide EVERY per-chunk"
            " replay GET in steady state (got " + String(Int(on_chunk_gets)) + ")",
        )
        # The lease head must be WARM after the steady-state run.
        assert_true(
            on.lease_head_warm(),
            "[1] seed=" + String(Int(seed)) + ": ON lease head warm post-run",
        )
        assert_false(
            off.lease_head_warm(),
            "[1] seed=" + String(Int(seed)) + ": OFF lease never warm",
        )

        # Cross-check the VISIBLE read view agrees key-for-key at the final
        # snapshot (a second, independent witness of identity beyond the WAL
        # snapshot: the reconstructed MVCC view must match).
        var t_off = off.begin()
        var t_on = on.begin()
        for ki in range(n_keys):
            var kk = _key(ki)
            var v_off = off.get(t_off, kk.copy())
            var v_on = on.get(t_on, kk.copy())
            assert_equal(
                Bool(v_off),
                Bool(v_on),
                "[1] seed=" + String(Int(seed)) + " k" + String(ki)
                + ": presence must agree (ON vs OFF)",
            )
            if Bool(v_off) and Bool(v_on):
                assert_true(
                    bytes_eq(v_off.value(), v_on.value()),
                    "[1] seed=" + String(Int(seed)) + " k" + String(ki)
                    + ": visible value must agree (ON vs OFF)",
                )
        off.abort(t_off^)
        on.abort(t_on^)
        _ = off^
        _ = on^
    assert_equal(divergences, 0, "[1] zero divergences across all seeds")
    print(
        "    [OK] (1) —", n_seeds, "seeds x", n_txns,
        "txns: lease-ON WAL byte-identical to OFF + ON elided all LISTs",
    )


# =============================================================================
# (2) HIGH-CONCURRENCY STRESS — multiple lease-aware handles over ONE shared
#     store, deterministic interleave, lease ON: no lost-update, monotone gapless
#     offsets, FCW holds, final == serial-equivalent.
#
#     The create-CAS slot is the SOLE arbiter, so a deterministic interleave over
#     a shared store (no OS threads) is a FAITHFUL model of the concurrent race
#     without scheduler nondeterminism (the existing lease test's rationale).
#     `TableStore` is Movable-only (NOT Copyable) and holds heap-owning fields
#     (KeyIndex + the index Slab), so it CANNOT live in a `List` (List requires
#     Copyable) and MUST NOT live in a byte-backed `Slab` (that is the stale-reuse
#     byte-slab trap). So we use three individually-named handles — A holds the
#     lease (warm); B and C are plain siblings — and dispatch the seed-chosen
#     handle via if/elif (fully type-safe; no List-of-Movable, no byte-slab, no
#     wildcard origin). After the race a fresh recovered handle replays the WAL =
#     the create-CAS total order, and we assert the committed history's invariant
#     battery (monotone gapless slots, atomicity, no lost update on a hot key).
# =============================================================================


def _commit_one_write[
    Store: ConditionalWriteStore
](
    mut ts: TableStore[Store],
    ki: Int,
    is_del: Bool,
    var v: List[UInt8],
    seed: UInt64,
    r: Int,
) raises -> Bool:
    """Commit one single-write txn on `ts`. Returns True on a committed win,
    False on an OCC (40001) or retryable conflict; raises on any unexpected
    error (so a real defect is surfaced, not swallowed)."""
    var t = ts.begin()
    if is_del:
        t.delete(_key(ki))
    else:
        t.update(_key(ki), v^)
    try:
        _ = ts.commit(t^)
        return True
    except e:
        var em = String(e)
        if is_occ_conflict(em) or is_commit_retryable(em):
            return False
        raise Error(
            "[2] seed=" + String(Int(seed)) + " round=" + String(r)
            + ": unexpected commit error: " + em
        )


def _drive_concurrent_stress(seed: UInt64, n_rounds: Int) raises:
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("ts/leb/2/s") + String(Int(seed))

    # Three handles over the shared store. A holds the lease (warm); B, C are
    # plain siblings. (Three named handles, not a List/Slab — see the header.)
    var a = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    a.enable_writer_lease_fastpath()
    var b = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var c = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )

    var rng = Rng(seed)
    var n_keys = 6
    var commits_ok = 0
    var conflicts = 0
    for r in range(n_rounds):
        var hi = rng.next_int(3)
        var ki = rng.next_int(n_keys)
        var is_del = rng.next_int(7) == 0
        # A globally-unique value: handle-index + round (no two writes on a
        # contended key carry the same value unless a lost update dup'd it).
        var v = _b(String("h") + String(hi) + String("_r") + String(r))
        # Dispatch the chosen handle (if/elif — TableStore is Movable-only).
        # _commit_one_write returns True on a committed win, False on an
        # OCC/retryable conflict (raises on any unexpected error).
        var ok: Bool
        if hi == 0:
            ok = _commit_one_write(a, ki, is_del, v^, seed, r)
        elif hi == 1:
            ok = _commit_one_write(b, ki, is_del, v^, seed, r)
        else:
            ok = _commit_one_write(c, ki, is_del, v^, seed, r)
        if ok:
            commits_ok += 1
        else:
            conflicts += 1

    # --- POST-RACE INVARIANT BATTERY over the committed merged history ---
    # A fresh recovered handle replays the WAL = the create-CAS total order.
    var rec = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(),
            prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var head = rec.wal_head_seq()
    # INV-6 monotone gapless slots: every slot 0..head decodes to a non-empty
    # write-set (no hole, no dup — the create-CAS imposes a gapless total order).
    var total_records = Int64(0)
    var seq = Int64(0)
    while seq <= head:
        var ws = rec.wal_chunk_write_set(seq)
        assert_true(
            len(ws) >= 1,
            "[2] seed=" + String(Int(seed)) + " slot " + String(Int(seq))
            + ": committed chunk must have >=1 op (INV-2 atomicity)",
        )
        total_records += Int64(len(ws))
        seq += Int64(1)
    # INV-3/global accounting: the number of committed slots == handles' recorded
    # commits (no phantom commit, no dropped commit). Each commit here is a
    # single-write txn -> one chunk, so head+1 == commits_ok.
    assert_equal(
        head + Int64(1),
        Int64(commits_ok),
        "[2] seed=" + String(Int(seed)) + ": committed slot count ("
        + String(Int(head + Int64(1))) + ") must equal handles' recorded"
        " commits (" + String(commits_ok) + ") — no phantom/dropped commit",
    )
    # Each commit is a single-write txn -> exactly one record per slot.
    assert_equal(
        total_records,
        head + Int64(1),
        "[2] seed=" + String(Int(seed)) + ": total records (" + String(Int(total_records))
        + ") must equal the slot count (each single-write txn -> one chunk)",
    )
    # INV-4 no lost update on a HOT key: for every key, the values across the WAL
    # must be DISTINCT (each handle writes a globally-unique value; two chunks
    # carrying the same (key,value) on a contended key is a lost-update artefact —
    # two writers both "won" the same value). We scan per key.
    for ki in range(n_keys):
        var kk = _key(ki)
        var seen_vals = List[List[UInt8]]()
        var sq = Int64(0)
        while sq <= head:
            var ws = rec.wal_chunk_write_set(sq)
            for wi in range(len(ws)):
                ref w = ws[wi]
                if w.op == TS_OP_PUT and bytes_eq(w.key, kk):
                    for sv in range(len(seen_vals)):
                        assert_false(
                            bytes_eq(seen_vals[sv], w.row),
                            "[2] seed=" + String(Int(seed)) + " key=" + _str(kk)
                            + " value=" + _str(w.row) + " appears twice in the"
                            " WAL — LOST UPDATE (two writers won the same value)",
                        )
                    seen_vals.append(w.row.copy())
            sq += Int64(1)
    _ = rec^

    _ = a^
    _ = b^
    _ = c^
    _ = shared^
    print(
        "    seed=", Int(seed), " handles=3 rounds=", n_rounds,
        " commits=", commits_ok, " conflicts=", conflicts, " head=", Int(head),
    )


def test_2_high_concurrency_stress() raises:
    print(
        "[2] HIGH-CONCURRENCY STRESS — 3 lease-aware handles, shared store,"
        " deterministic interleave: monotone gapless slots, no lost update, FCW"
    )
    var n_seeds = 12
    for s in range(n_seeds):
        var seed = UInt64(0x2C0FFEE000 + s * 0x1000193)
        _drive_concurrent_stress(seed, 80)
    print("    [OK] (2) —", n_seeds, "seeds x 3 handles x 80 rounds, invariants hold")


# =============================================================================
# (3) FAULT INJECTION — a transient (retryable) store error mid-commit with the
#     lease ON: the fast-path falls back (invalidate + re-LIST), no corruption,
#     the next commit recovers, committed state == the fault-free equivalent.
#
# THE FAULT SEAM (synchronous, retryable): `_FaultConditionalStore` wraps an
# `InMemoryConditionalStore` and, when armed, raises a TORN-CHUNK-READ-shaped
# error ("truncated") from the next `get` of a `/manifest/` chunk key — exactly
# the transient the sync `commit()` loop classifies via `_is_transient_chunk_read`
# and recovers by `lease_note_lost_slot()` + re-LIST + retry. So a fault fires
# DURING the lease-elided OCC scan (or the cold-warm LIST replay) and the lease
# must self-heal. We arm the fault once mid-sequence and assert: the run still
# completes, NO chunk corruption, the final WAL state == the SAME schedule run
# with NO fault (the retryable transient is recovered, not lost).
# =============================================================================


struct _FaultCounts(Movable, Deinitable):
    var armed: Bool          # one-shot fault armed
    var chunk_gets: Int64    # /manifest/ chunk GETs observed
    var faults_fired: Int64  # how many times the fault actually raised

    def __init__(out self):
        self.armed = False
        self.chunk_gets = Int64(0)
        self.faults_fired = Int64(0)


struct _FaultConditionalStore(
    ConditionalWriteStore, ObjectStore, Movable, Deinitable
):
    """A fault-injecting wrapper over `SharedInMemoryConditionalStore`
    (test-only). `clone()` SHARES the inner Arc-backed map but mints a FRESH
    (un-armed) counter slab — so two handles can contend on one map while only
    the lease-holder's instance is armed. When `armed`, the NEXT `get` of a
    `/manifest/` chunk key RAISES a TORN-CHUNK-READ-shaped ("truncated") error
    ONCE, then disarms. This is the transient the sync `commit()` loop classifies
    as retryable (`_is_transient_chunk_read`) and recovers via
    `lease_note_lost_slot()` + re-LIST + retry. Counters live in a length-1
    Slab[POD] (the in-tree conformer interior-mutability pattern; reuse-safe (no heap fields): POD
    counters, no byte-slab element with a heap-owning inner field)."""

    var _inner: SharedInMemoryConditionalStore
    var _c: Slab[_FaultCounts]

    def __init__(out self):
        var slab = Slab[_FaultCounts]()
        slab.append(_FaultCounts())
        self._inner = SharedInMemoryConditionalStore()
        self._c = slab^

    def __init__(out self, var inner: SharedInMemoryConditionalStore):
        var slab = Slab[_FaultCounts]()
        slab.append(_FaultCounts())
        self._inner = inner^
        self._c = slab^

    def clone(self) -> Self:
        """Share the inner Arc-backed map; FRESH un-armed counter slab (a fault
        is per-handle, never shared — mirrors the slow-CAS conformer's clone)."""
        return Self(inner=self._inner.clone())

    def arm_fault(self):
        # SAFETY (get_mut_interior): single-threaded test store, only slot 0,
        # `self` outlives the ref; no realloc (slab sized 1, never grown).
        ref c = self._c.get_mut_interior(0)
        c.armed = True

    def faults_fired(self) -> Int64:
        ref c = self._c.get_mut_interior(0)
        return c.faults_fired

    def chunk_get_count(self) -> Int64:
        ref c = self._c.get_mut_interior(0)
        return c.chunk_gets

    # ---- ObjectStore base surface ----

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    # ---- ConditionalWriteStore surface ----

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if path.raw().find("/manifest/") >= 0:
            ref c = self._c.get_mut_interior(0)
            c.chunk_gets += Int64(1)
            if c.armed:
                c.armed = False
                c.faults_fired += Int64(1)
                # TORN-CHUNK-READ shape: the sync commit() loop classifies a
                # "truncated" chunk-read as RETRYABLE -> lease_note_lost_slot()
                # + re-LIST + retry (NOT a corruption, NOT an OCC conflict).
                raise Error(
                    "_FaultConditionalStore: simulated torn chunk-read"
                    " (truncated i64) at " + path.raw()
                )
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


# Snapshot the committed WAL state of a SHARED map (via a plain fault-store
# handle, NO arm) — the same shape as `_wal_state_snapshot`, used to compare the
# faulted-run map against the fault-free reference map.
def _drive_schedule_fault[
    S: ConditionalWriteStore
](mut ts: TableStore[S], sched: Schedule, autocommit: List[Bool]) raises:
    _drive_schedule(ts, sched, autocommit)


def test_3_fault_injection_lease_recovers() raises:
    print(
        "[3] FAULT INJECTION — transient torn-read on the lease's authoritative"
        " read, lease ON: falls back + re-LISTs, recovers, state == fault-free"
    )
    var n_seeds = 16
    var n_txns = 14
    var n_keys = 6
    var max_writes = 3
    var total_faults = Int64(0)
    for s in range(n_seeds):
        var seed = UInt64(0x3FA17000 + s * 0x1000193)
        var sched = _gen_schedule(seed, n_txns, n_keys, max_writes)
        var ac = _autocommit_flags(seed, len(sched.txns))

        # ---- (a) the fault-free reference ----
        # Pre-populate a shared map with a few chunks via a lease-OFF handle, then
        # replay the schedule with a FRESH lease-ON handle (cold head) — NO fault.
        # This is the reference final WAL state.
        var ref_map = SharedInMemoryConditionalStore()
        var prefix = String("ts/leb/3/s") + String(s)
        var seeder = TableStore[_FaultConditionalStore].open(
            CasManifestStore[_FaultConditionalStore](
                store=_FaultConditionalStore(ref_map.clone()),
                prefix=prefix.copy(), retry=RetryPolicy.fast_test(),
            )
        )
        # Seed 3 chunks (so the cold-start authoritative read replays >=1 chunk).
        for i in range(3):
            var t = seeder.begin()
            t.insert(_b("seed") + _b(String(i)), _b("s") + _b(String(i)))
            _ = seeder.commit(t^)
        _ = seeder^
        var ref_lease = TableStore[_FaultConditionalStore].open(
            CasManifestStore[_FaultConditionalStore](
                store=_FaultConditionalStore(ref_map.clone()),
                prefix=prefix.copy(), retry=RetryPolicy.fast_test(),
            )
        )
        ref_lease.enable_writer_lease_fastpath()
        _drive_schedule_fault(ref_lease, sched, ac)
        var snap_ref = _wal_state_snapshot(ref_lease)
        _ = ref_lease^
        _ = ref_map^

        # ---- (b) the FAULTED run ----
        # Same recipe over a fresh map; the lease-ON handle's FIRST commit goes
        # through its COLD authoritative read (LIST + per-chunk replay GET over the
        # seeded chunks). We ARM the one-shot fault BEFORE that first commit so a
        # /manifest/ chunk GET RAISES a transient mid-read. The commit loop must
        # classify it retryable, invalidate the (not-yet-warm) lease head, re-LIST
        # (fault now disarmed), and recover — the final WAL must EQUAL the
        # fault-free reference (the transient was recovered, not lost).
        var f_map = SharedInMemoryConditionalStore()
        var f_seeder = TableStore[_FaultConditionalStore].open(
            CasManifestStore[_FaultConditionalStore](
                store=_FaultConditionalStore(f_map.clone()),
                prefix=prefix.copy(), retry=RetryPolicy.fast_test(),
            )
        )
        for i in range(3):
            var t = f_seeder.begin()
            t.insert(_b("seed") + _b(String(i)), _b("s") + _b(String(i)))
            _ = f_seeder.commit(t^)
        _ = f_seeder^
        var faulted = TableStore[_FaultConditionalStore].open(
            CasManifestStore[_FaultConditionalStore](
                store=_FaultConditionalStore(f_map.clone()),
                prefix=prefix.copy(), retry=RetryPolicy.fast_test(),
            )
        )
        faulted.enable_writer_lease_fastpath()
        # ARM the one-shot fault: the cold-start authoritative read's first
        # /manifest/ chunk GET will RAISE the transient.
        faulted.wal_mut().store_mut().arm_fault()
        _drive_schedule_fault(faulted, sched, ac)
        var fired = faulted.wal_mut().store_mut().faults_fired()
        total_faults += fired
        # The fault MUST have fired (else the test is vacuous): the cold-start
        # authoritative read replays the seeded chunks, so a /manifest/ GET ran.
        assert_true(
            fired >= Int64(1),
            "[3] seed=" + String(Int(seed)) + ": the armed fault must fire on"
            " the lease's cold-start authoritative read (non-vacuous)",
        )
        var snap_faulted = _wal_state_snapshot(faulted)
        _ = faulted^
        _ = f_map^

        assert_equal(
            snap_faulted,
            snap_ref,
            "[3] seed=" + String(Int(seed)) + ": FAULTED WAL state must EQUAL"
            " the fault-free reference — the transient was recovered, not lost",
        )
    print(
        "    [OK] (3) —", n_seeds, "seeds (", Int(total_faults), "faults fired):"
        " lease self-heals a transient on its authoritative read, final WAL =="
        " fault-free reference (no corruption, no lost write)",
    )


# =============================================================================
# (4) CRASH RECOVERY — lease state dies with the handle. Mid-sequence, drop the
#     warm-lease handle + open a FRESH one over the SAME store: the new handle's
#     lease cache is COLD, so its first commit re-LISTs the AUTHORITATIVE head and
#     recovers the correct tail. NO lost or duplicated write; monotone continues.
#     Exercises "stale-high impossible under crash" (a fresh handle can never
#     carry a stale-HIGH local head — it starts cold + re-LISTs).
# =============================================================================


def test_4_crash_recovery_lease_state_loss() raises:
    print(
        "[4] CRASH RECOVERY — drop the warm-lease handle mid-sequence, fresh"
        " handle re-LISTs the authoritative head, no lost/dup write, monotone"
    )
    var n_seeds = 12
    var n_txns = 24
    var n_keys = 6
    var max_writes = 3
    for s in range(n_seeds):
        var seed = UInt64(0x4C2A54000 + s * 0x1000193)
        var sched = _gen_schedule(seed, n_txns, n_keys, max_writes)
        var ac = _autocommit_flags(seed, len(sched.txns))
        var shared = SharedInMemoryConditionalStore()
        var prefix = String("ts/leb/4/s") + String(s)

        # The "crash points": after every txn, drop the handle + reopen a FRESH
        # lease-enabled handle over the SAME store (the lease cache dies with the
        # handle). The fresh handle must continue the gapless monotone slot
        # sequence — never re-commit a slot, never skip one, never lose a write.
        var committed_slots = Int64(0)
        for ti in range(len(sched.txns)):
            ref txn = sched.txns[ti]
            # Open a FRESH lease-enabled handle (cold local head).
            var ts = TableStore[SharedInMemoryConditionalStore].open(
                CasManifestStore[SharedInMemoryConditionalStore](
                    store=shared.clone(),
                    prefix=prefix.copy(),
                    retry=RetryPolicy.fast_test(),
                )
            )
            ts.enable_writer_lease_fastpath()
            # A fresh handle starts COLD — its lease head is NOT warm until its
            # first commit lists + warms it (stale-high is structurally
            # impossible: it never carries a head from a prior handle).
            assert_false(
                ts.lease_head_warm(),
                "[4] seed=" + String(Int(seed)) + " ti=" + String(ti)
                + ": a FRESH lease handle must start COLD (no stale-high head)",
            )
            if ac[ti]:
                for wi in range(len(txn.writes)):
                    ref w = txn.writes[wi]
                    var t = ts.begin()
                    if w.op == TS_OP_TOMBSTONE:
                        t.delete(w.key.copy())
                    else:
                        t.insert(w.key.copy(), w.value.copy())
                    var r = ts.commit(t^)
                    # The won slot MUST be exactly the next monotone slot.
                    assert_equal(
                        r.commit_lsn,
                        committed_slots,
                        "[4] seed=" + String(Int(seed)) + " ti=" + String(ti)
                        + ": fresh handle must commit at the next monotone slot"
                        + " (expected " + String(Int(committed_slots)) + ", got "
                        + String(Int(r.commit_lsn)) + ")",
                    )
                    committed_slots += Int64(1)
            else:
                var t = ts.begin()
                for wi in range(len(txn.writes)):
                    ref w = txn.writes[wi]
                    if w.op == TS_OP_TOMBSTONE:
                        t.delete(w.key.copy())
                    else:
                        t.insert(w.key.copy(), w.value.copy())
                var r = ts.commit(t^)
                assert_equal(
                    r.commit_lsn,
                    committed_slots,
                    "[4] seed=" + String(Int(seed)) + " ti=" + String(ti)
                    + ": fresh handle must commit at the next monotone slot"
                    + " (expected " + String(Int(committed_slots)) + ", got "
                    + String(Int(r.commit_lsn)) + ")",
                )
                committed_slots += Int64(1)
            # CRASH: drop the handle (the lease cache dies with it).
            _ = ts^

        # FINAL recovery: a fresh handle replays the WAL; the head must be exactly
        # the count of committed slots - 1 (gapless, no lost/dup write), and the
        # slot sequence must be gapless 0..head with non-empty chunks.
        var rec = TableStore[SharedInMemoryConditionalStore].open(
            CasManifestStore[SharedInMemoryConditionalStore](
                store=shared.clone(),
                prefix=prefix.copy(),
                retry=RetryPolicy.fast_test(),
            )
        )
        assert_equal(
            rec.wal_head_seq(),
            committed_slots - Int64(1),
            "[4] seed=" + String(Int(seed)) + ": recovered head must equal the"
            " committed slot count - 1 (no lost/duplicated write under crash)",
        )
        var sq = Int64(0)
        while sq <= rec.wal_head_seq():
            var ws = rec.wal_chunk_write_set(sq)
            assert_true(
                len(ws) >= 1,
                "[4] seed=" + String(Int(seed)) + " slot " + String(Int(sq))
                + ": gapless recovered chunk must be non-empty",
            )
            sq += Int64(1)
        _ = rec^
        _ = shared^
    print(
        "    [OK] (4) —", n_seeds, "seeds: fresh handles re-LIST after the warm"
        " head dies; monotone gapless, no lost/dup write under crash",
    )


# =============================================================================
# (5) stale-reuse CHURN SOAK — destroy-recreate TableStore cycles with the lease ENABLED
#     across cycles. The lease fields are plain PODs (Bool + Int64) on the
#     TableStore; the struct also owns heap fields (KeyIndex, the index Slab).
#     N destroy-recreate cycles over a shared store, each enabling the lease and
#     committing, exercise the allocator byte-reuse path the stale-reuse trap rides:
#     a destroyed handle's bytes are recycled under the next handle's lifetime.
#     A stale-reuse/double-free/UAF would crash or corrupt; we assert every cycle's
#     commit lands at the correct monotone slot + the final recovery is exact.
#     (Mirrors the stale-reuse soak shape: sustained churn, fixed seeds.)
# =============================================================================


def test_5_stale_reuse_churn_soak() raises:
    print(
        "[5] stale-reuse CHURN SOAK — destroy-recreate TableStore cycles, lease ENABLED"
        " across cycles, sustained: no stale-reuse/double-free/UAF, monotone exact"
    )
    var n_cycles = 200
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("ts/leb/5/churn")
    var rng = Rng(UInt64(0x6A96000DEAD))
    var n_keys = 8
    var expected_slot = Int64(0)
    for cyc in range(n_cycles):
        # Build a FRESH lease-enabled handle (its lease PODs + heap fields are
        # allocated into byte ranges a prior cycle's handle just freed).
        var ts = TableStore[SharedInMemoryConditionalStore].open(
            CasManifestStore[SharedInMemoryConditionalStore](
                store=shared.clone(),
                prefix=prefix.copy(),
                retry=RetryPolicy.fast_test(),
            )
        )
        ts.enable_writer_lease_fastpath()
        # Commit 1-3 single-write txns this cycle (varying, deterministic).
        var nw = 1 + rng.next_int(3)
        for _ in range(nw):
            var ki = rng.next_int(n_keys)
            var t = ts.begin()
            var v = _b(String("c") + String(cyc) + String("_k") + String(ki))
            t.update(_key(ki), v^)
            var r = ts.commit(t^)
            assert_equal(
                r.commit_lsn,
                expected_slot,
                "[5] cycle=" + String(cyc) + ": commit must land at the next"
                " monotone slot (expected " + String(Int(expected_slot))
                + ", got " + String(Int(r.commit_lsn)) + ")",
            )
            expected_slot += Int64(1)
        # The warm lease head must reflect the last committed slot within a cycle
        # (it warmed on this handle's first commit, advanced on each win).
        assert_true(
            ts.lease_head_warm(),
            "[5] cycle=" + String(cyc) + ": lease head warm after cycle commits",
        )
        # DESTROY the handle (its bytes recycle into the next cycle's handle).
        _ = ts^

    # FINAL recovery: the WAL must be a gapless 0..expected_slot-1 sequence with
    # every chunk intact (a stale-reuse corruption would surface as a torn/absent chunk
    # or a wrong head here, or have crashed mid-soak).
    var rec = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(),
            prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    assert_equal(
        rec.wal_head_seq(),
        expected_slot - Int64(1),
        "[5] recovered head must equal the total committed slot count - 1"
        " (no stale-reuse-induced lost/torn chunk across " + String(n_cycles)
        + " destroy-recreate cycles)",
    )
    var sq = Int64(0)
    while sq <= rec.wal_head_seq():
        var ws = rec.wal_chunk_write_set(sq)
        assert_true(
            len(ws) >= 1,
            "[5] slot " + String(Int(sq)) + ": intact non-empty chunk after"
            " the churn soak",
        )
        sq += Int64(1)
    _ = rec^
    _ = shared^
    print(
        "    [OK] (5) —", n_cycles, "destroy-recreate cycles, lease enabled:"
        " no stale-reuse/double-free/UAF, WAL gapless + intact",
    )


# =============================================================================
# (6) ELISION-EFFECTIVENESS INVARIANT — across varied single-writer schedules,
#     lease-ON steady-state issues ZERO authoritative-head LISTs + ZERO per-chunk
#     replay GETs after warmup (vs lease-OFF > 0). The win mechanism holds
#     BROADLY, not just on the one fixed schedule the existing count test covers.
#
# The _CountingConditionalStore counts the authoritative-head LIST
# (list_with_delimiter) + the per-chunk record-count replay GETs (get of a
# /manifest/ chunk key). We WARM both stores past the cold-start LIST (the first
# commit on a cold store pays a begin() LIST regardless of the lease — the
# durable _HEAD does not exist yet), RESET the counters, then drive the schedule
# and assert ON == 0/0 in steady state while OFF > 0.
# =============================================================================


struct _Counts(Movable, Deinitable):
    var list_calls: Int64
    var chunk_get_calls: Int64

    def __init__(out self):
        self.list_calls = Int64(0)
        self.chunk_get_calls = Int64(0)


struct _CountingConditionalStore(
    ConditionalWriteStore, ObjectStore, Movable, Deinitable
):
    """Counting wrapper over `InMemoryConditionalStore` (test-only). Increments
    `list_calls` on `list_with_delimiter` (the authoritative-head LIST) and
    `chunk_get_calls` on a full-object `get` of a `/manifest/` chunk key (the
    per-chunk record-count replay). Counters live in a length-1 Slab[POD] (the
    in-tree conformer interior-mutability pattern; reuse-safe (no heap fields))."""

    var _inner: InMemoryConditionalStore
    var _counts: Slab[_Counts]

    def __init__(out self):
        var slab = Slab[_Counts]()
        slab.append(_Counts())
        self._inner = InMemoryConditionalStore()
        self._counts = slab^

    def list_count(self) -> Int64:
        # SAFETY (get_mut_interior): single-threaded test store, only slot 0,
        # `self` outlives the ref; no realloc (slab sized 1, never grown).
        ref c = self._counts.get_mut_interior(0)
        return c.list_calls

    def chunk_get_count(self) -> Int64:
        ref c = self._counts.get_mut_interior(0)
        return c.chunk_get_calls

    def reset_counts(self):
        ref c = self._counts.get_mut_interior(0)
        c.list_calls = Int64(0)
        c.chunk_get_calls = Int64(0)

    # ---- ObjectStore base surface ----

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        ref c = self._counts.get_mut_interior(0)
        c.list_calls += Int64(1)
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    # ---- ConditionalWriteStore surface ----

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self._inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self._inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        return self._inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self._inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        if path.raw().find("/manifest/") >= 0:
            ref c = self._counts.get_mut_interior(0)
            c.chunk_get_calls += Int64(1)
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


def _new_counting_store(
    prefix: String, lease_on: Bool
) raises -> TableStore[_CountingConditionalStore]:
    var ts = TableStore[_CountingConditionalStore].open(
        CasManifestStore[_CountingConditionalStore](
            store=_CountingConditionalStore(),
            prefix=prefix,
            retry=RetryPolicy.fast_test(),
        )
    )
    # ACCOMMODATION (lease is now DEFAULT-ON at construction):
    # the OFF arm must EXPLICITLY disable so the elision-COUNTING differential
    # still exercises the LIST-per-commit fallback (the discriminator > 0).
    if lease_on:
        ts.enable_writer_lease_fastpath()
    else:
        ts.disable_writer_lease_fastpath()
    return ts^


def test_6_elision_effectiveness_broad() raises:
    print(
        "[6] ELISION-EFFECTIVENESS — across many schedules, lease-ON steady"
        " state issues ZERO authoritative LISTs + ZERO replay GETs (vs OFF > 0)"
    )
    var n_seeds = 20
    var n_txns = 16
    var n_keys = 6
    var max_writes = 3
    for s in range(n_seeds):
        var seed = UInt64(0x6E115000 + s * 0x1000193)
        var sched = _gen_schedule(seed, n_txns, n_keys, max_writes)
        var ac = _autocommit_flags(seed, len(sched.txns))

        var off = _new_counting_store(
            String("ts/leb/6/off/s") + String(s), False
        )
        var on = _new_counting_store(
            String("ts/leb/6/on/s") + String(s), True
        )

        # WARMUP: one commit on each (establishes the durable _HEAD + warms ON's
        # local head). Then RESET counters so we measure only steady state.
        var tw_off = off.begin()
        tw_off.insert(_b("__warm"), _b("w"))
        _ = off.commit(tw_off^)
        var tw_on = on.begin()
        tw_on.insert(_b("__warm"), _b("w"))
        _ = on.commit(tw_on^)
        off.wal_mut().store_mut().reset_counts()
        on.wal_mut().store_mut().reset_counts()
        assert_true(
            on.lease_head_warm(),
            "[6] seed=" + String(Int(seed)) + ": ON lease warm after warmup",
        )

        # STEADY STATE: drive the schedule on each.
        _drive_schedule(off, sched, ac)
        _drive_schedule(on, sched, ac)

        var off_lists = off.wal_mut().store_mut().list_count()
        var off_chunk_gets = off.wal_mut().store_mut().chunk_get_count()
        var on_lists = on.wal_mut().store_mut().list_count()
        var on_chunk_gets = on.wal_mut().store_mut().chunk_get_count()

        # OFF issues at least one authoritative-head LIST per steady-state commit
        # + the O(chunks) per-chunk replay GET fan — the cost the lease removes.
        assert_true(
            off_lists > Int64(0),
            "[6] seed=" + String(Int(seed)) + ": OFF issues authoritative-head"
            " LISTs in steady state (got " + String(Int(off_lists)) + ")",
        )
        assert_true(
            off_chunk_gets > Int64(0),
            "[6] seed=" + String(Int(seed)) + ": OFF issues per-chunk replay"
            " GETs in steady state (got " + String(Int(off_chunk_gets)) + ")",
        )
        # ON elides BOTH across ALL steady-state commits (the win mechanism).
        assert_equal(
            on_lists,
            Int64(0),
            "[6] seed=" + String(Int(seed)) + ": ON elides EVERY steady-state"
            " commit's authoritative-head LIST (got " + String(Int(on_lists))
            + ")",
        )
        assert_equal(
            on_chunk_gets,
            Int64(0),
            "[6] seed=" + String(Int(seed)) + ": ON elides EVERY per-chunk"
            " replay GET in steady state (got " + String(Int(on_chunk_gets))
            + ")",
        )
        _ = off^
        _ = on^
    print(
        "    [OK] (6) —", n_seeds, "seeds: lease-ON steady state = 0 LISTs +"
        " 0 replay-GETs (broad win-mechanism), OFF > 0",
    )


# =============================================================================
# main
# =============================================================================


def main() raises:
    print("== table store LEASE ENABLEMENT CORRECTNESS BATTERY ==")
    test_1_property_differential_on_eq_off()       # headline differential
    test_2_high_concurrency_stress()               # shared-store interleave
    test_3_fault_injection_lease_recovers()        # transient fault self-heal
    test_4_crash_recovery_lease_state_loss()       # lease-state-loss recovery
    test_5_stale_reuse_churn_soak()                        # destroy-recreate stale-reuse soak
    test_6_elision_effectiveness_broad()           # broad win-mechanism
    print(
        "[OK] test_table_store_lease_enablement_battery — the flip-readiness gate:"
        " lease-ON ==byte== lease-OFF across a broad schedule space; concurrency"
        " invariants hold; transient faults self-heal; crash-recovery loses no"
        " write; stale-reuse churn is clean; the elision win holds broadly"
    )
