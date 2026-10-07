# =============================================================================
# test_local_dispatcher_wid_mask_no_alias.mojo
# =============================================================================
# BUG: THE wid >= 32 MASK ALIASING.
#
# WHAT WAS WRONG. `LocalDispatcher` carried the per-dispatch DELIVERED and
# ENTERED shard bitmasks in ONE `Atomic[DType.int64]` cell, split 32/32:
#
#     DELIVERED:  fetch_add(1 << (32 + (wid & 31)))     # local_dispatcher:592
#     ENTERED:    fetch_add(1 << (wid & 63))            # local_dispatcher:623
#
# Those two ranges OVERLAP. At `wid = 32` the ENTERED mark sets bit 32, which is
# DELIVERED's bit for `wid = 0`; at `wid = 63` the ENTERED mark `fetch_add`s the
# Int64 SIGN BIT; and `wid = 32..63` all fold onto DELIVERED's `wid = 0..31`.
# Worker count is NOT capped — `run_with_state` shards across
# `self._worker_senders.len()`, which the runtime sizes from
# `physical_core_count()`. Hosts with more than 32 cores are common, so this
# is LIVE on ordinary server hardware.
#
# WHAT IT COST. The masks are the ONLY diagnostic that exists for the barrier
# hang class: `[BARRIER-STALL]` prints `entered_mask` /
# `delivered_mask` and a human reads which wid went missing. Above 32 workers
# the two masks corrupt EACH OTHER by carry, so the one instrument for the hang
# lies exactly on the machines big enough to hit it.
#
# WHY A CARRY IS NORMALLY A FEATURE, AND WHY THAT ARGUMENT NEEDED THIS FIX.
# The marks use `fetch_add` of a power of two rather than `fetch_or` (which this
# stdlib's `Atomic` genuinely does not expose — it has add/sub/xchg/max/min/CAS
# and nothing else). `fetch_add` equals `fetch_or` only
# while each bit is added AT MOST ONCE, and the deliberate payoff is that when
# that stops being true the carry makes the mask VISIBLY WRONG — "a shard that
# ran twice" is the double-decrement bug announcing itself. That signal is only
# readable while bits cannot collide for any OTHER reason. Two masks sharing one
# 64-bit cell gave carries a second, meaningless cause, which is what this fix
# removes: separate word arrays, one bit per (mask, wid), so a carry again means
# exactly one thing.
#
# FAILS ON CURRENT CODE (pre-fix). With 40 attached workers and a 64-task
# dispatch every shard is delivered exactly once and enters exactly once, so
# both masks must hold wids 0..39 and nothing else. Pre-fix the single cell
# instead settles at `0x000001FD_FFFFFFFF`:
#   * ENTERED bits 32..39 collide with DELIVERED bits 0..7, three marks land on
#     each of bits 32..39, and the carries clear bit 33 outright — so
#     `shard_delivered_bit(1)` reads FALSE for a shard that was delivered.
#   * `shard_entered_bit(64)` reads bit `64 & 63 = 0` — wid 0's bit — so a
#     worker id the dispatch never used reports as having run.
# Post-fix both masks are exact and independent at every width.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.memory import OwnedPointer, alloc
from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)
from komira_async_api.worker_pool_traits import KeepAlive, Segment


# ABOVE 32 on purpose, and not a multiple of 32: 40 puts wids 32..39 in the
# overlap and leaves 8 wids in the low band to be corrupted by them.
comptime _N_WORKERS: Int = 40
# Wider than the worker set so `n_workers = min(n, attached)` is the full 40.
comptime _N_TASKS: Int = 64
comptime _CYCLES: Int = 8
# Scanned beyond the worker count to catch WRAPAROUND as well as cross-mask
# aliasing: pre-fix `wid = 64` folds onto `wid = 0` in both masks. Two words
# past the active range is enough to prove it and stays well inside the fixed
# mark-table capacity.
comptime _SCAN_WIDS: Int = 128


struct _CounterState(KeepAlive, Movable, Deinitable):
    """Task ledger owned by the TEST frame, which outlives every dispatch."""

    var _ran: OwnedPointer[AtomicI64]

    def __init__(out self):
        var p = alloc[AtomicI64](1)
        # SAFETY: fresh allocation we own; ownership transfers to OwnedPointer,
        # whose __del__ frees it.
        p[] = AtomicI64(Int64(0))
        self._ran = OwnedPointer[AtomicI64](unsafe_from_raw_pointer=p)

    def ran(self) -> Int64:
        return self._ran[].load()

    def __keep_alive(mut self):
        pass


@fieldwise_init
struct _TickSegment(Segment, Deinitable):
    var _pad: Int64

    def execute[S: KeepAlive](
        mut self, mut state: S, worker_id: Int32, task_id: Int64
    ) raises:
        var sp = UnsafePointer(to=state).bitcast[_CounterState]()
        _ = sp[]._ran[].fetch_add(Int64(1))
        _ = worker_id
        _ = task_id

    def __keep_alive(mut self):
        pass


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def test_bug_wid_ge_32_entered_and_delivered_masks_do_not_alias() raises:
    """ENTERED and DELIVERED must be independent for EVERY wid the dispatcher
    can produce — the worker count is uncapped hardware, not 32.

    FAILS ON CURRENT CODE: see the header. With 40 workers the shared cell
    reports wids as un-delivered that were delivered, and reports wid 64 (never
    used) as entered.
    """
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_N_WORKERS, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref d = rt.dispatcher()
    assert_equal(
        d.worker_count(),
        _N_WORKERS,
        "this test is only meaningful above 32 workers",
    )
    # The ghost-bit scan below is only a falsifier while the wids it asks about
    # are inside the mark table. Out of range the accessors answer False by
    # construction, which would make the scan pass by saying nothing.
    assert_true(
        d.shard_mark_capacity() >= _SCAN_WIDS,
        "the scan must stay inside the mark table's range, else it asserts"
        " nothing about the wids past it",
    )

    var state = _CounterState()

    for cycle in range(_CYCLES):
        var seg = _TickSegment(_pad=Int64(0))
        var back = d.run_with_state[_CounterState, _TickSegment](
            state, seg^, _N_TASKS, CancellationToken.never(),
        )
        _ = back^

        # PRECONDITION, not the claim. A refused shard legitimately leaves its
        # ENTERED bit clear (the guard returns before the mark), so a refusal
        # would fail the assertions below for an unrelated reason. Since the per-shard home
        # this must be 0; say so rather than silently tolerating it.
        assert_equal(
            d.stale_shard_refusals_snapshot(),
            Int64(0),
            "a refusal makes the mask assertions below ambiguous; this is a"
            " different defect (a dispatch use-after-free), not the mask aliasing",
        )

        # Every shard of this dispatch was handed to its worker and every one
        # ran its body, so both masks hold exactly wids 0.._N_WORKERS-1.
        var missing_delivered = String("")
        var missing_entered = String("")
        var ghost_delivered = String("")
        var ghost_entered = String("")
        var wid = 0
        while wid < _SCAN_WIDS:
            var want = wid < _N_WORKERS
            var got_d = d.shard_delivered_bit(wid)
            var got_e = d.shard_entered_bit(wid)
            if want and not got_d:
                missing_delivered += String(wid) + " "
            if want and not got_e:
                missing_entered += String(wid) + " "
            if not want and got_d:
                ghost_delivered += String(wid) + " "
            if not want and got_e:
                ghost_entered += String(wid) + " "
            wid += 1

        assert_equal(
            missing_delivered,
            String(""),
            "cycle " + String(cycle) + ": DELIVERED bit clear for wids that"
            " were delivered: " + missing_delivered,
        )
        assert_equal(
            missing_entered,
            String(""),
            "cycle " + String(cycle) + ": ENTERED bit clear for wids that ran"
            " their body: " + missing_entered,
        )
        assert_equal(
            ghost_delivered,
            String(""),
            "cycle " + String(cycle) + ": DELIVERED bit SET for wids this"
            " dispatch never used: " + ghost_delivered,
        )
        assert_equal(
            ghost_entered,
            String(""),
            "cycle " + String(cycle) + ": ENTERED bit SET for wids this"
            " dispatch never used: " + ghost_entered,
        )
        # A mark that could not be recorded is a mask that silently under-counts
        # — the failure mode the fix must not reintroduce at its own ceiling.
        assert_equal(
            d.shard_mark_overflow_snapshot(),
            Int64(0),
            "no shard mark may be dropped for being out of the table's range",
        )

    assert_equal(
        state.ran(),
        Int64(_CYCLES * _N_TASKS),
        "every task must run exactly once",
    )
    var tasks_ran = state.ran()
    _ = state^
    _ = rt^
    print(
        "[wid-mask-no-alias] workers=", _N_WORKERS,
        " cycles=", _CYCLES,
        " tasks_ran=", tasks_ran,
    )


def main() raises:
    test_bug_wid_ge_32_entered_and_delivered_masks_do_not_alias()
    print("OK test_local_dispatcher_wid_mask_no_alias")
