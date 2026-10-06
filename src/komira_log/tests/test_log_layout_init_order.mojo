# =============================================================================
# test_log_layout_init_order.mojo — `init_logging_from_spec` selects the line
#   layout whatever ran first.
# =============================================================================
#
# The filter installs ONCE per process (the first install wins), but the
# layout the binary's `--log-format` / deployed-platform flags ask for must
# apply even when something installed the filter before the binary's init:
#   1. a bare `log.*` call, which lazily installs the built-in default;
#   2. an explicit `init_logging()`.
# A layout decision gated behind the install-once guard would leave such a
# process on the text layout for good.
#
# Each test file is its own process, so this one may install the global
# config. The tests run in order and share it.
# =============================================================================

from std.testing import assert_true, assert_false

import komira_log as log
from komira_log import (
    init_logging,
    init_logging_from_spec,
    is_installed,
    log_layout_is_json,
    select_log_layout,
    LOG_SPEC_SOURCE_FLAG,
)


def test_a_log_call_before_init_does_not_pin_the_text_layout() raises:
    select_log_layout(String("text"), False)
    assert_false(is_installed(), "nothing is installed at process start")
    log.info["layout init-order test: before init", "komira_log_test"]()
    assert_true(is_installed(), "the first log call lazily installed a config")
    assert_false(log_layout_is_json(), "the default layout is text")

    init_logging_from_spec(
        String("info"), String(LOG_SPEC_SOURCE_FLAG), String("json"), False
    )
    assert_true(
        log_layout_is_json(),
        "--log-format=json applies after a lazy install",
    )
    print("  test_a_log_call_before_init_does_not_pin_the_text_layout PASS")


def test_the_deployed_platform_fact_applies_after_init_logging() raises:
    select_log_layout(String("text"), False)
    init_logging()
    assert_true(is_installed(), "still installed")
    assert_false(log_layout_is_json(), "text before the flag path runs")

    init_logging_from_spec(String(""), String(LOG_SPEC_SOURCE_FLAG), String(""), True)
    assert_true(
        log_layout_is_json(),
        "an empty --log-format on a deployed platform selects JSON",
    )

    init_logging_from_spec(
        String(""), String(LOG_SPEC_SOURCE_FLAG), String("text"), True
    )
    assert_false(
        log_layout_is_json(), "an explicit --log-format=text overrides the fact"
    )
    print("  test_the_deployed_platform_fact_applies_after_init_logging PASS")


def main() raises:
    print("test_log_layout_init_order")
    test_a_log_call_before_init_does_not_pin_the_text_layout()
    test_the_deployed_platform_fact_applies_after_init_logging()
    print("test_log_layout_init_order: ALL PASS")
