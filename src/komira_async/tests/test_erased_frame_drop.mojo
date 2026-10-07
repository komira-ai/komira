# =============================================================================
# test_erased_frame_drop.mojo — the dual-step-drop
# DOUBLE-FREE regression for ErasedHandlerFrame.
# =============================================================================
# THE BUG: a
# `ErasedHandlerFrame.__del__` + `_erased_drop_for[H]` use a TWO-STEP teardown — run
# the handler `H` destructor IN-PLACE via `destroy_pointee()`, then free the raw
# byte home via a SEPARATE `_blob: OwnedPointer[UInt8]` drop. Under Mojo
# 1.0.0b1, for any handler `H` with a NESTED heap-owning field (an inner
# `OwnedPointer` / `List` at a realistic offset), the in-place destroy and the
# separate byte-free are NOT tracked as ONE consume of H's storage, so the inner
# field's home is freed TWICE — a heap corruption that only trips on a LATER
# allocation (the destroy-recreate / use-after-free family).
#
# THE PROVEN FIX (already on main in `shared_erasure.mojo`'s `ErasedHandle`):
# `__del__` RELINQUISHES `_blob`'s free (`unsafe_leak()`), and the drop trampoline
# reconstructs ONE `OwnedPointer[H]` over the bytes and `.take()`s it — destroy
# + free as a SINGLE tracked consume (the blessed pointer-rule shape). This test
# is the `_HeapWork` double-free regression from `test_shared_erasure.mojo`
# adapted to `ErasedHandlerFrame` / `make_erased_handler_frame[H, S]`.
#
# ── HOW IT DETERMINISTICALLY DETECTS THE DOUBLE-FREE ─────────────────────────
# `_HeapHandler` is deliberately the destroy-recreate shape: a `SuspendableHandler` with
# BOTH a `List[Int]` heap field AND an `OwnedPointer[Int]` heap field (at a
# realistic offset). The double-free of the inner `OwnedPointer[Int]` home
# corrupts tcmalloc's freelist; the corruption manifests on the NEXT same-size
# allocation. The test makes this deterministic the way the library's `_HeapWork`
# test does: erase TWO heap-owning handlers into frames, DROP both (each runs the
# two-step teardown → each double-frees its inner `OwnedPointer[Int]`), then
# immediately allocate a fresh batch of same-shaped heap structures into the now-
# corrupted freelist and assert their data + a survival sentinel are INTACT. A
# correct single-consume drop frees each inner home exactly once, the freelist
# stays sane, the follow-up allocs return clean blocks, and the sentinels survive.
# A double-free poisons the freelist and the follow-up allocs return corrupted /
# aliased blocks, tripping the assert (or crashing the allocator) — so the test
# FAILS against the two-step drop and PASSES against the single-consume drop.
# =============================================================================

from std.memory import OwnedPointer, UnsafePointer, alloc
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink, WakerSink
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.runtime.shared_erasure import (
    ErasedHandlerFrame,
    make_erased_handler_frame,
)
from komira_async.runtime.suspendable_handler import (
    HandlerStepResult,
    SuspendableHandler,
)

from komira_collections.slab import Slab


# -----------------------------------------------------------------------------
# Test helper — build a List[Int] via append (the version-agnostic shape; the
# variadic `List[Int](e1, e2, ...)` ctor is brittle on Mojo 1.0.0b1, per the
# sibling test_shared_erasure.mojo's note).
# -----------------------------------------------------------------------------


def _ints(a: Int, b: Int, c: Int, d: Int) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    out.append(b)
    out.append(c)
    out.append(d)
    return out^


# =============================================================================
# _PodResp — a trivial POD response (the response round-trip is covered by
# test_erased_frame_spike; here the response is a plain status so the test
# focuses squarely on the HANDLER's inner-heap-field drop).
# =============================================================================


struct _PodResp(Movable, Deinitable):
    """A trivial terminal response: just a status. POD — the response box is not
    what this regression tests (test_erased_frame_spike covers it); this test isolates the
    HANDLER SM's nested-heap-field drop."""

    var status: Int

    def __init__(out self, status: Int):
        self.status = status


# =============================================================================
# _HeapHandler — a SuspendableHandler that is the destroy-recreate shape: a Movable-not-
# Copyable handler SM with BOTH a `List[Int]` heap field AND an
# `OwnedPointer[Int]` heap field at a realistic offset. DONEs on first step.
# =============================================================================


struct _HeapHandler(Movable, Deinitable, SuspendableHandler):
    """The double-free bait: a handler SM with TWO nested heap-owning fields —
    a `List[Int]` AND an `OwnedPointer[Int]` (the inner home whose double-free
    the two-step drop produces). DONEs on its first step (no park needed; the
    bug is in the DROP path, not the step path). The handler mutates its own
    heap state in `step` so a read-after-free would also surface."""

    comptime Resp = _PodResp

    var _items: List[Int]
    var _accum: OwnedPointer[Int]

    def __init__(out self, var items: List[Int]):
        self._items = items^
        var raw = alloc[Int](1)
        raw[] = 0
        self._accum = OwnedPointer[Int](unsafe_from_raw_pointer=raw)

    def step[
        S: WakerSink & Movable & Deinitable,
    ](mut self, mut reactor: Reactor[S]) raises -> HandlerStepResult[_PodResp]:
        # Touch both heap fields (a UAF would surface on this read-through), then
        # DONE. The handler retires in one step; the regression is its DROP.
        var s = 0
        for i in range(len(self._items)):
            s += self._items[i]
        self._accum[] = self._accum[] + s
        return HandlerStepResult[_PodResp].done(_PodResp(200))


comptime _Frame = ErasedHandlerFrame[NoopSink]


def test_erased_frame_drop_no_double_free() raises:
    """REGRESSION: the dual-step-drop double-free of an `ErasedHandlerFrame` handler's
    nested heap-owning field. Erase TWO `_HeapHandler`s (each with a `List[Int]`
    + an `OwnedPointer[Int]`) into frames, step each once (DONE), then DROP both
    frames — each runs `_erased_drop_for[_HeapHandler]` + the `_blob` free. Under
    the BUGGY two-step drop, each inner `OwnedPointer[Int]` home is freed twice,
    corrupting the allocator freelist. We then allocate a fresh batch of same-
    shaped heap structures into the corrupted freelist and assert their data +
    survival sentinels are INTACT — a double-free poisons the freelist so the
    follow-up allocs return corrupted/aliased blocks (assert trips / crash). The
    single-consume drop keeps the freelist sane → this test PASSES."""
    var reactor = Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK
    )

    # ---- erase + step + DROP two heap-owning handler frames. --------
    # Two erasures (the library's `_HeapWork` test uses repetition to make the
    # corruption deterministic across the freelist). Each handler owns a
    # List[Int] + an OwnedPointer[Int]; the drop of each must free each inner
    # home EXACTLY ONCE.
    var frame_a = make_erased_handler_frame[_HeapHandler, NoopSink](
        _HeapHandler(_ints(1, 2, 3, 4)), Int64(100)
    )
    var frame_b = make_erased_handler_frame[_HeapHandler, NoopSink](
        _HeapHandler(_ints(5, 6, 7, 8)), Int64(101)
    )

    # Step each once → DONE (touches both heap fields, then retires-on-DONE-drop
    # is NOT triggered by step; the frame stays steppable, dropped explicitly).
    var sr_a = frame_a.step(reactor)
    assert_true(sr_a.is_done())
    var sr_b = frame_b.step(reactor)
    assert_true(sr_b.is_done())
    # The POD responses round-trip (not the focus; just confirm step ran).
    assert_equal(sr_a.take_response[_PodResp]().status, 200)
    assert_equal(sr_b.take_response[_PodResp]().status, 200)

    # DROP both frames. Each runs `_erased_drop_for[_HeapHandler]` (the handler
    # destructor over its List[Int] + OwnedPointer[Int]) + the `_blob` free.
    # The two-step shape double-frees each inner OwnedPointer[Int] home here.
    _ = frame_a^
    _ = frame_b^

    # ---- allocate into the (possibly-corrupted) freelist. -----------
    # If the inner OwnedPointer[Int] homes were double-freed, the
    # freelist is now corrupted; these same-size allocations return poisoned /
    # aliased blocks. We write a distinct sentinel into each and read them ALL
    # back — a double-free-poisoned freelist hands back overlapping/garbage
    # blocks, so the sentinels collide or read wrong, tripping the assert.
    # OwnedPointer[Int] is Movable-not-Copyable → a Slab (NOT List) holds it
    # (the blessed Movable-only container; List requires T: Copyable).
    var probes = Slab[OwnedPointer[Int]]()
    var n_probes = 64
    for i in range(n_probes):
        var raw = alloc[Int](1)
        raw[] = 0xBEEF_0000 + i  # distinct per-probe sentinel
        probes.append(OwnedPointer[Int](unsafe_from_raw_pointer=raw))

    # Every probe must read back its OWN sentinel — no aliasing, no corruption.
    for i in range(n_probes):
        assert_equal(probes[i][], 0xBEEF_0000 + i)

    # ---- a heap-owning structure into the recycled bytes. -----------
    # The strongest detector for the inner-field double-free: build fresh
    # _HeapHandler-shaped heap structures (List[Int] + OwnedPointer[Int]) into
    # the recycled bytes and read both heap fields back. A corrupted freelist
    # would surface here as a wrong read or a crash on the List buffer.
    # _HeapHandler is Movable-not-Copyable → Slab again.
    var revivals = Slab[_HeapHandler]()
    for i in range(8):
        revivals.append(_HeapHandler(_ints(i, i + 1, i + 2, i + 3)))
    for i in range(8):
        # _accum starts at 0 (the ctor sets it); the List holds the 4 ints.
        assert_equal(revivals[i]._accum[], 0)
        assert_equal(len(revivals[i]._items), 4)
        assert_equal(revivals[i]._items[0], i)
        assert_equal(revivals[i]._items[3], i + 3)

    # Reached here with all sentinels + heap-field reads intact → the inner
    # OwnedPointer[Int] homes were each freed EXACTLY ONCE (single-consume drop),
    # the freelist stayed sane, and there is no double-free.
    _ = probes^
    _ = revivals^
    assert_true(True)

    print("  [drop] ErasedHandlerFrame nested-heap-field drop: no double-free OK")


def test_erased_frame_drop_undelivered_parked_frame() raises:
    """REGRESSION (abandoned-frame variant): a frame that never finished — built,
    stepped to DONE but here we ALSO cover the path where a heap-owning frame is
    dropped WITHOUT ever stepping (driver-teardown with a still-fresh/parked
    frame). The drop must still free the handler's nested heap fields EXACTLY
    once. Build N heap-owning frames in a Slab, never step them, drop the Slab,
    then allocate into the recycled bytes and assert integrity."""
    var frames = Slab[_Frame]()
    var n = 16
    for i in range(n):
        frames.append(
            make_erased_handler_frame[_HeapHandler, NoopSink](
                _HeapHandler(_ints(i, i * 2, i * 3, i * 4)), Int64(200 + i)
            )
        )
    assert_equal(frames.len(), n)

    # Drop the whole Slab WITHOUT stepping any frame — each frame's drop runs the
    # handler destructor over its List[Int] + OwnedPointer[Int] (the abandoned-
    # frame teardown path). The two-step shape double-frees each inner home here.
    _ = frames^

    # Allocate into the recycled bytes; assert no corruption (distinct sentinels
    # all survive). A double-freed inner home poisons the freelist → collisions.
    # Slab (NOT List) — OwnedPointer[Int] is Movable-not-Copyable.
    var probes = Slab[OwnedPointer[Int]]()
    for i in range(64):
        var raw = alloc[Int](1)
        raw[] = 0xCAFE_0000 + i
        probes.append(OwnedPointer[Int](unsafe_from_raw_pointer=raw))
    for i in range(64):
        assert_equal(probes[i][], 0xCAFE_0000 + i)
    _ = probes^

    print("  [drop] abandoned heap-owning frame teardown: no double-free OK")


def main() raises:
    test_erased_frame_drop_no_double_free()
    test_erased_frame_drop_undelivered_parked_frame()
    print("PASS test_erased_frame_drop")
