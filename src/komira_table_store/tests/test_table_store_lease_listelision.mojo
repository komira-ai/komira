# =============================================================================
# src/komira_pgstore/tests/test_pgstore_lease_listelision.mojo
#   Single-writer LEASE LIST-elision fast-path — the
#   correctness + win-mechanism tests. The concurrent + 412 tests are
#   single-threaded DETERMINISTIC interleaves over a shared store (two
#   lease-aware handles, scripted commit order — no OS threads); the
#   create-CAS slot is the only arbiter, so a fixed interleave is a faithful
#   model of the concurrent race without thread nondeterminism.
# =============================================================================
#
# The lease fast-path elides the per-commit (post-P3: per coalesced BATCH)
# authoritative head recovery — `read_head_authoritative()` is a LIST + a
# GET-per-chunk record-count replay — when the lease is held (the flag is on AND
# a local monotone head is warm). The create-CAS slot stays the SOLE OCC arbiter;
# a wrong/stale local head can only LOSE the slot (412) -> fall back to the LIST.
#
# Tests (all RED-verifiable — see each test's discrimination note):
#   1. lease-vs-LIST BYTE-IDENTITY DIFFERENTIAL — single-writer AND concurrent-
#      writer; the committed state (rows / offsets / chunk contents) is
#      BYTE-IDENTICAL with the flag ON vs OFF. (the discriminating correctness
#      test — a deliberate off-by-one in the win-advance makes ON diverge.)
#   2. LIST-ELISION COUNTING — lease-ON single-writer steady state issues ZERO
#      authoritative-head LIST + per-chunk-replay GETs after warmup (count drops
#      from once-per-commit [OFF] to ~1-then-0 [ON]).
#   3. 412 -> re-LIST FALLBACK — a concurrent writer steals the slot -> the
#      lease-holder 412s -> invalidates + re-LISTs + retries + commits correctly.
#   4. STALE-LEASE FENCE — a superseded lease epoch -> create-CAS is lease_fenced
#      -> correct fallback/rejection (no wrong-offset commit).
#   5. OCC-UNDER-LEASE SOUNDNESS — a conflicting txn under lease still aborts
#      40001; SI/MVCC semantics UNCHANGED.
#
# Design: the lease fast-path scope note;
#   broker `_LocalHeadCache` cas_manifest.mojo:523-597 (the elision MECHANISM).
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.testing import assert_equal, assert_false, assert_true

from komira_collections.slab import Slab

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    ManifestHead,
    RetryPolicy,
    chunk_key,
    encode_chunk,
    encode_head,
    head_key,
    is_lease_fenced,
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

from komira_pgstore.key_index import KeyValue
from komira_pgstore.pgstore_codec import (
    PG_OP_PUT,
    PG_OP_TOMBSTONE,
    WriteOp,
    bytes_eq,
    encode_commit_chunk,
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


def _str(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out^


# =============================================================================
# _CountingConditionalStore — wraps InMemoryConditionalStore + counts the
# authoritative-head LIST (`list_with_delimiter`) and the per-chunk record-count
# replay GETs (`get` on a `/manifest/` chunk key). Single-threaded (the
# elision-count test is single-writer). Counters live in a length-1 Slab for
# interior mutability (the trait verbs take immutable `self`) — exactly the
# InMemory/S3 conformer pattern; stale-reuse N/A (POD counters, no byte-slab element).
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
    """Counting wrapper over `InMemoryConditionalStore` (test-only). Delegates
    every verb; increments `list_calls` on `list_with_delimiter` (the
    authoritative-head LIST) and `chunk_get_calls` on a full-object `get` of a
    `/manifest/` chunk key (the per-chunk record-count replay)."""

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


# =============================================================================
# Store constructors (flag OFF / flag ON).
# =============================================================================


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
    # disable to exercise the byte-identical pre-lease LIST path. The ON arm is a
    # no-op (already on by default) but kept explicit for intent.
    if lease_on:
        ts.enable_writer_lease_fastpath()
    else:
        ts.disable_writer_lease_fastpath()
    return ts^


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
    # the OFF arm must EXPLICITLY disable so the elision-COUNTING test still
    # exercises the LIST-per-commit fallback (the discriminator).
    if lease_on:
        ts.enable_writer_lease_fastpath()
    else:
        ts.disable_writer_lease_fastpath()
    return ts^


# A tiny single-write commit helper (returns the won commit_lsn).
def _commit_put[
    Store: ConditionalWriteStore
](mut ts: TableStore[Store], k: String, v: String) raises -> Int64:
    var t = ts.begin()
    t.insert(_b(k), _b(v))
    var r = ts.commit(t^)
    return r.commit_lsn


def _commit_delete[
    Store: ConditionalWriteStore
](mut ts: TableStore[Store], k: String) raises -> Int64:
    var t = ts.begin()
    t.delete(_b(k))
    var r = ts.commit(t^)
    return r.commit_lsn


# Drive an identical single-writer workload (the SAME ops both ON and OFF).
def _drive_single_writer_workload[
    Store: ConditionalWriteStore
](mut ts: TableStore[Store]) raises:
    _ = _commit_put(ts, String("a"), String("1"))
    _ = _commit_put(ts, String("b"), String("2"))
    _ = _commit_put(ts, String("a"), String("3"))  # overwrite a
    _ = _commit_delete(ts, String("b"))  # tombstone b
    _ = _commit_put(ts, String("c"), String("4"))
    _ = _commit_put(ts, String("a"), String("5"))  # overwrite a again


# Snapshot the FULL committed WAL state of a store as a byte string: per chunk,
# (seq, [op,key,row]*). Two stores with byte-identical snapshots committed the
# IDENTICAL chunk SEQUENCE — same gapless seq, same rows, same chunk contents.
#
# DISCRIMINATION SCOPE (reviewer note): the `@base=` column is RE-DERIVED here
# from the cumulative record counts of the scanned chunks (it is NOT read back
# from each chunk's persisted offset metadata). So the byte-identity assertion
# directly discriminates the SEQ component of a wrong win-advance — an off-by-one
# in the win-advance makes a stale local head always LOSE the create-CAS slot
# (412) and fall back, perturbing the committed chunk sequence, which this
# snapshot catches. The chunk's PERSISTED offset is correct-by-analysis (the
# create-CAS slot is the sole arbiter, and any wrong local head is self-healed
# by the authoritative-LIST replay on the 412 fallback) rather than asserted
# byte-for-byte against stored offset bytes here.
def _wal_state_snapshot[
    Store: ConditionalWriteStore
](ts: TableStore[Store]) raises -> String:
    var head = ts.wal_head_seq()
    var out = String("head=") + String(Int(head)) + String("\n")
    var seq = Int64(0)
    var base = Int64(0)  # cumulative base offset (re-derived from record counts)
    while seq <= head:
        var ws = ts.wal_chunk_write_set(seq)
        # Capture the re-derived base offset too — the gapless offset sequence is
        # part of the committed state (a wrong win-advance perturbs the SEQ, which
        # shifts this re-derived base; see the DISCRIMINATION SCOPE note above).
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


# =============================================================================
# (1) lease-vs-LIST BYTE-IDENTITY DIFFERENTIAL — single-writer.
#     DISCRIMINATING (SEQ component): a wrong win-advance (off-by-one) perturbs
#     the committed chunk SEQUENCE -> ON diverges from OFF. The persisted offset
#     is correct-by-analysis + self-healing on the authoritative-LIST replay (see
#     the _wal_state_snapshot DISCRIMINATION SCOPE note), not asserted directly.
# =============================================================================


def test_1a_byte_identity_single_writer() raises:
    print(
        "[1a] lease-vs-LIST byte-identity — single-writer — DISCRIMINATING"
    )
    var off = _new_mem_store(String("pg/li/1a_off"), False)
    var on = _new_mem_store(String("pg/li/1a_on"), True)

    _drive_single_writer_workload(off)
    _drive_single_writer_workload(on)

    var snap_off = _wal_state_snapshot(off)
    var snap_on = _wal_state_snapshot(on)
    assert_equal(
        snap_on, snap_off, "[1a] ON WAL state byte-identical to OFF"
    )

    # Cross-check the visible reads agree exactly too (RYOW/snapshot view).
    var t_off = off.begin()
    var t_on = on.begin()
    assert_true(
        bytes_eq(off.get(t_off, _b("a")).value(), _b("5")),
        "[1a] OFF a==5",
    )
    assert_true(
        bytes_eq(on.get(t_on, _b("a")).value(), _b("5")), "[1a] ON a==5"
    )
    assert_false(Bool(off.get(t_off, _b("b"))), "[1a] OFF b tombstoned")
    assert_false(Bool(on.get(t_on, _b("b"))), "[1a] ON b tombstoned")
    assert_true(
        bytes_eq(on.get(t_on, _b("c")).value(), _b("4")), "[1a] ON c==4"
    )

    # The lease head must be WARM after the steady-state single-writer run
    # (every commit after the first elided the LIST).
    assert_true(on.lease_head_warm(), "[1a] lease head warm after steady run")
    assert_false(off.lease_head_warm(), "[1a] OFF lease never warm")
    print("    [OK] (1a) — ON ≡ OFF, lease warm")
    _ = off^
    _ = on^
    _ = t_off^
    _ = t_on^


# =============================================================================
# (2) LIST-ELISION COUNTING — lease-ON single-writer issues ZERO authoritative
#     head LIST + per-chunk-replay GETs after warmup.
# =============================================================================


def test_2_list_elision_count() raises:
    print("[2] LIST-elision count — lease-ON elides per-commit LIST + replay")
    # The discriminating measure is the per-commit LIST DELTA in STEADY STATE
    # (after warmup), where the only difference between ON and OFF is the lease:
    #   * OFF: each commit's `commit_prelude` reads the authoritative head
    #     (read_head_authoritative = 1 LIST + a per-chunk record-count replay GET
    #     per existing chunk). The LIST + replay-GET count GROWS with the commit
    #     sequence.
    #   * ON: the warm local head ELIDES that authoritative read entirely — each
    #     steady-state commit adds ZERO authoritative-head LISTs AND ZERO
    #     per-chunk replay GETs.
    # (The very first commit on a cold store ALSO pays a `begin()` LIST because
    # the durable `_HEAD` object does not exist yet — that LIST is independent of
    # the lease, so we WARM both stores past it, then measure the steady-state
    # delta, isolating the lease's effect.)
    var n = 6
    var off = _new_counting_store(String("pg/li/2_off"), False)
    var on = _new_counting_store(String("pg/li/2_on"), True)

    # WARMUP: one commit on each (establishes the durable `_HEAD` + warms ON's
    # local lease head). Then RESET the counters so we measure only steady state.
    _ = _commit_put(off, String("warm"), String("w"))
    _ = _commit_put(on, String("warm"), String("w"))
    off.wal_mut().store_mut().reset_counts()
    on.wal_mut().store_mut().reset_counts()
    assert_true(on.lease_head_warm(), "[2] ON lease head warm after warmup")

    # STEADY STATE: n more commits on each.
    for i in range(n):
        _ = _commit_put(off, String("k") + String(i), String("v") + String(i))
    for i in range(n):
        _ = _commit_put(on, String("k") + String(i), String("v") + String(i))

    var off_lists = off.wal_mut().store_mut().list_count()
    var off_chunk_gets = off.wal_mut().store_mut().chunk_get_count()
    var on_lists = on.wal_mut().store_mut().list_count()
    var on_chunk_gets = on.wal_mut().store_mut().chunk_get_count()
    print(
        "    OFF steady-state list_calls =",
        off_lists,
        " chunk_get_calls =",
        off_chunk_gets,
    )
    print(
        "    ON  steady-state list_calls =",
        on_lists,
        " chunk_get_calls =",
        on_chunk_gets,
    )

    # OFF issues at LEAST one authoritative-head LIST per steady-state commit,
    # plus the O(chunks) per-chunk replay GET fan — the cost the lease removes.
    assert_true(
        off_lists >= Int64(n),
        "[2] OFF issues >= one authoritative-head LIST per steady-state commit",
    )
    assert_true(
        off_chunk_gets > Int64(0),
        "[2] OFF issues per-chunk record-count replay GETs (the O(chunks) tail)",
    )

    # ON elides BOTH: ZERO authoritative-head LISTs AND ZERO per-chunk replay
    # GETs across ALL n steady-state commits (the win mechanism).
    assert_equal(
        on_lists,
        Int64(0),
        "[2] ON elides EVERY steady-state commit's authoritative-head LIST",
    )
    assert_equal(
        on_chunk_gets,
        Int64(0),
        "[2] ON elides EVERY per-chunk record-count replay GET in steady state",
    )

    # The win must be REAL: both stores committed all chunks gaplessly (warm + n).
    assert_equal(off.wal_head_seq(), Int64(n), "[2] OFF committed warm + n")
    assert_equal(on.wal_head_seq(), Int64(n), "[2] ON committed warm + n")
    print(
        "    [OK] (2) — ON drops from",
        off_lists,
        "LISTs +",
        off_chunk_gets,
        "replay-GETs to 0 + 0",
    )
    _ = off^
    _ = on^


# =============================================================================
# (3) 412 -> re-LIST FALLBACK — a concurrent writer steals the slot; the
#     lease-holder 412s -> invalidates + re-LISTs + retries + commits correctly.
# =============================================================================


def test_3_412_relist_fallback() raises:
    print("[3] 412 -> re-LIST fallback — concurrent slot steal")
    # Two TableStore handles over ONE shared store (clone shares the map). A is
    # the lease-holder (warm); B is a sibling writer with no lease.
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/li/3")
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
    # ACCOMMODATION (lease is now DEFAULT-ON): disable B so it
    # matches the stated scenario ("B is a sibling writer with no lease"). B does
    # a single commit so the outcome is unchanged either way; the disable keeps
    # the test's intent honest.
    b.disable_writer_lease_fastpath()

    # Warm A's lease head with a first commit.
    var lsn0 = _commit_put(a, String("ka"), String("a0"))
    assert_equal(lsn0, Int64(0), "[3] A first commit wins slot 0")
    assert_true(a.lease_head_warm(), "[3] A lease head warm after first commit")

    # B (sibling, no lease) commits a chunk DIRECTLY into the next slot — this
    # is the concurrent slot steal: A's warm local head still points at seq 0,
    # but the true tail is now seq 1 (B's chunk on a DIFFERENT key, so NO OCC
    # conflict for A — A must fall back, re-LIST, and re-commit at seq 2).
    var lsn_b = _commit_put(b, String("kb"), String("b0"))
    assert_equal(lsn_b, Int64(1), "[3] B steals slot 1")

    # A commits again on its OWN key. Its warm local head (seq 0) -> create-CAS
    # at seq 1 -> 412 (B took it) -> invalidate + re-LIST (true tail seq 1) ->
    # re-OCC (B's key kb does NOT intersect A's ka -> no conflict) -> commit at
    # seq 2. NO lost write, correct monotone offset.
    var lsn_a2 = _commit_put(a, String("ka"), String("a1"))
    assert_equal(
        lsn_a2,
        Int64(2),
        "[3] A re-LISTs after 412 + commits at the correct monotone slot 2",
    )

    # All three rows visible at the correct values (no lost update, no
    # wrong-offset commit).
    var ta = a.begin()
    assert_true(
        bytes_eq(a.get(ta, _b("ka")).value(), _b("a1")), "[3] ka==a1"
    )
    assert_true(
        bytes_eq(a.get(ta, _b("kb")).value(), _b("b0")), "[3] kb==b0 (B's write)"
    )
    assert_equal(a.wal_head_seq(), Int64(2), "[3] gapless tail at seq 2")
    print("    [OK] (3) — 412 -> re-LIST -> correct slot 2, no lost write")
    _ = a^
    _ = b^
    _ = ta^


# =============================================================================
# (4) STALE-LEASE FENCE — a superseded lease epoch -> create-CAS is lease_fenced
#     -> correct rejection (no wrong-offset commit).
# =============================================================================


def test_4_stale_lease_fence() raises:
    print("[4] stale-lease fence — superseded epoch rejected at create-CAS")
    var ts = _new_mem_store(String("pg/li/4"), False)
    # A first clean commit (no lease) establishes a tail.
    var lsn0 = _commit_put(ts, String("k"), String("v0"))
    assert_equal(lsn0, Int64(0), "[4] first commit at slot 0")

    # Now enable the lease with a STALE writer epoch (1) BELOW the live epoch
    # (5): the create-CAS must FENCE the commit (lease_fenced) — a stale
    # displaced writer never takes a slot.
    ts.enable_writer_lease_fastpath(
        writer_lease_epoch=Int64(1), current_lease_epoch=Int64(5)
    )
    var fenced = False
    try:
        _ = _commit_put(ts, String("k"), String("v1"))
    except e:
        if is_lease_fenced(String(e)):
            fenced = True
        else:
            raise e^
    assert_true(fenced, "[4] stale-lease commit is FENCED (lease_fenced)")
    # The fenced commit took NO slot: the tail is still seq 0, k still == v0.
    assert_equal(ts.wal_head_seq(), Int64(0), "[4] fenced commit took no slot")
    var t = ts.begin()
    assert_true(
        bytes_eq(ts.get(t, _b("k")).value(), _b("v0")),
        "[4] k unchanged (v0) — no wrong-offset commit",
    )
    # The lease head was invalidated by the fence.
    assert_false(ts.lease_head_warm(), "[4] lease head invalidated by fence")

    # A FRESH (non-stale) epoch then commits cleanly at the next slot.
    ts.enable_writer_lease_fastpath(
        writer_lease_epoch=Int64(5), current_lease_epoch=Int64(5)
    )
    var lsn1 = _commit_put(ts, String("k"), String("v2"))
    assert_equal(lsn1, Int64(1), "[4] fresh-epoch commit at slot 1")
    var t2 = ts.begin()
    assert_true(
        bytes_eq(ts.get(t2, _b("k")).value(), _b("v2")), "[4] k==v2 after fresh"
    )
    print("    [OK] (4) — stale fenced (no slot), fresh commits cleanly")
    _ = ts^
    _ = t^
    _ = t2^


# =============================================================================
# (5) OCC-UNDER-LEASE SOUNDNESS — a conflicting txn under lease still aborts
#     40001. SI/MVCC semantics UNCHANGED.
# =============================================================================


def test_5_occ_under_lease_soundness() raises:
    print("[5] OCC-under-lease soundness — first-committer-wins still 40001")
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/li/5")
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
    # ACCOMMODATION (lease is now DEFAULT-ON): disable B (the
    # plain sibling writer). B does a single commit so the outcome is unchanged;
    # the disable keeps the OCC-conflict scenario matching its stated shape.
    b.disable_writer_lease_fastpath()

    # Seed a value + warm A's lease head.
    var lsn0 = _commit_put(a, String("x"), String("0"))
    assert_equal(lsn0, Int64(0), "[5] seed at slot 0")

    # Two txns BOTH pin the same snapshot S (=0) and BOTH write key "x". The
    # first committer wins; the second is a genuine write-write conflict ->
    # 40001, EVEN with A's lease held (the OCC scan over (snapshot, auth_head]
    # against the LOCAL head must still catch B's just-committed conflict after
    # the 412 re-LIST).
    var ta = a.begin()
    ta.update(_b("x"), _b("A"))
    var tb = b.begin()
    tb.update(_b("x"), _b("B"))

    # B commits first (no lease) -> wins slot 1.
    var rb = b.commit(tb^)
    assert_equal(rb.commit_lsn, Int64(1), "[5] B wins slot 1")

    # A (lease-held) commits its conflicting txn: warm head seq 0 -> create-CAS
    # at seq 1 -> 412 -> invalidate + re-LIST (true tail seq 1) -> re-OCC sees
    # B's x@1 > snapshot 0 intersecting A's write-set -> ABORT 40001.
    var aborted = False
    try:
        _ = a.commit(ta^)
    except e:
        if is_occ_conflict(String(e)):
            aborted = True
        else:
            raise e^
    assert_true(aborted, "[5] A's conflicting commit ABORTS 40001 under lease")

    # The store reflects B's write (first committer won); A's was rejected.
    var tr = a.begin()
    assert_true(
        bytes_eq(a.get(tr, _b("x")).value(), _b("B")),
        "[5] x==B (first committer won; no lost update)",
    )
    assert_equal(a.wal_head_seq(), Int64(1), "[5] tail at seq 1 (no A chunk)")
    print("    [OK] (5) — OCC 40001 still fires under lease, SI intact")
    _ = a^
    _ = b^
    _ = tr^


# =============================================================================
# (1b) lease-vs-LIST BYTE-IDENTITY DIFFERENTIAL — CONCURRENT writers.
#      Two handles over one shared store; an interleaved sequence run ON and OFF
#      must produce the SAME committed chunk sequence (deterministic single-
#      threaded interleave — the lease never changes the committed total order;
#      the create-CAS slot does). DISCRIMINATING via the win-advance off-by-one.
# =============================================================================


def _drive_concurrent_interleave[
    Store: ConditionalWriteStore
](mut a: TableStore[Store], mut b: TableStore[Store]) raises:
    # A deterministic interleave: A, B, A, A, B, A on DISJOINT keys (no OCC
    # conflict — pure offset/sequence interleave). Both handles are lease-aware
    # callers; only A has the lease enabled by the caller (B is a plain sibling).
    _ = _commit_put(a, String("a0"), String("av0"))
    _ = _commit_put(b, String("b0"), String("bv0"))
    _ = _commit_put(a, String("a1"), String("av1"))
    _ = _commit_put(a, String("a0"), String("av0b"))  # A overwrites a0
    _ = _commit_put(b, String("b1"), String("bv1"))
    _ = _commit_put(a, String("a2"), String("av2"))


def test_1b_byte_identity_concurrent() raises:
    print("[1b] lease-vs-LIST byte-identity — concurrent — DISCRIMINATING")

    # OFF run.
    var shared_off = SharedInMemoryConditionalStore()
    var poff = String("pg/li/1b_off")
    var a_off = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared_off.clone(), prefix=poff.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var b_off = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared_off.clone(), prefix=poff.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    # ACCOMMODATION (lease is now DEFAULT-ON): explicitly DISABLE
    # both OFF-run handles, otherwise this differential degenerates to ON-vs-ON
    # (tautological). Disabling preserves the genuine ON-vs-OFF discrimination.
    a_off.disable_writer_lease_fastpath()
    b_off.disable_writer_lease_fastpath()
    _drive_concurrent_interleave(a_off, b_off)
    var snap_off = _wal_state_snapshot(a_off)

    # ON run (A holds the lease).
    var shared_on = SharedInMemoryConditionalStore()
    var pon = String("pg/li/1b_on")
    var a_on = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared_on.clone(), prefix=pon.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    a_on.enable_writer_lease_fastpath()
    var b_on = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared_on.clone(), prefix=pon.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    _drive_concurrent_interleave(a_on, b_on)
    var snap_on = _wal_state_snapshot(a_on)

    # The prefixes differ in the snapshot only via the chunk KEYS (not the
    # prefix — the snapshot encodes op/key/row, not the store path), so the two
    # snapshots must be byte-identical.
    assert_equal(
        snap_on,
        snap_off,
        "[1b] concurrent ON WAL state byte-identical to OFF",
    )
    assert_equal(a_on.wal_head_seq(), Int64(5), "[1b] 6 chunks committed (ON)")
    assert_equal(
        a_off.wal_head_seq(), Int64(5), "[1b] 6 chunks committed (OFF)"
    )
    print("    [OK] (1b) — concurrent ON ≡ OFF")
    _ = a_off^
    _ = b_off^
    _ = a_on^
    _ = b_on^


def main() raises:
    test_1a_byte_identity_single_writer()
    test_1b_byte_identity_concurrent()
    test_2_list_elision_count()
    test_3_412_relist_fallback()
    test_4_stale_lease_fence()
    test_5_occ_under_lease_soundness()
    print("[lease-listelision] ALL TESTS PASSED")
