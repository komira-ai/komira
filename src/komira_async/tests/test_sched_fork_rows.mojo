"""PER-FORK OCCUPANCY ROWS — separating forks that share one site id.

WHAT IS UNDER TEST, AND WHY A VALUE ORACLE CANNOT SEE IT
--------------------------------------------------------
`SCHED_SITE` bins `busy_ns` / `occ_span_ns` PER SITE, SUMMED OVER EVERY FORK
(`_posix_shim.c`, `_sched_s_busy_ns` / `_sched_s_occ_span_ns`, accumulated in
`komira_sched_add_segment_occ`). Where one site id is stamped by several
dispatches, its occupancy is an average over forks of different sizes doing
different jobs, and NO reading of that row can say which fork owns the idle.

Example: a site stamped by THREE `run_with_state` call sites reports an
occupancy of 0.70. That is consistent BOTH with its one big pipeline fork being
~70% packed (worth optimizing) AND with it being 85%+ packed and the average
being dragged down by several tiny forks (nothing to gain). Only per-fork rows
can tell the two apart.

⚠ THE PROPERTY HERE IS A TRACE SHAPE, NOT A VALUE. The fork geometry changes only
HOW work is sharded, never WHICH rows come out, so an output oracle is
structurally blind to it — the same argument `grain_geometry.mojo`'s header makes.
The counter IS the falsifier, so it is the counter these tests assert on.

★ EVERY TEST BELOW IS WRITTEN TO FAIL AGAINST A PER-SITE-ONLY INSTRUMENT, not
merely to fail to compile against one. `test_two_forks_one_site_are_separable`
drives two forks at ONE site whose true occupancies are 0.90 and 0.20 and asserts
each is recoverable AND that the site average equals NEITHER — which is precisely
the reading the site row gives and the misattribution it invites.

Fork-row field ids (must match `komira_sched_get_fork`):
  0=site 1=tag 2=tasks 3=span_ns 4=busy_ns 5=inter_ns 6=t0_rel_ns 7=units
  8=rows 9=flags  (flags bit0 = no occupancy sample, bit1 = note site mismatch)
Census field ids (must match `komira_sched_fork_count`):
  0=forks seen 1=rows kept 2=notes set 3=notes used 4=notes mismatched
  5=notes overwritten 6=ring capacity
"""

from std.testing import assert_equal, assert_true, assert_false

from komira_async.runtime.sched_trace import (
    FORKTAG_MK_BUILD,
    FORKTAG_MSINK_COMBINE_PART,
    FORKTAG_MSINK_OP_PULL,
    FORKTAG_MSINK_STREAM_PULL,
    FORKTAG_NONE,
    SITE_CONCAT,
    SITE_MK_JOIN_BUILD,
    SITE_SINK_EXECUTOR,
    sched_trace_add_segment,
    sched_trace_add_segment_occ,
    sched_trace_dump,
    sched_trace_fork,
    sched_trace_fork_count,
    sched_trace_reset,
    sched_trace_set_fork_note,
    sched_trace_site,
)

comptime FK_SITE: Int32 = 0
comptime FK_TAG: Int32 = 1
comptime FK_TASKS: Int32 = 2
comptime FK_SPAN: Int32 = 3
comptime FK_BUSY: Int32 = 4
comptime FK_INTER: Int32 = 5
comptime FK_T0: Int32 = 6
comptime FK_UNITS: Int32 = 7
comptime FK_ROWS: Int32 = 8
comptime FK_FLAGS: Int32 = 9

comptime CT_SEEN: Int32 = 0
comptime CT_KEPT: Int32 = 1
comptime CT_NOTES_SET: Int32 = 2
comptime CT_NOTES_USED: Int32 = 3
comptime CT_MISMATCH: Int32 = 4
comptime CT_OVERWRITTEN: Int32 = 5
comptime CT_CAP: Int32 = 6


def _occ(i: UInt64) -> Float64:
    """occupancy = (busy / span) / tasks, recomputed from the RECORDED integers.

    The reader divides, deliberately: the C side stores only the integers so a
    rounded double can never be mistaken for a measurement."""
    var span = sched_trace_fork(i, FK_SPAN)
    var busy = sched_trace_fork(i, FK_BUSY)
    var tasks = sched_trace_fork(i, FK_TASKS)
    if span == UInt64(0) or tasks == UInt64(0):
        return -1.0
    return (Float64(busy) / Float64(span)) / Float64(tasks)


# =============================================================================
# ★ THE HEADLINE: two forks at ONE site are separable, and the site row is not
# =============================================================================


def test_two_forks_one_site_are_separable() raises:
    """The fork de-conflation, in its smallest possible form.

    Two forks at `SITE_SINK_EXECUTOR`, both 20 tasks:
      fork A: span 100_000 ns, busy 1_800_000 ns -> span_avg 18.0, occ 0.90
      fork B: span 100_000 ns, busy   400_000 ns -> span_avg  4.0, occ 0.20

    A per-SITE instrument reports ONE number for both: busy 2_200_000 over
    occ_span 200_000 -> span_avg 11.0 -> occupancy 0.55. That number is the
    average, it equals NEITHER fork, and it is what makes a shared
    site's number unattributable. Both halves are asserted, because asserting only that the
    per-fork rows are right would pass against an instrument that also silently
    changed the site row."""
    sched_trace_reset()
    sched_trace_add_segment_occ(
        SITE_SINK_EXECUTOR, UInt64(1_000_000), UInt64(1_100_000), UInt64(20),
        UInt64(0), UInt64(1_800_000),
    )
    sched_trace_add_segment_occ(
        SITE_SINK_EXECUTOR, UInt64(2_000_000), UInt64(2_100_000), UInt64(20),
        UInt64(5_000_000), UInt64(5_400_000),
    )

    assert_equal(Int(sched_trace_fork_count(CT_SEEN)), 2)
    assert_equal(Int(sched_trace_fork_count(CT_KEPT)), 2)

    # PER-FORK: each fork's own occupancy, to the integer.
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_BUSY)), 1_800_000)
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_SPAN)), 100_000)
    assert_equal(Int(sched_trace_fork(UInt64(1), FK_BUSY)), 400_000)
    assert_equal(Int(sched_trace_fork(UInt64(1), FK_SPAN)), 100_000)
    var oa = _occ(UInt64(0))
    var ob = _occ(UInt64(1))
    assert_true(oa > 0.899 and oa < 0.901, "fork 0 occupancy must be 0.90")
    assert_true(ob > 0.199 and ob < 0.201, "fork 1 occupancy must be 0.20")

    # PER-SITE: the average, which is the reading that cannot separate the forks. Field
    # ids 9/10 are busy_ns / occ_span_ns.
    var s_busy = sched_trace_site(SITE_SINK_EXECUTOR, Int32(9))
    var s_span = sched_trace_site(SITE_SINK_EXECUTOR, Int32(10))
    assert_equal(Int(s_busy), 2_200_000)
    assert_equal(Int(s_span), 200_000)
    var s_occ = (Float64(s_busy) / Float64(s_span)) / 20.0
    assert_true(s_occ > 0.549 and s_occ < 0.551,
                "the SITE row must read 0.55 -- the average of the two")
    # ⭐ And it must equal NEITHER fork. This is the assertion that fails against
    # a per-site-only instrument even if that instrument is otherwise correct.
    assert_true(s_occ < oa - 0.05, "site average must be BELOW the packed fork")
    assert_true(s_occ > ob + 0.05, "site average must be ABOVE the starved fork")

    # And the two forks must sum back to the site totals -- the row set is a
    # PARTITION of the site row, not a second, differently-derived quantity.
    assert_equal(
        Int(sched_trace_fork(UInt64(0), FK_BUSY))
        + Int(sched_trace_fork(UInt64(1), FK_BUSY)),
        Int(s_busy),
    )
    assert_equal(
        Int(sched_trace_fork(UInt64(0), FK_SPAN))
        + Int(sched_trace_fork(UInt64(1), FK_SPAN)),
        Int(s_span),
    )


def test_fork_rows_carry_tasks_and_inter_gap() raises:
    """`tasks` is per fork, and the driver-serial gap BEFORE each fork is on the
    row. The second fork's `inter_ns` is fork_start(2) - barrier(1)."""
    sched_trace_reset()
    sched_trace_add_segment_occ(
        SITE_SINK_EXECUTOR, UInt64(1_000), UInt64(3_000), UInt64(20),
        UInt64(0), UInt64(30_000),
    )
    sched_trace_add_segment_occ(
        SITE_CONCAT, UInt64(9_000), UInt64(10_000), UInt64(7),
        UInt64(30_000), UInt64(34_000),
    )
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_TASKS)), 20)
    assert_equal(Int(sched_trace_fork(UInt64(1), FK_TASKS)), 7)
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_SITE)),
                 Int(SITE_SINK_EXECUTOR))
    assert_equal(Int(sched_trace_fork(UInt64(1), FK_SITE)), Int(SITE_CONCAT))
    # Row 0 is the first fork in the window, so nothing precedes it.
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_INTER)), 0)
    # 9_000 - 3_000
    assert_equal(Int(sched_trace_fork(UInt64(1), FK_INTER)), 6_000)
    # t0 is relative to the FIRST fork, so it orders rows within the window.
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_T0)), 0)
    assert_equal(Int(sched_trace_fork(UInt64(1), FK_T0)), 8_000)


# =============================================================================
# CALL-SITE TAGS — the half that names WHICH dispatch forked
# =============================================================================


def test_note_tags_the_next_fork_only() raises:
    """A note labels exactly ONE fork and is then gone. The fork after it is
    UNLABELLED (`FORKTAG_NONE`), which is true rather than sticky -- a note that
    persisted would label every later fork at that site with the first one's call
    site, which is the mislabel this whole mechanism exists to avoid."""
    sched_trace_reset()
    sched_trace_set_fork_note(
        FORKTAG_MSINK_OP_PULL, SITE_SINK_EXECUTOR, UInt64(49), UInt64(6_001_215),
    )
    sched_trace_add_segment_occ(
        SITE_SINK_EXECUTOR, UInt64(1_000), UInt64(2_000), UInt64(20),
        UInt64(0), UInt64(14_000),
    )
    sched_trace_add_segment_occ(
        SITE_SINK_EXECUTOR, UInt64(3_000), UInt64(4_000), UInt64(20),
        UInt64(14_000), UInt64(15_000),
    )
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_TAG)),
                 Int(FORKTAG_MSINK_OP_PULL))
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_UNITS)), 49)
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_ROWS)), 6_001_215)
    assert_equal(Int(sched_trace_fork(UInt64(1), FK_TAG)), Int(FORKTAG_NONE))
    assert_equal(Int(sched_trace_fork(UInt64(1), FK_UNITS)), 0)
    assert_equal(Int(sched_trace_fork(UInt64(1), FK_ROWS)), 0)
    assert_equal(Int(sched_trace_fork_count(CT_NOTES_SET)), 1)
    assert_equal(Int(sched_trace_fork_count(CT_NOTES_USED)), 1)
    assert_equal(Int(sched_trace_fork_count(CT_MISMATCH)), 0)


def test_three_call_sites_at_one_site_are_named() raises:
    """Three tagged forks, ONE site id. The tags are what turn
    three indistinguishable rows into three named ones."""
    sched_trace_reset()
    sched_trace_set_fork_note(
        FORKTAG_MSINK_OP_PULL, SITE_SINK_EXECUTOR, UInt64(49), UInt64(6_001_215))
    sched_trace_add_segment_occ(
        SITE_SINK_EXECUTOR, UInt64(1_000), UInt64(2_000), UInt64(20),
        UInt64(0), UInt64(18_000))
    sched_trace_set_fork_note(
        FORKTAG_MSINK_STREAM_PULL, SITE_SINK_EXECUTOR, UInt64(3), UInt64(900))
    sched_trace_add_segment_occ(
        SITE_SINK_EXECUTOR, UInt64(3_000), UInt64(4_000), UInt64(20),
        UInt64(18_000), UInt64(20_000))
    sched_trace_set_fork_note(
        FORKTAG_MSINK_COMBINE_PART, SITE_SINK_EXECUTOR, UInt64(8), UInt64(0))
    sched_trace_add_segment_occ(
        SITE_SINK_EXECUTOR, UInt64(5_000), UInt64(5_500), UInt64(8),
        UInt64(20_000), UInt64(23_000))

    assert_equal(Int(sched_trace_fork_count(CT_SEEN)), 3)
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_TAG)),
                 Int(FORKTAG_MSINK_OP_PULL))
    assert_equal(Int(sched_trace_fork(UInt64(1), FK_TAG)),
                 Int(FORKTAG_MSINK_STREAM_PULL))
    assert_equal(Int(sched_trace_fork(UInt64(2), FK_TAG)),
                 Int(FORKTAG_MSINK_COMBINE_PART))
    # The three tags must be DISTINCT -- one name for two call sites would put
    # this instrument back where the site row already was.
    assert_true(
        sched_trace_fork(UInt64(0), FK_TAG) != sched_trace_fork(UInt64(1), FK_TAG)
        and sched_trace_fork(UInt64(1), FK_TAG)
            != sched_trace_fork(UInt64(2), FK_TAG)
        and sched_trace_fork(UInt64(0), FK_TAG)
            != sched_trace_fork(UInt64(2), FK_TAG),
        "the three msink call sites must carry three different tags",
    )
    # The site row still sums all three, unchanged -- committed traces must stay
    # comparable, which is why the tags are a SEPARATE id space and not new sites.
    assert_equal(Int(sched_trace_site(SITE_SINK_EXECUTOR, Int32(2))), 3)


def test_stolen_note_is_flagged_never_mislabelled() raises:
    """THE PROTOCOL'S OWN FALSIFIER. If some other dispatch forks between a stamp
    and the fork it was written for, the note is consumed by the WRONG fork. That
    fork must be recorded UNLABELLED with `note_mismatch`, and counted -- never
    with the wrong tag. A tag that can be silently wrong is worse than no tag."""
    sched_trace_reset()
    sched_trace_set_fork_note(
        FORKTAG_MK_BUILD, SITE_MK_JOIN_BUILD, UInt64(256), UInt64(1_500_000))
    # ... and a DIFFERENT site forks first.
    sched_trace_add_segment_occ(
        SITE_CONCAT, UInt64(1_000), UInt64(2_000), UInt64(7),
        UInt64(0), UInt64(7_000))
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_TAG)), Int(FORKTAG_NONE))
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_UNITS)), 0)
    # flags bit1 = note site mismatch.
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_FLAGS)) & 2, 2)
    assert_equal(Int(sched_trace_fork_count(CT_MISMATCH)), 1)
    assert_equal(Int(sched_trace_fork_count(CT_NOTES_USED)), 0)
    # And the note is CONSUMED, not left to mislabel the fork after it either.
    sched_trace_add_segment_occ(
        SITE_MK_JOIN_BUILD, UInt64(3_000), UInt64(4_000), UInt64(20),
        UInt64(7_000), UInt64(9_000))
    assert_equal(Int(sched_trace_fork(UInt64(1), FK_TAG)), Int(FORKTAG_NONE))
    assert_equal(Int(sched_trace_fork(UInt64(1), FK_FLAGS)) & 2, 0)


def test_note_overwritten_before_use_is_counted() raises:
    """A wave that DECLINES to dispatch (`fork_join_shared`'s inline arm, or the
    nested-dispatch interlock) leaves its note live. The next stamp overwrites it,
    and that is counted -- so `notes_overwritten > 0` reads as "some tagged wave
    did not fork", which is a finding, not a defect in the tag."""
    sched_trace_reset()
    sched_trace_set_fork_note(
        FORKTAG_MSINK_OP_PULL, SITE_SINK_EXECUTOR, UInt64(1), UInt64(1))
    sched_trace_set_fork_note(
        FORKTAG_MK_BUILD, SITE_MK_JOIN_BUILD, UInt64(2), UInt64(2))
    sched_trace_add_segment_occ(
        SITE_MK_JOIN_BUILD, UInt64(1_000), UInt64(2_000), UInt64(20),
        UInt64(0), UInt64(20_000))
    assert_equal(Int(sched_trace_fork_count(CT_OVERWRITTEN)), 1)
    assert_equal(Int(sched_trace_fork_count(CT_NOTES_SET)), 2)
    assert_equal(Int(sched_trace_fork_count(CT_NOTES_USED)), 1)
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_TAG)), Int(FORKTAG_MK_BUILD))


# =============================================================================
# UNMEASURED IS NOT IDLE, and the ring's own honesty
# =============================================================================


def test_no_occupancy_sample_is_flagged_not_zero() raises:
    """`sched_trace_add_segment` (the legacy 4-arg entry) passes 0/0 for "no
    sample". Its row must carry `flags & 1` and busy 0 -- and a reader that
    divides gets -1, not 0.00. "Unmeasured" and "idle" are different findings; a
    0 that meant the first must never read as the second."""
    sched_trace_reset()
    sched_trace_add_segment(
        SITE_CONCAT, UInt64(1_000), UInt64(2_000), UInt64(7))
    assert_equal(Int(sched_trace_fork_count(CT_SEEN)), 1)
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_FLAGS)) & 1, 1)
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_BUSY)), 0)
    var o = _occ(UInt64(0))
    assert_true(o >= 0.0, "busy=0 span=1000 tasks=7 still divides to 0.0")
    # The SITE row's occupancy sample count must NOT have advanced (field 11).
    assert_equal(Int(sched_trace_site(SITE_CONCAT, Int32(11))), 0)


def test_seen_exceeds_kept_and_says_so() raises:
    """FIRST-N, not a wrap. Past the ring capacity, `seen` keeps counting and
    `kept` saturates, so the dump can report how many rows it did NOT keep rather
    than silently truncating -- and the HEAD (which contains the per-rep pattern)
    is what survives."""
    sched_trace_reset()
    var cap = sched_trace_fork_count(CT_CAP)
    assert_true(cap > UInt64(0), "the ring must report a capacity")
    var n = cap + UInt64(3)
    for k in range(Int(n)):
        var t0 = UInt64(1_000_000 + k * 1_000)
        sched_trace_add_segment_occ(
            SITE_CONCAT, t0, t0 + UInt64(100), UInt64(4),
            UInt64(0), UInt64(200))
    assert_equal(Int(sched_trace_fork_count(CT_SEEN)), Int(n))
    assert_equal(Int(sched_trace_fork_count(CT_KEPT)), Int(cap))
    # Row 0 -- the HEAD -- is still the first fork, not overwritten by the tail.
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_T0)), 0)
    # A read past the kept rows is 0, never a wrapped row masquerading as one.
    assert_equal(Int(sched_trace_fork(cap, FK_SPAN)), 0)
    assert_equal(Int(sched_trace_fork(cap + UInt64(1), FK_TASKS)), 0)


def test_reset_clears_rows_and_the_pending_note() raises:
    """A note left live across a reset would attach to the first fork of the NEXT
    measurement window and label it with the previous window's call site. Both
    halves are asserted; clearing only the rows is the bug."""
    sched_trace_reset()
    sched_trace_set_fork_note(
        FORKTAG_MSINK_OP_PULL, SITE_SINK_EXECUTOR, UInt64(49), UInt64(99))
    sched_trace_add_segment_occ(
        SITE_SINK_EXECUTOR, UInt64(1_000), UInt64(2_000), UInt64(20),
        UInt64(0), UInt64(18_000))
    assert_equal(Int(sched_trace_fork_count(CT_SEEN)), 1)

    # A SECOND note, deliberately left un-consumed across the reset.
    sched_trace_set_fork_note(
        FORKTAG_MK_BUILD, SITE_MK_JOIN_BUILD, UInt64(7), UInt64(7))
    sched_trace_reset()
    assert_equal(Int(sched_trace_fork_count(CT_SEEN)), 0)
    assert_equal(Int(sched_trace_fork_count(CT_KEPT)), 0)
    assert_equal(Int(sched_trace_fork_count(CT_NOTES_SET)), 0)
    assert_equal(Int(sched_trace_fork_count(CT_NOTES_USED)), 0)
    assert_equal(Int(sched_trace_fork_count(CT_MISMATCH)), 0)
    assert_equal(Int(sched_trace_fork_count(CT_OVERWRITTEN)), 0)
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_SPAN)), 0)

    # The stale note must NOT label the first fork of the new window.
    sched_trace_add_segment_occ(
        SITE_MK_JOIN_BUILD, UInt64(1_000), UInt64(2_000), UInt64(20),
        UInt64(0), UInt64(18_000))
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_TAG)), Int(FORKTAG_NONE))
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_FLAGS)) & 2, 0)


def test_dump_does_not_crash_or_disturb_the_rows() raises:
    """The dump prints `SCHED_FORKS_BEGIN` / `SCHED_FORK` / `SCHED_FORKS_END`. It
    must be a pure read -- an instrument whose reporting mutates its own record
    cannot be read twice, and it is read many times."""
    sched_trace_reset()
    sched_trace_set_fork_note(
        FORKTAG_MSINK_OP_PULL, SITE_SINK_EXECUTOR, UInt64(49), UInt64(6_001_215))
    sched_trace_add_segment_occ(
        SITE_SINK_EXECUTOR, UInt64(1_000), UInt64(2_000), UInt64(20),
        UInt64(0), UInt64(14_015))
    var before_busy = sched_trace_fork(UInt64(0), FK_BUSY)
    var before_tag = sched_trace_fork(UInt64(0), FK_TAG)
    var before_seen = sched_trace_fork_count(CT_SEEN)
    sched_trace_dump()
    sched_trace_dump()
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_BUSY)), Int(before_busy))
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_TAG)), Int(before_tag))
    assert_equal(Int(sched_trace_fork_count(CT_SEEN)), Int(before_seen))


def test_barrier_before_fork_start_records_a_zero_span_row() raises:
    """A malformed span (barrier <= fork_start) is excluded from the site totals
    by the existing guard. The fork ROW is still emitted, with span 0 -- a fork
    that happened and could not be timed is a finding, and dropping the row would
    make the row set stop being a partition of the site's fork COUNT."""
    sched_trace_reset()
    sched_trace_add_segment_occ(
        SITE_CONCAT, UInt64(5_000), UInt64(5_000), UInt64(4),
        UInt64(0), UInt64(1_000))
    assert_equal(Int(sched_trace_fork_count(CT_SEEN)), 1)
    assert_equal(Int(sched_trace_fork(UInt64(0), FK_SPAN)), 0)
    assert_equal(Int(sched_trace_site(SITE_CONCAT, Int32(0))), 0)
    # The site's fork COUNT still advanced, so row count == site count holds.
    assert_equal(Int(sched_trace_site(SITE_CONCAT, Int32(2))), 1)
    assert_equal(_occ(UInt64(0)), -1.0)


def main() raises:
    test_two_forks_one_site_are_separable()
    test_fork_rows_carry_tasks_and_inter_gap()
    test_note_tags_the_next_fork_only()
    test_three_call_sites_at_one_site_are_named()
    test_stolen_note_is_flagged_never_mislabelled()
    test_note_overwritten_before_use_is_counted()
    test_no_occupancy_sample_is_flagged_not_zero()
    test_seen_exceeds_kept_and_says_so()
    test_reset_clears_rows_and_the_pending_note()
    test_dump_does_not_crash_or_disturb_the_rows()
    test_barrier_before_fork_start_records_a_zero_span_row()
    print("test_sched_fork_rows: all passed")
