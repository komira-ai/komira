# =============================================================================
# test_log_global_logger_levels.mojo — the module-bound `get_logger` handle and
# the `LogValue` factories no other test reaches.
# =============================================================================
#
# `get_logger[module]()` returns a zero-field handle whose five level methods
# forward to the facade `_emit` with the module baked in. Each method is its own
# function, so a method no test calls is code no test runs. This file calls all
# five on a handle (the output goes to stderr; the assertion is that every call
# returns and that the module-bound handle is the same type for every call).
#
# `LogValue.f64` and `LogValue.text_static` are factories of the runtime-switch
# argument model; their rendered text is asserted against the specialised
# `ArgF64` / `ArgStr` renders, which are what the drain reads.
# =============================================================================

from std.testing import assert_equal

from komira_log import (
    ArgF64,
    ArgI64,
    ArgStr,
    EnvFilter,
    init_logging_with,
)
from komira_log.facade import get_logger
from komira_log.log_value import LogValue


def test_every_level_through_the_handle() raises:
    init_logging_with(EnvFilter(String("trace")))
    var lg = get_logger["komira_log_test_global"]()
    lg.trace["global logger: trace {}"](ArgI64(Int64(1)))
    lg.debug["global logger: debug {}"](ArgI64(Int64(2)))
    lg.info["global logger: info {}"](ArgStr(String("three")))
    lg.warn["global logger: warn {}"](ArgF64(Float64(4.5)))
    lg.error["global logger: error {}"](ArgStr(String("five")))
    print("  test_every_level_through_the_handle PASS")


def test_log_value_f64_renders_like_arg_f64() raises:
    assert_equal(LogValue.f64(Float64(2.5)).render(), ArgF64(Float64(2.5)).render())
    assert_equal(LogValue.f64(Float64(2.5)).render(), String("2.5"))
    print("  test_log_value_f64_renders_like_arg_f64 PASS")


def test_log_value_text_static_renders_the_literal() raises:
    assert_equal(LogValue.text_static("a literal").render(), String("a literal"))
    assert_equal(
        LogValue.text_static("a literal").render(),
        LogValue.text(String("a literal")).render(),
    )
    print("  test_log_value_text_static_renders_the_literal PASS")


def main() raises:
    print("== test_log_global_logger_levels ==")
    test_every_level_through_the_handle()
    test_log_value_f64_renders_like_arg_f64()
    test_log_value_text_static_renders_the_literal()
    print("== test_log_global_logger_levels: ALL PASS ==")
