# =============================================================================
# tests/test_slow_cas_store_start_412_abi.mojo
#   ABI REGRESSION for SharedInMemorySlowCasStore.cas_put_start (BLOCKER-2,
# adversarial review of).
# =============================================================================
#
# THE BUG CLASS: an `AsyncCasStore` conformer's `*_start` verb MUST return one
# of READY / PENDING(op_id) / ERR — it MUST NEVER raise a precondition (412).
# The caller's poll-shaped driver branches on the returned `CasOpProgress`; a
# RAISED 412 escapes that branching entirely (it unwinds the frame instead of
# being classified as a lost-slot retry), so on the immediate-completion fast
# path (slow_ticks==0 — the loopback-MinIO / S3-Express deployment shape) the
# driver never gets a chance to re-OCC + retry the next slot.
#
# On `slow_ticks<=0`, `SharedInMemorySlowCasStore.cas_put_start` runs the CAS
# inline via `_run_cas_put_now()`; it must wrap that call the same way the
# sibling `cas_put_poll` does, into `CasOpProgress.error(...)`. This test
# directly drives `cas_put_start` against an already-occupied key (empty
# expected_etag => If-None-Match => 412) and asserts it RETURNS an ERR
# CasOpProgress, NOT a raise.
#
# A store that lets the 412 escape `_run_cas_put_now()` fails the "must not
# raise" assertion (the test catches the raise). A correct `cas_put_start`
# returns `CasOpProgress.error(...)` containing "412"/"precondition" — the test
# asserts is_error() + the message.
# =============================================================================

from std.testing import assert_false, assert_true

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)

from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_slow_cas_store import (
    SharedInMemorySlowCasStore,
)
from komira_objectstore.store import CasOpProgress


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


# =============================================================================
# THE GATE — cas_put_start on an already-occupied key (slow_ticks=0) RETURNS an
# ERR CasOpProgress, it does NOT raise the 412.
# =============================================================================
def test_cas_put_start_412_returns_err_not_raise() raises:
    print(
        "[slow-cas-abi] cas_put_start 412 on the immediate-completion fast path"
        " returns ERR (not a raise)"
    )
    var reactor = _new_reactor()
    var store = SharedInMemorySlowCasStore(slow_ticks=0)
    var key = Path.parse(String("cas/abi/slot"))

    # First create-CAS (If-None-Match, slot empty) — WINS, completes inline.
    var p1 = store.cas_put_start[NoopSink](
        key, _b("first"), String(""), reactor
    )
    assert_true(
        p1.is_ready(),
        "the first create-CAS (empty slot) completes READY in one burst",
    )
    var meta = store.cas_put_take()
    _ = meta

    # Second create-CAS at the SAME key with empty expected_etag (If-None-Match)
    # the slot is now occupied, so the conditional_put raises a 412 INSIDE
    # `_run_cas_put_now`. On the slow_ticks==0 fast path that runs inside
    # `cas_put_start`. The ABI demands it return an ERR CasOpProgress, NOT raise.
    var raised = False
    # Initialized so the binding is defined on the raise path; overwritten on the
    # return path. Gated by `raised` so the placeholder is never asserted-on.
    var prog = CasOpProgress.error(String("uninitialized"))
    try:
        prog = store.cas_put_start[NoopSink](
            key, _b("second"), String(""), reactor
        )
    except e:
        # PRE-FIX: the 412 RAISES here. That is the ABI violation under test.
        raised = True
        print("  (observed RAISE — pre-fix behavior): " + String(e))

    assert_false(
        raised,
        "cas_put_start must NOT raise a 412 on the immediate-completion fast"
        " path — the AsyncCasStore ABI requires *_start to return"
        " READY/PENDING/ERR (a raised precondition escapes the driver's"
        " lost-slot classification). This is BLOCKER-2.",
    )
    assert_true(
        prog.is_error(),
        "the lost-slot 412 must surface as an ERR CasOpProgress from"
        " cas_put_start (symmetric with cas_put_poll)",
    )
    var em = prog.err_text()
    assert_true(
        em.find("412") >= 0 or em.find("precondition") >= 0,
        "the ERR text carries the 412/precondition signal the driver's"
        " _is_lost_slot_412 classifier matches: " + em,
    )
    print("  test_cas_put_start_412_returns_err_not_raise: PASS")


def main() raises:
    test_cas_put_start_412_returns_err_not_raise()
    print("ALL slow-cas-store start-412 ABI tests PASSED")
