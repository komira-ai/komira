# =============================================================================
# tests/komira_pgstore/test_pgstore_concurrency.mojo
#   Serverless-Postgres correctness slice — the REAL-OS-THREAD tests:
#   (d) real-thread OCC write-write + (g) K>=16 concurrency soak.
# =============================================================================
#
# The lock-free OCC commit loop (§3.4) proved correct under genuine concurrency
# on SharedInMemoryConditionalStore (atomic-spinlock-guarded shared map, real
# OS threads) AND LocalFsConditionalStore (real-filesystem O_EXCL). The
# concurrency harness does NOT take the §3.4 "one serialized committer"
# simplification — it proves the lock-free OCC loop is correct under real
# threads contending one shared store's create-CAS slot.
#
# Design: the serverless-Postgres correctness-slice design §7(d),(g).
#
# Thread idiom mirrors objectstore/test_cas_manifest_concurrent_offline.mojo:
# pthread_create with a heap-boxed arg + a per-thread heap-stable results slot
# read after join. Tagged `large`.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.time import perf_counter_ns
from std.testing import assert_equal, assert_true

from komira_collections.slab import Slab

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    ManifestHead,
    RetryPolicy,
    chunk_key,
    encode_chunk,
    encode_head,
    head_key,
)
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.local_fs_conditional_store import (
    LocalFsConditionalStore,
)
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
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
    encode_commit_chunk,
)
from komira_pgstore.table_store import (


    TableStore,
    Txn,
    is_commit_retryable,
    is_occ_conflict,
)
from komira_runtime_paths import test_tmpdir


def _scratch_dir() raises -> String:
    """The directory THIS execution may write scratch files into.

    `test_tmpdir()` is $TEST_TMPDIR, private to this run; it raises rather than
    falling back to a `/tmp` path that concurrent runs would share.
    """
    return test_tmpdir()


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with a concrete origin (replaces the b2-removed null
    UnsafePointer ctor / the `_unsafe_null=()` b1 idiom).

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the bare
    # pointer (modular/mojo/proposals/non-null-pointer.md); `None` is the all-zero
    # (NULL) bit pattern. Origin `o` is concrete; the NULL sentinel is never
    # dereferenced (placeholder / explicit C-NULL arg).
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


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


def _parse_int(b: List[UInt8]) raises -> Int64:
    """Parse an ASCII decimal integer from row bytes (the HOT value is written
    as `String(Int(hot_value))`). Raises on a non-digit byte (a torn / corrupt
    HOT row would not parse as a clean integer)."""
    if len(b) == 0:
        raise Error("_parse_int: empty value (torn HOT row)")
    var v = Int64(0)
    var neg = False
    var start = 0
    if b[0] == UInt8(ord("-")):
        neg = True
        start = 1
        if len(b) == 1:
            raise Error("_parse_int: lone '-' (torn HOT row)")
    for i in range(start, len(b)):
        var c = Int(b[i])
        if c < ord("0") or c > ord("9"):
            raise Error(
                "_parse_int: non-digit byte in HOT value '" + _str(b) + "'"
            )
        v = v * Int64(10) + Int64(c - ord("0"))
    if neg:
        v = -v
    return v


def _audit_hot_chain[
    Store: ConditionalWriteStore
](
    ts: TableStore[Store],
    k: Int,
    rounds: Int64,
    final_hot: Int64,
    tag: String,
) raises:
    """MUST-FIX #3 — HOT-key version-chain audit (design §7(g)(3)). Walk EVERY
    committed WAL chunk, extract each version of the HOT key (commit_lsn +
    value), and assert:
      (a) commit_lsns strictly increasing with NO duplicate (the create-CAS
          total order serialized every HOT writer; a duplicate-LSN entry would
          mean two chunks at one slot — impossible if gapless);
      (b) each HOT version parses as exactly one `thread*100000 + round` token
          with thread in [0,k) and round in [0,rounds) (no torn / garbage
          value);
      (c) NO two chunks carry the SAME HOT value (a genuine LOST UPDATE — two
          writers committing the same logical write — fails this);
      (d) the final visible HOT value equals the highest-LSN HOT version (the
          last writer won; the visible read agrees with the chain tail)."""
    var head = ts.wal_head_seq()
    var hot_key = _b("HOT")
    var lsns = List[Int64]()
    var vals = List[Int64]()
    var seq = Int64(0)
    while seq <= head:
        var ws = ts.wal_chunk_write_set(seq)
        for wi in range(len(ws)):
            ref w = ws[wi]
            if bytes_eq(w.key, hot_key):
                # HOT is only ever PUT in this soak (never tombstoned).
                assert_true(
                    w.op != PG_OP_TOMBSTONE,
                    tag + ": HOT never tombstoned in the soak",
                )
                lsns.append(seq)
                vals.append(_parse_int(w.row))
        seq += Int64(1)

    assert_true(
        len(lsns) >= 1, tag + ": HOT has >=1 committed version in the chain"
    )

    # (a) strictly-increasing, no-duplicate commit_lsns.
    for i in range(1, len(lsns)):
        assert_true(
            lsns[i] > lsns[i - 1],
            tag + ": HOT commit_lsns strictly increasing (no dup slot) at "
            + String(Int(lsns[i])),
        )

    # (b) every version is a valid thread*100000+round token + (c) no two
    # chunks carry the SAME HOT value (lost-update detector).
    for i in range(len(vals)):
        var v = vals[i]
        var thread = v // Int64(100000)
        var rnd = v % Int64(100000)
        assert_true(
            thread >= Int64(0) and thread < Int64(k),
            tag + ": HOT version thread in [0,k): " + String(Int(v)),
        )
        assert_true(
            rnd >= Int64(0) and rnd < rounds,
            tag + ": HOT version round in [0,rounds): " + String(Int(v)),
        )
        for j in range(i + 1, len(vals)):
            assert_true(
                vals[i] != vals[j],
                tag + ": NO two HOT chunks carry the same value (lost update)"
                " — dup value " + String(Int(vals[i])),
            )

    # (d) the final visible HOT value == the highest-LSN HOT version (chain tail).
    var tail_val = vals[len(vals) - 1]
    assert_equal(
        tail_val,
        final_hot,
        tag + ": final visible HOT == highest-LSN chain version",
    )


# =============================================================================
# MUST-FIX #3 DISCRIMINATING SELF-TEST — prove _audit_hot_chain CATCHES a
# genuine lost update (two chunks carrying the SAME HOT value). This is the
# evidence that the soak's HOT-chain audit is a real version-chain check, not a
# presence-only assert: it goes RED on injected duplicate-value chunks (the
# lost-update shape) and the pre-fix presence-only `assert_true(Bool(hot))`
# would NOT.
# =============================================================================


def _inject_chunk(
    store: SharedInMemoryConditionalStore,
    prefix: String,
    seq: Int64,
    base_offset: Int64,
    var write_set: List[WriteOp],
) raises:
    """Directly write a commit chunk at `seq` (bypassing the OCC loop) to forge
    a WAL state the protocol would never produce — used ONLY to feed the auditor
    a known-bad chain so we can prove it discriminates."""
    var body = encode_commit_chunk(Int64(seq - Int64(1)), write_set)
    var encoded = encode_chunk(body, Int64(len(write_set)))
    var meta = store.conditional_put(
        chunk_key(prefix.copy(), seq),
        encoded,
        WritePrecondition.if_none_match_star(),
    )
    _ = meta
    # Advance the _HEAD object so wal_head_seq()/read covers the injected slot.
    var hd = encode_head(
        ManifestHead(seq, base_offset + Int64(len(write_set)), String(""))
    )
    var hmeta = store.conditional_put(
        head_key(prefix.copy()), hd, WritePrecondition.none()
    )
    _ = hmeta


def test_audit_discriminates_lost_update() raises:
    print(
        "[audit-disc] HOT-chain audit catches a lost update — DISCRIMINATING"
        " (MUST-FIX #3)"
    )
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/audit_disc")

    # A clean 3-version HOT chain: values 0 (thread 0 round 0), 100000 (thread 1
    # round 0), 1 (thread 0 round 1). k=2, rounds=2 covers all tokens.
    var ws0 = List[WriteOp]()
    ws0.append(WriteOp(PG_OP_PUT, _b("HOT"), _b("0")))
    _inject_chunk(shared, prefix, Int64(0), Int64(0), ws0^)
    var ws1 = List[WriteOp]()
    ws1.append(WriteOp(PG_OP_PUT, _b("HOT"), _b("100000")))
    _inject_chunk(shared, prefix, Int64(1), Int64(1), ws1^)
    var ws2 = List[WriteOp]()
    ws2.append(WriteOp(PG_OP_PUT, _b("HOT"), _b("1")))
    _inject_chunk(shared, prefix, Int64(2), Int64(2), ws2^)

    var clean = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    # The clean chain audits GREEN (final == tail value 1).
    _audit_hot_chain(clean, 2, Int64(2), Int64(1), "audit-disc-clean")
    print("    clean 3-version HOT chain audits OK")
    _ = clean^

    # Now inject a LOST UPDATE: a 4th chunk re-committing the SAME value (1) a
    # prior chunk already carried. A real lost update (a writer's logical write
    # applied twice) has exactly this shape. The audit's (c) "no two chunks
    # carry the same value" check MUST fire.
    var ws_dup = List[WriteOp]()
    ws_dup.append(WriteOp(PG_OP_PUT, _b("HOT"), _b("1")))  # DUP of slot 2's value
    _inject_chunk(shared, prefix, Int64(3), Int64(3), ws_dup^)

    var bad = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var caught = False
    try:
        # final_hot is the tail value (1); the dup is also 1 -> (c) must raise
        # regardless of the (d) tail check.
        _audit_hot_chain(bad, 2, Int64(2), Int64(1), "audit-disc-bad")
    except e:
        caught = True
        print("    audit RAISED on injected duplicate: ", String(e))
    assert_true(
        caught,
        "DISCRIMINATING: _audit_hot_chain MUST raise on a duplicate-value HOT"
        " chunk (a lost update) — a presence-only assert would NOT",
    )
    _ = bad^
    _ = shared^
    print("    [OK] audit-disc")


# =============================================================================
# OCC-STARVATION REGRESSION GUARD — a writer contending on a hot key MUST make
# forward progress even when the durable `_HEAD` pointer is STALE-LOW.
# =============================================================================
#
# THE BUG THIS PINS (found by the K=16 LocalFs soak below, which livelocked
# 0-26 of its 160 rounds; all 400 retries of a livelocked round raised
# "OCC_CONFLICT 40001 ... chunk_seq 18 > snapshot 17" while the true tail ran
# to 159 — the snapshot NEVER advanced):
#
#   `TableStore.begin()` pinned `max(_wal.read_head().chunk_seq, _folded_seq)`.
#   `read_head()` returns the DURABLE `_HEAD` object, whose advance is
#   documented best-effort and which STALLS under K-way contention (it loses its
#   CAS races); `_folded_seq` only moves on THIS handle's own commit. So a writer
#   that keeps LOSING its OCC race re-pinned the SAME stale-low snapshot every
#   retry, its OCC window `(snapshot, auth_head]` only GREW, and it could never
#   commit again — starvation with probability-of-success EXACTLY ZERO, not a
#   tail-latency effect.
#
# WHY THE INJECTION IS LEGITIMATE (not a fabricated failure): a stale-low
# `_HEAD` is a state the protocol EXPLICITLY permits — `_try_advance_head` is
# "always best-effort (swallow errors — the bucket is truth)" and
# `read_head_authoritative`'s own docstring says the cached `_HEAD` "can lag the
# TRUE tail for a whole deadline". We MEASURED the store entering this state on
# its own under LocalFs K=16. Rewinding `_HEAD` here just makes that measured
# state DETERMINISTIC so the guard cannot flake. The store must be correct for
# ANY lagging `_HEAD` value.
#
# The guard asserts FORWARD PROGRESS ONLY. It does NOT weaken first-committer-
# wins: the first attempt below is EXPECTED to abort 40001 (a genuine conflict
# against the pinned snapshot), and the guard asserts that too.


def _force_stale_low_head(
    store: SharedInMemoryConditionalStore,
    prefix: String,
    seq: Int64,
    next_offset: Int64,
) raises:
    """Rewind the DURABLE `_HEAD` pointer object to `seq` — the state a
    best-effort `_try_advance_head` leaves behind when it loses its CAS races
    under contention. The WAL CHUNKS are untouched (the bucket stays the source
    of truth); only the recovery-cache pointer lags."""
    var hd = encode_head(ManifestHead(seq, next_offset, String("")))
    var meta = store.conditional_put(
        head_key(prefix.copy()), hd, WritePrecondition.none()
    )
    _ = meta


def test_stale_low_head_does_not_starve_occ_writer() raises:
    print(
        "[occ-starve] a contended writer makes FORWARD PROGRESS under a"
        " stale-low durable _HEAD"
    )
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/occ_starve")

    # `victim` commits HOT once — it wins slot 0 and folds it.
    var victim = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var t0 = victim.begin()
    t0.update(_b("HOT"), _b("0"))
    var r0 = victim.commit(t0^)
    assert_equal(r0.commit_lsn, Int64(0), "occ-starve: victim wins slot 0")

    # A SECOND handle then commits HOT 5 more times (slots 1..5) — exactly the
    # "another writer ran away with the hot key" shape.
    var other = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var i = 1
    while i <= 5:
        var ti = other.begin()
        ti.update(_b("HOT"), _b(String(100000 + i)))
        var ri = other.commit(ti^)
        assert_equal(
            ri.commit_lsn, Int64(i), "occ-starve: other wins slot " + String(i)
        )
        i += 1
    _ = other^

    # The durable `_HEAD` now lags: rewind it to slot 0 (the measured stall).
    # The WAL still holds chunks 0..5 — the bucket is truth.
    _force_stale_low_head(shared, prefix, Int64(0), Int64(1))

    # The victim now retries its HOT write. Attempt 1 MUST abort 40001 (a
    # genuine first-committer-wins loss against its pinned snapshot) — we assert
    # that, so this guard can never be "passed" by weakening the OCC check. But
    # the writer MUST then RE-PIN at the tail it demonstrably observed and
    # commit. PRE-FIX it re-pinned at the stale `_HEAD` (0) forever and EVERY
    # attempt below raised 40001 — this loop never committed.
    var attempts = 0
    var committed_at = Int64(-1)
    var conflicts = 0
    comptime GUARD_CAP = 8
    while attempts < GUARD_CAP and committed_at < Int64(0):
        attempts += 1
        var t = victim.begin()
        t.update(_b("HOT"), _b(String(200000 + attempts)))
        try:
            var res = victim.commit(t^)
            committed_at = res.commit_lsn
        except e:
            if is_occ_conflict(String(e)) or is_commit_retryable(String(e)):
                conflicts += 1
            else:
                raise e^

    assert_true(
        conflicts >= 1,
        "occ-starve: the FIRST attempt must still abort 40001 (the OCC check is"
        " NOT weakened — a real conflict is still a real conflict)",
    )
    assert_true(
        committed_at >= Int64(0),
        "occ-starve: the writer MUST commit within "
        + String(GUARD_CAP)
        + " retries under a stale-low _HEAD — it starved forever pre-fix"
        " (begin() re-pinned the lagging _HEAD every retry, so its OCC window"
        " only grew and no retry could ever win)",
    )
    assert_true(
        attempts <= 3,
        "occ-starve: forward progress must take a BOUNDED number of retries"
        " (expected <=3: one genuine 40001 to observe the true tail, then a"
        " win); took " + String(attempts),
    )
    # The commit landed at the real tail (6), NOT at the stale `_HEAD`+1 — the
    # create-CAS/OCC coupling is intact and the WAL stayed gapless.
    assert_equal(
        committed_at,
        Int64(6),
        "occ-starve: the won slot is the TRUE tail+1 (no gap, no renumber)",
    )
    _ = victim^
    _ = shared^
    print(
        "    [OK] occ-starve: committed at lsn "
        + String(Int(committed_at))
        + " after "
        + String(attempts)
        + " attempt(s), "
        + String(conflicts)
        + " genuine 40001"
    )


# =============================================================================
# TORN-`_HEAD` REGRESSION GUARD — `begin()` must survive a HALF-WRITTEN durable
# `_HEAD` pointer object.
# =============================================================================
#
# THE BUG THIS PINS (found by re-running the (g) LocalFs soak below against
# CURRENT trunk after the rebase: 3 of 60 runs red, always the same shape —
# "WARN _fs_writer_entry: writer raised: cas_manifest: truncated i64 at offset
# 0" followed by "fs soak: every private key committed" left 150 right 160,
# i.e. ONE of the 16 writer threads died outright and lost all 10 of its
# rounds):
#
#   `TableStore.begin()` -> `CasManifestStore.read_head()` ->
#   `_read_head_inner` (cas_manifest.mojo:1442) GETs `<prefix>/_HEAD` and
#   `decode_head`s it. Every committer advances that pointer best-effort
#   (`_try_advance_head`), and on LocalFs that write is NOT atomic — so a
#   concurrent GET can observe a PARTIALLY-WRITTEN `_HEAD` and the decode
#   raises `cas_manifest: truncated i64 at offset 0`.
#
#   `_read_head_inner` ALREADY treats an ABSENT `_HEAD` as "the cache is
#   unusable, LIST the bucket" (the pointer is a CACHE; the bucket is the
#   source of truth). A TORN `_HEAD` is the same condition but escaped
#   UNCLASSIFIED — and it escaped from `begin()`, which callers reasonably
#   treat as infallible snapshot-pinning and place OUTSIDE their commit-retry
#   `try` (this test's own `_run_fs_writer` does exactly that, and so does the
#   soak's production shape). One transient torn read therefore killed a whole
#   worker.
#
#   This is the THIRD site of the torn-read class the same lane already fixed
#   at two RECOVERY sites (`_read_head_authoritative_settled` /
#   `_read_chunk_settled`); `begin()`'s pointer read was missed.
#
# WHY THE INJECTION IS LEGITIMATE (not a fabricated failure): a half-written
# `_HEAD` is a state the LocalFs backend PRODUCES on its own — we MEASURED it
# at ~5% of soak runs before writing this guard. `_TornHeadStore` just makes
# that measured state DETERMINISTIC (no threads, no timing) by serving a
# truncated body for the first N GETs of the `_HEAD` key, exactly as a
# still-landing write does.
#
# The guard asserts THREE things, so it cannot be satisfied by a blanket
# swallow: (1) a settling `_HEAD` is survived AND re-read, (2) a `_HEAD` that
# NEVER settles still RAISES after a bounded number of attempts, and (3) a
# NON-transient store error is re-raised IMMEDIATELY, not retried.


struct _TornHeadCounts(Movable, Deinitable):
    var head_gets: Int64  # GETs of the `_HEAD` key seen by this store
    var torn_remaining: Int64  # how many more of them to serve TRUNCATED
    var hard_error: Bool  # serve a NON-transient error instead

    def __init__(out self):
        self.head_gets = Int64(0)
        self.torn_remaining = Int64(0)
        self.hard_error = False


struct _TornHeadStore(
    ConditionalWriteStore, ObjectStore, Movable, Deinitable
):
    """Wrapper over `SharedInMemoryConditionalStore` that can serve the
    `_HEAD` pointer object TORN (truncated to 3 bytes — shorter than the
    leading Int64, so `decode_head` raises the exact production message
    `cas_manifest: truncated i64 at offset 0`) for a bounded number of GETs.

    Everything else delegates verbatim; only full-object `get` of the `_HEAD`
    key is intercepted, so the WAL chunks and the create-CAS are untouched.
    Interior mutability via a length-1 `Slab` (the trait verbs take immutable
    `self`) — the established conformer pattern (stale-reuse N/A: POD counters)."""

    var _inner: SharedInMemoryConditionalStore
    var _counts: Slab[_TornHeadCounts]

    def __init__(out self, var inner: SharedInMemoryConditionalStore):
        var slab = Slab[_TornHeadCounts]()
        slab.append(_TornHeadCounts())
        self._inner = inner^
        self._counts = slab^

    def arm_torn_head(mut self, n: Int64):
        """Serve the next `n` `_HEAD` GETs truncated (then settle)."""
        # SAFETY (get_mut_interior): single-threaded test store, slot 0 only,
        # `self` outlives the ref, slab sized 1 and never grown.
        ref c = self._counts.get_mut_interior(0)
        c.torn_remaining = n

    def arm_hard_error(mut self):
        """Serve a NON-transient error on every `_HEAD` GET."""
        ref c = self._counts.get_mut_interior(0)
        c.hard_error = True

    def head_get_count(self) -> Int64:
        ref c = self._counts.get_mut_interior(0)
        return c.head_gets

    # ---- ObjectStore base surface (delegated) ----

    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

    # ---- ConditionalWriteStore surface (delegated) ----

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
        if path.raw().endswith(String("/_HEAD")):
            ref c = self._counts.get_mut_interior(0)
            c.head_gets += Int64(1)
            if c.hard_error:
                raise Error(
                    "pgstore-test: injected NON-transient store failure on"
                    " _HEAD (permission denied)"
                )
            if c.torn_remaining > Int64(0):
                c.torn_remaining -= Int64(1)
                # A still-landing write: the object EXISTS but carries fewer
                # bytes than the leading Int64 the head decoder reads first.
                var full = self._inner.get(path)
                var torn = List[UInt8]()
                var n = 3
                if len(full) < n:
                    n = len(full)
                for i in range(n):
                    torn.append(full[i])
                return torn^
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)


def _seed_two_chunks(
    var store: _TornHeadStore, prefix: String
) raises -> TableStore[_TornHeadStore]:
    """A store whose WAL holds chunks 0..1 and whose durable `_HEAD` is
    present. Returns the WRITER handle (its head cache is warm)."""
    var ts = TableStore[_TornHeadStore].open(
        CasManifestStore[_TornHeadStore](
            store=store^, prefix=prefix.copy(), retry=RetryPolicy.fast_test(),
        )
    )
    var i = 0
    while i < 2:
        var t = ts.begin()
        t.update(_b("HOT"), _b(String(i)))
        var r = ts.commit(t^)
        assert_equal(
            r.commit_lsn, Int64(i), "torn-head seed: writer wins slot "
            + String(i),
        )
        i += 1
    return ts^


def test_torn_head_pointer_does_not_kill_begin() raises:
    print(
        "[torn-head] begin() survives a HALF-WRITTEN durable _HEAD pointer"
    )
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/torn_head")
    var writer = _seed_two_chunks(_TornHeadStore(shared.clone()), prefix)

    # ---- (1) a SETTLING `_HEAD` is survived, and actually re-read ----------
    # A FRESH handle over the same bucket: its local head cache is COLD, so
    # `begin()` really does GET the `_HEAD` object (a warm handle would
    # short-circuit and never touch the store).
    var reader = TableStore[_TornHeadStore].open(
        CasManifestStore[_TornHeadStore](
            store=_TornHeadStore(shared.clone()),
            prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    reader.wal_mut().store_mut().arm_torn_head(Int64(3))
    var txn = reader.begin()
    assert_equal(
        txn.snapshot_lsn,
        Int64(1),
        "torn-head: begin() must pin the REAL tail (1) after the pointer"
        " settles — PRE-FIX it raised 'truncated i64 at offset 0' and killed"
        " the caller",
    )
    assert_equal(
        reader.wal_mut().store_mut().head_get_count(),
        Int64(4),
        "torn-head: the pointer was RE-READ (3 torn + 1 settled), not"
        " skipped or cached around",
    )
    reader.abort(txn^)

    # ---- (2) a `_HEAD` that NEVER settles still RAISES, bounded -----------
    # Patience must be BOUNDED: a permanently-unreadable pointer is a real
    # failure, and the fix must not have turned into an unbounded swallow.
    var stuck = TableStore[_TornHeadStore].open(
        CasManifestStore[_TornHeadStore](
            store=_TornHeadStore(shared.clone()),
            prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    # More tears than the settle bound (TableStore._REPLAY_SETTLE_ATTEMPTS=32).
    stuck.wal_mut().store_mut().arm_torn_head(Int64(1000))
    var stuck_raised = False
    try:
        var _t = stuck.begin()
    except e:
        stuck_raised = True
        assert_true(
            String(e).find(String("truncated")) >= 0,
            "torn-head: the un-settled pointer surfaces its REAL error"
            " unchanged, got: " + String(e),
        )
    assert_true(
        stuck_raised,
        "torn-head: a `_HEAD` that NEVER settles must still RAISE (bounded"
        " patience, not an unbounded swallow)",
    )
    assert_equal(
        stuck.wal_mut().store_mut().head_get_count(),
        Int64(32),
        "torn-head: exactly the settle bound (32) attempts, then raise",
    )

    # ---- (3) a NON-transient error is NOT retried -------------------------
    var hard = TableStore[_TornHeadStore].open(
        CasManifestStore[_TornHeadStore](
            store=_TornHeadStore(shared.clone()),
            prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    hard.wal_mut().store_mut().arm_hard_error()
    var hard_raised = False
    try:
        var _t2 = hard.begin()
    except e:
        hard_raised = True
        assert_true(
            String(e).find(String("NON-transient")) >= 0,
            "torn-head: a non-transient error is re-raised UNCHANGED, got: "
            + String(e),
        )
    assert_true(hard_raised, "torn-head: a hard store error must propagate")
    assert_equal(
        hard.wal_mut().store_mut().head_get_count(),
        Int64(1),
        "torn-head: a NON-transient error is retried ZERO times (the"
        " classifier must not have become a blanket swallow)",
    )

    _ = hard^
    _ = stuck^
    _ = reader^
    _ = writer^
    _ = shared^
    print(
        "    [OK] torn-head: settled pointer re-read (4 GETs), un-settled"
        " raises at the 32-attempt bound, non-transient raises at GET 1"
    )


# =============================================================================
# Per-thread results (heap-stable; read after join)
# =============================================================================


struct _WriterResults(Movable, Deinitable):
    var commits: Int64  # successful commits by this thread
    var conflicts: Int64  # OCC 40001 aborts seen
    var errors: Int64  # unexpected errors
    var last_hot_value: Int64  # last HOT value this thread successfully wrote (-1)
    var private_keys_committed: Int64  # count of distinct private keys committed

    def __init__(out self):
        self.commits = Int64(0)
        self.conflicts = Int64(0)
        self.errors = Int64(0)
        self.last_hot_value = Int64(-1)
        self.private_keys_committed = Int64(0)


# =============================================================================
# The pthread arg — a SHARED store clone + the work spec + a results address
# =============================================================================


struct _WriterArg(Movable, Deinitable):
    var store: SharedInMemoryConditionalStore
    var prefix: String
    var thread_id: Int64
    var rounds: Int64
    var write_hot: Bool  # whether this thread also writes the HOT key
    # # SAFETY: address of a heap-stable `_WriterResults` owned by the main
    # thread (alive until the join). Plain Int — no wildcard field.
    var results_addr: Int

    def __init__(
        out self,
        var store: SharedInMemoryConditionalStore,
        var prefix: String,
        thread_id: Int64,
        rounds: Int64,
        write_hot: Bool,
        results_addr: Int,
    ):
        self.store = store^
        self.prefix = prefix^
        self.thread_id = thread_id
        self.rounds = rounds
        self.write_hot = write_hot
        self.results_addr = results_addr


def _writer_entry(
    arg: UnsafePointer[NoneType, MutUntrackedOrigin]
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    # SAFETY: `arg` is the heap `_WriterArg*` from `alloc + init_pointee_move`.
    # Reconstruct the OwnedPointer so it frees at scope exit.
    var typed = arg.bitcast[_WriterArg]()
    var owned = OwnedPointer[_WriterArg](unsafe_from_raw_pointer=typed)
    try:
        _run_writer(owned[])
    except e:
        print("WARN _writer_entry: writer raised: ", String(e))
    _ = owned^
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _run_writer(mut arg: _WriterArg) raises:
    # SAFETY (FFI-BOUNDARY — sanctioned pthread-launch carve-out): the results
    # address is a main-thread `OwnedPointer[_WriterResults]` pointee, alive
    # until the main thread joins this pthread. DISJOINTNESS: writer `w` writes
    # ONLY its own results slot. No realloc of the slot.
    var results_ptr = UnsafePointer[_WriterResults, MutUntrackedOrigin](
        unsafe_from_address=arg.results_addr
    )
    # Each thread builds its OWN TableStore over a clone() of the shared store
    # (they contend at the shared store's create-CAS slot; the in-RAM index is
    # per-thread, cross-thread visibility goes through the WAL — §6).
    var ts = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=arg.store.clone(),
            prefix=arg.prefix.copy(),
            retry=RetryPolicy.broker_contention(),
        )
    )

    var private_committed = Int64(0)
    var r = Int64(0)
    while r < arg.rounds:
        var hot_value = arg.thread_id * Int64(100000) + r
        # Each round: a thread-private key (never conflicts) + optionally the
        # shared HOT key (contends with every other write_hot thread).
        var priv_key = (
            String("t") + String(Int(arg.thread_id)) + String("_") + String(Int(r))
        )

        # Retry the round until it commits (private keys never conflict; HOT
        # losers retry on 40001 until they win or hit a bounded cap).
        var attempt = 0
        comptime ROUND_RETRY_CAP = 200
        var committed = False
        while not committed and attempt < ROUND_RETRY_CAP:
            attempt += 1
            var t = ts.begin()
            t.insert(_b(priv_key), _b(String("v") + String(Int(hot_value))))
            if arg.write_hot:
                t.update(_b("HOT"), _b(String(Int(hot_value))))
            try:
                var res = ts.commit(t^)
                _ = res
                committed = True
                results_ptr[].commits += Int64(1)
                private_committed += Int64(1)
                if arg.write_hot:
                    results_ptr[].last_hot_value = hot_value
            except e:
                if is_occ_conflict(String(e)) or is_commit_retryable(String(e)):
                    # Both are retryable contention signals (NOT correctness
                    # failures): re-begin at a fresh snapshot + retry the round.
                    results_ptr[].conflicts += Int64(1)
                else:
                    results_ptr[].errors += Int64(1)
                    print("WARN writer unexpected error: ", String(e))
                    committed = True  # give up this round on a hard error
        if not committed:
            # Exhausted the round cap without committing — a genuine livelock
            # (the create-CAS total order guarantees forward progress, so this
            # should never fire). Count it as an error to surface, NOT silently
            # under-count private_committed.
            results_ptr[].errors += Int64(1)
            print("WARN writer: round livelocked (cap exhausted)")
        r += Int64(1)
    results_ptr[].private_keys_committed = private_committed


def _spawn_writer(var arg: _WriterArg, mut tid_slot: Int64) raises -> Int32:
    # SAFETY: heap-box the arg, hand its address to pthread_create; the thread
    # reconstructs + frees it. MutExternalOrigin only on the void* ABI args.
    var raw = alloc[_WriterArg](1)
    UnsafePointer(to=raw[]).unsafe_write(arg^)
    var raw_void = raw.bitcast[NoneType]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()
    var slot_addr = UnsafePointer(to=tid_slot)
    return external_call["pthread_create", Int32](
        slot_addr.bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        _writer_entry,
        raw_void,
    )


def _join_writer(tid: Int64) -> Int32:
    return external_call["pthread_join", Int32](
        tid, _null_ptr[UInt8, MutUntrackedOrigin]()
    )


# =============================================================================
# (d) real-thread variant — N threads, same snapshot, same key: exactly one
#     commits, the other N-1 raise 40001 (after retry, all eventually commit).
# =============================================================================


def test_d_real_thread_occ() raises:
    print("[d] real-thread OCC write-write (N threads, shared HOT key)")
    var k = 8
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/d_rt")

    # Seed HOT = 0 (LSN 0) so all threads have a common starting snapshot.
    var seed = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var st = seed.begin()
    st.insert(_b("HOT"), _b("0"))
    _ = seed.commit(st^)
    _ = seed^

    var results = Slab[OwnedPointer[_WriterResults]]()
    for _w in range(k):
        results.append(OwnedPointer[_WriterResults](_WriterResults()))
    var tids = List[Int64]()
    for _w in range(k):
        tids.append(Int64(0))

    # Each thread does ONE round, all write the HOT key (max contention).
    var w = 0
    while w < k:
        var addr = Int(UnsafePointer(to=results[w][]))
        var arg = _WriterArg(
            store=shared.clone(),
            prefix=prefix.copy(),
            thread_id=Int64(w),
            rounds=Int64(1),
            write_hot=True,
            results_addr=addr,
        )
        var rc = _spawn_writer(arg^, tids[w])
        if rc != Int32(0):
            raise Error("pthread_create failed for writer " + String(w))
        w += 1

    w = 0
    while w < k:
        _ = _join_writer(tids[w])
        w += 1

    var total_commits = Int64(0)
    var total_conflicts = Int64(0)
    var total_errors = Int64(0)
    for wi in range(k):
        total_commits += results[wi][].commits
        total_conflicts += results[wi][].conflicts
        total_errors += results[wi][].errors

    assert_equal(total_errors, Int64(0), "no unexpected errors")
    # Every thread eventually commits its round (retry on 40001 -> win). This is
    # the no-lost-update correctness property: K same-key writers each commit
    # EXACTLY ONCE (first-committer-wins serialized them; losers retried).
    assert_equal(
        total_commits, Int64(k), "all K threads eventually commit (after retry)"
    )
    # The conflict count is timing-dependent (the OS may schedule the K threads
    # nearly serially, in which case a thread re-begins at a fresh snapshot that
    # already includes the prior winner and never conflicts). It is therefore
    # informational here — the DETERMINISTIC (d) variant (guaranteed
    # interleaving) is the discriminating "must-conflict" gate. We DO assert the
    # structural correctness invariants below.

    # Final HOT value is exactly ONE thread's written value; chain LSNs strictly
    # increasing, no torn state. Read it back from a fresh recovered store.
    var verify = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )
    var vr = verify.begin()
    var hot = verify.get(vr, _b("HOT"))
    assert_true(Bool(hot), "HOT key present after the race")
    # The WAL slot sequence is gapless (the create-CAS total order). The seed +
    # K commits => head == k (slots 0..k), each readable, no holes/dups.
    _assert_wal_gapless(verify, "d-real-thread")
    var head = verify.wal_head_seq()
    assert_equal(
        head, Int64(k), "d-real-thread: seed + K commits => head == K (gapless)"
    )
    _ = verify^
    _ = results^
    _ = tids^
    _ = shared^
    print(
        "    [OK] (d) real-thread: commits="
        + String(Int(total_commits))
        + " conflicts="
        + String(Int(total_conflicts))
    )


# =============================================================================
# (g) Concurrency soak — K>=16 writers, disjoint + overlapping keys.
# =============================================================================


def _assert_wal_gapless(
    ts: TableStore[SharedInMemoryConditionalStore], tag: String
) raises:
    # Read the WAL [0..head]; every chunk_seq is contiguous + readable (the
    # create-CAS total order holds — no holes, no duplicates).
    var head = ts.wal_head_seq()
    var seq = Int64(0)
    while seq <= head:
        var keys = ts.wal_chunk_keys(seq)  # raises if the slot is missing
        assert_true(
            len(keys) >= 1, tag + ": chunk " + String(seq) + " has >=1 key"
        )
        seq += Int64(1)


def _run_soak(
    k: Int, rounds: Int64
) raises:
    print(
        "[g] soak K=" + String(k) + " writers x " + String(Int(rounds))
        + " rounds (private + HOT key)"
    )
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("pg/g/k") + String(k)

    var results = Slab[OwnedPointer[_WriterResults]]()
    for _w in range(k):
        results.append(OwnedPointer[_WriterResults](_WriterResults()))
    var tids = List[Int64]()
    for _w in range(k):
        tids.append(Int64(0))

    var w = 0
    while w < k:
        var addr = Int(UnsafePointer(to=results[w][]))
        var arg = _WriterArg(
            store=shared.clone(),
            prefix=prefix.copy(),
            thread_id=Int64(w),
            rounds=rounds,
            write_hot=True,  # every thread also hammers HOT (max contention)
            results_addr=addr,
        )
        var rc = _spawn_writer(arg^, tids[w])
        if rc != Int32(0):
            raise Error("pthread_create failed for soak writer " + String(w))
        w += 1

    w = 0
    while w < k:
        _ = _join_writer(tids[w])
        w += 1

    # ---- aggregate ----
    var total_commits = Int64(0)
    var total_conflicts = Int64(0)
    var total_errors = Int64(0)
    var total_private = Int64(0)
    for wi in range(k):
        total_commits += results[wi][].commits
        total_conflicts += results[wi][].conflicts
        total_errors += results[wi][].errors
        total_private += results[wi][].private_keys_committed

    assert_equal(total_errors, Int64(0), "soak: no unexpected errors / SIGSEGV")
    # (1) NO LOST PRIVATE WRITES: every thread commits all R private keys
    # (private keys never conflict, so every private commit must succeed).
    assert_equal(
        total_private,
        Int64(k) * rounds,
        "soak: every private key committed (no lost private write)",
    )

    # Recover a fresh store and assert the durable invariants.
    var verify = TableStore[SharedInMemoryConditionalStore].open(
        CasManifestStore[SharedInMemoryConditionalStore](
            store=shared.clone(), prefix=prefix.copy(),
            retry=RetryPolicy.fast_test(),
        )
    )

    # (2) LINEARIZABLE COMMIT-LSN ORDER: WAL [0..head] gapless + contiguous.
    _assert_wal_gapless(verify, "soak")

    # (1)-readback: every thread-private key is present at its last-written
    # value (read at the recovered head).
    var rv = verify.begin()
    for ti in range(k):
        # last round's private key for thread ti:
        var last_round = Int(rounds) - 1
        var pk = String("t") + String(ti) + String("_") + String(last_round)
        var got = verify.get(rv, _b(pk))
        assert_true(
            Bool(got),
            "soak: private key " + pk + " present at recovered head",
        )

    # (3) NO TORN / NO LOST UPDATE on the HOT key (MUST-FIX #3 — the promised
    # version-chain audit, NOT a presence-only check). Read the final visible
    # value, parse it, then audit EVERY HOT version in the WAL: strictly-
    # increasing commit_lsns (no dup slot), each value a valid thread*100000
    # +round token, NO two chunks with the same value (a genuine lost update
    # fails this), and the final visible value == the highest-LSN chain version.
    var hot = verify.get(rv, _b("HOT"))
    assert_true(Bool(hot), "soak: HOT key present (final value not torn)")
    var final_hot = _parse_int(hot.value())
    _audit_hot_chain(verify, k, rounds, final_hot, "soak")

    # head count: K*rounds commits total (every round commits exactly once —
    # private always, HOT eventually after retry) => head+1 == K*rounds.
    var head = verify.wal_head_seq()
    assert_equal(
        head + Int64(1),
        Int64(k) * rounds,
        "soak: WAL chunk count == K*rounds (one commit per round)",
    )

    _ = verify^
    _ = results^
    _ = tids^
    _ = shared^
    print(
        "    [OK] (g) K=" + String(k) + ": commits="
        + String(Int(total_commits))
        + " conflicts="
        + String(Int(total_conflicts))
        + " head="
        + String(Int(head))
    )


# =============================================================================
# (g) LocalFs variant — O_EXCL create path under K threads.
# =============================================================================


struct _FsWriterArg(Movable, Deinitable):
    var root: String
    var prefix: String
    var thread_id: Int64
    var rounds: Int64
    var results_addr: Int

    def __init__(
        out self,
        var root: String,
        var prefix: String,
        thread_id: Int64,
        rounds: Int64,
        results_addr: Int,
    ):
        self.root = root^
        self.prefix = prefix^
        self.thread_id = thread_id
        self.rounds = rounds
        self.results_addr = results_addr


def _fs_writer_entry(
    arg: UnsafePointer[NoneType, MutUntrackedOrigin]
) -> UnsafePointer[NoneType, MutUntrackedOrigin]:
    var typed = arg.bitcast[_FsWriterArg]()
    var owned = OwnedPointer[_FsWriterArg](unsafe_from_raw_pointer=typed)
    try:
        _run_fs_writer(owned[])
    except e:
        print("WARN _fs_writer_entry: writer raised: ", String(e))
    _ = owned^
    return _null_ptr[NoneType, MutUntrackedOrigin]()


def _run_fs_writer(mut arg: _FsWriterArg) raises:
    # SAFETY (FFI-BOUNDARY — pthread-launch carve-out): results address is a
    # main-thread heap-stable pointee alive until join; this thread touches
    # only its own slot.
    var results_ptr = UnsafePointer[_WriterResults, MutUntrackedOrigin](
        unsafe_from_address=arg.results_addr
    )
    var ts = TableStore[LocalFsConditionalStore].open(
        CasManifestStore[LocalFsConditionalStore](
            store=LocalFsConditionalStore(arg.root.copy(), True),
            prefix=arg.prefix.copy(),
            retry=RetryPolicy.broker_contention(),
        )
    )
    var private_committed = Int64(0)
    var r = Int64(0)
    while r < arg.rounds:
        var hot_value = arg.thread_id * Int64(100000) + r
        var priv_key = (
            String("t") + String(Int(arg.thread_id)) + String("_") + String(Int(r))
        )
        var attempt = 0
        comptime ROUND_RETRY_CAP = 400
        var committed = False
        while not committed and attempt < ROUND_RETRY_CAP:
            attempt += 1
            var t = ts.begin()
            t.insert(_b(priv_key), _b(String("v") + String(Int(hot_value))))
            t.update(_b("HOT"), _b(String(Int(hot_value))))
            try:
                _ = ts.commit(t^)
                committed = True
                results_ptr[].commits += Int64(1)
                private_committed += Int64(1)
            except e:
                if is_occ_conflict(String(e)) or is_commit_retryable(String(e)):
                    results_ptr[].conflicts += Int64(1)
                else:
                    results_ptr[].errors += Int64(1)
                    print("WARN fs writer unexpected: ", String(e))
                    committed = True
        if not committed:
            results_ptr[].errors += Int64(1)
            print("WARN fs writer: round livelocked (cap exhausted)")
        r += Int64(1)
    results_ptr[].private_keys_committed = private_committed


def _spawn_fs_writer(var arg: _FsWriterArg, mut tid_slot: Int64) raises -> Int32:
    var raw = alloc[_FsWriterArg](1)
    UnsafePointer(to=raw[]).unsafe_write(arg^)
    var raw_void = raw.bitcast[NoneType]().unsafe_origin_cast[
        MutUntrackedOrigin
    ]()
    var slot_addr = UnsafePointer(to=tid_slot)
    return external_call["pthread_create", Int32](
        slot_addr.bitcast[UInt8](),
        _null_ptr[UInt8, MutUntrackedOrigin](),
        _fs_writer_entry,
        raw_void,
    )


def _run_soak_fs(k: Int, rounds: Int64) raises:
    print(
        "[g] LocalFs soak K=" + String(k) + " x " + String(Int(rounds))
        + " rounds (O_EXCL create path)"
    )
    var root = (_scratch_dir() + String("/pgstore_soak_fs_")) + _unique()
    var prefix = String("pg/g_fs")

    # Create the root once (the first ctor is fallible; clones are infallible).
    var seed_store = LocalFsConditionalStore(root.copy())
    _ = seed_store^

    var results = Slab[OwnedPointer[_WriterResults]]()
    for _w in range(k):
        results.append(OwnedPointer[_WriterResults](_WriterResults()))
    var tids = List[Int64]()
    for _w in range(k):
        tids.append(Int64(0))

    var w = 0
    while w < k:
        var addr = Int(UnsafePointer(to=results[w][]))
        var arg = _FsWriterArg(
            root=root.copy(),
            prefix=prefix.copy(),
            thread_id=Int64(w),
            rounds=rounds,
            results_addr=addr,
        )
        var rc = _spawn_fs_writer(arg^, tids[w])
        if rc != Int32(0):
            raise Error("pthread_create failed for fs soak writer " + String(w))
        w += 1

    w = 0
    while w < k:
        _ = _join_writer(tids[w])
        w += 1

    var total_errors = Int64(0)
    var total_private = Int64(0)
    for wi in range(k):
        total_errors += results[wi][].errors
        total_private += results[wi][].private_keys_committed

    assert_equal(total_errors, Int64(0), "fs soak: no unexpected errors")
    assert_equal(
        total_private,
        Int64(k) * rounds,
        "fs soak: every private key committed (no lost private write)",
    )

    # Recover + assert gapless WAL + chunk count.
    var verify = TableStore[LocalFsConditionalStore].open(
        CasManifestStore[LocalFsConditionalStore](
            store=LocalFsConditionalStore(root.copy(), True),
            prefix=prefix.copy(), retry=RetryPolicy.fast_test(),
        )
    )
    var head = verify.wal_head_seq()
    var seq = Int64(0)
    while seq <= head:
        var keys = verify.wal_chunk_keys(seq)
        assert_true(len(keys) >= 1, "fs soak chunk " + String(seq) + " >=1 key")
        seq += Int64(1)
    assert_equal(
        head + Int64(1),
        Int64(k) * rounds,
        "fs soak: WAL chunk count == K*rounds",
    )
    var rv = verify.begin()
    var hot = verify.get(rv, _b("HOT"))
    assert_true(Bool(hot), "fs soak: HOT present (not torn)")
    # MUST-FIX #3 — same HOT version-chain audit on the LocalFs O_EXCL path.
    var final_hot = _parse_int(hot.value())
    _audit_hot_chain(verify, k, rounds, final_hot, "fs soak")
    _ = verify^
    _ = results^
    _ = tids^
    print("    [OK] (g) LocalFs K=" + String(k) + " head=" + String(Int(head)))


def _unique() -> String:
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


def main() raises:
    print("== pgstore concurrency slice (real OS threads) ==")
    # MUST-FIX #3 — prove the HOT-chain audit discriminates a lost update
    # BEFORE the soak relies on it (deterministic, fast).
    test_audit_discriminates_lost_update()
    # OCC-STARVATION guard — the deterministic pin for the stale-low-`_HEAD`
    # forward-progress bug the (g) LocalFs soak surfaced (fast, no threads).
    test_stale_low_head_does_not_starve_occ_writer()
    # TORN-`_HEAD` guard — the deterministic pin for the half-written pointer
    # that killed a whole (g) LocalFs soak writer (fast, no threads).
    test_torn_head_pointer_does_not_kill_begin()
    # (d) real-thread OCC write-write.
    test_d_real_thread_occ()
    # (g) soak on SharedInMemory: K>=16, R>=50 (the RFC C5 gate). Now audits the
    # full HOT version-chain (MUST-FIX #3), not just presence.
    _run_soak(16, Int64(50))
    # (g) LocalFs variant (O_EXCL path) — smaller R (disk-bound) but K>=16.
    _run_soak_fs(16, Int64(10))
    print(
        "[OK] test_pgstore_concurrency — (audit-disc) lost-update detector +"
        " (d) real-thread OCC + (g) K=16 soak (SharedInMemory R=50, LocalFs"
        " R=10) — no lost updates / torn state / gaps / SIGSEGV"
    )
