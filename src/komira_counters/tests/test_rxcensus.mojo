# komira_counters/tests/test_rxcensus.mojo -- add, read and reset of the
# regexp census table. `rxcensus_add` itself is never gated (only the per-row
# call sites are), so it counts in every build.

from std.testing import TestSuite, assert_equal

from komira_counters.rxcensus import (
    RXC_ARM_CALLS,
    RXC_DICTMAT_BYTES,
    RXC_N_SLOTS,
    RXC_REPLACE_CALLS,
    RXC_REPLACE_ROWS,
    rxcensus_add,
    rxcensus_read,
    rxcensus_reset,
)


def test_slots_are_independent() raises:
    rxcensus_reset()
    rxcensus_add(RXC_REPLACE_CALLS, 1)
    rxcensus_add(RXC_REPLACE_ROWS, 1000)
    rxcensus_add(RXC_REPLACE_ROWS, 24)
    assert_equal(rxcensus_read(RXC_REPLACE_CALLS), 1)
    assert_equal(rxcensus_read(RXC_REPLACE_ROWS), 1024)
    assert_equal(rxcensus_read(RXC_ARM_CALLS), 0)


def test_reset_clears_every_slot() raises:
    for i in range(RXC_N_SLOTS):
        rxcensus_add(i, i + 1)
    assert_equal(rxcensus_read(RXC_DICTMAT_BYTES), 11)
    rxcensus_reset()
    for i in range(RXC_N_SLOTS):
        assert_equal(rxcensus_read(i), 0)


def test_a_slot_out_of_range_is_dropped_not_written() raises:
    rxcensus_reset()
    # NON-RAISING by contract: an instrument must not change control flow.
    rxcensus_add(RXC_N_SLOTS, 5)
    rxcensus_add(-1, 5)
    for i in range(RXC_N_SLOTS):
        assert_equal(rxcensus_read(i), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
