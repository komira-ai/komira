# komira_counters/tests/test_strdrain_counter.mojo -- the drain counters of
# `strdrain_counter`: totals, the eight site slots, the four owner slots, the
# radix / count-distinct arms, the converted aggdict site, and reset.

from std.testing import TestSuite, assert_equal

from komira_counters.strdrain_counter import (
    SD_OWNER_CD_PARALLEL,
    SD_SITE_AGG_DICT,
    SD_SITE_OTHER,
    reset_strdrain_counters,
    strdrain_aggdict_builder_values,
    strdrain_aggdict_calls,
    strdrain_aggdict_stage_values,
    strdrain_bytes,
    strdrain_calls,
    strdrain_cdp_builder_values,
    strdrain_cdp_calls,
    strdrain_cdp_stage_values,
    strdrain_note_aggdict_builder,
    strdrain_note_aggdict_call,
    strdrain_note_aggdict_stage,
    strdrain_note_cdp_builder,
    strdrain_note_cdp_call,
    strdrain_note_cdp_stage,
    strdrain_note_from_strings,
    strdrain_note_owner,
    strdrain_note_rx_builder,
    strdrain_note_rx_call,
    strdrain_note_rx_stage,
    strdrain_note_site,
    strdrain_owner_values,
    strdrain_rx_builder_values,
    strdrain_rx_calls,
    strdrain_rx_stage_values,
    strdrain_site_values,
    strdrain_values,
)


def test_from_strings_totals() raises:
    reset_strdrain_counters()
    strdrain_note_from_strings(10, 300)
    strdrain_note_from_strings(0, 0)
    strdrain_note_from_strings(5, 20)
    assert_equal(strdrain_calls(), 3)
    assert_equal(strdrain_values(), 15)
    assert_equal(strdrain_bytes(), 320)


def test_site_slots_partition_and_the_sum_is_a_lower_bound() raises:
    reset_strdrain_counters()
    strdrain_note_from_strings(100, 0)
    strdrain_note_site(SD_SITE_AGG_DICT, 30)
    strdrain_note_site(SD_SITE_OTHER, 20)
    strdrain_note_site(3, 0)
    var total = 0
    for s in range(8):
        total += strdrain_site_values(s)
    assert_equal(strdrain_site_values(SD_SITE_AGG_DICT), 30)
    assert_equal(strdrain_site_values(SD_SITE_OTHER), 20)
    assert_equal(strdrain_site_values(3), 0)
    assert_equal(total, 50)
    assert_equal(strdrain_values(), 100)


def test_owner_slots() raises:
    reset_strdrain_counters()
    strdrain_note_owner(0, 1)
    strdrain_note_owner(1, 2)
    strdrain_note_owner(2, 4)
    strdrain_note_owner(SD_OWNER_CD_PARALLEL, 8)
    strdrain_note_owner(0, 0)
    assert_equal(strdrain_owner_values(0), 1)
    assert_equal(strdrain_owner_values(1), 2)
    assert_equal(strdrain_owner_values(2), 4)
    assert_equal(strdrain_owner_values(3), 8)


def test_radix_and_count_distinct_arms() raises:
    reset_strdrain_counters()
    strdrain_note_rx_call()
    strdrain_note_rx_stage(7)
    strdrain_note_rx_builder(9)
    strdrain_note_cdp_call()
    strdrain_note_cdp_call()
    strdrain_note_cdp_stage(11)
    strdrain_note_cdp_builder(13)
    assert_equal(strdrain_rx_calls(), 1)
    assert_equal(strdrain_rx_stage_values(), 7)
    assert_equal(strdrain_rx_builder_values(), 9)
    assert_equal(strdrain_cdp_calls(), 2)
    assert_equal(strdrain_cdp_stage_values(), 11)
    assert_equal(strdrain_cdp_builder_values(), 13)


def test_aggdict_site_and_reset() raises:
    reset_strdrain_counters()
    strdrain_note_aggdict_call()
    strdrain_note_aggdict_stage(3)
    strdrain_note_aggdict_builder(4)
    assert_equal(strdrain_aggdict_calls(), 1)
    assert_equal(strdrain_aggdict_stage_values(), 3)
    assert_equal(strdrain_aggdict_builder_values(), 4)
    strdrain_note_from_strings(1, 1)
    strdrain_note_site(0, 1)
    strdrain_note_owner(0, 1)
    strdrain_note_rx_call()
    strdrain_note_cdp_call()
    reset_strdrain_counters()
    assert_equal(strdrain_aggdict_calls(), 0)
    assert_equal(strdrain_aggdict_stage_values(), 0)
    assert_equal(strdrain_aggdict_builder_values(), 0)
    assert_equal(strdrain_calls(), 0)
    assert_equal(strdrain_values(), 0)
    assert_equal(strdrain_bytes(), 0)
    assert_equal(strdrain_site_values(0), 0)
    assert_equal(strdrain_owner_values(0), 0)
    assert_equal(strdrain_rx_calls(), 0)
    assert_equal(strdrain_cdp_calls(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
