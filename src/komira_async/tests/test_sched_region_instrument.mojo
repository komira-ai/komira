"""REUSABLE DECOMPOSITION INSTRUMENT — Mojo-side unit coverage.

Sibling of `test_sched_trace_counters.mojo`, covering the pieces that landed
with the region instrument: `SchedRegion`'s RAII contract, the OBSERVED nest
stack, the misnest refusal, the driver/worker TID partition and the in-band
occupancy arithmetic.

⚠ WHY `sched_trace_force_enable(True)` IS THE FIRST LINE OF EVERY TEST HERE.
`SchedRegion` gates every call on the cached `sched_trace_enabled()` flag, which
is off until `sched_trace_configure` arms it. WITHOUT the forced enable each
guard would silently no-op and every assertion below would read a zero that
means "tracing is off" — the exact vacuity shape that lets a broken mechanism
report green. The counter-primitive tests in the sibling file do not need it
because the raw FFI recorders are ungated; the RAII guard is not.

The DUMP TEXT — the printed partition, the closure line, the occupancy columns —
is not asserted here: this file is structurally blind to what is printed, so
a wrong printed ratio can pass every test below. Cover the dump separately by
compiling the C shim and checking its output.

Region field ids (must match the C getters):
  region: 0=wall_ns 1=self_ns 2=fork_ns 3=count 4=n 5=depth_max
          6=wall_ns_worker 7=self_ns_worker 8=count_worker
  health: 0=misnest 1=overflow 2=orphan 3=driver_samples 4=worker_samples
          5=root_id 6=open_depth(this thread)
"""

from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from komira_async.runtime.sched_trace import (
    PHASE_ENTRY_BIND,
    PHASE_PLAN_PREPARE,
    PHASE_QUERY_ROOT,
    PHASE_WALKER_DISPATCH,
    SITE_RESIDUAL_MARK_BUILD,
    SITE_RESIDUAL_MARK_STREAM,
    SchedRegion,
    sched_region,
    sched_region_adopt_driver,
    sched_region_enter,
    sched_region_exit,
    sched_region_health,
    sched_region_set_root,
    sched_trace_add_segment,
    sched_trace_add_segment_occ,
    sched_trace_force_enable,
    sched_trace_reset,
    sched_trace_site,
)


def _fresh():
    """Enable tracing deterministically and zero every counter. `reset` also
    adopts the calling thread as the driver, which is what routes the regions
    below into the DRIVER partition rather than the WORKER one."""
    sched_trace_force_enable(True)
    sched_trace_reset()
    sched_region_adopt_driver()


def test_region_self_ns_is_observed_not_declared() raises:
    """A 3-level nest: self_ns = wall - sum(children wall), measured from the
    stack. This is the property `_sched_phase_is_nested` — a hand-edited
    `return id == 11 || id == 12 || id == 19 || id == 22;` — only approximated,
    and it is what makes a partition possible at all.

        root 1000ms
          A   400ms
            B 150ms
          C   250ms
      self: B=150  A=250  C=250  root=350   sum == 1000 == root wall
    """
    _fresh()
    sched_region_set_root(PHASE_QUERY_ROOT)
    var r = sched_region_enter(PHASE_QUERY_ROOT)
    var a = sched_region_enter(PHASE_PLAN_PREPARE)
    var b = sched_region_enter(PHASE_ENTRY_BIND)
    sched_region_exit(PHASE_ENTRY_BIND, b, UInt64(150), UInt64(0), UInt64(15))
    sched_region_exit(PHASE_PLAN_PREPARE, a, UInt64(400), UInt64(0), UInt64(40))
    var c = sched_region_enter(PHASE_WALKER_DISPATCH)
    sched_region_exit(PHASE_WALKER_DISPATCH, c, UInt64(250), UInt64(90), UInt64(25))
    sched_region_exit(PHASE_QUERY_ROOT, r, UInt64(1000), UInt64(90), UInt64(0))

    assert_equal(sched_region(PHASE_ENTRY_BIND, Int32(1)), UInt64(150))
    assert_equal(sched_region(PHASE_PLAN_PREPARE, Int32(1)), UInt64(250))
    assert_equal(sched_region(PHASE_WALKER_DISPATCH, Int32(1)), UInt64(250))
    # The root's own self_ns IS the UNATTRIBUTED residue.
    assert_equal(sched_region(PHASE_QUERY_ROOT, Int32(1)), UInt64(350))

    # CLOSURE: the four self_ns values partition the root's wall exactly.
    var total = (
        sched_region(PHASE_ENTRY_BIND, Int32(1))
        + sched_region(PHASE_PLAN_PREPARE, Int32(1))
        + sched_region(PHASE_WALKER_DISPATCH, Int32(1))
        + sched_region(PHASE_QUERY_ROOT, Int32(1))
    )
    assert_equal(total, sched_region(PHASE_QUERY_ROOT, Int32(0)))
    # and the run is clean, so the partition is usable
    assert_equal(sched_region_health(Int32(0)), UInt64(0))  # misnest
    assert_equal(sched_region_health(Int32(2)), UInt64(0))  # orphan
    assert_equal(sched_region_health(Int32(6)), UInt64(0))  # stack fully unwound


def test_region_fork_exclusion() raises:
    """`fork_ns` is the fork->barrier span completed INSIDE the bracket, so
    `wall - fork` is the residue a parallelization could actually recover. A
    region that already forks internally has near-zero serial and nothing to
    recover — which is the difference between a lever and a distraction."""
    _fresh()
    var t = sched_region_enter(PHASE_WALKER_DISPATCH)
    sched_region_exit(PHASE_WALKER_DISPATCH, t, UInt64(200), UInt64(150), UInt64(0))
    assert_equal(sched_region(PHASE_WALKER_DISPATCH, Int32(0)), UInt64(200))
    assert_equal(sched_region(PHASE_WALKER_DISPATCH, Int32(2)), UInt64(150))


def test_misnest_is_detected_and_attributes_nothing() raises:
    """Mojo destroys at LAST USE, not scope end, so a region can close early.
    An out-of-order close must be DETECTED and attribute NOTHING — a plausible
    wrong partition is worse than no partition."""
    _fresh()
    sched_region_set_root(PHASE_QUERY_ROOT)
    var r = sched_region_enter(PHASE_QUERY_ROOT)
    var a = sched_region_enter(PHASE_PLAN_PREPARE)
    # close the OUTER region while the inner is still open
    sched_region_exit(PHASE_QUERY_ROOT, r, UInt64(1000), UInt64(0), UInt64(0))
    assert_equal(sched_region_health(Int32(0)), UInt64(1))  # misnest observed
    # and the bad close contributed NO wall
    assert_equal(sched_region(PHASE_QUERY_ROOT, Int32(0)), UInt64(0))
    assert_equal(sched_region(PHASE_QUERY_ROOT, Int32(3)), UInt64(0))
    _ = a


def test_schedregion_raii_records_on_scope_close() raises:
    """The RAII guard itself: constructing and dropping a `SchedRegion` must
    record exactly one sample with a non-zero wall, and leave the stack empty."""
    _fresh()
    sched_region_set_root(PHASE_QUERY_ROOT)
    var before = sched_region(PHASE_PLAN_PREPARE, Int32(3))
    # No scope block: `_ = g^` is what closes the region, and that is the point.
    # Relying on scope exit is exactly the ASAP-destruction hazard the guard
    # documents — Mojo would destroy at LAST USE, which is the assert below it.
    var g = SchedRegion(PHASE_PLAN_PREPARE, UInt64(7))
    assert_equal(sched_region_health(Int32(6)), UInt64(1))  # open on this thread
    # ⚠ THE REGION MUST CONTAIN TIME THE CLOCK CAN SEE. `SchedRegion` measures
    # with `perf_counter_ns()`; on macOS that clock's OBSERVABLE granularity is
    # coarser than the FFI call above, so without a spin `t1 - t0` can come back
    # 0 and fail the `> 0` wall assertion at the bottom of this test. Spinning until the clock ADVANCES asserts the intended claim — a
    # region that really elapsed records a non-zero wall — on any clock
    # granularity, instead of asserting that this machine's clock is fine
    # enough to see an empty scope. Bounded so a stopped clock fails the
    # assertion below rather than hanging.
    var _t0 = perf_counter_ns()
    var _spins = 0
    while perf_counter_ns() == _t0 and _spins < 10_000_000:
        _spins = _spins + 1
    _ = g^
    assert_equal(sched_region(PHASE_PLAN_PREPARE, Int32(3)), before + UInt64(1))
    assert_equal(sched_region_health(Int32(6)), UInt64(0))  # closed, stack empty
    assert_equal(sched_region_health(Int32(0)), UInt64(0))  # and cleanly
    assert_equal(sched_region(PHASE_PLAN_PREPARE, Int32(4)), UInt64(7))  # work unit
    assert_true(sched_region(PHASE_PLAN_PREPARE, Int32(0)) > UInt64(0))  # real wall


def test_schedregion_nests_through_raii() raises:
    """Two RAII guards must nest through the same observed stack the raw FFI
    uses, so the outer's self_ns excludes the inner's whole wall."""
    _fresh()
    var outer = SchedRegion(PHASE_QUERY_ROOT)
    var inner = SchedRegion(PHASE_WALKER_DISPATCH)
    assert_equal(sched_region_health(Int32(6)), UInt64(2))  # depth 2
    _ = inner^
    _ = outer^
    var ow = sched_region(PHASE_QUERY_ROOT, Int32(0))
    var os = sched_region(PHASE_QUERY_ROOT, Int32(1))
    var iw = sched_region(PHASE_WALKER_DISPATCH, Int32(0))
    assert_equal(sched_region_health(Int32(0)), UInt64(0))
    # the inner's wall is charged out of the outer's self
    assert_equal(os, ow - iw)
    assert_equal(sched_region(PHASE_WALKER_DISPATCH, Int32(5)), UInt64(2))  # depth_max


def test_set_n_carries_the_work_unit() raises:
    """A phase's WORK UNIT is usually known only at the END of the region. Run-to-run
    wall noise can exceed a small lever's effect, so such a lever is not
    decidable from timing in one sweep; `n` is exact and
    moves the instant a lever removes work."""
    _fresh()
    var g = SchedRegion(PHASE_WALKER_DISPATCH)
    g.set_n(UInt64(6001215))
    g.add_n(UInt64(85))
    _ = g^
    assert_equal(sched_region(PHASE_WALKER_DISPATCH, Int32(4)), UInt64(6001300))


def test_capacity_above_the_old_bounds() raises:
    """The pre-raise bounds were MAXPHASE 32 (ids 1-24 used, 7 free) and MAXSITE
    64 (53 labelled, 11 free). Both over-bound failures were SILENT: a phase id
    >= 32 returned 0 and dropped the sample; a site id >= 64 was CLAMPED into
    SITE_OTHER and attributed to the wrong row. A single mark join consumes
    3 sites, so the old namespaces had almost no headroom."""
    _fresh()
    var hi: UInt32 = 200  # above the old MAXPHASE
    var t = sched_region_enter(hi)
    assert_true(t != Int32(0))
    sched_region_exit(hi, t, UInt64(500), UInt64(0), UInt64(0))
    assert_equal(sched_region(hi, Int32(0)), UInt64(500))
    assert_equal(sched_region(hi, Int32(3)), UInt64(1))


def test_occupancy_reproduces_the_measured_mark_join_split() raises:
    """THE headline. "Site 52 forks 2 tasks onto 22 workers" used to need a
    hand-written, query-specific counter module. The same two numbers must now fall out of any
    fork for free.

    span_avg = busy_ns / span; occupancy = span_avg / tasks_per_fork.
    Site 51 uses the whole fan (22/22); site 52 uses 2 of 22 = 9%.

    Site fields: 0=fork_ns 3=task_sum 9=busy_ns 10=occ_span_ns 11=occ_count.
    """
    _fresh()
    var span = UInt64(20_000_000)  # 20 ms
    var busy_full = UInt64(22) * span
    var busy_two = UInt64(2) * span
    sched_trace_add_segment_occ(
        SITE_RESIDUAL_MARK_BUILD, UInt64(0), span, UInt64(22),
        UInt64(0), busy_full,
    )
    sched_trace_add_segment_occ(
        SITE_RESIDUAL_MARK_STREAM, span, span + span, UInt64(22),
        busy_full, busy_full + busy_two,
    )
    # BUILD: all 22 shards busy for the whole span
    assert_equal(sched_trace_site(SITE_RESIDUAL_MARK_BUILD, Int32(9)), busy_full)
    assert_equal(sched_trace_site(SITE_RESIDUAL_MARK_BUILD, Int32(10)), span)
    assert_equal(sched_trace_site(SITE_RESIDUAL_MARK_BUILD, Int32(11)), UInt64(1))
    # STREAM: 2 of 22 — the defect, in-band, with no per-cell code
    assert_equal(sched_trace_site(SITE_RESIDUAL_MARK_STREAM, Int32(9)), busy_two)
    assert_equal(sched_trace_site(SITE_RESIDUAL_MARK_STREAM, Int32(10)), span)
    # tasks POSTED is still 22 on both: posted != busy is the whole point
    assert_equal(sched_trace_site(SITE_RESIDUAL_MARK_BUILD, Int32(3)), UInt64(22))
    assert_equal(sched_trace_site(SITE_RESIDUAL_MARK_STREAM, Int32(3)), UInt64(22))


def test_no_occupancy_sample_is_distinguishable_from_idle() raises:
    """A site recorded through the LEGACY entry point carries no occupancy
    sample. That must be distinguishable from a genuinely idle fan: `occ_count`
    stays 0 so the dump prints -1, never 0.00, so a zero that means "no
    sample" is never read as idle."""
    _fresh()
    sched_trace_add_segment(
        SITE_RESIDUAL_MARK_BUILD, UInt64(0), UInt64(1000), UInt64(22))
    assert_equal(sched_trace_site(SITE_RESIDUAL_MARK_BUILD, Int32(0)), UInt64(1000))
    assert_equal(sched_trace_site(SITE_RESIDUAL_MARK_BUILD, Int32(11)), UInt64(0))
    assert_equal(sched_trace_site(SITE_RESIDUAL_MARK_BUILD, Int32(9)), UInt64(0))


def main() raises:
    test_region_self_ns_is_observed_not_declared()
    test_region_fork_exclusion()
    test_misnest_is_detected_and_attributes_nothing()
    test_schedregion_raii_records_on_scope_close()
    test_schedregion_nests_through_raii()
    test_set_n_carries_the_work_unit()
    test_capacity_above_the_old_bounds()
    test_occupancy_reproduces_the_measured_mark_join_split()
    test_no_occupancy_sample_is_distinguishable_from_idle()
    print("test_sched_region_instrument: OK")
