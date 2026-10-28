# =============================================================================
# test_join_gates -- the settings, pure predicates and witnesses of the join
# build's levers, with no join and no dispatcher: BLOOML1 (decline a bloom over
# an L1-resident index), BLOOMSEL (the composite probe's sampled bloom latch),
# the phase-split size gate, the probe NULL mask, and the layout and
# parallel-build counters.
# =============================================================================
#
# What each test catches:
#   * `test_bloom_l1_index_bytes_and_boundary`: the index arithmetic, at the
#     exact row counts where a power-of-two capacity puts the 16 KiB and 32 KiB
#     budgets (n=512 declines, n=513 keeps). Counting `build_indices` on the
#     nobi layout, or the split arrays on the fused one, moves the boundary.
#   * `test_bloom_l1_setting_is_a_value_default_off`: an unconfigured process
#     declines nothing; a negative budget is OFF, not "decline everything".
#   * `test_bloomsel_latch_and_setting`: `seen == 0` never disarms; the integer
#     percent compare is exact at the boundary; a 0 percent is read as the
#     default 100, and values above 100 are clamped.
#   * `test_phase_split_gate`: each of the four refusal conditions, the
#     payload-inline width in the index bytes, and the OFF setting.
#   * `test_probe_null_mask`: an all-valid probe allocates nothing; a NULL row
#     is excluded and rows past the column's end read as valid.
#   * `test_layout_and_parallel_build_counters`: the hot probe recorder counts
#     once per process until reset; the span keeps the maximum.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.primitive_array import PrimitiveArray

from komira_op_join_build.join_bloom_l1_resident import (
    BLOOM_L1_DEFAULT_BUDGET_BYTES,
    BLOOM_L1_L1D_BYTES,
    bloom_l1_budget_bytes,
    bloom_l1_configure,
    bloom_l1_declined_count,
    bloom_l1_declined_rows,
    bloom_l1_index_bytes,
    bloom_l1_kept_count,
    bloom_l1_note_declined,
    bloom_l1_note_kept,
    bloom_l1_reset_config,
    bloom_l1_should_decline,
    reset_bloom_l1_counters,
)
from komira_op_join_build.join_bloom_selectivity import (
    BLOOMSEL_DEFAULT_PASS_PCT,
    bloomsel_configure,
    bloomsel_disarmed_count,
    bloomsel_kept_count,
    bloomsel_note_disarmed,
    bloomsel_note_kept,
    bloomsel_note_saved,
    bloomsel_pass_pct,
    bloomsel_reset_config,
    bloomsel_saved_checks,
    bloomsel_should_disarm,
    bloomsel_window_rows,
    reset_bloomsel_counters,
)
from komira_op_join_build.join_layout_counter import (
    join_layout_build_fused_count,
    join_layout_build_nobi_count,
    join_layout_probe_fused_count,
    join_layout_probe_nobi_count,
    join_layout_record_build,
    join_layout_record_probe_hot,
    reset_join_layout_counters,
)
from komira_op_join_build.join_parallel_build_counter import (
    join_parallel_build_fire_count,
    join_parallel_build_fire_incr,
    join_parallel_build_record_worker_span,
    join_parallel_build_worker_span,
    reset_join_parallel_build,
)
from komira_op_join_build.join_probe_null_mask import ProbeNullMask
from komira_op_join_build.join_probe_phase_split import (
    JOIN_PS_BATCH,
    JOIN_PS_MIN_HEADROOM,
    JOIN_PS_MIN_INDEX_BYTES,
    join_phase_split_admits,
    join_phase_split_configure,
    join_phase_split_declined,
    join_phase_split_fired,
    join_phase_split_index_bytes,
    join_phase_split_record,
    join_phase_split_reset_config,
    reset_join_phase_split_counters,
)


def _cap_for(n: Int) -> Int:
    """The capacity `HashJoinBuilder.build` sizes for `n` rows."""
    var min_cap = max(Int(Float64(n) * 1.4) + 1, 16)
    var cap = 1
    while cap < min_cap:
        cap *= 2
    return cap


def test_bloom_l1_index_bytes_and_boundary() raises:
    # h2o/j1's 100-row build: 2,048 B of table + 1,600 B of entries.
    assert_equal(_cap_for(100), 256)
    assert_equal(bloom_l1_index_bytes(100, 256, 2, True, True), 3_648)
    # The split layout counts build_keys + next_chain; nobi=False adds
    # build_indices.
    assert_equal(bloom_l1_index_bytes(100, 256, 2, False, True), 3_648)
    assert_equal(bloom_l1_index_bytes(100, 256, 2, True, False), 4_448)
    # The payload-inline entry is four words.
    assert_equal(bloom_l1_index_bytes(100, 256, 4, True, True), 5_248)
    # The quantised boundary of the default budget.
    var b512 = bloom_l1_index_bytes(512, _cap_for(512), 2, True, True)
    var b513 = bloom_l1_index_bytes(513, _cap_for(513), 2, True, True)
    assert_equal(b512, 16_384)
    assert_equal(b513, 16_400)
    assert_true(bloom_l1_should_decline(b512, BLOOM_L1_DEFAULT_BUDGET_BYTES))
    assert_false(bloom_l1_should_decline(b513, BLOOM_L1_DEFAULT_BUDGET_BYTES))
    # The full-L1d budget moves it to 1,024 rows.
    var b1024 = bloom_l1_index_bytes(1024, _cap_for(1024), 2, True, True)
    var b1025 = bloom_l1_index_bytes(1025, _cap_for(1025), 2, True, True)
    assert_true(bloom_l1_should_decline(b1024, BLOOM_L1_L1D_BYTES))
    assert_false(bloom_l1_should_decline(b1025, BLOOM_L1_L1D_BYTES))


def test_bloom_l1_setting_is_a_value_default_off() raises:
    bloom_l1_reset_config()
    assert_equal(bloom_l1_budget_bytes(), 0, "unconfigured is OFF")
    assert_false(bloom_l1_should_decline(0, bloom_l1_budget_bytes()))
    bloom_l1_configure(-5)
    assert_equal(bloom_l1_budget_bytes(), 0, "a negative budget is OFF")
    assert_false(bloom_l1_should_decline(0, -5), "never decline everything")
    bloom_l1_configure(16_384)
    assert_equal(bloom_l1_budget_bytes(), 16_384)
    bloom_l1_reset_config()
    assert_equal(bloom_l1_budget_bytes(), 0)
    # Witness counters: both dispositions, and the declined row total.
    reset_bloom_l1_counters()
    bloom_l1_note_kept()
    bloom_l1_note_declined(100)
    bloom_l1_note_declined(0)
    assert_equal(bloom_l1_kept_count(), 1)
    assert_equal(bloom_l1_declined_count(), 2)
    assert_equal(bloom_l1_declined_rows(), 100)
    reset_bloom_l1_counters()
    assert_equal(bloom_l1_kept_count() + bloom_l1_declined_count(), 0)


def test_bloomsel_latch_and_setting() raises:
    assert_false(bloomsel_should_disarm(0, 0, 100), "no evidence, no disarm")
    assert_true(bloomsel_should_disarm(64, 64, 100))
    assert_false(bloomsel_should_disarm(63, 64, 100))
    # 3/4 = 75%: disarms at 75, not at 76.
    assert_true(bloomsel_should_disarm(3, 4, 75))
    assert_false(bloomsel_should_disarm(3, 4, 76))

    bloomsel_reset_config()
    assert_equal(bloomsel_window_rows(), 0, "unconfigured is OFF")
    assert_equal(bloomsel_pass_pct(), BLOOMSEL_DEFAULT_PASS_PCT)
    bloomsel_configure(65_536, 0)
    assert_equal(bloomsel_window_rows(), 65_536)
    assert_equal(bloomsel_pass_pct(), 100, "a zero percent reads as unset")
    bloomsel_configure(1_000, 250)
    assert_equal(bloomsel_pass_pct(), 100, "clamped to 100")
    bloomsel_configure(1_000, 90)
    assert_equal(bloomsel_pass_pct(), 90)
    bloomsel_configure(-1, 90)
    assert_equal(bloomsel_window_rows(), 0, "a negative window is OFF")
    bloomsel_reset_config()

    reset_bloomsel_counters()
    bloomsel_note_kept()
    bloomsel_note_disarmed()
    bloomsel_note_disarmed()
    bloomsel_note_saved(10)
    bloomsel_note_saved(0)
    assert_equal(bloomsel_kept_count(), 1)
    assert_equal(bloomsel_disarmed_count(), 2)
    assert_equal(bloomsel_saved_checks(), 10)
    reset_bloomsel_counters()
    assert_equal(bloomsel_saved_checks(), 0)


def test_phase_split_gate() raises:
    join_phase_split_reset_config()
    # 16 B entries; 32 B under payload-inline.
    assert_equal(join_phase_split_index_bytes(10, 16, True), 16 * 8 + 10 * 16)
    assert_equal(
        join_phase_split_index_bytes(10, 16, True, pay_inline=True),
        16 * 8 + 10 * 32,
    )
    # A 1.5M-row build is over the 32 MiB default (2^22 slots + 16 B a row);
    # a 100K-row one is under.
    var big = 1_500_000
    var cap_big = _cap_for(big)
    assert_true(
        join_phase_split_index_bytes(big, cap_big, True) >= JOIN_PS_MIN_INDEX_BYTES
    )
    assert_true(join_phase_split_admits(big, cap_big, True, 4096, 65536))
    assert_false(
        join_phase_split_admits(100_000, _cap_for(100_000), True, 4096, 65536),
        "a cache-resident index is declined",
    )
    # The probe must fill one batch, and the buffer must have the headroom.
    assert_false(
        join_phase_split_admits(big, cap_big, True, JOIN_PS_BATCH - 1, 65536)
    )
    assert_false(
        join_phase_split_admits(
            big, cap_big, True, 4096, JOIN_PS_MIN_HEADROOM - 1
        )
    )
    # A lowered threshold admits the small build; OFF refuses the big one.
    join_phase_split_configure(True, 1024)
    assert_true(join_phase_split_admits(1_000, _cap_for(1_000), True, 4096, 65536))
    join_phase_split_configure(False)
    assert_false(join_phase_split_admits(big, cap_big, True, 4096, 65536))
    join_phase_split_reset_config()
    assert_true(join_phase_split_admits(big, cap_big, True, 4096, 65536))

    reset_join_phase_split_counters()
    assert_false(join_phase_split_fired())
    assert_false(join_phase_split_declined())
    join_phase_split_record(True)
    assert_true(join_phase_split_fired())
    assert_false(join_phase_split_declined())
    join_phase_split_record(False)
    assert_true(join_phase_split_declined())
    reset_join_phase_split_counters()


def test_probe_null_mask() raises:
    var valid = PrimitiveArray[DType.int64].allocate_nullable(4)
    for i in range(4):
        valid.set(i, Int64(i))
    var m0 = ProbeNullMask(valid, 4)
    assert_false(m0.has_nulls)
    assert_equal(len(m0.valid), 0, "an all-valid probe allocates nothing")
    for i in range(4):
        assert_false(m0.excludes(i))

    var nk = PrimitiveArray[DType.int64].allocate_nullable(4)
    for i in range(4):
        nk.set(i, Int64(0))
    nk._set_null(2)
    # Six rows over a four-row column: rows 4 and 5 read as valid.
    var m = ProbeNullMask(nk, 6)
    assert_true(m.has_nulls)
    assert_equal(len(m.valid), 6)
    assert_false(m.excludes(0))
    assert_true(m.excludes(2), "the NULL row (value bits zero) is excluded")
    assert_true(m.is_null_at(2))
    assert_false(m.excludes(4))
    assert_false(m.excludes(5))


def test_layout_and_parallel_build_counters() raises:
    reset_join_layout_counters()
    join_layout_record_build("serial", True, True, 10, False)
    join_layout_record_build("serial", False, True, 10, False)
    assert_equal(join_layout_build_nobi_count(), 1)
    assert_equal(join_layout_build_fused_count(), 2)
    # The hot recorder latches: one probe count per process until reset.
    for _ in range(5):
        join_layout_record_probe_hot("probe_inner_chunk", True, True)
    assert_equal(join_layout_probe_nobi_count(), 1)
    assert_equal(join_layout_probe_fused_count(), 1)
    # The default-off arm records nothing.
    reset_join_layout_counters()
    join_layout_record_probe_hot("probe_inner_chunk", False, False)
    assert_equal(join_layout_probe_fused_count(), 0)
    join_layout_record_probe_hot("probe_inner_chunk", False, True)
    assert_equal(join_layout_probe_fused_count(), 1)
    reset_join_layout_counters()

    reset_join_parallel_build()
    join_parallel_build_fire_incr()
    join_parallel_build_fire_incr()
    join_parallel_build_record_worker_span(3)
    join_parallel_build_record_worker_span(7)
    join_parallel_build_record_worker_span(5)
    assert_equal(join_parallel_build_fire_count(), 2)
    assert_equal(join_parallel_build_worker_span(), 7, "the span keeps the max")
    reset_join_parallel_build()
    assert_equal(join_parallel_build_worker_span(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
