# =============================================================================
# test_log_config_first_init.mojo — the P1 config's first-install arms, in a
# process where nothing has installed a config yet (each test file is its own
# process; the cases below run in order and depend on that order):
#
#   1. the banner writer with no config installed returns (it has nowhere to
#      write) and installs nothing;
#   2. `init_logging()` on an empty process installs the built-in default;
#   3. `init_logging_with` after that is a no-op: the first install wins.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_log.config import (
    _emit_banner,
    _resolve_config,
    init_logging,
    init_logging_with,
    is_installed,
)
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_INFO


def test_1_a_banner_before_any_install_is_dropped() raises:
    assert_false(is_installed(), "a fresh process has no config")
    _emit_banner([String("cov banner with no config")])
    assert_false(is_installed(), "the banner installed nothing")


def test_2_init_logging_installs_the_built_in_default() raises:
    init_logging()
    assert_true(is_installed())
    assert_equal(Int(_resolve_config()[].global_level()), Int(LEVEL_INFO))


def test_3_a_later_init_logging_with_is_a_no_op() raises:
    init_logging_with(EnvFilter(String("error")))
    assert_equal(
        Int(_resolve_config()[].global_level()),
        Int(LEVEL_INFO),
        "the first install wins",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
