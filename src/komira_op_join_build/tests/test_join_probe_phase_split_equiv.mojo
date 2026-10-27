# =============================================================================
# test_join_probe_phase_split_equiv — the PHASE-SPLIT chunked inner probe emits
# the SAME PAIRS, IN THE SAME ORDER, as the incumbent row-at-a-time walk; and
# the SIZE GATE actually keeps small joins off it
# =============================================================================
#
# WHAT IS UNDER TEST. `HashJoinBuilder.probe_inner_chunk` has two bodies now.
# The incumbent walks one probe row's chain to exhaustion before starting the
# next; the phase-split arm (`_probe_inner_chunk_ps`) advances a batch of 256
# rows one chain STEP at a time so the memory system sees B independent misses
# instead of one. The lever is claimed to be ANSWER-IDENTICAL, order included.
# This file is that claim's falsifier.
#
# A VALUE ORACLE ALONE IS VACUOUS HERE: both arms of an answer-preserving
# change agree whether or not the new arm ever ran, and half of what is under test here is a gate whose correct
# behaviour on the small side is THAT NOTHING HAPPENS. "The small join produced
# the right answer" is satisfied by a gate that is broken in either direction.
#
# So every case asserts, in this order:
#
#   1. DISPOSITION — the gate resolved the way the case says it did, read from
#      the process-wide latches (`join_phase_split_fired` /
#      `join_phase_split_declined`), reset per case. A case that says "the
#      phase-split ran" and finds only the decline latch set FAILS HERE, before
#      any value is compared.
#   2. VALUE, against the INCUMBENT — the same fixture through the same entry
#      point with the arm forced off, compared PAIR BY PAIR, position by
#      position. Not a multiset, not a count.
#   3. VALUE, against an INDEPENDENT IMPLEMENTATION — `probe_inner_into`, which
#      shares no code with either chunked body. Without this, a defect present
#      in BOTH chunked arms (the shared `_probe_row_walk`, the dispatcher, the
#      bloom pre-check) passes assertion 2 with both arms wrong together.
#
# ★ ASSERTION 3 IS ORDERED LAST DELIBERATELY. Assertions 1 and 2 localise a
# failure to the phase-split arm; 3 catches the class 2 cannot see. Reporting
# them the other way round would attribute a shared-substrate bug to this lever.
#
# COVERAGE, and why each case is here rather than being a variation of another:
#
#   unique_keys        one-step chains — isolates the batch SEED and the
#                      single-round emit from the multi-round walk.
#   fanout             every probe row matches SEVERAL build rows. THE ORDER
#                      CASE: this is the only shape where round-major and
#                      row-major emission differ at all, so a phase-split that
#                      skipped the counting sort passes every other case here.
#   null_probe_keys    a NULL probe key matches nothing and must be dropped by
#                      PHASE 0b, not by the chain compare. The fixture contains
#                      build key 0 on purpose: a NULL encodes as 0, so without a
#                      build row at 0 the case cannot tell "NULL skipped" from
#                      "NULL matched 0".
#   zero_match_rows    most probe rows hit an EMPTY bucket, so PHASE 0b's
#                      compaction does the majority of the work and `na` is far
#                      below `b`. Pins the compaction's in-place `na <= j`
#                      overwrite, which a batch of all-hits never exercises.
#   long_chains        forces the `s_stop == 0` row-at-a-time fallback: 256 rows
#                      all still walking when the match buffer fills. Without
#                      this case that path is unreachable and the kernel could
#                      not terminate on such data at all.
#   resume_chunks      chunk capacities that force MANY round trips, including
#                      one where a chunk boundary lands MID-CHAIN so the
#                      `_probe_row_walk` resume tail runs.
#   gate_boundary      the SIZE GATE, driven from BOTH sides over ONE fixture.
#
# ⚠ THE FIXTURES ARE TINY AND THE GATE IS PRODUCTION-SIZED (32 MiB of index,
# ~1M build rows). Every case therefore moves the THRESHOLD, not the fixture:
# `join_phase_split_configure(True, 1)` admits everything. Building a 1M-row
# build side per case would make this file a multi-minute test that still could
# not drive the OFF side of the gate.
# =============================================================================

from komira_arrow.primitive_array import PrimitiveArray

from komira_op_join_build.join import HashJoinBuilder, ProbeInnerState
from komira_op_join_build.join_probe_phase_split import (
    JOIN_PS_BATCH,
    JOIN_PS_MATCH_CAP,
    JOIN_PS_MIN_HEADROOM,
    join_phase_split_admits,
    join_phase_split_configure,
    join_phase_split_declined,
    join_phase_split_fired,
    join_phase_split_index_bytes,
    join_phase_split_reset_config,
    reset_join_phase_split_counters,
)


comptime I64 = DType.int64

# The smallest chunk capacity the gate admits. Anything below it must make the
# gate DECLINE — see `test_gate_refuses_small_chunk_capacity`.
comptime _CAP_OK = JOIN_PS_MIN_HEADROOM


# -----------------------------------------------------------------------------
# arm selection (the process setting)
# -----------------------------------------------------------------------------


def _arm_off() raises:
    """Force the INCUMBENT row-at-a-time walk (the control arm)."""
    join_phase_split_configure(False)


def _arm_on(min_bytes: Int) raises:
    """Force the PHASE-SPLIT walk for any index of at least `min_bytes`."""
    join_phase_split_configure(True, min_bytes)


def _arm_restore() raises:
    """Return the process to the shipped configuration (unconfigured: ON at
    `JOIN_PS_MIN_INDEX_BYTES`).

    Called at the end of EVERY case, and at the end of `main`, so a case that
    raised with the setting pinned does not pin it for every case after it.
    """
    join_phase_split_reset_config()


# -----------------------------------------------------------------------------
# fixtures
# -----------------------------------------------------------------------------


def _pa(imm keys: List[Int64]) raises -> PrimitiveArray[I64]:
    var n = len(keys)
    var arr = PrimitiveArray[I64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = keys[i]
    return arr^


def _pa_nullable(
    imm keys: List[Int64], imm nulls: List[Bool]
) raises -> PrimitiveArray[I64]:
    var n = len(keys)
    var arr = PrimitiveArray[I64].allocate_nullable(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = keys[i]
    for i in range(n):
        if nulls[i]:
            arr._set_null(i)
    return arr^


# -----------------------------------------------------------------------------
# oracles
# -----------------------------------------------------------------------------


def _chunk_pairs(
    imm b: HashJoinBuilder, imm probe: PrimitiveArray[I64], cap: Int
) raises -> List[Int]:
    """Drive `probe_inner_chunk` to exhaustion; flatten every pair in order.

    The returned list is [build0, probe0, build1, probe1, ...], so a compare
    over it is a compare of the SEQUENCE — a build index that migrated to a
    different probe row cannot cancel out.
    """
    var out = List[Int]()
    var bbuf = List[Int]()
    bbuf.resize(cap, 0)
    var pbuf = List[Int]()
    pbuf.resize(cap, 0)
    # PAYLOAD-INLINE: sized to `cap` (not 1) so this harness stays usable for a
    # payload-armed index without a second edit; unarmed it is never written.
    var paybuf = List[Int64]()
    paybuf.resize(cap, Int64(0))
    var st = ProbeInnerState()
    # A runaway guard: the phase-split's progress argument rests on `s_stop`
    # always advancing the cursor. If it ever does not, this raises instead of
    # hanging the whole bundle with no output.
    var trips = 0
    var max_trips = 16 + 8 * probe.length
    while True:
        var got = b.probe_inner_chunk(
            probe, st, Span(bbuf), Span(pbuf), Span(paybuf), cap
        )
        if got == 0:
            break
        if got > cap:
            raise Error(
                "probe_inner_chunk returned "
                + String(got)
                + " > capacity "
                + String(cap)
            )
        for i in range(got):
            out.append(bbuf[i])
            out.append(pbuf[i])
        trips += 1
        if trips > max_trips:
            raise Error("probe_inner_chunk made no progress (runaway chunks)")
    return out^


def _into_pairs(
    imm b: HashJoinBuilder, imm probe: PrimitiveArray[I64]
) raises -> List[Int]:
    """The INDEPENDENT oracle: `probe_inner_into`, flattened the same way."""
    var bm = List[Int]()
    var pm = List[Int]()
    b.probe_inner_into(probe, bm, pm)
    if len(bm) != len(pm):
        raise Error("probe_inner_into: build/probe lengths differ")
    var out = List[Int]()
    for i in range(len(bm)):
        out.append(bm[i])
        out.append(pm[i])
    return out^


def _assert_pairs_equal(
    imm a: List[Int], imm b: List[Int], imm label: String
) raises:
    if len(a) != len(b):
        raise Error(
            label
            + ": pair COUNT differs -- "
            + String(len(a) // 2)
            + " vs "
            + String(len(b) // 2)
        )
    for i in range(len(a)):
        if a[i] != b[i]:
            raise Error(
                label
                + ": pair "
                + String(i // 2)
                + (" build" if i % 2 == 0 else " probe")
                + " differs -- "
                + String(a[i])
                + " vs "
                + String(b[i])
            )


# -----------------------------------------------------------------------------
# the case driver
# -----------------------------------------------------------------------------


def _check(
    imm build: List[Int64],
    imm probe: List[Int64],
    imm probe_nulls: List[Bool],
    use_bloom: Bool,
    cap: Int,
    imm label: String,
) raises:
    """Run one fixture through BOTH arms at one chunk capacity and compare.

    ⚠ THE BUILDER IS REBUILT PER ARM AND THAT IS DELIBERATE. Reusing one would
    be faster and would also let a phase-split walk that modified the index
    (it holds `self` by borrow and must not) pass unnoticed, because the
    control arm would then be probing an index the treatment arm had already
    touched.
    """
    var pk: PrimitiveArray[I64]
    if len(probe_nulls) == 0:
        pk = _pa(probe)
    else:
        pk = _pa_nullable(probe, probe_nulls)

    # ---- CONTROL: the incumbent row-at-a-time walk.
    _arm_off()
    reset_join_phase_split_counters()
    var ctl = HashJoinBuilder.build(_pa(build), build_bloom=use_bloom)
    var ctl_pairs = _chunk_pairs(ctl, pk, cap)
    var ctl_into = _into_pairs(ctl, pk)
    if join_phase_split_fired():
        raise Error(
            label + "/control: the phase-split arm ran with the gate FORCED OFF"
        )
    if not join_phase_split_declined():
        raise Error(
            label
            + "/control: no chunked probe recorded a disposition -- the"
            " fixture never reached `probe_inner_chunk`, so this case proves"
            " nothing"
        )
    _ = ctl^

    # ---- TREATMENT: the phase-split walk.
    _arm_on(1)
    reset_join_phase_split_counters()
    var trt = HashJoinBuilder.build(_pa(build), build_bloom=use_bloom)
    var trt_pairs = _chunk_pairs(trt, pk, cap)
    # 1. DISPOSITION, before any value is looked at.
    if not join_phase_split_fired():
        raise Error(
            label
            + "/phase-split: the arm under test NEVER RAN (gate admitted"
            " nothing), so the value compare below would be the control"
            " against itself"
        )
    # 2. VALUE against the incumbent, pair by pair.
    _assert_pairs_equal(ctl_pairs, trt_pairs, label + "/phase-split vs chunk")
    # 3. VALUE against the independent implementation.
    _assert_pairs_equal(ctl_into, trt_pairs, label + "/phase-split vs into")
    _ = trt^

    _ = pk^
    _arm_restore()


def _check_caps(
    imm build: List[Int64],
    imm probe: List[Int64],
    imm probe_nulls: List[Bool],
    use_bloom: Bool,
    imm label: String,
) raises:
    """The same fixture at several chunk capacities.

    `_CAP_OK` is the smallest the gate admits; the larger ones move where the
    chunk boundary lands relative to a batch boundary, which is what decides
    whether the resume tail or the short-chunk return is exercised.
    """
    _check(build, probe, probe_nulls, use_bloom, _CAP_OK, label + "/cap1024")
    _check(build, probe, probe_nulls, use_bloom, 1500, label + "/cap1500")
    _check(build, probe, probe_nulls, use_bloom, 4096, label + "/cap4096")
    _check(build, probe, probe_nulls, use_bloom, 65536, label + "/cap65536")


# -----------------------------------------------------------------------------
# cases
# -----------------------------------------------------------------------------


def test_unique_keys() raises:
    """1:1 keys, chains of at most one step.

    Isolates PHASE 0 (seed + directory) and a single gather round from the
    multi-round walk. `n` is deliberately not a multiple of `JOIN_PS_BATCH`, so
    the final batch is SHORT and the `b = n - i` clamp is exercised.
    """
    var build = List[Int64]()
    for i in range(4000):
        build.append(Int64(i))
    var probe = List[Int64]()
    for i in range(3000 + 37):
        probe.append(Int64((i * 7) % 5000))  # 4000 hit, the rest miss
    _check_caps(build, probe, List[Bool](), True, String("unique"))


def test_fanout_multi_match() raises:
    """★ THE ORDER CASE. Every probe row matches SIX build rows.

    Round-major and row-major emission are the same sequence whenever every
    probe row has at most one match, so a phase-split that dropped the stable
    counting sort would pass every other case in this file and fail only here.

    The fixture is built so the six matches for one key are at six DIFFERENT
    build indices, and the LIFO chain gives them a fixed order the incumbent
    also produces — so the compare can stay exact rather than relaxing to a
    per-row multiset.
    """
    var build = List[Int64]()
    for _rep in range(6):
        for k in range(500):
            build.append(Int64(k))
    var probe = List[Int64]()
    for i in range(2048):
        probe.append(Int64(i % 700))  # keys 500..699 miss entirely
    _check_caps(build, probe, List[Bool](), True, String("fanout6"))


def test_null_probe_keys() raises:
    """NULL probe keys must be dropped in PHASE 0b, not by the key compare.

    A NULL encodes as DType-zero, so build key 0 is present ON PURPOSE: without
    it, "the NULL was skipped" and "the NULL matched key 0" produce the same
    answer and the case is blind to the defect it exists for.
    """
    var build = List[Int64]()
    for i in range(2000):
        build.append(Int64(i % 300))  # includes key 0, fan-out ~6-7
    var probe = List[Int64]()
    var pnulls = List[Bool]()
    for i in range(3000):
        probe.append(Int64(i % 400))
        pnulls.append(i % 3 == 0)  # 1000 NULL probe rows
    _check_caps(build, probe, pnulls, True, String("null_probe"))


def test_zero_match_rows() raises:
    """Most probe rows hit an EMPTY bucket.

    PHASE 0b then compacts a long way (`na` far below `b`), which is the only
    shape that exercises its in-place `na <= j` overwrite of `d_cur` / `d_key`
    for many rows at once. A fixture where every row survives leaves that
    compaction a no-op.
    """
    var build = List[Int64]()
    for i in range(1024):
        build.append(Int64(i * 1000))  # a very sparse key domain
    var probe = List[Int64]()
    for i in range(4000):
        probe.append(Int64(i))  # only i % 1000 == 0 can match
    _check_caps(build, probe, List[Bool](), True, String("zero_match"))


def test_long_chains_forces_row_fallback() raises:
    """★ THE `s_stop == 0` PATH — otherwise UNREACHABLE, and non-terminating
    without its fallback.

    Every probe row in a batch matches the SAME long chain, so after
    `JOIN_PS_MATCH_CAP / JOIN_PS_BATCH` rounds the match buffer is full with all
    256 rows still walking: no row has completed, nothing may be emitted in
    row-major order, and re-running the batch would make no progress at all.
    `_probe_inner_chunk_ps` finishes that one row through `_probe_row_walk`
    instead.

    The chain length is chosen from the constants rather than written down, so
    the case cannot quietly stop reaching the path if either is retuned.
    """
    var chain_len = 4 * (JOIN_PS_MATCH_CAP // JOIN_PS_BATCH) + 3
    var build = List[Int64]()
    for _rep in range(chain_len):
        for k in range(4):
            build.append(Int64(k))
    var probe = List[Int64]()
    for i in range(1200):
        probe.append(Int64(i % 5))  # key 4 misses; 0..3 each hit `chain_len`
    _check_caps(build, probe, List[Bool](), True, String("long_chains"))


def test_resume_mid_chain() raises:
    """A chunk boundary that lands MID-CHAIN, so the resume tail runs.

    With a fan-out that does not divide the chunk capacity, some call ends with
    `state.chain_pos != _CHAIN_END`; the next call must finish THAT row before
    it may start batching, or it would either re-emit the row's earlier matches
    or carry a half-walked row through every phase.

    ⚠ The capacities are PRIME-ish against the fan-out on purpose. A capacity
    that is an exact multiple of the per-row match count only ever cuts on a row
    boundary, and this case would then never reach the path it is named for.
    """
    var build = List[Int64]()
    for _rep in range(7):
        for k in range(400):
            build.append(Int64(k))
    var probe = List[Int64]()
    for i in range(2000):
        probe.append(Int64(i % 400))  # every row matches exactly 7
    _check(build, probe, List[Bool](), True, _CAP_OK, String("resume/1024"))
    _check(build, probe, List[Bool](), True, 1031, String("resume/1031"))
    _check(build, probe, List[Bool](), True, 2003, String("resume/2003"))
    _check(build, probe, List[Bool](), True, 4099, String("resume/4099"))


def test_no_bloom_arm() raises:
    """`build_bloom=False` — the `_use_bloom` bypass, which is the arm the
    parallel build adapter always produces.

    PHASE 0b's bloom pre-check is `self._use_bloom and ...`, so this is the case
    where that short-circuit, and not the bloom, decides which rows survive.
    """
    var build = List[Int64]()
    for i in range(3000):
        build.append(Int64(i % 900))
    var probe = List[Int64]()
    for i in range(2500):
        probe.append(Int64((i * 13) % 1200))
    _check_caps(build, probe, List[Bool](), False, String("no_bloom"))


# -----------------------------------------------------------------------------
# THE SIZE GATE
# -----------------------------------------------------------------------------


def test_gate_boundary_both_sides() raises:
    """★ THE GATE, DRIVEN FROM BOTH SIDES OVER ONE FIXTURE.

    The threshold is placed one byte BELOW the fixture's own index footprint
    (must fire) and one byte ABOVE it (must decline), and the answer is asserted
    identical in both dispositions.

    ⛔ ONE FIXTURE, TWO THRESHOLDS — NOT TWO FIXTURES. A gate test that shows a
    big join firing and a small join declining cannot distinguish a working gate
    from one that keys on something else entirely that happens to correlate with
    size. Holding the fixture FIXED and moving only the threshold makes the
    threshold the sole free variable.

    The footprint is read from `join_phase_split_index_bytes` rather than
    recomputed here: an independent re-derivation in the test would be a second
    implementation of the gate's arithmetic, and the two would drift.
    """
    var build = List[Int64]()
    for i in range(2000):
        build.append(Int64(i))
    var probe = List[Int64]()
    for i in range(1500):
        probe.append(Int64(i % 2500))
    var pk = _pa(probe)

    _arm_off()
    var b0 = HashJoinBuilder.build(_pa(build), build_bloom=True)
    var bytes = join_phase_split_index_bytes(
        b0.num_build, b0.capacity, b0._fused
    )
    if bytes <= 1:
        raise Error("gate fixture has a degenerate index footprint")
    var expected = _chunk_pairs(b0, pk, _CAP_OK)
    _ = b0^

    # --- BELOW the threshold: the gate must ADMIT.
    _arm_on(bytes)
    reset_join_phase_split_counters()
    var b1 = HashJoinBuilder.build(_pa(build), build_bloom=True)
    var got1 = _chunk_pairs(b1, pk, _CAP_OK)
    if not join_phase_split_fired():
        raise Error(
            "gate: threshold == footprint ("
            + String(bytes)
            + ") did NOT admit -- the comparison is not `>=`"
        )
    if join_phase_split_declined():
        raise Error("gate: admitted AND declined in the same run")
    _assert_pairs_equal(expected, got1, String("gate/admitted"))
    _ = b1^

    # --- ABOVE the threshold: the gate must DECLINE.
    _arm_on(bytes + 1)
    reset_join_phase_split_counters()
    var b2 = HashJoinBuilder.build(_pa(build), build_bloom=True)
    var got2 = _chunk_pairs(b2, pk, _CAP_OK)
    if join_phase_split_fired():
        raise Error(
            "gate: threshold ONE BYTE above the footprint still admitted --"
            " the gate is not comparing what it says it compares"
        )
    if not join_phase_split_declined():
        raise Error("gate: neither disposition recorded")
    _assert_pairs_equal(expected, got2, String("gate/declined"))
    _ = b2^

    _ = pk^
    _arm_restore()


def test_gate_refuses_small_chunk_capacity() raises:
    """A `chunk_capacity` below `JOIN_PS_MIN_HEADROOM` must DECLINE.

    ⛔ THIS IS A CORRECTNESS REFUSAL, NOT A TUNING ONE, AND ITS FAILURE MODE IS
    A SILENTLY SHORT JOIN. The phase-split returns a SHORT CHUNK rather than a
    partial batch when the caller's buffer is nearly full, and a zero-length
    chunk is the driver's "probe exhausted" signal. Admitted at a capacity below
    the headroom, the very first call could return 0 with rows still unprobed —
    a wrong answer with no exception, no crash, and a green value oracle
    everywhere the incumbent path is used.
    """
    var build = List[Int64]()
    for i in range(2000):
        build.append(Int64(i))
    var probe = List[Int64]()
    for i in range(1500):
        probe.append(Int64(i % 2500))
    var pk = _pa(probe)

    _arm_off()
    var b0 = HashJoinBuilder.build(_pa(build), build_bloom=True)
    var expected = _chunk_pairs(b0, pk, 7)
    _ = b0^

    _arm_on(1)
    reset_join_phase_split_counters()
    var b1 = HashJoinBuilder.build(_pa(build), build_bloom=True)
    var got = _chunk_pairs(b1, pk, JOIN_PS_MIN_HEADROOM - 1)
    if join_phase_split_fired():
        raise Error(
            "gate: admitted a chunk_capacity of "
            + String(JOIN_PS_MIN_HEADROOM - 1)
            + ", below JOIN_PS_MIN_HEADROOM"
        )
    _assert_pairs_equal(expected, got, String("small_cap"))
    _ = b1^

    # And the predicate says so directly, independent of any probe having run —
    # so the assertion above cannot pass merely because the fixture was small.
    if join_phase_split_admits(
        1 << 30, 1 << 30, True, 1 << 20, JOIN_PS_MIN_HEADROOM - 1
    ):
        raise Error(
            "join_phase_split_admits accepted a sub-headroom chunk_capacity on"
            " an index far above the threshold"
        )
    if not join_phase_split_admits(
        1 << 30, 1 << 30, True, 1 << 20, JOIN_PS_MIN_HEADROOM
    ):
        raise Error(
            "join_phase_split_admits refused a chunk_capacity EXACTLY at"
            " JOIN_PS_MIN_HEADROOM -- the comparison is not `>=`"
        )

    _ = pk^
    _arm_restore()


def test_gate_refuses_short_probe_and_kill_switch() raises:
    """The two remaining gate conditions, asserted on the predicate itself.

    A probe shorter than one batch cannot fill one, and the OFF setting has to
    win over an admitting threshold.
    """
    _arm_on(1)
    if join_phase_split_admits(
        1 << 30, 1 << 30, True, JOIN_PS_BATCH - 1, 65536
    ):
        raise Error("gate admitted a probe shorter than one batch")
    if not join_phase_split_admits(1 << 30, 1 << 30, True, JOIN_PS_BATCH, 65536):
        raise Error("gate refused a probe of EXACTLY one batch")

    # OFF after an admitting threshold.
    _arm_on(1)
    _arm_off()
    if join_phase_split_admits(1 << 30, 1 << 30, True, 1 << 20, 65536):
        raise Error("the OFF setting did not override an admitting threshold")
    _arm_restore()


def test_shipped_default_declines_a_small_join() raises:
    """THE SHIPPED CONFIGURATION, with the setting never configured.

    Every other case in this file moves the threshold, so a default that drifted
    to 0 — admitting every join in the tree, which is the regression the gate
    exists to prevent — would leave all of them green. Only a bare run can see
    it, and this is that run.
    """
    _arm_restore()
    reset_join_phase_split_counters()
    var build = List[Int64]()
    for i in range(2000):
        build.append(Int64(i))
    var probe = List[Int64]()
    for i in range(1500):
        probe.append(Int64(i % 2500))
    var pk = _pa(probe)
    var b = HashJoinBuilder.build(_pa(build), build_bloom=True)
    var got = _chunk_pairs(b, pk, 65536)
    var into = _into_pairs(b, pk)
    if join_phase_split_fired():
        raise Error(
            "the SHIPPED default admitted a 2000-row build side -- the size"
            " gate's threshold has drifted"
        )
    if not join_phase_split_declined():
        raise Error("no disposition recorded on the shipped default")
    _assert_pairs_equal(into, got, String("shipped_default"))
    _ = b^
    _ = pk^


def main() raises:
    test_unique_keys()
    test_fanout_multi_match()
    test_null_probe_keys()
    test_zero_match_rows()
    test_long_chains_forces_row_fallback()
    test_resume_mid_chain()
    test_no_bloom_arm()
    test_gate_boundary_both_sides()
    test_gate_refuses_small_chunk_capacity()
    test_gate_refuses_short_probe_and_kill_switch()
    test_shipped_default_declines_a_small_join()
    _arm_restore()
    print("test_join_probe_phase_split_equiv OK (11 cases)")
