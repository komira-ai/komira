# =============================================================================
# The spill-envelope verdict vocabulary and the two process-global witnesses
# of this package: which aggregate driver and route ran (`agg_driver_witness`)
# and how many streaming passes the 0-key scalar route made
# (`scalar_agg_stream_pass_counter`).
#
# Every name, every slot and every reset is read back here, because each of
# these values exists only to be read back: a slot that two names share, a
# reset that misses one slot, or a describe() arm that prints its neighbour's
# token would each make a trace or a regression test say the wrong thing
# while every query still returns the right rows.
#
# Each test file is its own binary, so these process-global slots start at
# their init values here and nothing else in the process moves them; the
# tests run in file order, and the first to read a slot is the one that
# asserts its init value.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_dispatch_agg_folds.agg_spill_envelope import (
    SPILL_ENV_ADMIT,
    SPILL_ENV_DECLINE_KEY_SURROGATE,
    SPILL_ENV_DECLINE_NO_AGGS,
    SPILL_ENV_DECLINE_NO_KEYS,
    SPILL_ENV_DECLINE_OP_UNMAPPED,
    SPILL_ENV_DECLINE_STATE_WIDTH,
    SPILL_ENV_NOT_CONSULTED,
    SpillEnvelopeVerdict,
)
from komira_dispatch_agg_folds.agg_driver_witness import (
    AGG_DRIVER_CMTOPK,
    AGG_DRIVER_GRACE_HASH_SPILL,
    AGG_DRIVER_GRACE_HASH_SPILL_YIELD,
    AGG_DRIVER_INMEM_LEAF,
    AGG_DRIVER_NONE,
    AGG_DRIVER_RESIDENT_GRACE_HASH_SPILL,
    AGG_DRIVER_STRATEGY_LEAF,
    AGG_DRIVER_VECTOR_DECODE_LEAF,
    AGG_ROUTE_NONE,
    AGG_ROUTE_SPILL_OR_STRATEGY,
    AGG_ROUTE_STRATEGY_LEAF,
    AGG_ROUTE_VECTOR_DECODE,
    agg_driver_fire_count,
    agg_driver_last,
    agg_driver_name,
    agg_driver_record,
    agg_route_last,
    agg_route_name,
    agg_route_record,
    agg_spill_env_last,
    agg_str_minmax_fold_calls,
    agg_str_minmax_fold_record_call,
    agg_str_minmax_fold_record_row_work,
    agg_str_minmax_fold_row_passes,
    reset_agg_driver_witness,
)
from komira_dispatch_agg_folds.scalar_agg_stream_pass_counter import (
    reset_scalar_agg_stream_pass_count,
    scalar_agg_stream_pass_count,
    scalar_agg_stream_pass_incr,
)


# =============================================================================
# agg_spill_envelope
# =============================================================================


def test_verdict_defaults_and_fields() raises:
    """The one-argument verdict takes the documented defaults, and every
    explicit argument lands in its own field. Catches a default swapped
    between two fields (`at` defaulting to 0 instead of -1)."""
    var d = SpillEnvelopeVerdict(SPILL_ENV_DECLINE_NO_KEYS)
    assert_equal(d.code, SPILL_ENV_DECLINE_NO_KEYS)
    assert_equal(d.at, -1)
    assert_equal(d.n_keys, 0)
    assert_equal(d.n_aggs, 0)
    assert_equal(d.n_avg_expanded, 0)
    assert_false(d.keys_need_decode)
    var v = SpillEnvelopeVerdict(SPILL_ENV_ADMIT, 7, 2, 5, 1, True)
    assert_equal(v.at, 7)
    assert_equal(v.n_keys, 2)
    assert_equal(v.n_aggs, 5)
    assert_equal(v.n_avg_expanded, 1)
    assert_true(v.keys_need_decode)


def test_only_admit_is_admitted() raises:
    """`admitted()` is exactly `code == SPILL_ENV_ADMIT`: true for ADMIT and
    false for NOT_CONSULTED and every decline. Catches `!=` or `>=` there."""
    assert_true(SpillEnvelopeVerdict(SPILL_ENV_ADMIT).admitted())
    assert_false(SpillEnvelopeVerdict(SPILL_ENV_NOT_CONSULTED).admitted())
    for c in range(SPILL_ENV_DECLINE_NO_KEYS, SPILL_ENV_DECLINE_STATE_WIDTH + 1):
        assert_false(SpillEnvelopeVerdict(c).admitted())


def test_describe_names_every_code() raises:
    """Each code prints its own token, the admit token carries its four
    terms, the descriptor declines carry `at`, and a code outside the
    vocabulary prints `decline(unknown)`. Catches two arms swapped (the
    NO_KEYS and NO_AGGS strings exchanged) and a dropped `at`."""
    assert_equal(
        SpillEnvelopeVerdict(SPILL_ENV_NOT_CONSULTED).describe(),
        "not_consulted",
    )
    assert_equal(
        SpillEnvelopeVerdict(SPILL_ENV_ADMIT, -1, 3, 4, 2, True).describe(),
        "admit(keys=3,key_decode=True,aggs=4,avg_expanded=2)",
    )
    assert_equal(
        SpillEnvelopeVerdict(SPILL_ENV_DECLINE_NO_KEYS).describe(),
        "decline(no_group_keys)",
    )
    assert_equal(
        SpillEnvelopeVerdict(SPILL_ENV_DECLINE_NO_AGGS).describe(),
        "decline(no_aggs)",
    )
    assert_equal(
        SpillEnvelopeVerdict(SPILL_ENV_DECLINE_KEY_SURROGATE, 1).describe(),
        "decline(key1_no_canonical_surrogate)",
    )
    assert_equal(
        SpillEnvelopeVerdict(SPILL_ENV_DECLINE_OP_UNMAPPED, 3).describe(),
        "decline(agg3_op_outside_row_map)",
    )
    assert_equal(
        SpillEnvelopeVerdict(SPILL_ENV_DECLINE_STATE_WIDTH, 2).describe(),
        "decline(agg2_state_wider_than_one_cell)",
    )
    assert_equal(SpillEnvelopeVerdict(99).describe(), "decline(unknown)")


# =============================================================================
# agg_driver_witness
# =============================================================================


def test_driver_and_route_names() raises:
    """Every driver and route code has its own name and anything else is
    `none`. Catches two codes mapped to one name, which would make the
    witness unable to tell two drivers apart."""
    assert_equal(agg_driver_name(AGG_DRIVER_NONE), "none")
    assert_equal(
        agg_driver_name(AGG_DRIVER_VECTOR_DECODE_LEAF), "vector_decode_leaf"
    )
    assert_equal(
        agg_driver_name(AGG_DRIVER_GRACE_HASH_SPILL), "grace_hash_spill"
    )
    assert_equal(agg_driver_name(AGG_DRIVER_STRATEGY_LEAF), "strategy_leaf")
    assert_equal(
        agg_driver_name(AGG_DRIVER_GRACE_HASH_SPILL_YIELD),
        "grace_hash_spill_yield",
    )
    assert_equal(agg_driver_name(AGG_DRIVER_INMEM_LEAF), "inmem_leaf")
    assert_equal(
        agg_driver_name(AGG_DRIVER_RESIDENT_GRACE_HASH_SPILL),
        "resident_grace_hash_spill",
    )
    assert_equal(agg_driver_name(AGG_DRIVER_CMTOPK), "cmtopk_certified_topk")
    assert_equal(agg_driver_name(42), "none")
    assert_equal(agg_route_name(AGG_ROUTE_NONE), "none")
    assert_equal(agg_route_name(AGG_ROUTE_VECTOR_DECODE), "vector_decode")
    assert_equal(
        agg_route_name(AGG_ROUTE_SPILL_OR_STRATEGY), "spill_or_strategy"
    )
    assert_equal(agg_route_name(AGG_ROUTE_STRATEGY_LEAF), "strategy_leaf")
    assert_equal(agg_route_name(-3), "none")


def test_driver_route_and_envelope_slots_are_separate() raises:
    """A fresh process reads zero in every slot; a record stores the driver,
    the envelope code and one fire, the route is stored on its own, and a
    second record overwrites the last-values and adds a second fire. Catches
    two `_Global` keys made equal (the driver and the route would then read
    each other's value) and a store written as an add."""
    assert_equal(agg_driver_last(), AGG_DRIVER_NONE)
    assert_equal(agg_route_last(), AGG_ROUTE_NONE)
    assert_equal(agg_spill_env_last(), 0)
    assert_equal(agg_driver_fire_count(), 0)

    agg_route_record(AGG_ROUTE_SPILL_OR_STRATEGY)
    agg_driver_record(AGG_DRIVER_STRATEGY_LEAF, SPILL_ENV_DECLINE_NO_AGGS)
    assert_equal(agg_route_last(), AGG_ROUTE_SPILL_OR_STRATEGY)
    assert_equal(agg_driver_last(), AGG_DRIVER_STRATEGY_LEAF)
    assert_equal(agg_spill_env_last(), SPILL_ENV_DECLINE_NO_AGGS)
    assert_equal(agg_driver_fire_count(), 1)

    agg_driver_record(AGG_DRIVER_GRACE_HASH_SPILL, SPILL_ENV_ADMIT)
    assert_equal(agg_driver_last(), AGG_DRIVER_GRACE_HASH_SPILL)
    assert_equal(agg_spill_env_last(), SPILL_ENV_ADMIT)
    assert_equal(agg_driver_fire_count(), 2)
    assert_equal(agg_route_last(), AGG_ROUTE_SPILL_OR_STRATEGY)


def test_string_minmax_arming_slots_count_independently() raises:
    """The arming slot and the work slot count their own events: two calls
    and one row pass read back as 2 and 1. Catches the two keys made equal
    (both would read 3)."""
    var calls0 = agg_str_minmax_fold_calls()
    var rows0 = agg_str_minmax_fold_row_passes()
    agg_str_minmax_fold_record_call()
    agg_str_minmax_fold_record_call()
    agg_str_minmax_fold_record_row_work()
    assert_equal(agg_str_minmax_fold_calls() - calls0, 2)
    assert_equal(agg_str_minmax_fold_row_passes() - rows0, 1)


def test_reset_clears_all_six_slots() raises:
    """After moving every slot, the reset puts each back: driver and route to
    NONE, the envelope to NOT_CONSULTED (-1, not 0), and the three counts to
    0. Catches a reset that misses a slot or writes 0 to the envelope."""
    agg_route_record(AGG_ROUTE_VECTOR_DECODE)
    agg_driver_record(AGG_DRIVER_CMTOPK, SPILL_ENV_DECLINE_STATE_WIDTH)
    agg_str_minmax_fold_record_call()
    agg_str_minmax_fold_record_row_work()
    reset_agg_driver_witness()
    assert_equal(agg_driver_last(), AGG_DRIVER_NONE)
    assert_equal(agg_route_last(), AGG_ROUTE_NONE)
    assert_equal(agg_spill_env_last(), SPILL_ENV_NOT_CONSULTED)
    assert_equal(agg_driver_fire_count(), 0)
    assert_equal(agg_str_minmax_fold_calls(), 0)
    assert_equal(agg_str_minmax_fold_row_passes(), 0)


# =============================================================================
# scalar_agg_stream_pass_counter
# =============================================================================


def test_stream_pass_counter_counts_and_resets() raises:
    """A fresh slot reads 0 (the init's zero write), three passes read 3, and
    the reset reads 0 again. Catches an init that leaves the slot
    uninitialised and an increment of 2."""
    assert_equal(scalar_agg_stream_pass_count(), 0)
    scalar_agg_stream_pass_incr()
    scalar_agg_stream_pass_incr()
    scalar_agg_stream_pass_incr()
    assert_equal(scalar_agg_stream_pass_count(), 3)
    reset_scalar_agg_stream_pass_count()
    assert_equal(scalar_agg_stream_pass_count(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
