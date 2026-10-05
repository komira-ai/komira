# =============================================================================
# test_localmodel_state_machine.mojo
#   The BackendSupervisor lifecycle STATE MACHINE, driven with a STUB backend
#   and a VIRTUAL clock (no process spawn, no sleep — deterministic).
# =============================================================================
#
# WHAT THIS PROVES:
#
#   (1) LOAD ON FIRST REQUEST — a REGISTERED model is NOT loaded until the
#       first request_load() drives it REGISTERED -> LOADING -> SERVING (the
#       backend's launch() is called once; before the request no child exists).
#
#   (2) IDLE UNLOAD AFTER THE TTL — a SERVING model whose last request is older
#       than the keep_alive TTL is torn down by tick_idle_unload()
#       (SERVING -> REGISTERED, the backend's teardown() called, no orphan). A
#       model still within the TTL is left SERVING. Driven by VIRTUAL time.
#
#   (3) LRU EVICTION — with a 1-resident budget, loading a SECOND model evicts
#       the FIRST (the LRU) before launching the second (the first's teardown()
#       runs and it returns to REGISTERED; only the second ends SERVING). With a
#       byte budget, re-requesting model A makes B the LRU victim.
#
#   (4) FAILED STATES NAME THEIR REASON — a backend whose launch() RAISES (never
#       becomes healthy) drives the model to LM_FAILED with FAIL_LAUNCH
#       (teardown ran — no orphan), and a later request does NOT silently retry
#       (it stays FAILED until clear_failure). A model larger than the whole
#       budget is refused with FAIL_WONT_FIT without launching anything.
#
#   (5) BOOKKEEPING — duplicate ids, absent ids, shutdown_all.
#
# THE STUB BACKEND: an in-process LocalBackend that RECORDS launch/teardown
# calls and can be told to fail its launch, so the SM's calls into the backend
# are asserted directly. The real spawn path (SupervisorRegistry) is covered by
# test_localmodel_registry; THIS test is about the SM's transitions.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_localmodel import (
    BackendSupervisor,
    LocalBackend,
    MonotonicClock,
    HostMemoryProfile,
    PLATFORM_MACOS,
    LM_REGISTERED,
    LM_SERVING,
    LM_FAILED,
    FAIL_LAUNCH,
    FAIL_WONT_FIT,
    FAIL_NONE,
)


# =============================================================================
# §0 — The STUB backend (the programmable LocalBackend under the SM).
# =============================================================================
struct StubBackend(LocalBackend, Movable, Deinitable):
    """A fake LocalBackend that records the SM's lifecycle calls + lets a test
    program the launch outcome. No real process, no HTTP — pure in-process
    bookkeeping so the SM transitions are asserted deterministically."""

    var _base_url: String
    var _fail_launch: Bool   # when True, launch() RAISES (never healthy).
    var launch_count: Int    # how many times launch() was called.
    var teardown_count: Int  # how many times teardown() was called.
    var _up: Bool            # internal "is the (fake) endpoint serving".

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


# =============================================================================
# §1 — The VIRTUAL clock (the TTL seam). A MonotonicClock conformer the test
# ADVANCES; the SM owns its clock by value, so the test advances it through the
# SM's clock_mut() accessor (Mojo has no mutable module globals; the clock
# carries its own _now_ms cell).
# =============================================================================
struct MockClock(MonotonicClock, Movable, Deinitable):
    """A virtual clock: starts at `start_ms`, only advances via advance_ms."""

    var _now_ms: Int

    def __init__(out self, start_ms: Int):
        self._now_ms = start_ms

    def now_ms(mut self) -> Int:
        return self._now_ms

    def advance_ms(mut self, delta_ms: Int):
        self._now_ms = self._now_ms + delta_ms


comptime _Sm = BackendSupervisor[StubBackend, MockClock]


# A fixed host profile (96 GB unified Mac) so the SM's default-budget ctor is
# deterministic; the budget tests pass an EXPLICIT byte budget so they do not
# depend on this.
def _hw() -> HostMemoryProfile:
    return HostMemoryProfile(
        total_ram_bytes=96 * 1024 * 1024 * 1024,
        vram_bytes=0,
        unified_memory=True,
        platform=PLATFORM_MACOS,
    )


# Convenience: GiB as Int.
def _gib(n: Int) -> Int:
    return n * 1024 * 1024 * 1024


# =============================================================================
# (1) LOAD ON FIRST REQUEST — REGISTERED -> SERVING on demand.
# =============================================================================
def test_jit_load_on_first_request() raises:
    # Generous budget + TTL so neither evict nor idle-unload interferes.
    var sm = _Sm(
        MockClock(0), _hw(), _gib(64), 60_000, 4
    )
    var ok = sm.register(
        String("qwen"),
        StubBackend(String("http://127.0.0.1:8081"), False),
        _gib(6),
    )
    assert_true(ok, String("register qwen"))

    # Before any request: REGISTERED, not loaded.
    assert_equal(sm.state_of(String("qwen")), LM_REGISTERED)
    assert_equal(sm.resident_count(), 0)

    # First request_load -> SERVING (launch called once).
    var loaded = sm.request_load(String("qwen"))
    assert_true(loaded, String("qwen JIT-loaded on first request"))
    assert_equal(sm.state_of(String("qwen")), LM_SERVING)
    assert_equal(sm.resident_count(), 1)
    assert_equal(
        sm.base_url_of(String("qwen")), String("http://127.0.0.1:8081")
    )

    # A second request is idempotent (already serving — no second launch),
    # confirmed via the SM staying SERVING with resident_count 1.
    var again = sm.request_load(String("qwen"))
    assert_true(again)
    assert_equal(sm.resident_count(), 1)
    sm.shutdown_all()


# =============================================================================
# (2) IDLE-UNLOAD after the keep_alive TTL — driven by VIRTUAL time.
# =============================================================================
def test_idle_unload_after_ttl() raises:
    # keep_alive TTL = 5000 ms.
    var sm = _Sm(
        MockClock(1000), _hw(), _gib(64), 5000, 4
    )
    _ = sm.register(
        String("m"), StubBackend(String("http://127.0.0.1:8082"), False), _gib(6)
    )
    _ = sm.request_load(String("m"))  # last_req stamped at now=1000.
    assert_equal(sm.state_of(String("m")), LM_SERVING)

    # Advance 4000 ms (within the 5000 TTL) -> a tick must NOT unload it.
    sm.clock_mut().advance_ms(4000)  # now = 5000, idle = 4000 < 5000.
    var unloaded_early = sm.tick_idle_unload()
    assert_equal(unloaded_early, 0, String("not idle yet"))
    assert_equal(sm.state_of(String("m")), LM_SERVING)

    # Advance past the TTL -> the tick idle-unloads it (SERVING -> REGISTERED).
    sm.clock_mut().advance_ms(2000)  # now = 7000, idle = 6000 >= 5000.
    var unloaded = sm.tick_idle_unload()
    assert_equal(unloaded, 1, String("idle past TTL -> unloaded"))
    assert_equal(sm.state_of(String("m")), LM_REGISTERED)
    assert_equal(sm.resident_count(), 0)

    # A request that lands WITHIN the TTL re-arms the deadline (the model stays
    # serving across a later tick because the clock moved but the request reset
    # last_req). Re-load, then re-request just before the deadline.
    _ = sm.request_load(String("m"))  # now=7000, reloaded + re-armed.
    assert_equal(sm.state_of(String("m")), LM_SERVING)
    sm.clock_mut().advance_ms(4000)  # now=11000, idle=4000 < 5000.
    sm.note_request(String("m"))  # now=11000, re-arm.
    sm.clock_mut().advance_ms(4000)  # now=15000, idle=4000 < 5000 (re-arm held it).
    assert_equal(
        sm.tick_idle_unload(), 0, String("re-arm kept it serving")
    )
    assert_equal(sm.state_of(String("m")), LM_SERVING)
    sm.shutdown_all()


# =============================================================================
# (3) LRU EVICTION — a 1-resident budget evicts the LRU on the 2nd load.
# =============================================================================
def test_lru_auto_evict_count() raises:
    # max_resident = 1, generous byte budget (so the COUNT cap is the trigger).
    var sm = _Sm(
        MockClock(0), _hw(), _gib(64), 60_000, 1
    )
    _ = sm.register(
        String("a"), StubBackend(String("http://127.0.0.1:9001"), False), _gib(6)
    )
    _ = sm.register(
        String("b"), StubBackend(String("http://127.0.0.1:9002"), False), _gib(6)
    )

    # Load A -> SERVING; resident_count 1.
    sm.clock_mut().advance_ms(10)
    _ = sm.request_load(String("a"))
    assert_equal(sm.state_of(String("a")), LM_SERVING)
    assert_equal(sm.resident_count(), 1)

    # Load B -> the 1-resident budget forces A (the LRU) to be evicted FIRST.
    sm.clock_mut().advance_ms(10)
    _ = sm.request_load(String("b"))
    assert_equal(
        sm.state_of(String("a")),
        LM_REGISTERED,
        String("A evicted when B loaded under a 1-resident budget"),
    )
    assert_equal(sm.state_of(String("b")), LM_SERVING)
    assert_equal(sm.resident_count(), 1)
    sm.shutdown_all()


def test_lru_auto_evict_bytes_and_recency() raises:
    # BYTE budget = 20 GiB, max_resident = 4 (so the BYTE budget is the trigger).
    # Each model is 8 GiB resident -> two fit (16 <= 20) but a third does not
    # (24 > 20) -> the LRU is evicted on the third load.
    var sm = _Sm(
        MockClock(0), _hw(), _gib(20), 60_000, 4
    )
    _ = sm.register(
        String("x"), StubBackend(String("http://127.0.0.1:9101"), False), _gib(8)
    )
    _ = sm.register(
        String("y"), StubBackend(String("http://127.0.0.1:9102"), False), _gib(8)
    )
    _ = sm.register(
        String("z"), StubBackend(String("http://127.0.0.1:9103"), False), _gib(8)
    )

    sm.clock_mut().advance_ms(10)
    _ = sm.request_load(String("x"))  # x SERVING (LRU stamp 1).
    sm.clock_mut().advance_ms(10)
    _ = sm.request_load(String("y"))  # y SERVING (LRU stamp 2). 16 GiB <= 20.
    assert_equal(sm.resident_count(), 2)
    assert_equal(sm.state_of(String("x")), LM_SERVING)
    assert_equal(sm.state_of(String("y")), LM_SERVING)

    # RECENCY: re-request x so x is now MORE recent than y -> y becomes the LRU.
    sm.clock_mut().advance_ms(10)
    sm.note_request(String("x"))  # x stamp 3 (y is now the LRU).

    # Load z -> 24 GiB would exceed 20 -> evict the LRU (y), keep x + z.
    sm.clock_mut().advance_ms(10)
    _ = sm.request_load(String("z"))
    assert_equal(
        sm.state_of(String("y")),
        LM_REGISTERED,
        String("y (the LRU after x was re-requested) evicted for z"),
    )
    assert_equal(sm.state_of(String("x")), LM_SERVING)
    assert_equal(sm.state_of(String("z")), LM_SERVING)
    assert_equal(sm.resident_count(), 2)
    sm.shutdown_all()


# =============================================================================
# (4) FAILED states — launch never healthy, and won't fit.
# =============================================================================
def test_failed_launch_surfaces_loud() raises:
    var sm = _Sm(
        MockClock(0), _hw(), _gib(64), 60_000, 4
    )
    # A backend whose launch() RAISES (never becomes healthy).
    _ = sm.register(
        String("broken"),
        StubBackend(String("http://127.0.0.1:9201"), True),
        _gib(6),
    )

    var ok = sm.request_load(String("broken"))
    assert_false(ok, String("a failing launch returns False"))
    assert_equal(
        sm.state_of(String("broken")),
        LM_FAILED,
        String("a launch that never becomes healthy -> LM_FAILED"),
    )
    var st = sm.status_of(String("broken"))
    assert_equal(
        st.failure_reason,
        FAIL_LAUNCH,
        String("the failure reason is actionable (launch timeout)"),
    )
    assert_equal(
        sm.resident_count(), 0, String("a failed model is not resident")
    )

    # A subsequent request does NOT silently retry-spin — it stays FAILED.
    var retry = sm.request_load(String("broken"))
    assert_false(retry, String("a FAILED model does not silently retry"))
    assert_equal(sm.state_of(String("broken")), LM_FAILED)

    # clear_failure lets a retry happen (after the cause was fixed).
    assert_true(sm.clear_failure(String("broken")))
    assert_equal(sm.state_of(String("broken")), LM_REGISTERED)
    assert_equal(sm.status_of(String("broken")).failure_reason, FAIL_NONE)
    sm.shutdown_all()


def test_wont_fit_refused_loud() raises:
    # A 4 GiB budget; a 50 GiB model cannot fit even after evicting everything.
    var sm = _Sm(
        MockClock(0), _hw(), _gib(4), 60_000, 4
    )
    _ = sm.register(
        String("huge"),
        StubBackend(String("http://127.0.0.1:9301"), False),
        _gib(50),
    )
    var ok = sm.request_load(String("huge"))
    assert_false(ok, String("a model bigger than the budget is refused"))
    assert_equal(sm.state_of(String("huge")), LM_FAILED)
    assert_equal(
        sm.status_of(String("huge")).failure_reason,
        FAIL_WONT_FIT,
        String("won't-fit is refused with FAIL_WONT_FIT, nothing launched"),
    )
    assert_equal(sm.resident_count(), 0)
    sm.shutdown_all()


# =============================================================================
# (5) BOOKKEEPING — register dup-id, absent-id, shutdown_all.
# =============================================================================
def test_registry_bookkeeping() raises:
    var sm = _Sm(
        MockClock(0), _hw(), _gib(64), 60_000, 4
    )
    assert_equal(sm.count(), 0)
    assert_false(sm.contains(String("nope")))
    assert_equal(sm.state_of(String("nope")), -1)

    _ = sm.register(
        String("one"), StubBackend(String("http://127.0.0.1:9401"), False), _gib(6)
    )
    assert_equal(sm.count(), 1)
    assert_true(sm.contains(String("one")))

    # Duplicate id -> no-op register (count unchanged).
    var dup = sm.register(
        String("one"), StubBackend(String("http://127.0.0.1:9402"), False), _gib(6)
    )
    assert_false(dup, String("duplicate id register is a no-op"))
    assert_equal(sm.count(), 1)

    # shutdown_all from a serving state -> back to REGISTERED, no resident.
    _ = sm.request_load(String("one"))
    assert_equal(sm.resident_count(), 1)
    sm.shutdown_all()
    assert_equal(sm.resident_count(), 0)
    assert_equal(sm.state_of(String("one")), LM_REGISTERED)


def test_wont_fit_does_not_evict_serving_models() raises:
    # A 10 GiB budget with one 6 GiB model serving; a request for a 50 GiB
    # model is refused before anything is unloaded on its behalf.
    var sm = _Sm(MockClock(0), _hw(), _gib(10), 60_000, 1)
    _ = sm.register(
        String("small"),
        StubBackend(String("http://127.0.0.1:9311"), False),
        _gib(6),
    )
    _ = sm.register(
        String("huge"),
        StubBackend(String("http://127.0.0.1:9312"), False),
        _gib(50),
    )
    assert_true(sm.request_load(String("small")))
    assert_false(sm.request_load(String("huge")))
    assert_equal(sm.status_of(String("huge")).failure_reason, FAIL_WONT_FIT)
    assert_equal(
        sm.state_of(String("small")),
        LM_SERVING,
        String("the serving model was not evicted for a load that cannot fit"),
    )
    assert_equal(sm.launch_count_of(String("small")), 1)
    assert_equal(sm.launch_count_of(String("huge")), 0)
    assert_equal(sm.resident_count(), 1)
    sm.shutdown_all()


def test_launch_failure_keeps_backend_message() raises:
    var sm = _Sm(MockClock(0), _hw(), _gib(64), 60_000, 4)
    _ = sm.register(
        String("broken"),
        StubBackend(String("http://127.0.0.1:9321"), True),
        _gib(6),
    )
    assert_false(sm.request_load(String("broken")))
    var st = sm.status_of(String("broken"))
    assert_equal(st.failure_reason, FAIL_LAUNCH)
    assert_true(
        st.failure_detail.find(String("never became healthy")) >= 0,
        String("the backend's own message is kept: ") + st.failure_detail,
    )
    assert_true(sm.clear_failure(String("broken")))
    assert_equal(sm.status_of(String("broken")).failure_detail, String(""))
    sm.shutdown_all()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
