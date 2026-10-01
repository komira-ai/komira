# =============================================================================
# test_log_facade_smoke.mojo — end-to-end `log.<level>(...)` facade smoke.
# =============================================================================
#
# Exercises the REAL facade call sites (the contract P2 inherits): the bare
# `log.info[fmt, module](*args)` ambient reach, the level gate, structured
# positional + key=value args. These calls write to stderr; the test asserts
# the process does not crash and the facade resolves its ambient config.
#
# The disabled path is exercised: a `log.trace(...)` at the default INFO
# threshold is suppressed (produces no output, takes the gate-and-return path).
# We can't easily capture stderr from inside the test, so the assertion here is
# "no crash + config installed"; the OUTPUT SHAPE is asserted by
# test_log_p1.test_render_line_shape (the pure render path the facade uses).
# =============================================================================

from std.testing import assert_true, assert_equal

import komira_log as log
from komira_log import (
    ArgI64,
    ArgStr,
    ArgF64,
    ArgBool,
    Field,
    EnvFilter,
    init_logging_with,
    is_installed,
    LEVEL_INFO,
)


def test_init_and_install() raises:
    # Install an explicit filter so the test is deterministic. Idempotent — a
    # second call is a no-op.
    var f = EnvFilter(String("info,komira_log_test=debug"))
    init_logging_with(f^)
    assert_true(is_installed(), "config installed after init")
    print("  test_init_and_install PASS")


def test_info_emits() raises:
    # A real INFO call — admitted at the INFO global threshold. Writes to
    # stderr; asserts no crash.
    log.info["facade smoke: plain info", "komira_log_test"]()
    log.info["facade smoke: job {} started", "komira_log_test"](
        ArgStr(String("job-123"))
    )
    print("  test_info_emits PASS")


def test_structured_fields_emit() raises:
    # Positional args fill {}; trailing Field args render as key=value.
    log.warn[
        "facade smoke: upload failed for {}", "komira_log_test"
    ](
        ArgStr(String("artifact.bin")),
        Field(String("attempt"), ArgI64(Int64(3))),
        Field(String("fatal"), ArgBool(False)),
    )
    log.error["facade smoke: rate {} exceeded", "komira_log_test"](
        ArgF64(Float64(99.5))
    )
    print("  test_structured_fields_emit PASS")


def test_disabled_path_no_crash() raises:
    # TRACE/DEBUG are below the INFO global threshold → gated out (no output,
    # no render). Asserting no crash exercises the gate-and-return path.
    log.trace["facade smoke: should be suppressed", "komira_log_test"](
        ArgI64(Int64(1))
    )
    # komira_log_test has a DEBUG override → DEBUG admitted, but TRACE still
    # below DEBUG, so this TRACE is gated by the per-module level too.
    log.debug["facade smoke: debug under module override", "komira_log_test"]()
    print("  test_disabled_path_no_crash PASS")


def test_tagless_default_module() raises:
    # The module tag defaults to "komira" when omitted.
    log.info["facade smoke: tagless default module"]()
    print("  test_tagless_default_module PASS")


def main() raises:
    print("== test_log_facade_smoke ==")
    test_init_and_install()
    test_info_emits()
    test_structured_fields_emit()
    test_disabled_path_no_crash()
    test_tagless_default_module()
    print("== test_log_facade_smoke: ALL PASS ==")
