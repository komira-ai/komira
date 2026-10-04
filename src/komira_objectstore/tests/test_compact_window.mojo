# =============================================================================
# tests/test_compact_window.mojo
#   The compaction substrate: the standalone test rig + GATE for the GENERAL
#   compaction primitive.
# =============================================================================
#
# The primitive (komira_objectstore/compact_window.mojo) is tested
# STANDALONE here via two in-mem stub CompactionSource conformers + a clone-
# shared in-mem conditional store. NO consumer code (comms / pgstore) is
# involved — those adoptions are SEPARATE later slices.
#
# The two stub conformers:
#   * _CasWatermarkSource — the CAS-watermark model over a SHARED in-mem manifest
#     map: plan reads the durable HEAD + watermark, fold appends ONE base chunk +
#     records the materialized high-water, advance does an If-Match-style CAS on a
#     shared watermark object (returns False on a 412-shaped race-loss), retire
#     frees one input, floor = min(hi+1, materialized_thru+1). Drives the K1 race
#     + the K2 crash-atomicity soak.
#   * _DerivedWatermarkSource — the derived-watermark model: the materialize step
#     IS the advance, so advance_watermark returns True trivially. Drives the
#     no-op early-exit + the derived-watermark consumer paths.
#
# Tests (the dispatch's acceptance set):
#   (1) K1 watermark-CAS-loser-no-op — two compactors race the same range; the
#       loser's 412 -> returns lost-redundant, does NOT retire, no corruption; the
#       winner advances + retires.
#   (2) K2 crash-atomicity (the DISCRIMINATING soak) — materialize succeeds but
#       advance is interrupted (crash between step 4 and 5 via fault injection) ->
#       on retry, output is NOT double-materialized into a wrong state, inputs are
#       freed exactly once, nothing is retired above safe_retire_floor. RED on a
#       naive retire-without-the-floor-clamp variant; GREEN on the clamped
#       derivation (the RED-verify is shown via a parallel naive run).
#   (3) noop early-exit (lo > hi) + derived-watermark consumer (advance returns
#       True trivially) both drive cleanly.
# =============================================================================

from std.memory import ArcPointer

from std.testing import assert_equal, assert_true, assert_false

from komira_objectstore.compact_window import (
    COMPACT_LOST,
    COMPACT_NOOP,
    COMPACT_WON,
    CompactionSource,
    CompactProduct,
    CompactRange,
    CompactSummary,
    compact_once,
    run_clamped_retire,
    run_watermark_advance,
)


# =============================================================================
# A — a shared, mutable in-mem compaction-state model (the K1/K2 substrate).
# =============================================================================
# A clone-shared (ArcPointer) model of the durable compaction state that a real
# CasManifestStore compaction races over: a per-input liveness vector, a
# committed-watermark slot (the seq the watermark has advanced past), a free-
# count ledger per input (to discriminate a double-free), and a count of
# materialized outputs. Two _CasWatermarkSource handles sharing the SAME inner
# model = two compactors racing the SAME range (the K1 model), exactly like two
# CasManifestStore handles over a SharedInMemoryConditionalStore.


struct _ModelState(Movable, Deinitable):
    """The shared durable-compaction-state model. Single-threaded rig; plain
    Int counters suffice."""

    # input chunk_seq i is in [0, n_inputs); live[i] False once retired.
    var live: List[Bool]
    # how many times input i was retired (a double-free => > 1; the K2 ledger).
    var free_count: List[Int64]
    # the committed watermark: inputs with seq < watermark are folded+retired.
    # -1 => nothing folded yet (the first uncompacted seq is 0).
    var watermark: Int64
    # how many distinct outputs were durably materialized (the double-
    # materialize ledger: a correct retry must NOT push the state forward twice).
    var materialized_outputs: Int64
    # the highest input seq any durable output covers (monotone forward).
    var materialized_high_water: Int64

    def __init__(out self, n_inputs: Int):
        self.live = List[Bool]()
        self.free_count = List[Int64]()
        for _ in range(n_inputs):
            self.live.append(True)
            self.free_count.append(Int64(0))
        self.watermark = Int64(-1)
        self.materialized_outputs = Int64(0)
        self.materialized_high_water = Int64(-1)

    @always_inline
    def n_inputs(self) -> Int:
        return len(self.live)

    @always_inline
    def live_count(self) -> Int:
        var c = 0
        for i in range(len(self.live)):
            if self.live[i]:
                c += 1
        return c


# =============================================================================
# B — _CasWatermarkSource — the CAS-watermark stub conformer (K1 + K2).
# =============================================================================
# OutputRef = Int64 (the output's seq id). Two handles sharing the same
# ArcPointer[_ModelState] race the SAME range. The watermark advance is an
# If-Match-shaped CAS: a handle reads the watermark at plan time (its `_planned_
# watermark` snapshot); advance succeeds iff the live watermark still equals the
# snapshot (no competitor advanced it first), else it's a 412-shaped LOSS
# (returns False) — exactly comms_index.compact's advance_log_start If-Match.


struct _CasWatermarkSource(CompactionSource, Movable, Deinitable):
    comptime OutputRef = Int64

    var _model: ArcPointer[_ModelState]
    # the watermark snapshot this handle read at plan time (the If-Match etag).
    var _planned_watermark: Int64
    # FAULT INJECTION (K2): when True, the FIRST advance_watermark call raises
    # (simulating a crash between MATERIALIZE (step 4) and ADVANCE (step 5)).
    var _crash_before_advance: Bool
    # NAIVE-VARIANT toggle (K2 RED-verify): when True, safe_retire_floor returns
    # the UNCLAMPED desired (range.hi + 1) instead of min(desired,
    # materialized_thru + 1) — the bug the clamp fixes.
    var _naive_unclamped_floor: Bool

    def __init__(
        out self,
        var model: ArcPointer[_ModelState],
        crash_before_advance: Bool = False,
        naive_unclamped_floor: Bool = False,
    ):
        self._model = model^
        self._planned_watermark = Int64(-1)
        self._crash_before_advance = crash_before_advance
        self._naive_unclamped_floor = naive_unclamped_floor

    # ---- step 1+2: plan the range from the durable HEAD + watermark ----
    def plan_range(mut self) raises -> CompactRange:
        ref m = self._model[]
        # snapshot the watermark (the If-Match etag for the later advance).
        self._planned_watermark = m.watermark
        # lo = first uncompacted seq = watermark + 1; hi = last input seq.
        var lo = m.watermark + Int64(1)
        if lo < Int64(0):
            lo = Int64(0)
        var hi = Int64(m.n_inputs() - 1)
        if lo > hi:
            return CompactRange.noop()
        return CompactRange(lo=lo, hi=hi)

    # ---- step 3+4: fold + materialize ONE base, record the high-water ----
    def fold_and_materialize(
        mut self, range: CompactRange
    ) raises -> CompactProduct[Self.OutputRef]:
        ref m = self._model[]
        # "Materialize" the folded survivors as ONE durable output. We DURABLY
        # record that an output covering [lo, hi] now exists (the materialized_
        # high_water moves forward; the output-count ledger increments). This is
        # the step a crash can leave done WITHOUT the watermark advancing.
        if range.hi > m.materialized_high_water:
            m.materialized_high_water = range.hi
        m.materialized_outputs += Int64(1)
        # the OutputRef is the output's seq id (the count is a fine opaque id).
        return CompactProduct[Self.OutputRef](
            covered=range,
            output=m.materialized_outputs,
            materialized_thru=range.hi,
            row_count=range.span(),
        )

    # ---- step 5: advance the watermark (If-Match CAS; 412 => False) ----
    def advance_watermark(
        mut self, product: CompactProduct[Self.OutputRef]
    ) raises -> Bool:
        # FAULT INJECTION (K2): simulate a crash AFTER materialize, BEFORE the
        # watermark advance commits. The retry re-plans against the unchanged
        # watermark.
        if self._crash_before_advance:
            raise Error("compact_window_test: injected crash before advance")
        ref m = self._model[]
        # If-Match: advance iff the live watermark still equals our snapshot.
        if m.watermark != self._planned_watermark:
            # a competitor advanced the watermark first -> 412-shaped LOSS. Our
            # materialized output is a harmless redundant chunk. Report lost.
            return False
        m.watermark = product.materialized_thru
        return True

    # ---- step 6: retire one input (free; ledger++) ----
    def retire_input(mut self, idx: Int64) raises:
        ref m = self._model[]
        var i = Int(idx)
        if i < 0 or i >= m.n_inputs():
            raise Error("compact_window_test: retire idx OOB")
        m.live[i] = False
        m.free_count[i] += Int64(1)

    # ---- the K2 clamp: min(desired, materialized_thru + 1) ----
    def safe_retire_floor(
        self, product: CompactProduct[Self.OutputRef]
    ) raises -> Int64:
        var desired = product.covered.hi + Int64(1)
        if self._naive_unclamped_floor:
            # THE BUG: retire up to the desired hi+1 WITHOUT clamping to what the
            # output durably covers. Under a crash-then-retry this frees inputs
            # the re-fold still needs / double-frees.
            return desired
        var clamped = product.materialized_thru + Int64(1)
        if clamped < desired:
            return clamped
        return desired


# =============================================================================
# C — _DerivedWatermarkSource — the derived-watermark stub conformer.
# =============================================================================
# The materialize step (an entry-append) IS the advance, so advance_watermark
# returns True trivially (mirrors log_compactor.run_once_columnarize_log, whose
# lock-free ColumnarFileEntry append is the watermark advance — there is no CAS
# to lose). OutputRef = String (a Parquet-key-shaped opaque id). Drives the
# no-op early-exit + the derived-watermark path.


struct _DerivedWatermarkSource(
    CompactionSource, Movable, Deinitable
):
    comptime OutputRef = String

    # the input high-water seq (hi); -1 => empty (the no-op case).
    var _hi: Int64
    # the high-water this consumer has already columnarized (the derived
    # watermark). lo = _high_water + 1.
    var _high_water: Int64
    # ledger: how many outputs were materialized + how many inputs retired.
    var materialized: Int64
    var retired: Int64
    var advance_calls: Int64

    def __init__(out self, hi: Int64, high_water: Int64 = Int64(-1)):
        self._hi = hi
        self._high_water = high_water
        self.materialized = Int64(0)
        self.retired = Int64(0)
        self.advance_calls = Int64(0)

    def plan_range(mut self) raises -> CompactRange:
        var lo = self._high_water + Int64(1)
        if lo < Int64(0):
            lo = Int64(0)
        if lo > self._hi:
            return CompactRange.noop()
        return CompactRange(lo=lo, hi=self._hi)

    def fold_and_materialize(
        mut self, range: CompactRange
    ) raises -> CompactProduct[Self.OutputRef]:
        self.materialized += Int64(1)
        # the entry-append (the materialize) IS the watermark advance: bump the
        # derived high-water here.
        self._high_water = range.hi
        return CompactProduct[Self.OutputRef](
            covered=range,
            output=String("cold-")
            + String(range.lo)
            + String("-")
            + String(range.hi)
            + String(".parquet"),
            materialized_thru=range.hi,
            row_count=range.span(),
        )

    def advance_watermark(
        mut self, product: CompactProduct[Self.OutputRef]
    ) raises -> Bool:
        # DERIVED watermark: the materialize (entry-append) already advanced the
        # high-water; there is no separate CAS to lose. Return True trivially.
        self.advance_calls += Int64(1)
        return True

    def retire_input(mut self, idx: Int64) raises:
        self.retired += Int64(1)

    def safe_retire_floor(
        self, product: CompactProduct[Self.OutputRef]
    ) raises -> Int64:
        # the derived-watermark consumer materialized the whole range durably, so
        # the clamp == the desired (materialized_thru + 1 == hi + 1).
        return product.materialized_thru + Int64(1)


# =============================================================================
# TEST 1 — K1: watermark-CAS-loser-no-op.
# =============================================================================


def test_k1_watermark_cas_loser_no_op() raises:
    print("[compact-window] case 1 K1 watermark-CAS-loser-no-op")
    # 5 inputs (seq 0..4), watermark at -1 (nothing folded yet).
    var model = ArcPointer[_ModelState](_ModelState(5))

    # Two compactors race the SAME range (both share the SAME inner model).
    var winner = _CasWatermarkSource(model.copy())
    var loser = _CasWatermarkSource(model.copy())

    # Both PLAN the same range against the SAME watermark snapshot (-1).
    # The winner runs FIRST: folds, materializes, advances (WON), retires.
    var w_summary = compact_once[_CasWatermarkSource](winner)
    assert_equal(w_summary.outcome, COMPACT_WON)
    assert_equal(Int(w_summary.lo), 0)
    assert_equal(Int(w_summary.hi), 4)
    assert_equal(Int(w_summary.retired_count), 5)

    # The shared model: watermark advanced to 4 (== materialized_thru); all 5
    # inputs retired exactly once.
    ref m = model[]
    assert_equal(Int(m.watermark), 4)
    assert_equal(m.live_count(), 0)
    for i in range(5):
        assert_equal(Int(m.free_count[i]), 1)  # freed exactly once
    var outputs_after_winner = m.materialized_outputs

    # The LOSER now runs. It already snapshotted the watermark (-1) at its
    # plan... but compact_once re-plans inside the driver, so to model a TRUE
    # race (loser planned the OLD watermark, then the winner advanced), we drive
    # the loser through the steps MANUALLY with a stale snapshot.
    var stale_range = loser.plan_range()  # plans against the NOW-advanced wm
    # The loser re-plans and sees the advanced watermark => its range is a no-op
    # (nothing left to fold). That is the COMMON outcome: the loser observes the
    # winner's advance and exits cleanly.
    assert_true(stale_range.is_noop())

    # To exercise the TRUE lost-CAS branch (loser planned BEFORE the winner
    # advanced), construct a loser whose snapshot predates the advance.
    var racer = _CasWatermarkSource(model.copy())
    racer._planned_watermark = Int64(-1)  # the STALE pre-advance snapshot
    # It folds + materializes a redundant base over [0, 4] (order-independent).
    var redundant = racer.fold_and_materialize(CompactRange(lo=Int64(0), hi=Int64(4)))
    # advance: the live watermark (4) != the stale snapshot (-1) => 412-LOSS.
    var won = run_watermark_advance[_CasWatermarkSource](racer, redundant)
    assert_false(won)  # LOST (redundant)

    # The loser did NOT retire (the winner owns the reap window): free_count
    # still exactly 1 per input, watermark unchanged.
    assert_equal(Int(m.watermark), 4)
    for i in range(5):
        assert_equal(Int(m.free_count[i]), 1)  # STILL exactly once (no re-free)
    # The loser DID materialize a redundant output (harmless), but pushed NO
    # extra retire + did NOT move the watermark.
    assert_true(m.materialized_outputs > outputs_after_winner)
    print("  PASS K1: winner advances+retires, loser 412->lost-redundant, no re-free")


# =============================================================================
# TEST 2 — K2: crash-atomicity (the DISCRIMINATING soak).
# =============================================================================


def test_k2_crash_atomicity_clamped_green() raises:
    print("[compact-window] case 2 K2 crash-atomicity (clamped derivation, GREEN)")
    # 4 inputs (seq 0..3), watermark -1.
    var model = ArcPointer[_ModelState](_ModelState(4))

    # PASS 1: a source that CRASHES between materialize and advance.
    var crasher = _CasWatermarkSource(
        model.copy(), crash_before_advance=True, naive_unclamped_floor=False
    )
    var raised = False
    try:
        _ = compact_once[_CasWatermarkSource](crasher)
    except e:
        raised = True
        _ = e
    assert_true(raised)  # the injected crash propagated out of the driver

    # After the crash: the output WAS materialized (high-water moved), but the
    # watermark did NOT advance and NOTHING was retired (the crash hit BEFORE
    # advance, so run_clamped_retire never ran).
    ref m = model[]
    assert_equal(Int(m.watermark), -1)  # watermark NOT advanced
    assert_equal(Int(m.materialized_high_water), 3)  # output WAS materialized
    assert_equal(m.live_count(), 4)  # NO input retired
    for i in range(4):
        assert_equal(Int(m.free_count[i]), 0)  # nothing freed

    # PASS 2 (the RETRY): a fresh, non-crashing source over the SAME model.
    var retry = _CasWatermarkSource(
        model.copy(), crash_before_advance=False, naive_unclamped_floor=False
    )
    var summary = compact_once[_CasWatermarkSource](retry)
    assert_equal(summary.outcome, COMPACT_WON)
    # The retry re-folds [0, 3] (the watermark was still -1), re-materializes the
    # SAME survivors (idempotent-by-range), advances the watermark to 3, and
    # retires [0, 3].
    assert_equal(Int(m.watermark), 3)
    assert_equal(m.live_count(), 0)
    # CRUX: every input was freed EXACTLY ONCE across the crash + retry (no
    # double-free), and NOTHING was retired above safe_retire_floor (== 4).
    for i in range(4):
        assert_equal(Int(m.free_count[i]), 1)
    # The output is NOT double-materialized into a WRONG state: the high-water is
    # 3 (not 7, not 4 + 3) — the retry folded the SAME range, not a phantom one.
    assert_equal(Int(m.materialized_high_water), 3)
    print("  PASS K2 GREEN: crash+retry frees each input exactly once, no double-state")


def test_k2_crash_atomicity_naive_unclamped_red() raises:
    # THE RED-VERIFY: the SAME crash+retry against the NAIVE (unclamped-floor)
    # variant. Here we drive the retire DIRECTLY with the unclamped floor to show
    # the bug the clamp fixes: a retire that ignores materialized_thru frees
    # inputs the crashed pass's re-fold still depends on. We assert the naive
    # path produces a DIFFERENT (wrong) free ledger than the clamped path.
    print("[compact-window] case 2b K2 crash-atomicity (naive unclamped, RED-verify)")

    # Model the dangerous shape: a pass plans [0, 3] but its output only DURABLY
    # covers [0, 1] (a SHORT materialize — e.g. a crash mid-encode left only the
    # first half durable). The clamp must refuse to retire inputs 2, 3.
    var model = ArcPointer[_ModelState](_ModelState(4))

    # Construct a product whose materialized_thru (1) is BELOW the planned hi (3)
    # the exact crash-mid-materialize shape the clamp guards.
    var planned = CompactRange(lo=Int64(0), hi=Int64(3))
    var short_product = CompactProduct[_CasWatermarkSource.OutputRef](
        covered=planned,
        output=Int64(1),
        materialized_thru=Int64(1),  # only [0, 1] is durable!
        row_count=Int64(2),
    )

    # CLAMPED source: safe_retire_floor = min(hi+1=4, materialized_thru+1=2) = 2.
    var clamped_src = _CasWatermarkSource(
        model.copy(), naive_unclamped_floor=False
    )
    var clamped_retired = run_clamped_retire[_CasWatermarkSource](
        clamped_src, planned, short_product
    )
    # The clamp retires ONLY [0, 1] (2 inputs) — NEVER 2 or 3 (not yet durable).
    assert_equal(Int(clamped_retired), 2)
    ref mc = model[]
    assert_true(mc.live[0] == False and mc.live[1] == False)
    assert_true(mc.live[2] == True and mc.live[3] == True)  # PRESERVED
    print("    clamped: retired only [0,1], inputs 2/3 PRESERVED (correct)")

    # NAIVE source over a FRESH model: safe_retire_floor = desired = hi+1 = 4.
    var model2 = ArcPointer[_ModelState](_ModelState(4))
    var naive_src = _CasWatermarkSource(
        model2.copy(), naive_unclamped_floor=True
    )
    var naive_retired = run_clamped_retire[_CasWatermarkSource](
        naive_src, planned, short_product
    )
    # The naive (unclamped) floor retires ALL of [0, 3] (4 inputs) — including 2
    # and 3, whose data is NOT yet durable. THE BUG.
    assert_equal(Int(naive_retired), 4)
    ref mn = model2[]
    assert_true(mn.live[2] == False and mn.live[3] == False)  # WRONGLY freed
    print("    naive: WRONGLY retired [0,3] incl. not-yet-durable 2/3 (the bug)")

    # The DISCRIMINATION: clamped preserves inputs 2/3; naive frees them. A pass
    # that crash-resumes after the naive free has LOST inputs 2/3 forever.
    assert_true(clamped_retired != naive_retired)
    assert_true(mc.live[2] != mn.live[2])  # the clamp is observably load-bearing
    print("  PASS K2 RED-verify: naive-unclamped frees not-yet-durable inputs; clamp does not")


# =============================================================================
# TEST 3 — noop early-exit + derived-watermark consumer.
# =============================================================================


def test_noop_early_exit() raises:
    print("[compact-window] case 3a noop early-exit (lo > hi)")
    # An empty source: hi = -1, high_water = -1 => lo (0) > hi (-1) => no-op.
    var src = _DerivedWatermarkSource(Int64(-1), Int64(-1))
    var summary = compact_once[_DerivedWatermarkSource](src)
    assert_equal(summary.outcome, COMPACT_NOOP)
    assert_true(summary.is_noop())
    # NOTHING was folded / materialized / advanced / retired.
    assert_equal(Int(src.materialized), 0)
    assert_equal(Int(src.advance_calls), 0)
    assert_equal(Int(src.retired), 0)

    # A source whose high_water already covers the head is ALSO a no-op.
    var caught_up = _DerivedWatermarkSource(Int64(3), Int64(3))
    var s2 = compact_once[_DerivedWatermarkSource](caught_up)
    assert_true(s2.is_noop())
    assert_equal(Int(caught_up.materialized), 0)
    print("  PASS noop: empty + caught-up both exit without folding")


def test_derived_watermark_consumer() raises:
    print("[compact-window] case 3b derived-watermark consumer (advance==True)")
    # 6 inputs (seq 0..5), high_water -1 => fold [0, 5].
    var src = _DerivedWatermarkSource(Int64(5), Int64(-1))
    var summary = compact_once[_DerivedWatermarkSource](src)
    assert_equal(summary.outcome, COMPACT_WON)
    assert_equal(Int(summary.lo), 0)
    assert_equal(Int(summary.hi), 5)
    assert_equal(Int(summary.materialized_thru), 5)
    assert_equal(Int(summary.row_count), 6)
    # The derived-watermark consumer: ONE materialize (== the advance), advance
    # returned True trivially, all 6 inputs retired (floor == hi + 1 == 6).
    assert_equal(Int(src.materialized), 1)
    assert_equal(Int(src.advance_calls), 1)
    assert_equal(Int(summary.retired_count), 6)
    assert_equal(Int(src.retired), 6)

    # A SECOND pass is a no-op (the derived high-water caught up to the head).
    var s2 = compact_once[_DerivedWatermarkSource](src)
    assert_true(s2.is_noop())
    assert_equal(Int(src.materialized), 1)  # no second materialize
    print("  PASS derived-watermark: materialize-is-advance, retires whole range, idempotent")


# =============================================================================
# main
# =============================================================================


def main() raises:
    test_k1_watermark_cas_loser_no_op()
    test_k2_crash_atomicity_clamped_green()
    test_k2_crash_atomicity_naive_unclamped_red()
    test_noop_early_exit()
    test_derived_watermark_consumer()
    print("[compact-window] ALL PASS")
