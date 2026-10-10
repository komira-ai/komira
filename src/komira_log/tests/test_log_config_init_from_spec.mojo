# =============================================================================
# test_log_config_init_from_spec.mojo — `init_logging_from_spec` as the FIRST
# init of a process installs the filter its spec names (its own process: no
# other suite's install can have run first).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_log.config import _resolve_config, init_logging_from_spec, is_installed
from komira_log.env_filter import LOG_SPEC_SOURCE_FLAG
from komira_log.levels import LEVEL_WARN, LEVEL_DEBUG


def test_the_first_init_from_a_spec_installs_that_spec() raises:
    assert_false(is_installed(), "a fresh process has no config")
    init_logging_from_spec(
        String("warn,cov_spec_mod=debug"), String(LOG_SPEC_SOURCE_FLAG)
    )
    assert_true(is_installed())
    ref cfg = _resolve_config()[]
    assert_equal(Int(cfg.global_level()), Int(LEVEL_WARN))
    assert_equal(Int(cfg.effective_level("cov_spec_mod")), Int(LEVEL_DEBUG))
    assert_equal(cfg.filter_rule_count(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
