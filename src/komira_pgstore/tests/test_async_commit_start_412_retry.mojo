# =============================================================================
# tests/komira_pgstore/test_async_commit_start_412_retry.mojo
#   START-PATH 412 RETRY PROOF for the parkable AsyncCommitOp (BLOCKER-1,
#   adversarial review of ).
# =============================================================================
#
# THE BUG CLASS: `_commit_async_begin_attempt` (the START path) treated a 412
# (lost-slot) ERR from `append.start[...]` as a TERMINAL error
# (`op._set_error("commit_async: create-CAS start: ...412...")`). But BOTH
# AsyncCasStore conformers surface a lost-slot 412 as an ERR (not a take-raise),
# and on the immediate-completion fast path (the loopback-MinIO / S3-Express
# deployment target) the 412 completes INSIDE `cas_put_start`. The POLL path
# (`commit_async_poll`) already classified `_is_lost_slot_412` and re-ran the
# prelude (re-read auth head + re-OCC) — the START path was ASYMMETRIC: it
# crashed the commit with a terminal error instead of re-running. That breaks
# sync-equivalence on the fast path.
#
# THE FIX: `_commit_async_begin_attempt`, on a 412 ERR from start, re-runs the
# prelude (re-read authoritative head + re-OCC) and re-parks the next slot —
# IDENTICAL to the poll path. (And it wraps `append.start` so a RAISED 412 is
# caught + classified the same way.)
#
# THE PROOF (deterministic, no TOCTOU race): a one-shot conformer-double whose
# FIRST `cas_put_start` returns `CasOpProgress.error("HTTP 412 precondition
# failed (lost CAS)")` (writing NOTHING) and delegates on every subsequent call.
# A real COMPETITOR commit lands at slot 0 first (a normal handle on the SAME
# shared backing). The victim's commit then drives `commit_async_start`:
#   * Its prelude reads the authoritative head (sees the competitor at slot 0),
#     targets slot 1, and the double injects a 412 at the slot-1 create-CAS.
#   * The START path RE-RUNS the prelude (re-reads the auth head, re-runs OCC
#     against the competitor's chunk at slot 0 — a non-conflicting key, so OCC
#     passes), and the second create-CAS (delegated, slot 1 is free) WINS.
#   * The victim commits at the NEXT slot — NOT a terminal
#     "commit_async: create-CAS start: ...412..." error.
#
# FAILS ON CURRENT CODE (pre-fix): the injected START-path 412 sets a TERMINAL
# `op._set_error("commit_async: create-CAS start: HTTP 412 ...")` and
# `op.is_error()` is True; the test asserts `op.is_done()` (committed) and the
# err-text NOT containing the terminal-start prefix — RED pre-fix, GREEN after.
#
# From the adversarial review of the parkable AsyncCommitOp.
# =============================================================================

from std.testing import assert_false, assert_true

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
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


# =============================================================================
# A one-shot 412-on-START conformer-double. Delegates EVERY verb to an inner
# `SharedInMemorySlowCasStore` (slow_ticks=0 => immediate-completion fast path),
# EXCEPT `cas_put_start`: the FIRST call returns an ERR-412 CasOpProgress
# WITHOUT writing (the deterministic lost-slot inject); every subsequent call
# delegates to the inner store. This reproduces the START-path 412 the real S3
# conformer surfaces on the immediate-completion fast path, deterministically.
# =============================================================================
struct _OneShot412OnStartStore(
    AsyncCasStore,
    CloneableConditionalWriteStore,
    ConditionalWriteStore,
    ObjectStore,
    Movable,
    Deinitable,
):
    var _inner: SharedInMemorySlowCasStore
    var _injected: Bool  # one-shot: True after the first cas_put_start inject

    def __init__(out self, var inner: SharedInMemorySlowCasStore):
        self._inner = inner^
        self._injected = False

    def clone(self) -> Self:
        # Share the inner Arc-backed map; carry the one-shot flag (so a clone of
        # an already-injected store does NOT re-inject). The victim handle in the
        # test is NEVER cloned, so the flag's per-instance reset on clone is moot
        # here; we carry it forward to be faithful to the one-shot contract.
        var out = Self(self._inner.clone())
        out._injected = self._injected
        return out^

    # ---- ObjectStore + ConditionalWriteStore — delegate every SYNC verb. ----
    def head(self, path: Path) raises -> ObjectMeta:
        return self._inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self._inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self._inner.coalesce_policy()

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
        return self._inner.get(path)

    def delete(self, path: Path) raises -> None:
        self._inner.delete(path)

    # ---- AsyncCasStore — delegate read; inject a one-shot 412 on cas_put_start.
    def read_start[
        S: WakerSink & Movable & Deinitable,
    ](mut self, path: Path, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self._inner.read_start[S](path, reactor)

    def read_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self._inner.read_poll[S](reactor)

    def read_take(mut self) raises -> CasReadResult:
        return self._inner.read_take()

    def cas_put_start[
        S: WakerSink & Movable & Deinitable,
    ](
        mut self,
        path: Path,
        var bytes: List[UInt8],
        expected_etag: String,
        mut reactor: Reactor[S],
    ) raises -> CasOpProgress:
        if not self._injected:
            # ONE-SHOT INJECT: surface a lost-slot 412 as an ERR (the real S3
            # conformer's immediate-completion fast-path shape) WITHOUT writing.
            # The driver must re-run the prelude + retry the next slot.
            self._injected = True
            _ = bytes^
            return CasOpProgress.error(
                String("HTTP 412 precondition failed (lost CAS)")
            )
        return self._inner.cas_put_start[S](path, bytes^, expected_etag, reactor)

    def cas_put_poll[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> CasOpProgress:
        return self._inner.cas_put_poll[S](reactor)

    def cas_put_take(mut self) raises -> ObjectMeta:
        return self._inner.cas_put_take()


comptime _Store = _OneShot412OnStartStore
comptime _RealStore = SharedInMemorySlowCasStore


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


def _real_handle(
    var inner: SharedInMemoryConditionalStore,
) raises -> TableStore[_RealStore]:
    """A normal (non-injecting) TableStore handle over the shared backing — used
    for the competitor commit + the durable read-back verifier."""
    var slow = SharedInMemorySlowCasStore(inner=inner^, slow_ticks=0)
    var wal = CasManifestStore[_RealStore](
        store=slow^, prefix=String("pg/start412"), retry=RetryPolicy.fast_test()
    )
    return TableStore[_RealStore].open(wal^)


def _victim_handle(
    var inner: SharedInMemoryConditionalStore,
) raises -> TableStore[_Store]:
    """A TableStore handle whose backend injects a one-shot START-path 412 on the
    next create-CAS — shares `inner`'s map with the competitor's handle."""
    var slow = SharedInMemorySlowCasStore(inner=inner^, slow_ticks=0)
    var dbl = _OneShot412OnStartStore(slow^)
    var wal = CasManifestStore[_Store](
        store=dbl^, prefix=String("pg/start412"), retry=RetryPolicy.fast_test()
    )
    return TableStore[_Store].open(wal^)


# =============================================================================
# THE GATE — a START-path 412 re-runs the prelude + lands at the next slot
# (NOT a terminal error). This is the sync-equivalent immediate-completion path.
# =============================================================================
def test_start_path_412_reruns_prelude_and_commits() raises:
    print(
        "[start-412] a START-path 412 re-runs the prelude (re-read auth head +"
        " re-OCC) and commits at the next slot — NOT a terminal error"
    )
    var reactor = _new_reactor()
    var backing = SharedInMemoryConditionalStore()

    # ── COMPETITOR: a normal handle commits a NON-conflicting key at slot 0. ──
    var comp = _real_handle(backing.clone())
    var tc = comp.begin()
    tc.insert(_b("competitor-key"), _b("comp-val"))
    var op_c = AsyncCommitOp.from_txn(tc^)
    var park_c = commit_async_start[_RealStore, NoopSink](comp, op_c, reactor)
    assert_true(
        park_c == Int64(0) and op_c.is_done(),
        "the competitor commit completed in one synchronous burst (slow_ticks=0)",
    )
    var res_c = op_c.take_result()
    assert_true(res_c.did_append, "the competitor appended a chunk")

    # ── VICTIM: its FIRST create-CAS gets a one-shot injected 412 on the START
    # path. The fix must re-run the prelude (re-read auth head, re-OCC against the
    # competitor's slot-0 chunk — non-conflicting, OCC passes) + win the next slot.
    var victim = _victim_handle(backing.clone())
    var tv = victim.begin()
    tv.insert(_b("victim-key"), _b("victim-val"))  # non-conflicting key
    var op_v = AsyncCommitOp.from_txn(tv^)
    var park_v = commit_async_start[_Store, NoopSink](victim, op_v, reactor)

    # The retry's create-CAS is also slow_ticks=0, so the victim completes in one
    # synchronous burst (park id 0) — but via TWO begin-attempts (the injected
    # 412 forced a re-run). Drive any residual park defensively.
    if park_v != Int64(0):
        var park_id = park_v
        var rounds = 0
        while not (op_v.is_done() or op_v.is_error()):
            rounds += 1
            if rounds > 1000:
                raise Error("start-412: op did not converge in 1000 rounds")
            var completions = reactor.poll_completions(Int32(50_000))
            var fired = False
            for i in range(len(completions)):
                if completions[i].op_id == park_id:
                    fired = True
            if not fired:
                continue
            park_id = commit_async_poll[_Store, NoopSink](victim, op_v, reactor)

    # GATE: the victim COMMITTED — it did NOT terminally error on the START 412.
    assert_false(
        op_v.is_error(),
        "the victim must NOT terminally error on the START-path 412 — it must"
        " re-run the prelude + retry (sync-equivalence). Pre-fix err_text: "
        + op_v.err_text(),
    )
    assert_true(
        op_v.is_done(),
        "the victim's commit DONE after the START-path 412 re-run",
    )
    assert_true(
        op_v.err_text().find("create-CAS start") < 0,
        "the victim must NOT carry the terminal 'create-CAS start: ...412...'"
        " error the buggy START path set: " + op_v.err_text(),
    )
    var res_v = op_v.take_result()
    assert_true(res_v.did_append, "the victim appended a chunk (durable)")

    # The victim landed at a DISTINCT slot from the competitor (next slot, no
    # overwrite) — the create-CAS arbitrated them.
    assert_true(
        res_v.commit_lsn != res_c.commit_lsn,
        "the victim won a DISTINCT slot from the competitor (re-OCC + retry"
        " advanced it to the next free slot)",
    )

    # ── DURABLE: both rows visible on a FRESH disjoint handle. ───────────────
    var verifier = _real_handle(backing.clone())
    var tverif = verifier.begin()
    var got_c = verifier.get(tverif, _b("competitor-key"))
    var got_v = verifier.get(tverif, _b("victim-key"))
    assert_true(Bool(got_c), "the competitor row is durably visible")
    assert_true(
        bytes_eq(got_c.value(), _b("comp-val")),
        "the competitor row value is byte-correct",
    )
    assert_true(
        Bool(got_v),
        "the victim row is durably visible after the START-path 412 re-run",
    )
    assert_true(
        bytes_eq(got_v.value(), _b("victim-val")),
        "the victim row value is byte-correct",
    )
    verifier.abort(tverif^)
    print("  test_start_path_412_reruns_prelude_and_commits: PASS")


def main() raises:
    test_start_path_412_reruns_prelude_and_commits()
    print("ALL pgstore async-commit START-412 retry tests PASSED")
