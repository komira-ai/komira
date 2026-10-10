# =============================================================================
# tests/test_cas_manifest_concurrent_offline.mojo
#   OFFLINE K-thread CAS-manifest contention characterization
# =============================================================================
#
# The OFFLINE twin of a live S3-compatible contention run. Drives K = 1, 2, 4, 8, 16 REAL
# concurrent OS-thread writers racing the SAME manifest-append CAS lineage
# through `CasManifestStore[SharedInMemoryConditionalStore]` — the IDENTICAL
# append CAS loop the live S3 path runs, but over a thread-safe in-process
# backend (atomic-spinlock-guarded shared map) so it runs ANYWHERE with no
# object store. This isolates the pure CAS-manifest contention behavior from
# any backend-transport concern, and runs anywhere.
#
# Asserts (the same three properties as the live run, offline):
#   (1) CORRECTNESS — exactly one winner per offset slot; NO GAPS; contiguous
#       ordering. The union of claimed chunk_seqs across all K*M appends is
#       {0 .. K*M-1}, each once; base offsets contiguous.
#   (2) CHARACTERIZE — per-K 412-retry-rate + p50/p99/p999 commit latency +
#       exhausted (re-issued) calls (printed for the record).
#   (3) LIVELOCK BOUND — no append call exceeds max_retries+1 attempts, and
#       the CAS loop is lock-free: an append that exhausts its retries raises
#       the RETRYABLE error the contract names, and a writer that re-issues
#       it (as a caller must) fails no more often than the OTHER writers
#       commit. See "THE LOCK-FREEDOM BOUND" below for why that bound holds at
#       any speed, and why "zero exhausted calls" was not the property.
#       And every retried 412 is followed by exactly one full-jitter backoff:
#       the k-th 412 of a call draws within THIS test's
#       `RetryPolicy.fast_test().backoff_us_for_attempt(k)` and sleeps at
#       least the draw, counted per attempt by the product
#       (`cas_backoff_probe`): full jitter may draw 0, so no time floor can.
#
# This is the offline contention gate. A live S3-compatible stress run
# additionally exercises the real S3 transport; this test guarantees the
# CAS-loop concurrency correctness + livelock bound independent of any backend.
# =============================================================================

from std.ffi import external_call
from std.memory import OwnedPointer, UnsafePointer, alloc
from std.time import perf_counter_ns
from std.testing import assert_equal, assert_true

from komira_collections.slab import Slab

from komira_objectstore.cas_backoff_probe import (
    CAS_BACKOFF_PROBE_MAX_ATTEMPT,
    cas_backoff_counts,
    reset_cas_backoff_counts,
)
from komira_objectstore.cas_manifest import (
    CAS_LIST_ESCALATE_AFTER,
    CasManifestStore,
    RetryPolicy,
    is_retryable_contention,
)
from komira_objectstore.shared_in_memory_conditional_store import (


    SharedInMemoryConditionalStore,
)

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



# =============================================================================
# Per-append record + per-writer results (heap-stable; read after join)
# =============================================================================


@fieldwise_init
struct _AppendRecord(Copyable, Movable, Deinitable):
    var chunk_seq: Int64
    var base_offset: Int64
    var attempts: Int64
    var latency_ns: Int64
    var terminal_fail: Int64


struct _WriterResults(Movable, Deinitable):
    var records: List[_AppendRecord]
    # Calls that raised the retryable "exhausted N retries" error and were
    # re-issued by this writer.
    var exhausted_calls: Int64
    # Calls that raised anything else (the backend has no transport flake, so
    # there must be none).
    var hard_errors: Int64

    def __init__(out self):
        self.records = List[_AppendRecord]()
        self.exhausted_calls = Int64(0)
        self.hard_errors = Int64(0)


# =============================================================================
# THE LOCK-FREEDOM BOUND
# =============================================================================
#
# What "no livelock" means for a CAS loop is that the SYSTEM makes progress: a
# writer loses only because another writer won. It does not mean no writer
# ever runs out of retries: `RetryPolicy` bounds the attempts of one call, and
# `append` then raises a RETRYABLE error by contract (`cas_manifest.mojo`,
# "After `max_retries` 412s, RAISES a retryable error"). How many writers run
# out depends on how long one attempt takes against the backoff window, which
# is wall-clock. Measured on the build farm, the most attempts any call
# needed at K = 8 / K = 16 was 7 / 7 in the release build, and under
# instrumentation, where an attempt is far slower and the `fast_test` window
# (100 us .. 5 ms) no longer spreads the writers out, 7-10 / 13 under -O0 +
# kcov (a call ran out at K = 16 in every kcov run observed) and 13 / 13 in the
# branch-coverage (PGO-instrumented) build, where 14 calls at K = 16 ran out,
# at most 2 of one writer. Asserting "zero exhausted calls" asserted that the
# machine was fast, not that the loop was livelock-free.
#
# The bound that holds at any speed. Within one call, after
# `LIST_ESCALATE_AFTER` (3) consecutive 412s the loop re-anchors on the
# bucket's true tail, and every later attempt targets a slot past it; a 412
# there is a slot some OTHER writer committed after the re-anchor (this one
# committed nothing during the call). A call that exhausts all
# `max_retries + 1` attempts therefore saw at least one commit by another
# writer while it ran, and two calls of one writer never overlap, so they saw
# different commits. Hence, per writer:
#
#     exhausted calls <= commits by the other writers = (K - 1) * M
#
# A loop that livelocks (retries a taken slot without re-anchoring, or gives
# up before spending its budget) fails on and on after the others are done;
# the writer stops re-issuing past the bound, so such a build goes RED here
# rather than hanging.


# =============================================================================
# The pthread arg — the cloned (shared!) store + work spec + results ptr
# =============================================================================


struct _WriterArg(Movable, Deinitable):
    var store: SharedInMemoryConditionalStore
    var prefix: String
    var num_appends: Int64
    var records_per_append: Int64
    # The lock-freedom bound on this writer's exhausted calls: the number of
    # appends the other writers make, (K - 1) * M.
    var exhausted_bound: Int64
    # # SAFETY: address of a heap-stable `_WriterResults` owned by the main
    # thread (kept alive until the join). Plain Int — no wildcard field.
    var results_addr: Int

    def __init__(
        out self,
        var store: SharedInMemoryConditionalStore,
        var prefix: String,
        num_appends: Int64,
        records_per_append: Int64,
        exhausted_bound: Int64,
        results_addr: Int,
    ):
        self.store = store^
        self.prefix = prefix^
        self.num_appends = num_appends
        self.records_per_append = records_per_append
        self.exhausted_bound = exhausted_bound
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
    # SAFETY (FFI-BOUNDARY — sanctioned pthread-launch carve-out): the
    # results address is a main-thread `OwnedPointer[_WriterResults]` pointee,
    # alive until the main thread joins this pthread. DISJOINTNESS: writer `w`
    # touches ONLY its own results slot. No realloc of the slot.
    var results_ptr = UnsafePointer[_WriterResults, MutUntrackedOrigin](
        unsafe_from_address=arg.results_addr
    )
    # The store is a SHARED handle (Arc to one map) — all K writers contend
    # on the same manifest. Build a CasManifestStore over this writer's
    # handle.
    var manifest = CasManifestStore[SharedInMemoryConditionalStore](
        store=arg.store.clone(),
        prefix=arg.prefix.copy(),
        retry=RetryPolicy.fast_test(),
    )
    var i = Int64(0)
    while i < arg.num_appends:
        var body = _body(Int(i), 16)
        var t0 = Int64(perf_counter_ns())
        var failed = Int64(0)
        var seq = Int64(-1)
        var base = Int64(-1)
        var attempts = Int64(0)
        # Re-issue a call that ran out of retries, as the contract tells a
        # caller to, up to the lock-freedom bound (see above); past it, this
        # append is recorded as a terminal fail.
        while True:
            try:
                var res = manifest.append(body, arg.records_per_append)
                seq = res.chunk_seq
                base = res.base_offset
                attempts = Int64(res.attempts)
                break
            except e:
                if is_retryable_contention(String(e)):
                    results_ptr[].exhausted_calls += Int64(1)
                    if results_ptr[].exhausted_calls <= arg.exhausted_bound:
                        continue
                else:
                    results_ptr[].hard_errors += Int64(1)
                failed = Int64(1)
                break
        var t1 = Int64(perf_counter_ns())
        results_ptr[].records.append(
            _AppendRecord(seq, base, attempts, t1 - t0, failed)
        )
        i += Int64(1)


def _body(tag: Int, n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(UInt8((i + tag) & 0xFF))
    return out^


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
# Percentile helpers
# =============================================================================


def _sort_i64(mut xs: List[Int64]):
    var n = len(xs)
    var i = 1
    while i < n:
        var key = xs[i]
        var j = i - 1
        while j >= 0 and xs[j] > key:
            xs[j + 1] = xs[j]
            j -= 1
        xs[j + 1] = key
        i += 1


def _percentile(sorted_xs: List[Int64], p: Float64) -> Int64:
    var n = len(sorted_xs)
    if n == 0:
        return Int64(0)
    var idx = Int(p * Float64(n - 1) + 0.5)
    if idx < 0:
        idx = 0
    if idx >= n:
        idx = n - 1
    return sorted_xs[idx]


# =============================================================================
# One K-fan-out run + assertions
# =============================================================================


def _run_k_writers(
    k: Int, appends_per_writer: Int64, records_per_append: Int64
) raises:
    print(
        "[C-4 offline] K=" + String(k) + " writers x "
        + String(Int(appends_per_writer)) + " appends"
    )

    # ONE shared store; every writer gets a clone() that SHARES the map.
    var shared = SharedInMemoryConditionalStore()
    var prefix = String("offline/k") + String(k)
    reset_cas_backoff_counts()

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
            num_appends=appends_per_writer,
            records_per_append=records_per_append,
            exhausted_bound=Int64(k - 1) * appends_per_writer,
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

    # ---- aggregate ----
    var all_seqs = List[Int64]()
    var all_bases = List[Int64]()
    var latencies = List[Int64]()
    var total_attempts = Int64(0)
    var total_commits = Int64(0)
    var terminal_fails = Int64(0)
    var max_attempts_seen = Int64(0)
    var exhausted_calls = Int64(0)
    var retried_412s = Int64(0)
    # expected_at[k - 1]: retried k-th 412s, i.e. calls that made more than k
    # attempts (an exhausted call's last 412 raises instead of backing off).
    var expected_at = List[Int](length=CAS_BACKOFF_PROBE_MAX_ATTEMPT, fill=0)
    var max_exhausted_one_writer = Int64(0)
    var hard_errors = Int64(0)

    for wi in range(k):
        exhausted_calls += results[wi][].exhausted_calls
        hard_errors += results[wi][].hard_errors
        if results[wi][].exhausted_calls > max_exhausted_one_writer:
            max_exhausted_one_writer = results[wi][].exhausted_calls
        ref recs = results[wi][].records
        for ri in range(len(recs)):
            ref r = recs[ri]
            if r.terminal_fail == Int64(1):
                terminal_fails += Int64(1)
                continue
            total_commits += Int64(1)
            total_attempts += r.attempts
            retried_412s += r.attempts - Int64(1)
            for a in range(1, Int(r.attempts)):
                expected_at[min(a, CAS_BACKOFF_PROBE_MAX_ATTEMPT) - 1] += 1
            if r.attempts > max_attempts_seen:
                max_attempts_seen = r.attempts
            all_seqs.append(r.chunk_seq)
            all_bases.append(r.base_offset)
            latencies.append(r.latency_ns)
    # An exhausted call retried `max_retries` 412s (its last one raised).
    retried_412s += exhausted_calls * Int64(RetryPolicy.fast_test().max_retries)
    for a in range(1, RetryPolicy.fast_test().max_retries + 1):
        expected_at[min(a, CAS_BACKOFF_PROBE_MAX_ATTEMPT) - 1] += Int(exhausted_calls)

    # ---- (1) no-gap, one-winner-per-slot, contiguous ----
    var expected = Int64(k) * appends_per_writer
    var exhausted_bound = Int64(k - 1) * appends_per_writer
    var policy = RetryPolicy.fast_test()
    # The bound's argument needs an exhausted call to make at least one
    # attempt past its first re-anchor (see THE LOCK-FREEDOM BOUND).
    assert_true(
        policy.max_retries + 1 > CAS_LIST_ESCALATE_AFTER + 1,
        "the retry budget must outlast the LIST escalation, or the"
        " lock-freedom bound below does not follow",
    )
    assert_equal(
        hard_errors,
        Int64(0),
        "offline backend has no transport flake — no append raised anything"
        " but the retryable exhausted-retries error",
    )
    assert_true(
        max_exhausted_one_writer <= exhausted_bound,
        "lock-freedom bound: a writer ran out of retries "
        + String(Int(max_exhausted_one_writer))
        + " times, more than the "
        + String(Int(exhausted_bound))
        + " appends the other writers made — a call that exhausts its budget"
        " must have lost to a commit made while it ran (livelock)",
    )
    assert_equal(
        terminal_fails,
        Int64(0),
        "every append commits once re-issued within the lock-freedom bound",
    )
    assert_equal(
        total_commits, expected, "every append commits (K*M)"
    )

    var seqs_sorted = all_seqs.copy()
    _sort_i64(seqs_sorted)
    var no_gap = True
    var one_winner = True
    for idx in range(len(seqs_sorted)):
        if seqs_sorted[idx] != Int64(idx):
            no_gap = False
        if idx > 0 and seqs_sorted[idx] == seqs_sorted[idx - 1]:
            one_winner = False
    assert_true(one_winner, "exactly one winner per chunk slot (no dup)")
    assert_true(no_gap, "chunk seqs are gapless {0..N-1} (no gap)")

    var bases_sorted = all_bases.copy()
    _sort_i64(bases_sorted)
    var contiguous = True
    for idx in range(len(bases_sorted)):
        if bases_sorted[idx] != Int64(idx) * records_per_append:
            contiguous = False
    assert_true(contiguous, "base offsets contiguous (no overlap/hole)")

    # ---- (2) characterize ----
    _sort_i64(latencies)
    var p50 = _percentile(latencies, 0.50)
    var p99 = _percentile(latencies, 0.99)
    var p999 = _percentile(latencies, 0.999)
    var extra = total_attempts - total_commits
    var retry_rate_milli = Int64(0)
    if total_commits > Int64(0):
        retry_rate_milli = (extra * Int64(1000)) / total_commits
    print(
        "      commits="
        + String(Int(total_commits))
        + " 412-retry-rate="
        + String(Int(retry_rate_milli))
        + "/1000  max_attempts="
        + String(Int(max_attempts_seen))
        + "  exhausted-calls="
        + String(Int(exhausted_calls))
        + " (max one writer "
        + String(Int(max_exhausted_one_writer))
        + ", bound "
        + String(Int(exhausted_bound))
        + ")  backoff-draws="
        + String(Int(retried_412s))
        + "  terminal-fails="
        + String(Int(terminal_fails))
    )
    print(
        "      commit-latency  p50="
        + String(Int(p50 / 1000))
        + "us  p99="
        + String(Int(p99 / 1000))
        + "us  p999="
        + String(Int(p999 / 1000))
        + "us"
    )

    # ---- (3) livelock bound ----
    # BACKOFF. Every retried 412 is followed by one full-jitter backoff: a
    # committed call that took `a` attempts retried its 412s 1 .. a - 1, an
    # exhausted call 1 .. max_retries (its last 412 raises instead). The
    # product counts each backoff by attempt (cas_backoff_probe), because full
    # jitter may draw 0 and no wall-clock floor can see a missing sleep; the
    # bound is computed HERE, from this test's own policy, so a call site that
    # passes a looser bound than the policy's is caught too. Without backoff
    # the writers re-collide in lockstep.
    var backoff = cas_backoff_counts()
    assert_equal(
        Int64(backoff.draws()),
        retried_412s,
        "each retried 412 must be followed by exactly one backoff draw",
    )
    for a in range(1, CAS_BACKOFF_PROBE_MAX_ATTEMPT + 1):
        assert_equal(
            backoff.draws_at[a - 1],
            expected_at[a - 1],
            "backoffs after the " + String(a) + "-th 412 of a call",
        )
        assert_equal(
            backoff.upper_sum_at[a - 1],
            expected_at[a - 1] * Int(policy.backoff_us_for_attempt(a)),
            "the backoff bound after the "
            + String(a)
            + "-th 412 is not RetryPolicy.backoff_us_for_attempt("
            + String(a)
            + ") = "
            + String(Int(policy.backoff_us_for_attempt(a)))
            + " us",
        )
    assert_equal(
        backoff.draws_over_upper,
        0,
        "a backoff draw exceeded the bound it was drawn under",
    )
    assert_true(
        backoff.slept_us >= backoff.drawn_us,
        "the backoffs slept "
        + String(backoff.slept_us)
        + " us in all, less than the "
        + String(backoff.drawn_us)
        + " us drawn: a draw was not slept",
    )
    assert_true(
        max_attempts_seen <= Int64(policy.max_retries + 1),
        "no writer exceeded max_retries+1 (livelock bound held)",
    )

    _ = results^
    _ = tids^
    _ = shared^


def main() raises:
    print(
        "[C-4 offline] manifest-append CAS under K=1,2,4,8,16 concurrent"
        " OS-thread writers (in-process, no MinIO)"
    )
    var appends_per_writer = Int64(8)
    var records_per_append = Int64(1)

    var ks = List[Int]()
    ks.append(1)
    ks.append(2)
    ks.append(4)
    ks.append(8)
    ks.append(16)
    for i in range(len(ks)):
        _run_k_writers(ks[i], appends_per_writer, records_per_append)

    print(
        "[OK] test_cas_manifest_concurrent_offline — no-gap linearizable"
        " append + livelock bound held across K=1,2,4,8,16 (offline,"
        " thread-safe shared backend)"
    )
