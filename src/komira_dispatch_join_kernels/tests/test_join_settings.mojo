"""The package's three process settings, which a binary sets once at startup
from its flags: `join_gather_unroll_enabled` (default ON),
`join_payload_narrow_enabled` (default ON) and `join_payload_narrow_all_sizes`
(default OFF).

Each is a process-global slot, so the defaults are read FIRST, before anything
configures them, and the configure calls then set each setting independently
of the others.
"""

from std.testing import assert_equal

from komira_dispatch_join_kernels.join_gather_unrolled import (
    configure_join_gather_unroll,
    join_gather_unroll_enabled,
)
from komira_dispatch_join_kernels.join_payload_narrow_exec import (
    configure_join_payload_narrow,
    join_payload_narrow_all_sizes,
    join_payload_narrow_enabled,
)


def test_the_defaults_before_any_configure() raises:
    """Run FIRST. Unconfigured, both levers read ON and the bypass OFF, and
    reading does not change them.
    MUTANT: `_init_pn_on` writing 0: the narrow lever reads OFF."""
    for _ in range(2):
        assert_equal(join_gather_unroll_enabled(), True)
        assert_equal(join_payload_narrow_enabled(), True)
        assert_equal(join_payload_narrow_all_sizes(), False)


def test_configure_sets_each_setting_on_its_own() raises:
    """Every combination of the two narrow settings reads back as set, and the
    unroll setting is independent of both.
    MUTANT: `configure_join_payload_narrow` storing `enabled` into the
    all-sizes slot: (False, True) reads back (True, False)."""
    configure_join_payload_narrow(False, True)
    assert_equal(join_payload_narrow_enabled(), False)
    assert_equal(join_payload_narrow_all_sizes(), True)
    assert_equal(join_gather_unroll_enabled(), True)
    configure_join_payload_narrow(True, True)
    assert_equal(join_payload_narrow_enabled(), True)
    assert_equal(join_payload_narrow_all_sizes(), True)
    configure_join_payload_narrow(False, False)
    assert_equal(join_payload_narrow_enabled(), False)
    assert_equal(join_payload_narrow_all_sizes(), False)

    configure_join_gather_unroll(False)
    assert_equal(join_gather_unroll_enabled(), False)
    assert_equal(join_payload_narrow_enabled(), False)
    configure_join_gather_unroll(True)
    assert_equal(join_gather_unroll_enabled(), True)
    configure_join_payload_narrow(True, False)
    assert_equal(join_payload_narrow_enabled(), True)
    assert_equal(join_payload_narrow_all_sizes(), False)


def main() raises:
    # First: it needs every slot unconfigured.
    test_the_defaults_before_any_configure()
    test_configure_sets_each_setting_on_its_own()
    print("All 2 settings tests passed.")
