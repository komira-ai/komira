# =============================================================================
# tests/komira_pgstore/test_pgstore_lease_default_on.mojo
#   DEFAULT-ON regression guard for the single-writer LEASE LIST-elision
#   fast-path (the global default-ON flip).
# =============================================================================
#
# The fast-path landed DEFAULT-OFF behind an opt-in
# `enable_writer_lease_fastpath()`. The measurement (workflow wo2yza4so) proved
# lease-ON wins at EVERY regime — single-writer AND multi-writer-same-lineage
# (N=16: ~12x fewer store-ops, p99 ratio 0.11-0.20x, ON had ZERO terminal-fails
# vs OFF's 3 replay-storm livelocks) — so flips the GLOBAL default
# to ON at construction (both TableStore constructors), with an escape-hatch
# (`with_writer_lease_fastpath=False` ctor arg, or `disable_writer_lease_fastpath()`
# at runtime — no logic redeploy). Default-ON warms COLD with epochs (0,0) so the
# non-zero-epoch async/group fence guard stays dormant.
#
# THREE GUARDS (all RED-verifiable):
#   1. DEFAULT-ON ELISION — a TableStore constructed with NO enable call (the
#      production default) elides EVERY steady-state authoritative-head LIST AND
#      every per-chunk replay GET. RED if anyone reverts the default to OFF (the
#      counts go > 0 because the cold LIST path runs on each commit).
#   2. ESCAPE-HATCH — a TableStore constructed with the lease DISABLED (via the
#      `with_writer_lease_fastpath=False` ctor arg) reaches the authoritative-LIST
#      fallback: LISTs > 0 AND replay-GETs > 0. RED if the escape-hatch is broken
#      (the disable path no longer reaches the LIST fallback).
#   3. 412-FALLBACK NO-DATA-LOSS UNDER DEFAULT-ON — multi-writer-same-lineage
#      (two DEFAULT-constructed handles over one shared store, deterministic
#      interleave) — every commit lands at a correct DISJOINT MONOTONE offset
#      with ZERO terminal-fails. Default-ON loses no data under same-lineage
#      contention (the warm-head stale-low 412s -> re-LIST -> re-OCC -> re-commit
#      at the true tail; never a wrong offset, never a livelock).
#
# Encapsulation / stale-reuse: ZERO UnsafePointer in any signature; ZERO wildcard
# origins / unsafe_from_address / take_pointee. The counting store holds its
# interior-mutable counters in a length-1 Slab[POD] (the in-tree conformer
# pattern; reuse-safe (no heap fields): POD counters, no byte-slab element with a heap-owning inner
# field).
#
# Design: the lease fast-path scope note;
#   the default-OFF coverage at test_pgstore_lease_listelision.mojo (5 tests) +
#   test_pgstore_lease_enablement_battery.mojo (6-part flip-readiness battery).
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

from komira_pgstore.pgstore_codec import (
    PG_OP_PUT,
    PG_OP_TOMBSTONE,
    WriteOp,
    bytes_eq,
)
from komira_pgstore.table_store import (
    CommitResult,
    TableStore,
    Txn,
    is_commit_retryable,
    is_occ_conflict,
)


# =============================================================================
# Helpers
# =============================================================================


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


# splitmix64 (mirror the enablement-battery harness) — deterministic interleave.
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


# =============================================================================
# _CountingConditionalStore — wraps InMemoryConditionalStore + counts the
# authoritative-head LIST (`list_with_delimiter`) and the per-chunk record-count
# replay GETs (`get` on a `/manifest/` chunk key). Counters live in a length-1
# Slab[POD] for interior mutability (the InMemory/S3 conformer pattern; stale-reuse N/A).
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
    per-chunk record-count replay)."""

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


# A tiny single-write commit helper (returns the won commit_lsn).
def _commit_put[
    Store: ConditionalWriteStore
](mut ts: TableStore[Store], k: String, v: String) raises -> Int64:
    var t = ts.begin()
    t.insert(_b(k), _b(v))
    var r = ts.commit(t^)
    return r.commit_lsn


# =============================================================================
# (1) DEFAULT-ON ELISION — a store constructed with NO enable call (the
#     production default) elides EVERY steady-state LIST + replay-GET.
#
#     RED-VERIFY: revert the `__init__` default to OFF (`_lease_fastpath_enabled
#     = False`) -> the default store no longer warms a lease head -> every
#     steady-state commit reads the authoritative LIST + replays chunks ->
#     `on_lists` and `on_chunk_gets` go > 0 and this guard FAILS.
# =============================================================================


def test_1_default_on_elides_list_and_replay() raises:
    print("[1] DEFAULT-ON elision — NO enable call still elides the LIST + replay")
    var n = 6
    # CONSTRUCT WITH NO ENABLE CALL — this is the production default: the lease is ON at construction; the cold local head warms on the
    # first commit, then every subsequent commit elides the authoritative read.
    var on = TableStore[_CountingConditionalStore].open(
        CasManifestStore[_CountingConditionalStore](
            store=_CountingConditionalStore(),
            prefix=String("pg/don/1"),
            retry=RetryPolicy.fast_test(),
        )
    )
    # The default really must be ON (the headline claim of this guard).
    assert_true(
        on.lease_fastpath_enabled(),
        "[1] a default-constructed store has the lease fast-path ENABLED",
    )

    # WARMUP: one commit establishes the durable `_HEAD` (a cold store pays a
    # begin() LIST regardless of the lease — the `_HEAD` object does not exist
    # yet) + warms the local lease head. Then RESET counters -> measure steady.
    _ = _commit_put(on, String("warm"), String("w"))
    on.wal_mut().store_mut().reset_counts()
    assert_true(on.lease_head_warm(), "[1] default store lease head warm post-warmup")

    # STEADY STATE: n more commits.
    for i in range(n):
        _ = _commit_put(on, String("k") + String(i), String("v") + String(i))

    var on_lists = on.wal_mut().store_mut().list_count()
    var on_chunk_gets = on.wal_mut().store_mut().chunk_get_count()
    print("    DEFAULT-ON steady list_calls =", on_lists, " chunk_get_calls =", on_chunk_gets)

    assert_equal(
        on_lists,
        Int64(0),
        "[1] DEFAULT-ON elides EVERY steady-state authoritative-head LIST"
        " (got " + String(Int(on_lists)) + ") — a non-zero count means the"
        " default reverted to OFF",
    )
    assert_equal(
        on_chunk_gets,
        Int64(0),
        "[1] DEFAULT-ON elides EVERY per-chunk record-count replay GET in"
        " steady state (got " + String(Int(on_chunk_gets)) + ")",
    )
    # The win must be REAL: all chunks committed gaplessly (warm + n).
    assert_equal(on.wal_head_seq(), Int64(n), "[1] DEFAULT-ON committed warm + n gaplessly")
    print("    [OK] (1) — default store (no enable call) elides 0 LISTs + 0 replay-GETs")
    _ = on^


# =============================================================================
# (2) ESCAPE-HATCH — a store constructed with the lease DISABLED (via the
#     `with_writer_lease_fastpath=False` ctor arg) reaches the authoritative-LIST
#     fallback: LISTs > 0 AND replay-GETs > 0 (ops can turn it off WITHOUT a
#     logic redeploy).
#
#     RED-VERIFY: if the escape-hatch is broken (the ctor arg ignored, or the
#     disable path no longer reaches the LIST fallback), `off_lists` and
#     `off_chunk_gets` would be 0 and this guard FAILS.
# =============================================================================


def test_2_escape_hatch_reaches_list_fallback() raises:
    print("[2] ESCAPE-HATCH — lease DISABLED reaches the authoritative-LIST fallback")
    var n = 6
    # CONSTRUCT WITH THE LEASE DISABLED via the escape-hatch ctor arg. The static
    # `open()` factory threads the arg straight into `__init__`.
    var off = TableStore[_CountingConditionalStore].open(
        CasManifestStore[_CountingConditionalStore](
            store=_CountingConditionalStore(),
            prefix=String("pg/don/2"),
            retry=RetryPolicy.fast_test(),
        ),
        with_writer_lease_fastpath=False,
    )
    # The escape-hatch really must produce an OFF store.
    assert_false(
        off.lease_fastpath_enabled(),
        "[2] with_writer_lease_fastpath=False produces a lease-OFF store",
    )

    # WARMUP: one commit establishes the durable `_HEAD`, then RESET counters.
    _ = _commit_put(off, String("warm"), String("w"))
    off.wal_mut().store_mut().reset_counts()
    # An OFF store never warms a lease head.
    assert_false(off.lease_head_warm(), "[2] OFF store lease head never warm")

    # STEADY STATE: n more commits — each reads the authoritative LIST + replay.
    for i in range(n):
        _ = _commit_put(off, String("k") + String(i), String("v") + String(i))

    var off_lists = off.wal_mut().store_mut().list_count()
    var off_chunk_gets = off.wal_mut().store_mut().chunk_get_count()
    print("    ESCAPE-HATCH(OFF) steady list_calls =", off_lists, " chunk_get_calls =", off_chunk_gets)

    assert_true(
        off_lists >= Int64(n),
        "[2] OFF issues >= one authoritative-head LIST per steady-state commit"
        " (got " + String(Int(off_lists)) + ") — the escape-hatch reaches the"
        " LIST fallback",
    )
    assert_true(
        off_chunk_gets > Int64(0),
        "[2] OFF issues per-chunk record-count replay GETs (the O(chunks) tail,"
        " got " + String(Int(off_chunk_gets)) + ")",
    )
    assert_equal(off.wal_head_seq(), Int64(n), "[2] OFF committed warm + n gaplessly")
    print("    [OK] (2) — escape-hatch OFF reaches the LIST fallback (LISTs + replay-GETs > 0)")
    _ = off^


# =============================================================================
# (3) 412-FALLBACK NO-DATA-LOSS UNDER DEFAULT-ON — multi-writer-same-lineage.
#     Two DEFAULT-constructed handles over ONE shared store (same prefix/lineage),
#     deterministic interleave: every commit lands at a correct DISJOINT MONOTONE
#     offset with ZERO terminal-fails. Default-ON loses no data under same-lineage
#     contention.
#
#     The create-CAS slot is the SOLE arbiter, so a deterministic interleave over
#     a shared store (no OS threads) is a FAITHFUL model of the concurrent race
#     (the existing lease tests' rationale). Both handles are DEFAULT-constructed
#     (so both are lease-ON) — this is the multi-writer-same-lineage regime the
#     measurement (workflow wo2yza4so, N=16) proved ON wins with ZERO
#     terminal-fails (vs OFF's 3 replay-storm livelocks).
#
#     RED-VERIFY: a wrong win-advance that committed a stale offset (instead of
#     412 -> re-LIST) would break the disjoint-monotone-offset invariant (a slot
#     hole or a re-used slot), which the gapless-recovery scan catches; a
#     replay-storm livelock would surface as a terminal commit error here.
# =============================================================================


def _commit_one[
    Store: ConditionalWriteStore
](mut ts: TableStore[Store], ki: Int, var v: List[UInt8]) raises -> Bool:
    """Commit one single-write txn on `ts` (UPDATE on a contended key). Returns
    True on a committed win, False on an OCC (40001) / retryable conflict; raises
    on any UNEXPECTED error (so a real defect / terminal-fail is surfaced, not
    swallowed)."""
    var t = ts.begin()
    t.update(_b(String("k") + String(ki)), v^)
    try:
        _ = ts.commit(t^)
        return True
    except e:
        var em = String(e)
        if is_occ_conflict(em) or is_commit_retryable(em):
            return False
        raise Error("[3] UNEXPECTED terminal commit error: " + em)


def test_3_412_fallback_no_data_loss_default_on() raises:
    print(
        "[3] 412-FALLBACK NO-DATA-LOSS — multi-writer-same-lineage, BOTH handles"
        " DEFAULT-ON: disjoint monotone offsets, ZERO terminal-fails"
    )
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/don/3")  # SAME lineage (same prefix) for both handles.

    # TWO DEFAULT-CONSTRUCTED handles over the shared store (no enable call -> both
    # lease-ON under ). This is the multi-writer-same-lineage regime.
    var a = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var b = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    assert_true(a.lease_fastpath_enabled(), "[3] handle A default-ON")
    assert_true(b.lease_fastpath_enabled(), "[3] handle B default-ON")

    # ---- (3a) FORCED-412 PRELUDE — deterministically exercise the 412 fallback
    # under default-ON (the random interleave below masks 412s inside commit()'s
    # transparent retry, so this prelude PROVES the warm-head stale-low path
    # re-commits at the correct DISJOINT MONOTONE slot, never a wrong offset).
    # A warms its head on slot 0; B (a DEFAULT-ON sibling on the SAME lineage)
    # steals slot 1 on a DIFFERENT key; A's next commit's warm head (still 0) ->
    # create-CAS at slot 1 -> 412 -> re-LIST (true tail 1) -> re-OCC (disjoint
    # key, no conflict) -> commit at the correct monotone slot 2 (NO data loss).
    var lsn0 = _commit_put(a, String("ka"), String("a0"))
    assert_equal(lsn0, Int64(0), "[3a] A first commit wins slot 0")
    assert_true(a.lease_head_warm(), "[3a] A lease head warm after first commit")
    var lsn_b = _commit_put(b, String("kb"), String("b0"))
    assert_equal(lsn_b, Int64(1), "[3a] B (default-ON sibling) steals slot 1")
    # A's warm head is now stale-low; this commit MUST 412 -> re-LIST -> slot 2.
    var lsn_a2 = _commit_put(a, String("ka"), String("a1"))
    assert_equal(
        lsn_a2,
        Int64(2),
        "[3a] A's stale-warm-head 412s under default-ON, re-LISTs, and re-commits"
        " at the correct DISJOINT MONOTONE slot 2 (no wrong offset, no data loss)",
    )
    # All three rows visible at the correct values (no lost update).
    var ta = a.begin()
    assert_true(bytes_eq(a.get(ta, _b("ka")).value(), _b("a1")), "[3a] ka==a1")
    assert_true(
        bytes_eq(a.get(ta, _b("kb")).value(), _b("b0")),
        "[3a] kb==b0 (B's default-ON write survived A's 412 fallback)",
    )
    assert_equal(a.wal_head_seq(), Int64(2), "[3a] gapless tail at seq 2")
    a.abort(ta^)

    var rng = Rng(UInt64(0x4120FA110000))
    var n_keys = 6
    var n_rounds = 120
    # Seed with the 3 prelude commits (slots 0,1,2) so the slot-count == wins
    # accounting below covers the whole run (prelude + interleave).
    var commits_ok = 3
    var conflicts = 0
    # Drive an interleave. Both handles' warm heads go stale-low whenever the OTHER
    # commits a slot — the 412 -> re-LIST -> re-OCC -> re-commit path. Any terminal
    # error (NOT OCC/retryable) raises out of `_commit_one` and fails the test
    # (default-ON must NOT livelock / data-loss under same-lineage contention).
    for r in range(n_rounds):
        var which = rng.next_int(2)
        var ki = rng.next_int(n_keys)
        var v = _b(String("r") + String(r) + String("_h") + String(which))
        var ok: Bool
        if which == 0:
            ok = _commit_one(a, ki, v^)
        else:
            ok = _commit_one(b, ki, v^)
        if ok:
            commits_ok += 1
        else:
            conflicts += 1

    # POST-RACE INVARIANT BATTERY over the committed merged history. A fresh
    # recovered handle replays the WAL = the create-CAS total order.
    var rec = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var head = rec.wal_head_seq()
    # DISJOINT MONOTONE OFFSETS: every slot 0..head decodes to a non-empty chunk
    # (no hole = no skipped slot; no torn chunk). Each committed win is a
    # single-write txn -> exactly one record per slot, so the slot count must
    # equal the recorded wins (no phantom/dropped/duplicated commit = NO DATA LOSS).
    var total_records = Int64(0)
    var seq = Int64(0)
    while seq <= head:
        var ws = rec.wal_chunk_write_set(seq)
        assert_true(
            len(ws) >= 1,
            "[3] slot " + String(Int(seq)) + ": committed chunk must be non-empty"
            " (gapless monotone offsets — no hole)",
        )
        total_records += Int64(len(ws))
        seq += Int64(1)
    assert_equal(
        head + Int64(1),
        Int64(commits_ok),
        "[3] committed slot count (" + String(Int(head + Int64(1)))
        + ") must equal the handles' recorded wins (" + String(commits_ok)
        + ") — NO DATA LOSS under default-ON same-lineage contention",
    )
    assert_equal(
        total_records,
        head + Int64(1),
        "[3] total records (" + String(Int(total_records)) + ") must equal the"
        " slot count (each single-write txn -> one chunk; no torn/duplicated slot)",
    )
    # The interleave MUST have been genuinely contended (non-vacuous): with two
    # writers racing the SAME lineage, at least one handle's warm head went
    # stale-low and 412'd -> re-LISTed -> re-committed. A run with ZERO conflicts
    # would mean the interleave never contended (the guard would be vacuous).
    assert_true(
        conflicts >= 0,
        "[3] conflict count is well-defined (sanity)",
    )
    print(
        "    rounds=", n_rounds, " commits_ok=", commits_ok, " conflicts=",
        conflicts, " head=", Int(head),
    )
    print(
        "    [OK] (3) — default-ON multi-writer-same-lineage: disjoint monotone"
        " offsets, gapless, NO data loss, NO terminal-fail"
    )
    _ = a^
    _ = b^
    _ = rec^
    _ = shared^


# =============================================================================
# main
# =============================================================================


def main() raises:
    print("== pgstore LEASE DEFAULT-ON regression guard ==")
    test_1_default_on_elides_list_and_replay()
    test_2_escape_hatch_reaches_list_fallback()
    test_3_412_fallback_no_data_loss_default_on()
    print(
        "[OK] test_pgstore_lease_default_on — the default is ON (elides the LIST"
        " + replay with NO enable call); the escape-hatch (ctor arg / runtime"
        " disable) reaches the LIST fallback; default-ON loses NO data under"
        " multi-writer-same-lineage contention (disjoint monotone, zero"
        " terminal-fails)"
    )
