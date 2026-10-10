# komira_counters/tests/test_keyeq_census.mojo -- the key-equality census.
# `KEYEQ_CENSUS_ENABLED` is a comptime constant and ships False, so `keyeq_record`
# is compiler-erased in the shipped build; the test asserts whichever of the
# two behaviours the constant selects, so it is correct (and not vacuous) in a
# census build too.

from std.testing import TestSuite, assert_equal, assert_true

from komira_counters.keyeq_census import (
    KEYEQ_AGGCD_SERIAL,
    KEYEQ_CENSUS_ENABLED,
    KEYEQ_N_SITES,
    KEYEQ_SLAB_STRIDE16,
    keyeq_read,
    keyeq_record,
    keyeq_reset,
    keyeq_site_name,
)


def test_record_follows_the_gate() raises:
    keyeq_reset()
    keyeq_record(KEYEQ_AGGCD_SERIAL, 12, 5, True)
    keyeq_record(KEYEQ_AGGCD_SERIAL, 40, 40, False)
    comptime if KEYEQ_CENSUS_ENABLED:
        assert_equal(keyeq_read(KEYEQ_AGGCD_SERIAL, 0), 2)  # calls
        assert_equal(keyeq_read(KEYEQ_AGGCD_SERIAL, 1), 45)  # bytes touched
        assert_equal(keyeq_read(KEYEQ_AGGCD_SERIAL, 2), 1)  # hits
        assert_equal(keyeq_read(KEYEQ_AGGCD_SERIAL, 3), 52)  # width sum
        assert_equal(keyeq_read(KEYEQ_AGGCD_SERIAL, 4 + 3), 1)  # 8-15
        assert_equal(keyeq_read(KEYEQ_AGGCD_SERIAL, 4 + 5), 1)  # 32-63
    else:
        # Gated off: the arm does not exist, so nothing was recorded.
        assert_equal(keyeq_read(KEYEQ_AGGCD_SERIAL, 0), 0)
        assert_equal(keyeq_read(KEYEQ_AGGCD_SERIAL, 1), 0)


def test_unrecorded_sites_read_zero_and_have_names() raises:
    keyeq_reset()
    assert_equal(keyeq_read(KEYEQ_SLAB_STRIDE16, 0), 0)
    for s in range(KEYEQ_N_SITES):
        assert_true(keyeq_site_name(s) != String(""))
        # An in-range site has its own name, never the numbered fallback.
        assert_true(not keyeq_site_name(s).startswith("site_"))


def test_out_of_range_site_falls_back_to_its_number() raises:
    # A site id past the table (a newer caller, a stale dump reader) is named
    # by its number rather than dropped or aliased to a real site.
    assert_equal(keyeq_site_name(KEYEQ_N_SITES), String("site_") + String(KEYEQ_N_SITES))
    assert_equal(keyeq_site_name(1000), "site_1000")
    assert_equal(keyeq_site_name(-1), "site_-1")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
