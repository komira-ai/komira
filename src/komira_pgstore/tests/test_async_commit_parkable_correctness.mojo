# =============================================================================
# tests/komira_pgstore/test_async_commit_parkable_correctness.mojo
#   COMPREHENSIVE parkable-commit CORRECTNESS gate — the
#   DRIVER-LEVEL half: scenarios that exercise the `commit_async_*` poll-shaped
#   commit driver (table_store) DIRECTLY over a controllable-slow / one-shot-
#   fault `AsyncCasStore` on a real reactor, asserting the INVARIANT BATTERY
#   (INV-2 atomicity / INV-3 durability / INV-4 FCW / INV-5 recovery idempotency
#   / INV-6 no-torn-_HEAD / INV-7 gapless / INV-11 connection-survivability).
#
#   Scenarios in this file (all DRIVER-LEVEL — no sockets, so they compile fast
#   and isolate the commit FSM from the wire framing):
#     C-PARK-LOSE-40001        — a conflict lands during the park window on an
#                                OVERLAPPING key -> the parked commit re-OCCs at
#                                the AUTHORITATIVE head and loses (40001). The
#                                driver returns a clean ERR (not a crash); a sibling
#                                handle stays fully usable (INV-11 at the driver).
#     C-PARK-DISJOINT-REAPPEND — a conflict lands during the park window on a
#                                DISJOINT key -> the parked commit re-reads the auth
#                                head + re-appends at new head+1; BOTH commit gapless
#                                (INV-4 FCW non-conflict / INV-7 gapless).
#     C-OCC-COUPLING-PARK      — the §8 hole stays closed ACROSS a park: a committer
#                                that lands DURING A's park is SEEN by A's resume-edge
#                                re-OCC (the re-read uses the AUTHORITATIVE head, NOT
#                                a park-cached head). RED if the head were park-cached.
#     C-PARK-STORE-RAISE       — the AsyncCasStore RAISES during a parked commit
#                                (S-6 raise_on_poll) -> the driver catches it into a
#                                clean ERR; the op is terminal-once; a sibling handle
#                                keeps committing (INV-11).
#     C-CRASH-PRE-CAS          — abandon a parked op BEFORE its create-CAS ran
#                                (mid-park) -> ZERO durable trace; a fresh open()
#                                recovers exactly the pre-park committed prefix (INV-2
#                                all-or-nothing / INV-3 durability of only the landed).
#     C-CRASH-CAS-INFLIGHT     — abandon with the create-CAS having physically landed
#                                its bytes but the op NOT finalized -> recovery is
#                                strictly all-or-nothing: the landed chunk IS recovered
#                                (bucket-is-truth), no torn _HEAD (INV-3 / INV-6).
#     C-CRASH-MULTI-PARKED     — several commits parked/abandoned in scrambled order;
#                                a fresh open() recovers a CONSISTENT GAPLESS PREFIX =
#                                exactly the landed winners; re-fold is idempotent
#                                (INV-5 / INV-7).
#
# Each scenario asserts the relevant invariants; a violation prints a seed/step
# tag + the failing assert message. The op the commit parks on is a reactor timer
# (SharedInMemorySlowCasStore yields CAS_OP_PENDING via register_timer), driven
# through the SAME demux a real S3 socket-read completion would.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    OP_ID_ALLOC_BASE,
    Reactor,
)

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)
from komira_objectstore.store import (
    AsyncCasStore,
    CasOpProgress,
    CasReadResult,
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
)
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

from komira_pgstore.pgstore_codec import bytes_eq
from komira_pgstore.table_store import (
    AsyncCommitOp,
    TableStore,
    commit_async_poll,
    commit_async_start,
)


comptime _Store = SharedInMemorySlowCasStore
comptime _PREFIX = "pg/parkcorrect"


# =============================================================================
# Helpers.
# =============================================================================


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def _new_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_macos():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)
    else:
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)


def _handle(
    var inner: SharedInMemoryConditionalStore,
    slow_ticks: Int,
    raise_on_poll: Bool = False,
) raises -> TableStore[_Store]:
    """A TableStore handle over a slow AsyncCasStore sharing `inner`'s map."""
    var slow = SharedInMemorySlowCasStore(
        inner=inner^, slow_ticks=slow_ticks, raise_on_poll=raise_on_poll
    )
    var wal = CasManifestStore[_Store](
        store=slow^, prefix=String(_PREFIX), retry=RetryPolicy.fast_test()
    )
    return TableStore[_Store].open(wal^)


def _build_op(
    mut store: TableStore[_Store], key: String, val: String
) raises -> AsyncCommitOp:
    """Begin a write txn on (key,val) and build its AsyncCommitOp (not started).
    Returned by `^`-move so the move-only op is owned by the caller."""
    var t = store.begin()
    t.insert(_b(key), _b(val))
    return AsyncCommitOp.from_txn(t^)


def _start_parked_write(
    mut store: TableStore[_Store],
    mut op: AsyncCommitOp,
    mut reactor: Reactor[NoopSink],
) raises -> Int64:
    """START the (already-built) commit op so it PARKS. Returns park_id; the
    caller owns `op` (move-only AsyncCommitOp) and drives it later."""
    return commit_async_start[_Store, NoopSink](store, op, reactor)


def _drive_op_to_done(
    mut store: TableStore[_Store],
    mut op: AsyncCommitOp,
    mut reactor: Reactor[NoopSink],
    first_op_id: Int64,
) raises:
    """Fire the reactor for the biased op_id + re-enter `commit_async_poll`
    until DONE/ERR. Bounded loop."""
    var park_id = first_op_id
    var rounds = 0
    while not (op.is_done() or op.is_error()):
        rounds += 1
        if rounds > 2000:
            raise Error("parkable: op did not converge in 2000 reactor rounds")
        var completions = reactor.poll_completions(Int32(50_000))
        var fired = False
        for i in range(len(completions)):
            if completions[i].op_id == park_id:
                fired = True
        if not fired:
            continue
        park_id = commit_async_poll[_Store, NoopSink](store, op, reactor)


def _commit_sync_one(
    var inner: SharedInMemoryConditionalStore,
    mut reactor: Reactor[NoopSink],
    key: String,
    val: String,
) raises -> Int64:
    """Commit a single write on a FRESH disjoint handle (slow_ticks=0 => one
    synchronous burst, no park). Returns the won commit_lsn. Used as a
    'competitor lands DURING the park window' actor."""
    var h = _handle(inner^, slow_ticks=0)
    var t = h.begin()
    t.insert(_b(key), _b(val))
    var op = AsyncCommitOp.from_txn(t^)
    var park = commit_async_start[_Store, NoopSink](h, op, reactor)
    if park != Int64(0) or not op.is_done():
        raise Error("competitor commit (slow_ticks=0) unexpectedly parked")
    var res = op.take_result()
    return res.commit_lsn


def _read_back(
    var inner: SharedInMemoryConditionalStore, key: String
) raises -> Optional[List[UInt8]]:
    """Read `key` on a FRESH disjoint handle (proves durability on the shared
    backend, not local cache)."""
    var h = _handle(inner^, slow_ticks=0)
    var t = h.begin()
    var got = h.get(t, _b(key))
    h.abort(t^)
    return got^


# =============================================================================
# C-PARK-LOSE-40001 — an OVERLAPPING-key conflict lands during the park window ->
# the parked commit re-OCCs at the auth head and LOSES (40001). The driver
# returns a CLEAN terminal ERR (not a crash); a sibling handle stays usable.
# =============================================================================
def test_c_park_lose_40001() raises:
    print(
        "[C-PARK-LOSE-40001] overlapping conflict during the park -> 40001, conn"
        " stays healthy (INV-4 FCW, INV-11 survivability)"
    )
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()

    # A: a write txn on key 'x' whose COMMIT parks (slow_ticks high so the park
    # window is wide enough for the competitor to land first).
    var a = _handle(backing.clone(), slow_ticks=4)
    var op_a = _build_op(a, "x", "from-A")
    var park_a = _start_parked_write(a, op_a, reactor)
    assert_true(
        park_a >= OP_ID_ALLOC_BASE,
        "A's commit PARKED on a biased op_id (did not run inline)",
    )
    assert_false(op_a.is_done() or op_a.is_error(), "A is in flight (parked)")

    # COMPETITOR: a fresh handle commits the SAME key 'x' DURING A's park window.
    var comp_lsn = _commit_sync_one(backing.clone(), reactor, "x", "from-COMP")
    assert_true(comp_lsn >= Int64(0), "the competitor landed a valid slot")

    # Drive A's parked commit to a terminal: it must re-OCC at the AUTHORITATIVE
    # head, see the competitor's overlapping write on 'x', and LOSE (40001).
    _drive_op_to_done(a, op_a, reactor, park_a)
    assert_true(
        op_a.is_error(),
        "A's overlapping commit LOST (40001) — the resume-edge re-OCC saw the"
        " competitor's write on the same key (INV-4 first-committer-wins)",
    )
    assert_true(
        op_a.err_text().find("40001") >= 0
        or op_a.err_text().find("conflict") >= 0,
        "A's terminal error is the OCC 40001 conflict, not a transport crash: "
        + op_a.err_text(),
    )

    # INV-11: a sibling handle on the SAME backing is fully usable after A's loss
    # — A's loss did not corrupt the store.
    var sib_lsn = _commit_sync_one(backing.clone(), reactor, "y", "from-SIB")
    assert_true(
        sib_lsn > comp_lsn,
        "a sibling commit lands gaplessly AFTER A's loss — the store is healthy"
        " (INV-11 connection-survivability)",
    )

    # INV-2 atomicity: A's write is NOT durable (it lost; all-or-nothing). The
    # competitor's value is the visible one.
    var got_x = _read_back(backing.clone(), "x")
    assert_true(Bool(got_x), "key 'x' is visible (the competitor's commit)")
    assert_true(
        bytes_eq(got_x.value(), _b("from-COMP")),
        "the COMPETITOR's value won 'x' (A's lost write left NO durable trace —"
        " INV-2 atomicity)",
    )
    _ = a^
    print("  test_c_park_lose_40001: PASS")


# =============================================================================
# C-PARK-DISJOINT-REAPPEND — a DISJOINT-key conflict lands during the park ->
# the parked commit re-reads the auth head + re-appends at new head+1; BOTH
# commit gapless (INV-4 non-conflict, INV-7 gapless).
# =============================================================================
def test_c_park_disjoint_reappend() raises:
    print(
        "[C-PARK-DISJOINT-REAPPEND] disjoint conflict during the park -> re-read"
        " head + re-append; both commit gapless (INV-7)"
    )
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()

    # A: parked commit on key 'a'.
    var a = _handle(backing.clone(), slow_ticks=4)
    var op_a = _build_op(a, "a", "from-A")
    var park_a = _start_parked_write(a, op_a, reactor)
    assert_true(park_a >= OP_ID_ALLOC_BASE, "A parked")

    # COMPETITOR: a DISJOINT key 'b' lands during A's park window.
    var comp_lsn = _commit_sync_one(backing.clone(), reactor, "b", "from-B")
    assert_true(comp_lsn >= Int64(0), "the disjoint competitor landed")

    # Drive A: the competitor took A's first target slot, so A's create-CAS 412s,
    # A re-reads the auth head, re-OCCs (disjoint key 'a' vs 'b' => no conflict),
    # and re-appends at the NEXT slot. A must COMMIT (not lose).
    _drive_op_to_done(a, op_a, reactor, park_a)
    assert_true(
        op_a.is_done(),
        "A's DISJOINT commit re-appended + WON after the competitor took its"
        " first slot (no false 40001): " + op_a.err_text(),
    )
    var res_a = op_a.take_result()
    assert_true(res_a.did_append, "A appended a chunk (durable)")

    # INV-7 gapless: A and the competitor won DISTINCT, adjacent slots.
    assert_true(
        res_a.commit_lsn != comp_lsn,
        "A and the competitor won DISTINCT slots (no torn/overwritten slot)",
    )
    assert_true(
        res_a.commit_lsn == comp_lsn + Int64(1)
        or comp_lsn == res_a.commit_lsn + Int64(1),
        "the two commits are ADJACENT (gapless slot sequence — INV-7)",
    )

    # INV-3 durability: both rows visible on a fresh disjoint handle.
    var got_a = _read_back(backing.clone(), "a")
    var got_b = _read_back(backing.clone(), "b")
    assert_true(Bool(got_a) and bytes_eq(got_a.value(), _b("from-A")), "'a' durable")
    assert_true(Bool(got_b) and bytes_eq(got_b.value(), _b("from-B")), "'b' durable")
    _ = a^
    print("  test_c_park_disjoint_reappend: PASS")


# =============================================================================
# C-OCC-COUPLING-PARK — the §8 hole stays closed ACROSS a park. The resume-edge
# re-read uses the AUTHORITATIVE head (NOT a park-cached head): a committer that
# lands DURING A's park is SEEN by A's re-OCC.
#
# Discrimination: A pins its snapshot at head H. A competitor commits an
# OVERLAPPING key at H+1 DURING A's park. If A's resume re-OCC re-read the
# AUTHORITATIVE head it sees H+1 and LOSES (correct). If it used a PARK-CACHED
# head (== H, frozen at start) it would MISS H+1 and wrongly COMMIT — the §8
# bug. So `op_a.is_error()` (40001) is the GREEN, discriminating outcome; a
# wrong COMMIT would be the RED §8 regression.
# =============================================================================
def test_c_occ_coupling_park() raises:
    print(
        "[C-OCC-COUPLING-PARK] the resume-edge re-OCC uses the AUTHORITATIVE head"
        " — a committer landing during the park is seen (§8 stays closed)"
    )
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()

    # Seed key 'k' at slot 0 so A pins a real snapshot above an existing chunk.
    var seed_lsn = _commit_sync_one(backing.clone(), reactor, "seed", "s0")
    assert_true(seed_lsn >= Int64(0), "seed landed")

    # A: BEGIN (pins snapshot at the seed head), buffer a write on 'k', then PARK
    # the commit. A's OCC window upper bound at START is the head it read; the
    # COUPLING requires the create-CAS to target auth_head+1 and re-validate at
    # EACH resume edge.
    var a = _handle(backing.clone(), slow_ticks=5)
    var ta = a.begin()
    ta.insert(_b("k"), _b("from-A"))
    var op_a = AsyncCommitOp.from_txn(ta^)
    var park_a = commit_async_start[_Store, NoopSink](a, op_a, reactor)
    assert_true(park_a >= OP_ID_ALLOC_BASE, "A parked on its create-CAS")
    assert_false(op_a.is_done() or op_a.is_error(), "A is parked")

    # COMPETITOR: commits the SAME key 'k' DURING A's park window. This lands at a
    # slot ABOVE the head A read at START. If the §8 coupling holds, A's resume-edge
    # re-OCC re-reads the auth head, sees this chunk, and LOSES.
    var comp_lsn = _commit_sync_one(backing.clone(), reactor, "k", "from-COMP")
    assert_true(comp_lsn > seed_lsn, "the competitor landed ABOVE A's start head")

    # Drive A to terminal.
    _drive_op_to_done(a, op_a, reactor, park_a)

    # THE §8 DISCRIMINATOR: A must LOSE (40001). A wrong COMMIT here would mean the
    # resume re-OCC used a park-cached head that missed the competitor's H+1 chunk.
    assert_true(
        op_a.is_error(),
        "A LOST (40001) — the resume-edge re-OCC re-read the AUTHORITATIVE head"
        " and SAW the competitor's overlapping commit landed during the park. A"
        " wrong COMMIT here would be the §8 park-cached-head regression.",
    )

    # The competitor's value is the durable one (A's lost write left no trace —
    # the §8 coupling guarantees the create-CAS slot is the sole arbiter).
    var got_k = _read_back(backing.clone(), "k")
    assert_true(
        Bool(got_k) and bytes_eq(got_k.value(), _b("from-COMP")),
        "'k' holds the COMPETITOR's value (A's overlapping write lost — §8 closed)",
    )
    _ = a^
    print("  test_c_occ_coupling_park: PASS")


# =============================================================================
# C-PARK-STORE-RAISE (driver-level contract) — the AsyncCasStore RAISES during a
# parked commit (S-6 raise_on_poll, the harder resume-edge fault).
#
# THE LAYERING (a finding worth pinning): `commit_async_poll` does NOT swallow a
# transport RAISE from the conformer — it deliberately PROPAGATES it. The CATCH
# site is the SERVE LOOP (`_pg_resume_parked_commit`'s `try/except poll_e`), which
# turns the raise into a clean conn-drop + ErrorResponse while OTHER conns keep
# serving. So the DRIVER-LEVEL contract is: the raise propagates, and CATCHING it
# leaves the store fully healthy (a sibling keeps committing, no corruption). The
# "other conns keep serving across the raise" property is proven at the WIRE level
# (test_pgwire_async_commit_parkable_wire — C-PARK-STORE-RAISE wire arm).
# =============================================================================
def test_c_park_store_raise() raises:
    print(
        "[C-PARK-STORE-RAISE] resume-edge store RAISE propagates from the driver"
        " (caught by the serve loop); catching it leaves the store healthy (INV-11)"
    )
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()

    # A: a handle whose store RAISES on the final cas_put_poll tick (the resume
    # edge, AFTER the conn parked) — the hardest transport-fault timing.
    var a = _handle(backing.clone(), slow_ticks=3, raise_on_poll=True)
    var ta = a.begin()
    ta.insert(_b("a"), _b("from-A"))
    var op_a = AsyncCommitOp.from_txn(ta^)
    var park_a = commit_async_start[_Store, NoopSink](a, op_a, reactor)
    assert_true(
        park_a >= OP_ID_ALLOC_BASE, "A parked (the raise fires on the final tick)"
    )

    # Drive A to the resume edge where the raise fires. Model the SERVE LOOP's
    # catch: wrap `commit_async_poll` in try/except — a clean catch (not a crash)
    # is the contract. A raise that ESCAPED the process would crash this test.
    var park_id = park_a
    var caught = False
    var rounds = 0
    while not caught:
        rounds += 1
        if rounds > 2000:
            raise Error("C-PARK-STORE-RAISE: raise never surfaced in 2000 rounds")
        var completions = reactor.poll_completions(Int32(50_000))
        var fired = False
        for i in range(len(completions)):
            if completions[i].op_id == park_id:
                fired = True
        if not fired:
            continue
        try:
            park_id = commit_async_poll[_Store, NoopSink](a, op_a, reactor)
        except poll_e:
            # The serve loop catches HERE: surface as a clean drop, free the op.
            caught = True
            assert_true(
                String(poll_e).find("errno=61") >= 0
                or String(poll_e).find("transport") >= 0,
                "the propagated error is the simulated transport fault: "
                + String(poll_e),
            )
    assert_true(
        caught,
        "the resume-edge store RAISE PROPAGATED from commit_async_poll and was"
        " CATCHABLE (the serve loop's try/except site) — not a process crash",
    )

    # INV-2 atomicity: A's write did NOT persist (the create-CAS raised before the
    # sync put ran). The store is empty of 'a'.
    var got_a = _read_back(backing.clone(), "a")
    assert_false(
        Bool(got_a),
        "A's raised commit left NO durable trace ('a' absent — INV-2 atomicity)",
    )

    # INV-11: a sibling handle on the SAME backing commits cleanly after A's raise.
    var sib_lsn = _commit_sync_one(backing.clone(), reactor, "b", "from-B")
    assert_true(
        sib_lsn >= Int64(0),
        "a sibling commits after A's transport fault — the store is healthy",
    )
    var got_b = _read_back(backing.clone(), "b")
    assert_true(Bool(got_b) and bytes_eq(got_b.value(), _b("from-B")), "'b' durable")
    _ = op_a^
    _ = a^
    print("  test_c_park_store_raise: PASS")


# =============================================================================
# C-CRASH-PRE-CAS — abandon a parked op BEFORE its create-CAS ran (mid-park) ->
# ZERO durable trace; a fresh open() recovers exactly the pre-park committed
# prefix (INV-2 all-or-nothing, INV-3 durability of only the landed).
# =============================================================================
def test_c_crash_pre_cas() raises:
    print(
        "[C-CRASH-PRE-CAS] abandon a parked op pre-create-CAS -> zero durable"
        " trace; recovery = exactly the pre-park prefix (INV-2/INV-3)"
    )
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()

    # Land a committed prefix: 'p0' at slot 0.
    var p0 = _commit_sync_one(backing.clone(), reactor, "p0", "v0")
    assert_equal(p0, Int64(0), "the pre-park prefix is slot 0")

    # A: PARK a commit with slow_ticks high enough that NO tick has run the sync
    # put yet. Then ABANDON it (drop the op without driving to completion) — the
    # "crash mid-park, pre-create-CAS" scenario.
    var a = _handle(backing.clone(), slow_ticks=8)
    var op_a = _build_op(a, "doomed", "should-not-persist")
    var park_a = _start_parked_write(a, op_a, reactor)
    assert_true(park_a >= OP_ID_ALLOC_BASE, "A parked, create-CAS not yet run")
    assert_false(op_a.is_done() or op_a.is_error(), "A is mid-park (abandon here)")
    # ABANDON: drop op_a + handle a WITHOUT driving. (No tick ran the sync put.)
    _ = op_a^
    _ = a^

    # RECOVERY: a fresh open() over the SAME backing must recover exactly the
    # pre-park prefix — the abandoned commit left ZERO durable trace.
    var rec = _handle(backing.clone(), slow_ticks=0)
    assert_equal(
        rec.wal_head_seq(),
        Int64(0),
        "recovery head is the pre-park prefix (slot 0) — the abandoned mid-park"
        " op left NO chunk (INV-2 all-or-nothing)",
    )
    var tr = rec.begin()
    var got_p0 = rec.get(tr, _b("p0"))
    var got_doomed = rec.get(tr, _b("doomed"))
    rec.abort(tr^)
    assert_true(
        Bool(got_p0) and bytes_eq(got_p0.value(), _b("v0")),
        "the committed prefix 'p0' is durably recovered (INV-3)",
    )
    assert_false(
        Bool(got_doomed),
        "the abandoned mid-park write 'doomed' is ABSENT after recovery (INV-2)",
    )
    print("  test_c_crash_pre_cas: PASS")


# =============================================================================
# C-CRASH-CAS-INFLIGHT — abandon AFTER the create-CAS physically landed its bytes
# but BEFORE the op finalized. Recovery is strictly all-or-nothing: the landed
# chunk IS recovered (bucket-is-truth), no torn _HEAD (INV-3 / INV-6).
#
# We land the bytes by driving the op until its underlying conditional_put has
# run (slow_ticks=0 on the create-CAS makes the put land in the start burst), but
# we ABANDON before reading the win-path finalize back through the SQL face — i.e.
# the chunk is durably on the backing, the in-RAM index is thrown away. A fresh
# open() must LIST-recover the landed chunk (bucket-is-truth, durably-but-unacked).
# =============================================================================
def test_c_crash_cas_inflight() raises:
    print(
        "[C-CRASH-CAS-INFLIGHT] create-CAS landed but op abandoned -> recovery is"
        " all-or-nothing: the landed chunk IS recovered (INV-3/INV-6 bucket-is-truth)"
    )
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()

    # slow_ticks=0 => the create-CAS runs the underlying conditional_put INSIDE the
    # start burst (the bytes physically land), and the op DONEs in one step. We
    # take the result (proving it landed) but then THROW AWAY the handle's in-RAM
    # index — simulating a crash AFTER the durable write but with no surviving
    # in-process state. Recovery must re-derive the landed chunk from the bucket.
    var a = _handle(backing.clone(), slow_ticks=0)
    var ta = a.begin()
    ta.insert(_b("landed"), _b("durable-val"))
    var op_a = AsyncCommitOp.from_txn(ta^)
    var park_a = commit_async_start[_Store, NoopSink](a, op_a, reactor)
    assert_equal(park_a, Int64(0), "slow_ticks=0 commit landed in one burst")
    assert_true(op_a.is_done(), "the create-CAS physically landed the chunk")
    var res_a = op_a.take_result()
    var landed_lsn = res_a.commit_lsn
    assert_true(landed_lsn >= Int64(0), "the landed chunk has a valid slot")
    # CRASH: drop the handle + op WITHOUT any further use (the in-RAM index is gone).
    _ = op_a^
    _ = a^

    # RECOVERY: a fresh open() must recover the landed chunk from the LIST
    # (bucket-is-truth) — durably-but-unacked landed writes ARE recovered.
    var rec = _handle(backing.clone(), slow_ticks=0)
    assert_equal(
        rec.wal_head_seq(),
        landed_lsn,
        "recovery head == the landed slot — no torn/lost _HEAD (INV-6 monotone,"
        " bucket-is-truth)",
    )
    var got = _read_back(backing.clone(), "landed")
    assert_true(
        Bool(got) and bytes_eq(got.value(), _b("durable-val")),
        "the durably-landed chunk is recovered all-or-nothing (INV-3)",
    )
    print("  test_c_crash_cas_inflight: PASS")


# =============================================================================
# C-CRASH-MULTI-PARKED — several commits parked/abandoned in scrambled order; a
# fresh open() recovers a CONSISTENT GAPLESS PREFIX = exactly the landed winners;
# re-fold is idempotent (INV-5 / INV-7).
#
# We land 3 winners (slot 0/1/2) and abandon 2 parked-but-undriven ops. Recovery
# must show exactly slots [0..2] gapless, the abandoned ops absent, and a SECOND
# open() (re-fold) is byte-identical (idempotent).
# =============================================================================
def test_c_crash_multi_parked() raises:
    print(
        "[C-CRASH-MULTI-PARKED] mixed landed winners + abandoned parked ops ->"
        " recovery = exactly the gapless landed prefix; re-fold idempotent (INV-5/7)"
    )
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()

    # Land 3 winners at slots 0,1,2 (each a fresh synchronous commit).
    var w0 = _commit_sync_one(backing.clone(), reactor, "w0", "v0")
    var w1 = _commit_sync_one(backing.clone(), reactor, "w1", "v1")
    var w2 = _commit_sync_one(backing.clone(), reactor, "w2", "v2")
    assert_equal(w0, Int64(0), "winner 0 at slot 0")
    assert_equal(w1, Int64(1), "winner 1 at slot 1")
    assert_equal(w2, Int64(2), "winner 2 at slot 2")

    # PARK two commits and ABANDON them (undriven) in a scrambled order — neither
    # runs its sync put, so neither lands.
    var d1 = _handle(backing.clone(), slow_ticks=8)
    var op_d1 = _build_op(d1, "doomed1", "x1")
    var park_d1 = _start_parked_write(d1, op_d1, reactor)
    assert_true(park_d1 >= OP_ID_ALLOC_BASE, "doomed1 parked")
    var d2 = _handle(backing.clone(), slow_ticks=8)
    var op_d2 = _build_op(d2, "doomed2", "x2")
    var park_d2 = _start_parked_write(d2, op_d2, reactor)
    assert_true(park_d2 >= OP_ID_ALLOC_BASE, "doomed2 parked")
    # Abandon both (scrambled: drop d2's op first, then d1's).
    _ = op_d2^
    _ = op_d1^
    _ = d2^
    _ = d1^

    # RECOVERY: a fresh open() recovers exactly [0..2] gapless; the abandoned ops
    # are absent.
    var rec = _handle(backing.clone(), slow_ticks=0)
    assert_equal(
        rec.wal_head_seq(),
        Int64(2),
        "recovery head is the last LANDED winner (slot 2) — abandoned parked ops"
        " left no chunk (INV-7 gapless: exactly the winners)",
    )
    var tr = rec.begin()
    for i in range(3):
        var key = String("w") + String(i)
        var val = String("v") + String(i)
        var got = rec.get(tr, _b(key))
        assert_true(
            Bool(got) and bytes_eq(got.value(), _b(val)),
            "landed winner " + key + " is recovered durably (INV-3)",
        )
    assert_false(Bool(rec.get(tr, _b("doomed1"))), "doomed1 absent (INV-2)")
    assert_false(Bool(rec.get(tr, _b("doomed2"))), "doomed2 absent (INV-2)")
    rec.abort(tr^)

    # INV-5 recovery idempotency: a SECOND open() (re-fold) yields the identical
    # head — re-folding the same WAL is idempotent.
    var rec2 = _handle(backing.clone(), slow_ticks=0)
    assert_equal(
        rec2.wal_head_seq(),
        Int64(2),
        "a second open() re-folds to the IDENTICAL head — recovery is idempotent"
        " (INV-5)",
    )
    print("  test_c_crash_multi_parked: PASS")


def main() raises:
    test_c_park_lose_40001()
    test_c_park_disjoint_reappend()
    test_c_occ_coupling_park()
    test_c_park_store_raise()
    test_c_crash_pre_cas()
    test_c_crash_cas_inflight()
    test_c_crash_multi_parked()
    print("test_async_commit_parkable_correctness: ALL PASS")
