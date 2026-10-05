# =============================================================================
# test_localmodel_admission.mojo
#   ADMISSION CONTROL in the BackendSupervisor state machine: the per-model
#   concurrency cap and the bounded request queue. Drives admit() / release()
#   / the queue with a STUB backend and a virtual clock (no process, no sleep).
# =============================================================================
#
# WHAT THIS PROVES (bounded latency under load, never a silent wrong answer
# or an OOM):
#
#   (1) CAP — admitting up to `max_concurrent` requests succeeds (ADMIT_ADMITTED,
#       in-flight count rises); the (cap+1)-th request at the cap is QUEUED
#       (ADMIT_QUEUED, the queued count rises, in-flight unchanged).
#
#   (2) QUEUE BOUND — beyond cap + (cap * QUEUE_DEPTH_MULTIPLE) the admission is
#       REJECTED (ADMIT_REJECTED, nothing bumped).
#
#   (3) PULL PROMOTION — a release frees an in-flight slot and a queued waiter
#       claims it with try_promote_if_under_cap (queued -> in-flight), so the
#       cap holds while the backlog drains.
#
#   (4) UNLOAD RESETS — idle-unloading / evicting a model clears its in-flight +
#       queued counters (a reload starts fresh; no leaked admission state).
#
#   (5) DERIVE FROM FIT — derive_concurrency_cap caps at 1 when the fit headroom
#       is negative (over budget), never raises the requested concurrency — so
#       the admission cap agrees with the concurrency-aware fit (the same N
#       that reserved the KV cache).
#
#   (6) ABSENT ID — admit against an unknown id is REJECTED; release /
#       release_queued on an absent id are no-ops.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_localmodel import (
    BackendSupervisor,
    LocalBackend,
    MonotonicClock,
    HostMemoryProfile,
    PLATFORM_MACOS,
    LM_SERVING,
    LM_REGISTERED,
    ADMIT_ADMITTED,
    ADMIT_QUEUED,
    ADMIT_REJECTED,
    derive_concurrency_cap,
    admission_decision_name,
    QUEUE_DEPTH_MULTIPLE,
)


# =============================================================================
# §0 — the STUB backend + the VIRTUAL clock (the same harness as
# test_localmodel_state_machine: a programmable in-process LocalBackend + a clock
# the test advances). No real process, no HTTP.
# =============================================================================
struct StubBackend(LocalBackend, Movable, Deinitable):
    var _base_url: String
    var _fail_launch: Bool
    var launch_count: Int
    var teardown_count: Int
    var _up: Bool

    def __init__(out self, base_url: String, fail_launch: Bool):
        self._base_url = base_url
        self._fail_launch = fail_launch
        self.launch_count = 0
        self.teardown_count = 0
        self._up = False

    def launch(mut self) raises -> String:
        self.launch_count += 1
        if self._fail_launch:
            raise Error("stub: engine never became healthy")
        self._up = True
        return self._base_url

    def health(self) -> Bool:
        return self._up

    def teardown(mut self):
        self.teardown_count += 1
        self._up = False

    def base_url(self) -> String:
        return self._base_url


struct MockClock(MonotonicClock, Movable, Deinitable):
    var _now_ms: Int

    def __init__(out self, start_ms: Int):
        self._now_ms = start_ms

    def now_ms(mut self) -> Int:
        return self._now_ms

    def advance_ms(mut self, delta_ms: Int):
        self._now_ms = self._now_ms + delta_ms


comptime _Sm = BackendSupervisor[StubBackend, MockClock]


def _hw() -> HostMemoryProfile:
    return HostMemoryProfile(
        total_ram_bytes=96 * 1024 * 1024 * 1024,
        vram_bytes=0,
        unified_memory=True,
        platform=PLATFORM_MACOS,
    )


def _gib(n: Int) -> Int:
    return n * 1024 * 1024 * 1024


# A serving model registered with an explicit admission cap, ready to admit.
def _serving_sm_with_cap(cap: Int) raises -> _Sm:
    var sm = _Sm(MockClock(0), _hw(), _gib(64), 60_000, 4)
    _ = sm.register_with_cap(
        String("m"), StubBackend(String("http://127.0.0.1:8081"), False),
        _gib(6), cap,
    )
    _ = sm.request_load(String("m"))  # -> SERVING
    return sm^


# =============================================================================
# (1) CAP — admit up to the cap, then QUEUE.
# =============================================================================
def test_admit_up_to_cap_then_queue() raises:
    var sm = _serving_sm_with_cap(2)  # cap = 2.
    assert_equal(sm.max_concurrent_of(String("m")), 2)

    # First two admits succeed (in-flight 0 -> 1 -> 2).
    assert_equal(sm.admit(String("m")), ADMIT_ADMITTED)
    assert_equal(sm.inflight_of(String("m")), 1)
    assert_equal(sm.admit(String("m")), ADMIT_ADMITTED)
    assert_equal(sm.inflight_of(String("m")), 2)
    assert_equal(sm.queued_of(String("m")), 0)

    # The third is at the cap -> QUEUED (in-flight unchanged, queued rises).
    assert_equal(sm.admit(String("m")), ADMIT_QUEUED)
    assert_equal(sm.inflight_of(String("m")), 2)
    assert_equal(sm.queued_of(String("m")), 1)
    sm.shutdown_all()


# =============================================================================
# (2) QUEUE BOUND — beyond cap + cap*QUEUE_DEPTH_MULTIPLE -> REJECTED.
# =============================================================================
def test_queue_bound_rejects_beyond_depth() raises:
    var cap = 2
    var sm = _serving_sm_with_cap(cap)
    # The bounded queue depth is cap * QUEUE_DEPTH_MULTIPLE.
    assert_equal(
        sm.queue_capacity_of(String("m")), cap * QUEUE_DEPTH_MULTIPLE
    )

    # Fill the cap (2 in-flight).
    assert_equal(sm.admit(String("m")), ADMIT_ADMITTED)
    assert_equal(sm.admit(String("m")), ADMIT_ADMITTED)
    # Fill the queue (cap * multiple queued).
    var queue_depth = cap * QUEUE_DEPTH_MULTIPLE
    for _i in range(queue_depth):
        assert_equal(sm.admit(String("m")), ADMIT_QUEUED)
    assert_equal(sm.queued_of(String("m")), queue_depth)

    # One more -> REJECTED (cap + queue full); nothing bumped.
    assert_equal(sm.admit(String("m")), ADMIT_REJECTED)
    assert_equal(sm.inflight_of(String("m")), cap)
    assert_equal(sm.queued_of(String("m")), queue_depth)
    sm.shutdown_all()


# =============================================================================
# (3) PULL PROMOTION — a queued waiter claims a freed slot via
#     try_promote_if_under_cap (the block-and-wait model). `release` just
#     decrements in-flight (no auto-promote); the queued worker PULLS its slot in
#     when one frees, so in-flight is a TRUE hard cap (== max_concurrent).
# =============================================================================
def test_release_then_pull_promote_drains_queue() raises:
    var sm = _serving_sm_with_cap(1)  # cap = 1 (one in-flight at a time).

    # Admit one (in-flight 1), queue two more.
    assert_equal(sm.admit(String("m")), ADMIT_ADMITTED)
    assert_equal(sm.admit(String("m")), ADMIT_QUEUED)
    assert_equal(sm.admit(String("m")), ADMIT_QUEUED)
    assert_equal(sm.inflight_of(String("m")), 1)
    assert_equal(sm.queued_of(String("m")), 2)

    # While the cap is full, a queued waiter's pull-attempt FAILS (in-flight stays
    # at the cap — the hard bound is never exceeded).
    assert_false(
        sm.try_promote_if_under_cap(String("m")),
        "pull fails while in-flight is at the cap",
    )
    assert_equal(sm.inflight_of(String("m")), 1)
    assert_equal(sm.queued_of(String("m")), 2)

    # Release the in-flight slot (decrement only, no auto-promote).
    sm.release(String("m"))
    assert_equal(sm.inflight_of(String("m")), 0)
    assert_equal(sm.queued_of(String("m")), 2)

    # Now a queued waiter PULLS the freed slot (queued 2 -> 1, in-flight 0 -> 1).
    assert_true(
        sm.try_promote_if_under_cap(String("m")),
        "pull succeeds once a slot frees",
    )
    assert_equal(sm.inflight_of(String("m")), 1)
    assert_equal(sm.queued_of(String("m")), 1)

    # A second pull fails again (cap full once more) until another release.
    assert_false(sm.try_promote_if_under_cap(String("m")))
    sm.release(String("m"))
    assert_true(sm.try_promote_if_under_cap(String("m")))
    assert_equal(sm.inflight_of(String("m")), 1)
    assert_equal(sm.queued_of(String("m")), 0)

    # No queued waiters left -> pull fails (nothing to promote).
    sm.release(String("m"))
    assert_false(sm.try_promote_if_under_cap(String("m")))
    assert_equal(sm.inflight_of(String("m")), 0)
    assert_equal(sm.queued_of(String("m")), 0)

    # An extra release never underflows below 0.
    sm.release(String("m"))
    assert_equal(sm.inflight_of(String("m")), 0)
    sm.shutdown_all()


def test_release_queued_drops_one_waiter() raises:
    var sm = _serving_sm_with_cap(1)
    assert_equal(sm.admit(String("m")), ADMIT_ADMITTED)  # in-flight 1.
    assert_equal(sm.admit(String("m")), ADMIT_QUEUED)    # queued 1.
    assert_equal(sm.admit(String("m")), ADMIT_QUEUED)    # queued 2.

    # A queued caller abandons the wait -> drop one queued slot (no promotion,
    # the in-flight slot is still held).
    sm.release_queued(String("m"))
    assert_equal(sm.queued_of(String("m")), 1)
    assert_equal(sm.inflight_of(String("m")), 1)

    # Drop the other; an extra drop never underflows.
    sm.release_queued(String("m"))
    assert_equal(sm.queued_of(String("m")), 0)
    sm.release_queued(String("m"))
    assert_equal(sm.queued_of(String("m")), 0)
    sm.shutdown_all()


# =============================================================================
# (4) UNLOAD RESETS — idle-unload / evict clears the admission counters.
# =============================================================================
def test_unload_resets_admission_counters() raises:
    # keep_alive 5000 ms so a tick past it idle-unloads.
    var sm = _Sm(MockClock(0), _hw(), _gib(64), 5000, 4)
    _ = sm.register_with_cap(
        String("m"), StubBackend(String("http://127.0.0.1:8081"), False),
        _gib(6), 2,
    )
    _ = sm.request_load(String("m"))  # SERVING, last_req at now=0.

    # Hold some in-flight + queued.
    assert_equal(sm.admit(String("m")), ADMIT_ADMITTED)
    assert_equal(sm.admit(String("m")), ADMIT_ADMITTED)
    assert_equal(sm.admit(String("m")), ADMIT_QUEUED)
    assert_true(sm.inflight_of(String("m")) > 0)
    assert_true(sm.queued_of(String("m")) > 0)

    # Idle-unload past the TTL -> the model returns to REGISTERED + counters clear.
    sm.clock_mut().advance_ms(6000)
    assert_equal(sm.tick_idle_unload(), 1)
    assert_equal(sm.state_of(String("m")), LM_REGISTERED)
    assert_equal(sm.inflight_of(String("m")), 0)
    assert_equal(sm.queued_of(String("m")), 0)

    # A reload starts fresh (admit succeeds from 0 in-flight again).
    _ = sm.request_load(String("m"))
    assert_equal(sm.state_of(String("m")), LM_SERVING)
    assert_equal(sm.admit(String("m")), ADMIT_ADMITTED)
    assert_equal(sm.inflight_of(String("m")), 1)
    sm.shutdown_all()


def test_evict_resets_admission_counters() raises:
    # max_resident = 1: loading B evicts A; A's admission counters must clear.
    var sm = _Sm(MockClock(0), _hw(), _gib(64), 60_000, 1)
    _ = sm.register_with_cap(
        String("a"), StubBackend(String("http://127.0.0.1:9001"), False),
        _gib(6), 4,
    )
    _ = sm.register_with_cap(
        String("b"), StubBackend(String("http://127.0.0.1:9002"), False),
        _gib(6), 4,
    )
    sm.clock_mut().advance_ms(10)
    _ = sm.request_load(String("a"))
    assert_equal(sm.admit(String("a")), ADMIT_ADMITTED)
    assert_equal(sm.inflight_of(String("a")), 1)

    # Load B -> evicts A (the LRU). A's counters reset to 0.
    sm.clock_mut().advance_ms(10)
    _ = sm.request_load(String("b"))
    assert_equal(sm.state_of(String("a")), LM_REGISTERED)
    assert_equal(sm.inflight_of(String("a")), 0)
    assert_equal(sm.queued_of(String("a")), 0)
    sm.shutdown_all()


# =============================================================================
# (5) DERIVE-FROM-FIT — the cap scales DOWN with tight headroom, never up.
# =============================================================================
def test_derive_cap_from_fit_headroom() raises:
    # Positive headroom (the fit reserved N streams' KV and still fit) -> the cap
    # is the full requested concurrency.
    assert_equal(derive_concurrency_cap(_gib(10), 4), 4)
    assert_equal(derive_concurrency_cap(1, 8), 8)

    # Negative headroom (over budget even at the reserved estimate) -> cap 1 (the
    # model does not fit its requested concurrency; admission must not grant N).
    assert_equal(derive_concurrency_cap(-_gib(2), 4), 1)
    assert_equal(derive_concurrency_cap(-1, 16), 1)

    # A requested concurrency of 0 floors at 1 (never 0 — a loaded model can
    # always serve at least one request).
    assert_equal(derive_concurrency_cap(_gib(10), 0), 1)


# =============================================================================
# (6) ABSENT-ID — admit against an unknown id is REJECTED; release is a no-op.
# =============================================================================
def test_absent_id_admission() raises:
    var sm = _serving_sm_with_cap(4)
    assert_equal(sm.admit(String("nope")), ADMIT_REJECTED)
    assert_equal(sm.inflight_of(String("nope")), 0)
    assert_equal(sm.max_concurrent_of(String("nope")), 0)
    # release / release_queued on an absent id are no-ops (no crash).
    sm.release(String("nope"))
    sm.release_queued(String("nope"))
    sm.shutdown_all()


def test_set_max_concurrent_override() raises:
    var sm = _serving_sm_with_cap(2)
    assert_equal(sm.max_concurrent_of(String("m")), 2)
    # Re-derive the cap (e.g. after a re-fit) -> override applies.
    assert_true(sm.set_max_concurrent(String("m"), 5))
    assert_equal(sm.max_concurrent_of(String("m")), 5)
    # An override <= 0 floors at 1.
    assert_true(sm.set_max_concurrent(String("m"), 0))
    assert_equal(sm.max_concurrent_of(String("m")), 1)
    # Absent id -> False.
    assert_false(sm.set_max_concurrent(String("nope"), 3))
    sm.shutdown_all()


def test_admission_decision_names() raises:
    assert_equal(admission_decision_name(ADMIT_ADMITTED), String("admitted"))
    assert_equal(admission_decision_name(ADMIT_QUEUED), String("queued"))
    assert_equal(admission_decision_name(ADMIT_REJECTED), String("rejected"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
