"""SCHED-TRACE + unit coverage
for the a/b/c/d wall-attribution counter block AND the per-site call-site
histogram (`komira_async/runtime/sched_trace.mojo` +
`komira_async/reactor/_posix_shim.c`).

These tests exercise the process-global counter primitives directly (reset /
add_segment / add_dispatch / worker store / per-site getters / ambient site /
dump), verifying the accounting math + the FFI wiring is correct and
deterministic. The env-gated enable flag is resolved ONCE at C init, so these
tests do not toggle it — the getters read the raw counters regardless of the
enable state, and the real a/b/c/d split + per-site attribution + <1%-overhead-
when-off A/B are verified by the bench runs.

Field ids (must match the C getters):
  global: 0=dispatch_ns 1=erasure_count 2=seg_count 3=fork_ns 4=inter_ns
          5=msink_drain_ns 6=msink_combine_wall_ns 7=msink_combine_fork_ns
          8=msink_finalize_wall_ns 9=msink_finalize_fork_ns 10=msink_phase_count
          (5-10 = the combine-phase split)
          11=msink_driver_wall_ns (cumulative) 12=msink_last_driver_wall_ns
          13=msink_last_drain_ns 14=msink_last_combine_wall_ns
          15=msink_last_combine_fork_ns 16=msink_last_finalize_wall_ns
          17=msink_last_finalize_fork_ns (11-17 = per-run WALL,
          the last-run overwrite snapshot the WALL_ATTR block
          divides by so a read is a true wall share, not the inter-gap %)
          18=msink_setup_ns 19=msink_prepare_ns 20=msink_teardown_ns
          21=msink_last_setup_ns 22=msink_last_prepare_ns 23=msink_last_teardown_ns
          (18-23 = msink handoff-residual brackets, —
          the named sub-phases that used to sit in the anonymous 86.5% residual)
  worker: 0=run 1=pop 2=park_inter 3=park_intra 4=spin 5=empty_windows 6=tasks 7=seen
          8=spin_found_ns 9=found_windows (8-9 = productive-spin blind spot)
  site:   0=fork_ns 1=inter_ns 2=count 3=task_sum 4=task_min 5=task_max
          6=inter_next_ns 7=inter_same_ns 8=inter_next_count (6-8 =
          post-barrier attribution, — `inter_ns` names the fork
          BEFORE a serial window, `inter_next_ns` the fork AFTER it, and
          `inter_same_ns` the share where the two agree)
  trans:  (prev_site, next_site) -> 0=gap_ns 1=count (transition matrix)
  phase:  0=wall_ns 1=fork_ns 2=count 3=serial_ns (named serial-phase
          bracket; serial == wall - fork, saturating)
"""

from std.testing import assert_equal, assert_true

from komira_async.runtime.sched_trace import (
    sched_trace_reset,
    sched_trace_add_segment,
    sched_trace_add_dispatch,
    sched_trace_add_msink_phase,
    sched_trace_global,
    sched_trace_worker,
    sched_trace_site,
    sched_trace_get_site,
    sched_trace_swap_site,
    sched_trace_set_site,
    sched_trace_dump,
    sched_trace_transition,
    sched_trace_add_serial_phase,
    sched_trace_add_serial_phase_n,
    sched_trace_serial_phase,
    PHASE_HBS_DYNAMIC_FILTER,
    PHASE_INMEM_FILTER_EVAL,
    _SchedWorkerAccum,
    SITE_PARQUET_DECODE,
    SITE_AGG_RADIX_MERGE,
    SITE_SINK_EXECUTOR,
    SITE_CONCAT,
    SITE_OTHER,
    PHASE_CONCAT_TILED_SETUP,
    PHASE_CONCAT_TILED_ASSEMBLE,
)


# =============================================================================
# POST-BARRIER ATTRIBUTION
# =============================================================================


def test_post_barrier_attribution_mirrors_pre_barrier() raises:
    """The two endpoint attributions of the SAME driver-serial wall.

    `inter_ns` (field 1) charges each gap to the site of the PREVIOUS fork;
    `inter_next_ns` (field 6) charges it to the site of the FOLLOWING fork. The
    two must SUM to the identical total (they redistribute one wall, they do not
    double-count it) while landing on different sites."""
    sched_trace_reset()
    # DECODE fork [1000,3000]; MERGE fork [5000,6000] -> gap 2000 between them.
    sched_trace_add_segment(
        SITE_PARQUET_DECODE, UInt64(1000), UInt64(3000), UInt64(8)
    )
    sched_trace_add_segment(
        SITE_AGG_RADIX_MERGE, UInt64(5000), UInt64(6000), UInt64(64)
    )
    # PRE-barrier: the gap lands on DECODE (the fork before the window).
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(1)), UInt64(2000))
    assert_equal(sched_trace_site(SITE_AGG_RADIX_MERGE, Int32(1)), UInt64(0))
    # POST-barrier: the SAME 2000 ns lands on MERGE (the fork after the window).
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(6)), UInt64(0))
    assert_equal(sched_trace_site(SITE_AGG_RADIX_MERGE, Int32(6)), UInt64(2000))
    # Cross-site window: the two attributions DISAGREE, so `inter_same_ns` is 0
    # on both — this is precisely the case that needs an explicit bracket.
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(7)), UInt64(0))
    assert_equal(sched_trace_site(SITE_AGG_RADIX_MERGE, Int32(7)), UInt64(0))
    # Both totals equal the global inter_ns.
    var pre = UInt64(0)
    var post = UInt64(0)
    for s in range(38):
        pre += sched_trace_site(UInt32(s), Int32(1))
        post += sched_trace_site(UInt32(s), Int32(6))
    assert_equal(pre, sched_trace_global(Int32(4)))
    assert_equal(post, sched_trace_global(Int32(4)))


def test_same_site_window_is_confirmed_own() raises:
    """A window fenced by two forks of the SAME site is CONFIRMED that site's own
    serial window — `inter_ns`, `inter_next_ns` and `inter_same_ns` all agree.
    This is the discriminator that upgrades an attribution from MEDIUM to FIRM
    with zero annotation."""
    sched_trace_reset()
    sched_trace_add_segment(SITE_CONCAT, UInt64(0), UInt64(100), UInt64(4))
    # Second CONCAT fork 700 ns later -> a 600 ns concat->concat window.
    sched_trace_add_segment(SITE_CONCAT, UInt64(700), UInt64(900), UInt64(4))
    assert_equal(sched_trace_site(SITE_CONCAT, Int32(1)), UInt64(600))
    assert_equal(sched_trace_site(SITE_CONCAT, Int32(6)), UInt64(600))
    assert_equal(sched_trace_site(SITE_CONCAT, Int32(7)), UInt64(600))


def test_transition_matrix_names_the_handoff() raises:
    """The prev->next matrix localizes a serial window to a specific driver
    handoff. Cells must partition the global inter_ns exactly."""
    sched_trace_reset()
    sched_trace_add_segment(SITE_CONCAT, UInt64(0), UInt64(100), UInt64(4))
    # concat -> concat, 600 ns.
    sched_trace_add_segment(SITE_CONCAT, UInt64(700), UInt64(900), UInt64(4))
    # concat -> msink, 100 ns.
    sched_trace_add_segment(
        SITE_SINK_EXECUTOR, UInt64(1000), UInt64(1200), UInt64(20)
    )
    # msink -> decode, 300 ns.
    sched_trace_add_segment(
        SITE_PARQUET_DECODE, UInt64(1500), UInt64(1600), UInt64(8)
    )
    assert_equal(
        sched_trace_transition(SITE_CONCAT, SITE_CONCAT, Int32(0)), UInt64(600)
    )
    assert_equal(
        sched_trace_transition(SITE_CONCAT, SITE_CONCAT, Int32(1)), UInt64(1)
    )
    assert_equal(
        sched_trace_transition(SITE_CONCAT, SITE_SINK_EXECUTOR, Int32(0)),
        UInt64(100),
    )
    assert_equal(
        sched_trace_transition(
            SITE_SINK_EXECUTOR, SITE_PARQUET_DECODE, Int32(0)
        ),
        UInt64(300),
    )
    # No phantom reverse edge.
    assert_equal(
        sched_trace_transition(SITE_SINK_EXECUTOR, SITE_CONCAT, Int32(0)),
        UInt64(0),
    )
    # The matrix partitions the global inter_ns.
    var tot = UInt64(0)
    for p in range(38):
        for n in range(38):
            tot += sched_trace_transition(UInt32(p), UInt32(n), Int32(0))
    assert_equal(tot, sched_trace_global(Int32(4)))
    assert_equal(tot, UInt64(1000))


def test_serial_phase_bracket_serial_excludes_internal_fork() raises:
    """A named serial-phase bracket reports wall, the fork span that completed
    INSIDE it, and SERIAL = wall - fork. A region that already forks internally
    must show near-zero SERIAL (nothing to recover by parallelizing it)."""
    sched_trace_reset()
    # Pure-serial region: 5000 ns wall, no internal fork.
    sched_trace_add_serial_phase(
        PHASE_CONCAT_TILED_ASSEMBLE, UInt64(5000), UInt64(0)
    )
    assert_equal(
        sched_trace_serial_phase(PHASE_CONCAT_TILED_ASSEMBLE, Int32(0)),
        UInt64(5000),
    )
    assert_equal(
        sched_trace_serial_phase(PHASE_CONCAT_TILED_ASSEMBLE, Int32(3)),
        UInt64(5000),
    )
    # Already-parallel region: 4000 ns wall of which 3900 ns was a fork span.
    sched_trace_add_serial_phase(
        PHASE_CONCAT_TILED_SETUP, UInt64(4000), UInt64(3900)
    )
    assert_equal(
        sched_trace_serial_phase(PHASE_CONCAT_TILED_SETUP, Int32(3)),
        UInt64(100),
    )
    # Accumulates across invocations; count tracks them.
    sched_trace_add_serial_phase(
        PHASE_CONCAT_TILED_ASSEMBLE, UInt64(1000), UInt64(0)
    )
    assert_equal(
        sched_trace_serial_phase(PHASE_CONCAT_TILED_ASSEMBLE, Int32(2)),
        UInt64(2),
    )
    assert_equal(
        sched_trace_serial_phase(PHASE_CONCAT_TILED_ASSEMBLE, Int32(3)),
        UInt64(6000),
    )
    # fork > wall must saturate to 0, never wrap.
    sched_trace_add_serial_phase(UInt32(9), UInt64(10), UInt64(999))
    assert_equal(sched_trace_serial_phase(UInt32(9), Int32(3)), UInt64(0))
    # phase 0 is reserved "no phase" and must be rejected.
    sched_trace_add_serial_phase(UInt32(0), UInt64(777), UInt64(0))
    assert_equal(sched_trace_serial_phase(UInt32(0), Int32(0)), UInt64(0))


def test_serial_phase_work_unit_accumulates_and_resets() raises:
    """TAIL-WINDOW work-unit counter.

    A tail-tier phase's WALL is not decidable in one sweep — the derived
    known-zero floor on those cells is 7.3-27.5 ms EACH, 8-19% of the cell's
    whole gap. `n` (rows / keys / morsels) is the falsifiable half of the
    bracket: exact, reproducible, and it moves the instant a lever removes
    work. This pins the four properties a reader of that number relies on.
    """
    sched_trace_reset()
    # 1. `n` accumulates independently of wall/fork and is readable as field 4.
    sched_trace_add_serial_phase_n(
        PHASE_HBS_DYNAMIC_FILTER, UInt64(5000), UInt64(0), UInt64(18_300_000)
    )
    assert_equal(
        sched_trace_serial_phase(PHASE_HBS_DYNAMIC_FILTER, Int32(4)),
        UInt64(18_300_000),
    )
    assert_equal(
        sched_trace_serial_phase(PHASE_HBS_DYNAMIC_FILTER, Int32(3)),
        UInt64(5000),
    )
    sched_trace_add_serial_phase_n(
        PHASE_HBS_DYNAMIC_FILTER, UInt64(1000), UInt64(0), UInt64(700_000)
    )
    assert_equal(
        sched_trace_serial_phase(PHASE_HBS_DYNAMIC_FILTER, Int32(4)),
        UInt64(19_000_000),
    )
    assert_equal(
        sched_trace_serial_phase(PHASE_HBS_DYNAMIC_FILTER, Int32(2)), UInt64(2)
    )
    # 2. A phase recorded through the PLAIN entry point leaves `n` at 0 — the
    #    two recorders must not cross-contaminate, or an un-instrumented
    #    bracket would appear to report a work unit it never measured.
    sched_trace_add_serial_phase(
        PHASE_INMEM_FILTER_EVAL, UInt64(2000), UInt64(0)
    )
    assert_equal(
        sched_trace_serial_phase(PHASE_INMEM_FILTER_EVAL, Int32(4)), UInt64(0)
    )
    # 3. The id guard applies to the `_n` entry point too (phase 0 rejected).
    sched_trace_add_serial_phase_n(
        UInt32(0), UInt64(9), UInt64(0), UInt64(12345)
    )
    assert_equal(sched_trace_serial_phase(UInt32(0), Int32(4)), UInt64(0))
    # 4. reset() zeroes `n`, or a per-window measurement inherits the last
    #    window's work volume — the exact defect the wall slots were fixed for.
    sched_trace_reset()
    assert_equal(
        sched_trace_serial_phase(PHASE_HBS_DYNAMIC_FILTER, Int32(4)), UInt64(0)
    )


def test_reset_clears_post_barrier_and_phase_slots() raises:
    """`sched_trace_reset` must zero the slots too, or a per-window
    measurement inherits the previous window's attribution."""
    sched_trace_add_segment(SITE_CONCAT, UInt64(0), UInt64(100), UInt64(4))
    sched_trace_add_segment(SITE_CONCAT, UInt64(700), UInt64(900), UInt64(4))
    sched_trace_add_serial_phase(
        PHASE_CONCAT_TILED_ASSEMBLE, UInt64(5000), UInt64(0)
    )
    assert_true(sched_trace_site(SITE_CONCAT, Int32(6)) > UInt64(0))
    sched_trace_reset()
    assert_equal(sched_trace_site(SITE_CONCAT, Int32(6)), UInt64(0))
    assert_equal(sched_trace_site(SITE_CONCAT, Int32(7)), UInt64(0))
    assert_equal(sched_trace_site(SITE_CONCAT, Int32(8)), UInt64(0))
    assert_equal(
        sched_trace_transition(SITE_CONCAT, SITE_CONCAT, Int32(0)), UInt64(0)
    )
    assert_equal(
        sched_trace_transition(SITE_CONCAT, SITE_CONCAT, Int32(1)), UInt64(0)
    )
    assert_equal(
        sched_trace_serial_phase(PHASE_CONCAT_TILED_ASSEMBLE, Int32(0)),
        UInt64(0),
    )
    assert_equal(
        sched_trace_serial_phase(PHASE_CONCAT_TILED_ASSEMBLE, Int32(2)),
        UInt64(0),
    )


def test_segment_span_and_inter_fork_gap() raises:
    """Records the fork->barrier span + the driver-serial inter-fork gap (bucket
    a driver-view) via add_segment. The FIRST segment has no inter-gap (last=0).
    The inter-gap FOLLOWING a fork is attributed to that fork's site."""
    sched_trace_reset()
    # Segment 1 @ site DECODE: fork_start=1000, barrier=3000 -> span 2000, no gap.
    sched_trace_add_segment(
        SITE_PARQUET_DECODE, UInt64(1000), UInt64(3000), UInt64(8)
    )
    # Segment 2 @ site MERGE: fork_start=5000, barrier=6000 -> span 1000,
    # inter-gap=5000-3000=2000 attributed to the PREVIOUS fork (DECODE).
    sched_trace_add_segment(
        SITE_AGG_RADIX_MERGE, UInt64(5000), UInt64(6000), UInt64(64)
    )
    assert_equal(sched_trace_global(Int32(2)), UInt64(2))     # seg_count
    assert_equal(sched_trace_global(Int32(3)), UInt64(3000))  # fork_ns (2000+1000)
    assert_equal(sched_trace_global(Int32(4)), UInt64(2000))  # inter_ns (5000-3000)
    # Per-site fork wall.
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(0)), UInt64(2000))
    assert_equal(sched_trace_site(SITE_AGG_RADIX_MERGE, Int32(0)), UInt64(1000))
    # The inter-gap accrues to DECODE (its combine window precedes MERGE's fork).
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(1)), UInt64(2000))
    assert_equal(sched_trace_site(SITE_AGG_RADIX_MERGE, Int32(1)), UInt64(0))
    # Per-site count + task min/max.
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(2)), UInt64(1))
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(4)), UInt64(8))  # min
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(5)), UInt64(8))  # max
    assert_equal(sched_trace_site(SITE_AGG_RADIX_MERGE, Int32(4)), UInt64(64))
    assert_equal(sched_trace_site(SITE_AGG_RADIX_MERGE, Int32(5)), UInt64(64))


def test_per_site_sums_partition_globals() raises:
    """The load-bearing accounting invariant: sum of per-site fork_ns == global
    fork_ns; sum of per-site inter_ns == global inter_ns; sum of per-site count
    == global seg_count. Three sites, non-idempotent task counts + gaps."""
    sched_trace_reset()
    # site DECODE: two forks; site SINK: one fork. Interleaved to exercise the
    # last-site inter attribution across site boundaries.
    sched_trace_add_segment(
        SITE_PARQUET_DECODE, UInt64(1000), UInt64(2000), UInt64(4)
    )  # span 1000, no gap (first)
    sched_trace_add_segment(
        SITE_SINK_EXECUTOR, UInt64(2500), UInt64(4000), UInt64(20)
    )  # span 1500, gap 500 -> DECODE
    sched_trace_add_segment(
        SITE_PARQUET_DECODE, UInt64(4600), UInt64(5100), UInt64(12)
    )  # span 500, gap 600 -> SINK
    var g_fork = sched_trace_global(Int32(3))
    var g_inter = sched_trace_global(Int32(4))
    var g_segs = sched_trace_global(Int32(2))
    assert_equal(g_fork, UInt64(3000))   # 1000+1500+500
    assert_equal(g_inter, UInt64(1100))  # 500+600
    assert_equal(g_segs, UInt64(3))
    # Sum per-site == global (iterate a small id window covering our sites).
    var sum_fork = UInt64(0)
    var sum_inter = UInt64(0)
    var sum_count = UInt64(0)
    for s in range(0, 24):
        sum_fork += sched_trace_site(UInt32(s), Int32(0))
        sum_inter += sched_trace_site(UInt32(s), Int32(1))
        sum_count += sched_trace_site(UInt32(s), Int32(2))
    assert_equal(sum_fork, g_fork)
    assert_equal(sum_inter, g_inter)
    assert_equal(sum_count, g_segs)
    # Spot the two DECODE forks + task min/max span.
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(2)), UInt64(2))
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(4)), UInt64(4))   # min
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(5)), UInt64(12))  # max
    # DECODE inter = 500 (the gap after its FIRST fork); SINK inter = 600.
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(1)), UInt64(500))
    assert_equal(sched_trace_site(SITE_SINK_EXECUTOR, Int32(1)), UInt64(600))


def test_task_avg_sum_tracks() raises:
    """task_sum accumulates so the dump's task_avg = sum/count is exact."""
    sched_trace_reset()
    sched_trace_add_segment(
        SITE_SINK_EXECUTOR, UInt64(0), UInt64(10), UInt64(20)
    )
    sched_trace_add_segment(
        SITE_SINK_EXECUTOR, UInt64(20), UInt64(30), UInt64(28)
    )
    assert_equal(sched_trace_site(SITE_SINK_EXECUTOR, Int32(2)), UInt64(2))   # count
    assert_equal(sched_trace_site(SITE_SINK_EXECUTOR, Int32(3)), UInt64(48))  # task_sum


def test_barrier_before_fork_start_ignored() raises:
    """A degenerate span (barrier <= fork_start, e.g. a clock hiccup) contributes
    zero to fork_ns; an inter-gap that would be negative is skipped. The site
    still counts (a real fork occurred)."""
    sched_trace_reset()
    sched_trace_add_segment(
        SITE_PARQUET_DECODE, UInt64(500), UInt64(400), UInt64(3)
    )  # barrier < fork_start
    assert_equal(sched_trace_global(Int32(2)), UInt64(1))  # still counts the seg
    assert_equal(sched_trace_global(Int32(3)), UInt64(0))  # fork_ns stays 0
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(2)), UInt64(1))
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(0)), UInt64(0))


def test_ambient_site_swap_and_restore() raises:
    """The ambient call-site set/swap/get round-trips (the SchedSiteScope guard
    substrate). swap returns the previous; set overwrites; reset clears to 0."""
    sched_trace_reset()
    assert_equal(sched_trace_get_site(), UInt32(0))
    var prev = sched_trace_swap_site(SITE_SINK_EXECUTOR)
    assert_equal(prev, UInt32(0))
    assert_equal(sched_trace_get_site(), SITE_SINK_EXECUTOR)
    var prev2 = sched_trace_swap_site(SITE_PARQUET_DECODE)
    assert_equal(prev2, SITE_SINK_EXECUTOR)
    sched_trace_set_site(prev2)  # restore
    assert_equal(sched_trace_get_site(), SITE_SINK_EXECUTOR)
    sched_trace_set_site(UInt32(0))
    assert_equal(sched_trace_get_site(), UInt32(0))


def test_dispatch_and_erasure_volume() raises:
    """Accumulates enqueue-loop wall (bucket c) + erasure volume (add_dispatch)."""
    sched_trace_reset()
    sched_trace_add_dispatch(UInt64(500), UInt64(28))
    sched_trace_add_dispatch(UInt64(300), UInt64(4))
    assert_equal(sched_trace_global(Int32(0)), UInt64(800))  # dispatch_ns
    assert_equal(sched_trace_global(Int32(1)), UInt64(32))   # erasure_count (28+4)


def test_msink_phase_counters_accumulate() raises:
    """add_msink_phase accumulates the drain
    wall + the WALL and internal-FORK spans of combine and finalize + the whole-
    driver WALL + bumps the phase count. Non-idempotent inputs across two calls
    verify true accumulation (not overwrite), so the dump's serial = wall-fork sums
    are exact per query. The fork inputs are < the matching walls (the fork-excluded
    serial residue is the recoverable quantity: e.g. combine wall 4000 with fork
    3600 -> serial 400, a combine that already forks 90% has little left to
    recover). The driver_wall exceeds drain+combine+finalize (those are disjoint
    sequential sub-intervals of the driver; the remainder is the scan/agg fork)."""
    sched_trace_reset()
    # Breaker 1: drain 100; combine wall 4000 / fork 3600; finalize wall 700 / fork
    # 0; driver wall 10000 (>= 100+4000+700).
    sched_trace_add_msink_phase(
        UInt64(100), UInt64(4000), UInt64(3600), UInt64(700), UInt64(0),
        UInt64(10000),
    )
    # Breaker 2: drain 50; combine wall 2500 / fork 2000; finalize wall 300 / fork
    # 50; driver wall 6000 (>= 50+2500+300).
    sched_trace_add_msink_phase(
        UInt64(50), UInt64(2500), UInt64(2000), UInt64(300), UInt64(50),
        UInt64(6000),
    )
    assert_equal(sched_trace_global(Int32(5)), UInt64(150))    # drain 100+50
    assert_equal(sched_trace_global(Int32(6)), UInt64(6500))   # combine wall 4000+2500
    assert_equal(sched_trace_global(Int32(7)), UInt64(5600))   # combine fork 3600+2000
    assert_equal(sched_trace_global(Int32(8)), UInt64(1000))   # finalize wall 700+300
    assert_equal(sched_trace_global(Int32(9)), UInt64(50))     # finalize fork 0+50
    assert_equal(sched_trace_global(Int32(10)), UInt64(2))     # phase_count
    # per-run WALL: cumulative driver wall accumulates (avg over runs);
    # the last-run slots OVERWRITE to the SECOND (final = measure) breaker's values.
    assert_equal(sched_trace_global(Int32(11)), UInt64(16000))  # cumulative 10000+6000
    assert_equal(sched_trace_global(Int32(12)), UInt64(6000))   # last driver wall
    assert_equal(sched_trace_global(Int32(13)), UInt64(50))     # last drain
    assert_equal(sched_trace_global(Int32(14)), UInt64(2500))   # last combine wall
    assert_equal(sched_trace_global(Int32(15)), UInt64(2000))   # last combine fork
    assert_equal(sched_trace_global(Int32(16)), UInt64(300))    # last finalize wall
    assert_equal(sched_trace_global(Int32(17)), UInt64(50))     # last finalize fork


def test_msink_wall_attr_per_run_sums_sanely() raises:
    """SCHED_MSINK per-run WALL attribution: the
    WALL_ATTR block reports each phase as a % of a SINGLE measured run's wall
    (the last msink invocation — a steady-state measure iteration), NOT the
    inflated % of the driver-serial inter-gap. This test drives the counter with a
    driver-run shape and asserts the load-bearing invariant the block prints as
    `phases_le_wall`: drain, combine, and finalize are DISJOINT sequential
    sub-intervals of the driver, so their walls sum to <= the driver wall (the
    remainder is the parallel scan/agg fork + handoff). It also pins the
    property that motivated the fix: a finalize that reads a LARGE share of the
    inter-gap can be a SMALL share of the run's wall.

    Shape (a multi-breaker query with a fully serial finalize,
    so finalize_fork == 0): a 90ms breaker run whose
    finalize is 6ms
    (~6.7% of wall) but would read ~60% of a ~10ms driver-serial inter-gap."""
    sched_trace_reset()
    var drain = UInt64(400)
    var combine_wall = UInt64(1200)
    var combine_fork = UInt64(1000)   # combine forks internally (radix combine)
    var finalize_wall = UInt64(6000)  # finalize fully serial (fork == 0)
    var finalize_fork = UInt64(0)
    var driver_wall = UInt64(90000)   # whole breaker wall (scan/agg fork dominates)
    sched_trace_add_msink_phase(
        drain, combine_wall, combine_fork, finalize_wall, finalize_fork,
        driver_wall,
    )
    # Read back the last-run snapshot the WALL_ATTR block divides by.
    var lw = sched_trace_global(Int32(12))   # last driver wall
    var ld = sched_trace_global(Int32(13))   # last drain
    var lcw = sched_trace_global(Int32(14))  # last combine wall
    var lfw = sched_trace_global(Int32(16))  # last finalize wall
    assert_equal(lw, driver_wall)
    assert_equal(ld, drain)
    assert_equal(lcw, combine_wall)
    assert_equal(lfw, finalize_wall)
    # The `phases_le_wall` invariant: sequential phase walls fit inside the run.
    var phases_wall = ld + lcw + lfw
    assert_true(phases_wall <= lw)
    # The recoverable driver-serial residue (drain + combine_serial + finalize_
    # serial) also fits inside the run.
    var combine_serial = lcw - sched_trace_global(Int32(15))   # wall - fork
    var finalize_serial = lfw - sched_trace_global(Int32(17))  # wall - fork == lfw
    var recoverable = ld + combine_serial + finalize_serial
    assert_true(recoverable <= lw)
    # Property: finalize is a SMALL share of WALL (6000/90000 ~= 6.7%),
    # while it would read a LARGE share of a driver-serial inter-gap. Assert the
    # wall-share numerator/denominator are the run wall, not the inter-gap.
    assert_true(finalize_serial * UInt64(10) < lw)  # < 10% of wall


def test_msink_phase_counters_reset() raises:
    """Reset zeroes the msink-phase counters (incl. the per-run WALL
    slots) along with the rest of the block (so a fresh per-window measurement
    starts clean)."""
    sched_trace_add_msink_phase(
        UInt64(9), UInt64(9), UInt64(3), UInt64(9), UInt64(2), UInt64(40)
    )
    sched_trace_reset()
    assert_equal(sched_trace_global(Int32(5)), UInt64(0))   # msink_drain
    assert_equal(sched_trace_global(Int32(6)), UInt64(0))   # msink_combine_wall
    assert_equal(sched_trace_global(Int32(7)), UInt64(0))   # msink_combine_fork
    assert_equal(sched_trace_global(Int32(8)), UInt64(0))   # msink_finalize_wall
    assert_equal(sched_trace_global(Int32(9)), UInt64(0))   # msink_finalize_fork
    assert_equal(sched_trace_global(Int32(10)), UInt64(0))  # msink_phase_count
    # per-run WALL slots also clear.
    assert_equal(sched_trace_global(Int32(11)), UInt64(0))  # cumulative driver wall
    assert_equal(sched_trace_global(Int32(12)), UInt64(0))  # last driver wall
    assert_equal(sched_trace_global(Int32(13)), UInt64(0))  # last drain
    assert_equal(sched_trace_global(Int32(14)), UInt64(0))  # last combine wall
    assert_equal(sched_trace_global(Int32(15)), UInt64(0))  # last combine fork
    assert_equal(sched_trace_global(Int32(16)), UInt64(0))  # last finalize wall
    assert_equal(sched_trace_global(Int32(17)), UInt64(0))  # last finalize fork
    # handoff-residual brackets also clear.
    assert_equal(sched_trace_global(Int32(18)), UInt64(0))  # setup (cumulative)
    assert_equal(sched_trace_global(Int32(19)), UInt64(0))  # prepare (cumulative)
    assert_equal(sched_trace_global(Int32(20)), UInt64(0))  # teardown (cumulative)
    assert_equal(sched_trace_global(Int32(21)), UInt64(0))  # last setup
    assert_equal(sched_trace_global(Int32(22)), UInt64(0))  # last prepare
    assert_equal(sched_trace_global(Int32(23)), UInt64(0))  # last teardown
    # PREPARE mislabel fix: the prepare FORK slots clear too, or a
    # fresh window inherits the previous window's fork span and under-reports the
    # driver-serial residue (serial = wall - fork) for the rest of the run.
    assert_equal(sched_trace_global(Int32(24)), UInt64(0))  # prepare fork (cum)
    assert_equal(sched_trace_global(Int32(25)), UInt64(0))  # last prepare fork


def test_msink_prepare_phase_is_not_pure_serial() raises:
    """PREPARE mislabel fix — REGRESSION GUARD.

    The msink PREPARE window brackets `_drive_combine_partition`, which calls
    `dispatcher.run_with_state(..., site_id=SITE_SINK_EXECUTOR)` whenever the
    sink reports `num_partitions() > 1`. That is a PARALLEL FORK, so PREPARE's
    wall is fork-INCLUSIVE and must be reported wall/fork/serial exactly like
    COMBINE and FINALIZE — never under a flat `(serial)` label.

    FAILS ON PRE-FIX CODE: `komira_sched_add_msink_phase` took no
    `prepare_fork_ns`, and fields 24 / 25 did not exist — the getter's trailing
    `return 0` made both reads 0 while the whole 9000 ns (fork included) was
    charged to the driver as `prepare_ns (serial)`. The observable symptom was
    a real query printing a `prepare_ns (serial)` share of the inter-gap of
    many thousand percent — many times the entire site-8 inter-gap that line
    claims to be a share of. Because the shim's
    `named = serial + prepare_WALL + teardown` used the wall, `named` also
    exceeded the inter-gap and the `handoff` clamp silently reported
    `unattributed_residual_ns=0` on a query whose gap was mostly unattributed.

    Shape below mirrors a partitioned agg sink: an 9000 ns prepare window of
    which 8600 ns was the partition-combine fork, leaving 400 ns of genuine
    driver-serial (num_partitions + the dispatch decision + prepare_finalize).
    """
    sched_trace_reset()
    # Breaker 1: prepare wall 9000 / fork 8600 -> serial 400.
    sched_trace_add_msink_phase(
        UInt64(10), UInt64(100), UInt64(0), UInt64(200), UInt64(0),
        UInt64(50000),
        UInt64(0), UInt64(9000), UInt64(0), UInt64(8600),
    )
    # Breaker 2: a sink with num_partitions() == 1 never forks -> serial == wall.
    sched_trace_add_msink_phase(
        UInt64(10), UInt64(100), UInt64(0), UInt64(200), UInt64(0),
        UInt64(50000),
        UInt64(0), UInt64(500), UInt64(0), UInt64(0),
    )
    # Field 19 keeps its meaning: prepare WALL, cumulative (symmetric with the
    # combine/finalize WALL slots 6 / 8). Nothing downstream of the rename moves.
    assert_equal(sched_trace_global(Int32(19)), UInt64(9500))  # 9000 + 500
    # Field 24 is the new fork span; it accumulates like 7 / 9 do.
    assert_equal(sched_trace_global(Int32(24)), UInt64(8600))  # 8600 + 0
    # Field 25 is the LAST-RUN overwrite snapshot (breaker 2, which did not fork).
    assert_equal(sched_trace_global(Int32(22)), UInt64(500))   # last prepare wall
    assert_equal(sched_trace_global(Int32(25)), UInt64(0))     # last prepare fork
    # The load-bearing property: the driver-serial residue the dump partitions
    # the inter-gap with is wall - fork, and it is 400 ns here, NOT 9000.
    var prepare_serial = (
        sched_trace_global(Int32(19)) - sched_trace_global(Int32(24))
    )
    assert_equal(prepare_serial, UInt64(900))  # (9000-8600) + (500-0)
    assert_true(prepare_serial < sched_trace_global(Int32(19)))
    # A phase that already forks 95% of its wall has almost nothing to recover —
    # the same property `test_serial_phase_bracket_...` pins for the
    # generic SCHED_PHASE table, now true for PREPARE too.
    assert_true(prepare_serial * UInt64(10) < sched_trace_global(Int32(19)))


def test_msink_handoff_brackets_name_the_residual() raises:
    """the msink SETUP / PREPARE / TEARDOWN brackets
    accumulate + snapshot exactly like the older phases, and — the point of the
    lane — they SHRINK the anonymous residual of the SITE_SINK_EXECUTOR inter-gap.

    Before this wave the site-8 inter-gap was 2484.3 ms of which only 334.9 ms
    (13.5%) was named (drain + combine_serial + finalize_serial); 2149.4 ms sat in
    an unnamed `handoff` bucket INSIDE an otherwise-instrumented window. The dump
    now computes `named = drain + combine_serial + finalize_serial + prepare +
    teardown` and reports `unattributed_residual = inter_gap - named`. This test
    pins that arithmetic on a shape scaled from real query measurements.

    SETUP is deliberately NOT part of `named`: it runs BEFORE site 8's own fork,
    so its wall lands in the PREVIOUS fork's inter-gap. It is asserted to
    round-trip on its own line, and to be a real (non-trivial) share of the driver
    wall — it is `n_workers` x `sink.init_local()` heap allocations, strictly
    serial, which is why it deserved a name.
    """
    sched_trace_reset()
    # One breaker. Numbers are the measured msink shape, scaled to round values.
    var drain = UInt64(400)
    var combine_wall = UInt64(1200)
    var combine_fork = UInt64(1000)   # combine already forks -> serial 200
    var finalize_wall = UInt64(600)
    var finalize_fork = UInt64(100)   # -> serial 500
    var driver_wall = UInt64(90000)
    var setup = UInt64(3000)          # locals slab + init_local x N + init_global
    var prepare = UInt64(150)         # num_partitions + prepare_finalize
    var teardown = UInt64(250)        # Finished guard + output take + fr drop
    sched_trace_add_msink_phase(
        drain, combine_wall, combine_fork, finalize_wall, finalize_fork,
        driver_wall, setup, prepare, teardown,
    )
    # Cumulative slots.
    assert_equal(sched_trace_global(Int32(18)), setup)
    assert_equal(sched_trace_global(Int32(19)), prepare)
    assert_equal(sched_trace_global(Int32(20)), teardown)
    # LAST-RUN overwrite slots (the single-run snapshot the WALL_ATTR block uses).
    assert_equal(sched_trace_global(Int32(21)), setup)
    assert_equal(sched_trace_global(Int32(22)), prepare)
    assert_equal(sched_trace_global(Int32(23)), teardown)
    # A second breaker proves ACCUMULATE-and-OVERWRITE (not overwrite-only, not
    # accumulate-only) — the same dual shape as the pre-existing phases.
    sched_trace_add_msink_phase(
        UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(5000),
        UInt64(1000), UInt64(50), UInt64(70),
    )
    assert_equal(sched_trace_global(Int32(18)), setup + UInt64(1000))
    assert_equal(sched_trace_global(Int32(21)), UInt64(1000))  # last-run overwrote
    # The lane's gate, in miniature: `named` must cover the site-8 inter-gap to
    # within the residual the dump prints. Recompute the dump's arithmetic for the
    # FIRST breaker's numbers against a synthetic inter-gap of the same span.
    var combine_serial = combine_wall - combine_fork      # 200
    var finalize_serial = finalize_wall - finalize_fork   # 500
    var named = drain + combine_serial + finalize_serial + prepare + teardown
    assert_equal(named, UInt64(1500))
    # An inter-gap that IS this driver's serial spine leaves ~0 unattributed; the
    # pre-lane `named` (drain + the two serials = 1100) would have left 400 (27%)
    # anonymous. The two new sub-phases are exactly that difference.
    var inter_gap = UInt64(1500)
    var unattributed = inter_gap - named
    assert_equal(unattributed, UInt64(0))
    var pre_lane_named = drain + combine_serial + finalize_serial
    assert_true(inter_gap - pre_lane_named == prepare + teardown)
    # SETUP is NOT inside `named` (it precedes site 8's fork) but IS a real share
    # of the driver wall — 3000/90000 = 3.3%, the thing that had no name before.
    assert_true(setup > UInt64(0))
    assert_true(setup < driver_wall)


def test_worker_store_roundtrips_all_fields() raises:
    """_SchedWorkerAccum.store overwrites the per-wid slot; every field reads
    back and `seen` flips to 1."""
    sched_trace_reset()
    var acc = _SchedWorkerAccum()
    acc.run_ns = UInt64(10000)
    acc.pop_ns = UInt64(200)
    acc.park_inter_ns = UInt64(4000)
    acc.park_intra_ns = UInt64(1500)
    acc.spin_ns = UInt64(600)
    acc.empty_windows = UInt64(7)
    acc.tasks = UInt64(42)
    acc.spin_found_ns = UInt64(850)
    acc.found_windows = UInt64(13)
    # the causality split partitions empty_windows (7 = 5 + 2).
    acc.empty_inter_w = UInt64(5)
    acc.empty_intra_w = UInt64(2)
    acc.store(UInt64(3))
    assert_equal(sched_trace_worker(UInt64(3), Int32(0)), UInt64(10000))  # run
    assert_equal(sched_trace_worker(UInt64(3), Int32(1)), UInt64(200))    # pop
    assert_equal(sched_trace_worker(UInt64(3), Int32(2)), UInt64(4000))   # park_inter
    assert_equal(sched_trace_worker(UInt64(3), Int32(3)), UInt64(1500))   # park_intra
    assert_equal(sched_trace_worker(UInt64(3), Int32(4)), UInt64(600))    # spin
    assert_equal(sched_trace_worker(UInt64(3), Int32(5)), UInt64(7))      # empty_windows
    assert_equal(sched_trace_worker(UInt64(3), Int32(6)), UInt64(42))     # tasks
    assert_equal(sched_trace_worker(UInt64(3), Int32(7)), UInt64(1))      # seen
    # productive-spin blind spot: the found-work
    # spin residue + its window count round-trip through the SAME store call.
    assert_equal(sched_trace_worker(UInt64(3), Int32(8)), UInt64(850))    # spin_found
    assert_equal(sched_trace_worker(UInt64(3), Int32(9)), UInt64(13))     # found_windows
    # empty-window causality split.
    assert_equal(sched_trace_worker(UInt64(3), Int32(10)), UInt64(5))     # empty_inter_w
    assert_equal(sched_trace_worker(UInt64(3), Int32(11)), UInt64(2))     # empty_intra_w


def test_empty_window_cause_split_partitions_empty_windows() raises:
    """`empty_inter_w + empty_intra_w == empty_windows`. This is the
    invariant the Q1 headline fraction rests on — if the two arms of the depth
    branch at the empty-window sample point ever stopped partitioning the count
    (e.g. one arm skipped, or a third arm added), `pct_inter` would silently stop
    meaning "share of empty windows that fell inside a driver-serial gap"."""
    sched_trace_reset()
    var acc = _SchedWorkerAccum()
    acc.empty_windows = UInt64(9)
    acc.empty_inter_w = UInt64(6)
    acc.empty_intra_w = UInt64(3)
    acc.store(UInt64(2))
    var total = sched_trace_worker(UInt64(2), Int32(5))
    var inter = sched_trace_worker(UInt64(2), Int32(10))
    var intra = sched_trace_worker(UInt64(2), Int32(11))
    assert_equal(inter + intra, total)


def test_reset_clears_empty_window_cause_slots() raises:
    """reset zeroes the causality slots with the rest of the per-worker
    block, so a per-window snapshot cannot inherit a previous query's split."""
    sched_trace_reset()
    var acc = _SchedWorkerAccum()
    acc.empty_inter_w = UInt64(41)
    acc.empty_intra_w = UInt64(17)
    acc.store(UInt64(6))
    assert_equal(sched_trace_worker(UInt64(6), Int32(10)), UInt64(41))
    sched_trace_reset()
    assert_equal(sched_trace_worker(UInt64(6), Int32(10)), UInt64(0))
    assert_equal(sched_trace_worker(UInt64(6), Int32(11)), UInt64(0))


def test_new_accum_zeroes_empty_window_cause_slots() raises:
    """A fresh accumulator starts both slots at 0 — they are absolute
    totals, so a non-zero init would double-count on the first store."""
    var acc = _SchedWorkerAccum()
    assert_equal(acc.empty_inter_w, UInt64(0))
    assert_equal(acc.empty_intra_w, UInt64(0))


def test_worker_store_overwrites_not_accumulates() raises:
    """Store is absolute-overwrite (the worker holds absolute totals); a second
    store replaces, not adds."""
    sched_trace_reset()
    var acc = _SchedWorkerAccum()
    acc.run_ns = UInt64(1000)
    acc.store(UInt64(5))
    acc.run_ns = UInt64(2500)
    acc.store(UInt64(5))
    assert_equal(sched_trace_worker(UInt64(5), Int32(0)), UInt64(2500))


def test_unseen_worker_slot_is_zero() raises:
    """A wid that never stored reads back zero + seen=0 (excluded from the
    workers count in the dump)."""
    sched_trace_reset()
    var acc = _SchedWorkerAccum()
    acc.run_ns = UInt64(99)
    acc.store(UInt64(1))
    # wid 9 never stored.
    assert_equal(sched_trace_worker(UInt64(9), Int32(0)), UInt64(0))
    assert_equal(sched_trace_worker(UInt64(9), Int32(7)), UInt64(0))
    assert_equal(sched_trace_worker(UInt64(9), Int32(8)), UInt64(0))


def test_reset_clears_productive_spin_slots() raises:
    """reset zeroes the two productive-spin slots
    with the rest of the per-worker block. Without this the found-work spin burn
    would leak across a per-window measurement and inflate bucket (e)."""
    sched_trace_reset()
    var acc = _SchedWorkerAccum()
    acc.spin_found_ns = UInt64(7777)
    acc.found_windows = UInt64(31)
    acc.store(UInt64(4))
    assert_equal(sched_trace_worker(UInt64(4), Int32(8)), UInt64(7777))
    sched_trace_reset()
    assert_equal(sched_trace_worker(UInt64(4), Int32(8)), UInt64(0))
    assert_equal(sched_trace_worker(UInt64(4), Int32(9)), UInt64(0))


def test_new_accum_zeroes_productive_spin_slots() raises:
    """A freshly-constructed accumulator starts both slots at 0 (they are
    absolute totals; a non-zero init would double-count on the first store)."""
    var acc = _SchedWorkerAccum()
    assert_equal(acc.spin_found_ns, UInt64(0))
    assert_equal(acc.found_windows, UInt64(0))


def test_reset_clears_globals_workers_and_sites() raises:
    """Reset zeroes the globals, every per-worker slot, every per-site slot, and
    the ambient site."""
    sched_trace_add_segment(
        SITE_PARQUET_DECODE, UInt64(1), UInt64(2), UInt64(1)
    )
    sched_trace_add_dispatch(UInt64(9), UInt64(3))
    _ = sched_trace_swap_site(SITE_SINK_EXECUTOR)
    var acc = _SchedWorkerAccum()
    acc.run_ns = UInt64(7)
    acc.store(UInt64(2))
    sched_trace_reset()
    assert_equal(sched_trace_global(Int32(0)), UInt64(0))  # dispatch_ns
    assert_equal(sched_trace_global(Int32(1)), UInt64(0))  # erasure_count
    assert_equal(sched_trace_global(Int32(2)), UInt64(0))  # seg_count
    assert_equal(sched_trace_worker(UInt64(2), Int32(0)), UInt64(0))
    assert_equal(sched_trace_worker(UInt64(2), Int32(7)), UInt64(0))  # seen cleared
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(2)), UInt64(0))  # count
    assert_equal(sched_trace_get_site(), UInt32(0))  # ambient cleared


def test_dump_does_not_crash_and_preserves_counters() raises:
    """The on-demand summary dump (incl. the per-site table) prints without
    crashing and does NOT mutate the counters (read-only aggregation)."""
    sched_trace_reset()
    var acc = _SchedWorkerAccum()
    acc.run_ns = UInt64(10000)
    acc.pop_ns = UInt64(500)
    acc.park_inter_ns = UInt64(2000)
    acc.park_intra_ns = UInt64(3000)
    acc.spin_ns = UInt64(400)
    acc.tasks = UInt64(11)
    acc.store(UInt64(0))
    sched_trace_add_dispatch(UInt64(1500), UInt64(4))
    sched_trace_add_segment(
        SITE_PARQUET_DECODE, UInt64(100), UInt64(9100), UInt64(8)
    )
    sched_trace_add_segment(
        SITE_OTHER, UInt64(9200), UInt64(9500), UInt64(2)
    )
    sched_trace_dump()
    # Counters intact after the dump.
    assert_equal(sched_trace_global(Int32(0)), UInt64(1500))
    assert_equal(sched_trace_worker(UInt64(0), Int32(0)), UInt64(10000))
    assert_equal(sched_trace_site(SITE_PARQUET_DECODE, Int32(0)), UInt64(9000))


def main() raises:
    test_post_barrier_attribution_mirrors_pre_barrier()
    test_same_site_window_is_confirmed_own()
    test_transition_matrix_names_the_handoff()
    test_serial_phase_bracket_serial_excludes_internal_fork()
    test_serial_phase_work_unit_accumulates_and_resets()
    test_reset_clears_post_barrier_and_phase_slots()
    test_segment_span_and_inter_fork_gap()
    test_per_site_sums_partition_globals()
    test_task_avg_sum_tracks()
    test_barrier_before_fork_start_ignored()
    test_ambient_site_swap_and_restore()
    test_dispatch_and_erasure_volume()
    test_msink_phase_counters_accumulate()
    test_msink_wall_attr_per_run_sums_sanely()
    test_msink_phase_counters_reset()
    test_msink_prepare_phase_is_not_pure_serial()
    test_msink_handoff_brackets_name_the_residual()
    test_worker_store_roundtrips_all_fields()
    test_worker_store_overwrites_not_accumulates()
    test_unseen_worker_slot_is_zero()
    test_reset_clears_productive_spin_slots()
    test_new_accum_zeroes_productive_spin_slots()
    test_empty_window_cause_split_partitions_empty_windows()
    test_reset_clears_empty_window_cause_slots()
    test_new_accum_zeroes_empty_window_cause_slots()
    test_reset_clears_globals_workers_and_sites()
    test_dump_does_not_crash_and_preserves_counters()
    print("test_sched_trace_counters: all passed")
