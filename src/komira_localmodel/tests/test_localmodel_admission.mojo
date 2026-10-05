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
#   (4) BUSY MODELS STAY LOADED — a model with an admitted or queued request
#       is not idle-unloaded, not chosen as an eviction victim (an idle model
#       is chosen instead, or the load waits) and not stopped; the counters
#       are never reset, so a late release cannot take a newer request's slot.
#
#   (5) DERIVE FROM FIT — derive_concurrency_cap is the requested concurrency
#       when the fit (computed at that concurrency) has non-negative headroom,
#       and 1 when it is over budget.
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
# (4) BUSY MODELS STAY LOADED — a model with an admitted or queued request is
#     not idle-unloaded, not evicted and not stopped, and its counters are
#     never reset, so every admit is balanced by its own release.
# =============================================================================
def test_idle_sweep_skips_busy_model() raises:
    # keep_alive 5000 ms; the request outlives it.
    var sm = _Sm(MockClock(0), _hw(), _gib(64), 5000, 4)
    _ = sm.register_with_cap(
        String("m"), StubBackend(String("http://127.0.0.1:8081"), False),
        _gib(6), 2,
    )
    _ = sm.request_load(String("m"))  # SERVING, last_req at now=0.
    assert_equal(sm.admit(String("m")), ADMIT_ADMITTED)
    assert_equal(sm.admit(String("m")), ADMIT_ADMITTED)
    assert_equal(sm.admit(String("m")), ADMIT_QUEUED)

    # Far past the TTL with requests outstanding: nothing is unloaded.
    sm.clock_mut().advance_ms(60_000)
    assert_equal(sm.tick_idle_unload(), 0)
    assert_equal(sm.state_of(String("m")), LM_SERVING)
    assert_equal(sm.inflight_of(String("m")), 2)
    assert_equal(sm.queued_of(String("m")), 1)

    # Queued alone keeps it loaded too.
    sm.release(String("m"))
    sm.release(String("m"))
    assert_equal(sm.tick_idle_unload(), 0)
    assert_equal(sm.state_of(String("m")), LM_SERVING)

    # Once the last waiter is gone the expired model is swept.
    sm.release_queued(String("m"))
    assert_equal(sm.tick_idle_unload(), 1)
    assert_equal(sm.state_of(String("m")), LM_REGISTERED)
    sm.shutdown_all()


def test_busy_model_is_not_evicted() raises:
    # max_resident = 1: B cannot load while A is serving a request.
    var sm = _Sm(MockClock(0), _hw(), _gib(64), 60_000, 1)
    _ = sm.register_with_cap(
        String("a"), StubBackend(String("http://127.0.0.1:9001"), False),
        _gib(6), 4,
    )
    _ = sm.register_with_cap(
        String("b"), StubBackend(String("http://127.0.0.1:9002"), False),
        _gib(6), 4,
    )
    _ = sm.request_load(String("a"))
    assert_equal(sm.admit(String("a")), ADMIT_ADMITTED)

    assert_false(
        sm.request_load(String("b")), "a load that needs a busy victim waits"
    )
    assert_equal(sm.state_of(String("a")), LM_SERVING)
    assert_equal(sm.state_of(String("b")), LM_REGISTERED)
    assert_equal(sm.launch_count_of(String("b")), 0)
    assert_equal(sm.inflight_of(String("a")), 1)

    # A's request finishes; now B evicts the idle A.
    sm.release(String("a"))
    assert_true(sm.request_load(String("b")))
    assert_equal(sm.state_of(String("a")), LM_REGISTERED)
    assert_equal(sm.state_of(String("b")), LM_SERVING)
    sm.shutdown_all()


def test_eviction_prefers_idle_over_lru() raises:
    # max_resident = 2: A (older, busy) and B (newer, idle) resident; loading
    # C evicts B, the idle one, even though A is least recently used.
    var sm = _Sm(MockClock(0), _hw(), _gib(64), 60_000, 2)
    _ = sm.register(
        String("a"), StubBackend(String("http://127.0.0.1:9011"), False), _gib(6)
    )
    _ = sm.register(
        String("b"), StubBackend(String("http://127.0.0.1:9012"), False), _gib(6)
    )
    _ = sm.register(
        String("c"), StubBackend(String("http://127.0.0.1:9013"), False), _gib(6)
    )
    _ = sm.request_load(String("a"))
    _ = sm.request_load(String("b"))
    assert_equal(sm.admit(String("a")), ADMIT_ADMITTED)
    assert_true(sm.request_load(String("c")))
    assert_equal(sm.state_of(String("a")), LM_SERVING)
    assert_equal(sm.state_of(String("b")), LM_REGISTERED)
    assert_equal(sm.state_of(String("c")), LM_SERVING)
    sm.release(String("a"))
    sm.shutdown_all()


def test_stop_refuses_busy_model() raises:
    var sm = _serving_sm_with_cap(2)
    assert_equal(sm.admit(String("m")), ADMIT_ADMITTED)
    assert_false(sm.stop(String("m")), "stop refuses a model serving a request")
    assert_equal(sm.state_of(String("m")), LM_SERVING)
    sm.release(String("m"))
    assert_true(sm.stop(String("m")))
    assert_equal(sm.state_of(String("m")), LM_REGISTERED)
    sm.shutdown_all()


def test_late_release_after_shutdown_balances() raises:
    # shutdown_all unloads a busy model but leaves its counters, so the late
    # release of the old request does not take a slot from a new one.
    var sm = _serving_sm_with_cap(1)
    assert_equal(sm.admit(String("m")), ADMIT_ADMITTED)
    sm.shutdown_all()
    assert_equal(sm.state_of(String("m")), LM_REGISTERED)
    assert_equal(sm.inflight_of(String("m")), 1)
    sm.release(String("m"))
    assert_equal(sm.inflight_of(String("m")), 0)
    _ = sm.request_load(String("m"))
    assert_equal(sm.admit(String("m")), ADMIT_ADMITTED)
    assert_equal(sm.admit(String("m")), ADMIT_QUEUED, "the cap of 1 still holds")
    sm.release_queued(String("m"))
    sm.release(String("m"))
    sm.shutdown_all()


# =============================================================================
# (5) DERIVE-FROM-FIT — the requested cap, or 1 when the fit is over budget.
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
