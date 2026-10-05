# =============================================================================
# test_log_p1.mojo — komira_log P1 facade unit tests.
# =============================================================================
#
# Covers the P1 acceptance surface:
#   * levels parse + comptime floor + names
#   * EnvFilter parse (--log-level=info,komira_pg=debug) + longest-prefix
#   * per-module effective-level resolution (the gate logic)
#   * the disabled-path gate (a below-threshold level is suppressed)
#   * pattern layout: interpolation, key=value fields, the rendered line shape
#   * structured fields render correctly
#   * timestamp formatting
#
# The facade itself writes to stderr (a process side effect); we exercise the
# GATE + RENDER components directly (the pure functions) plus the LogConfig
# threshold API, which is what the facade consults. A separate smoke test
# exercises a real `log.info(...)` call (it writes to stderr; we assert it
# does not crash).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_log.levels import (
    LEVEL_TRACE,
    LEVEL_DEBUG,
    LEVEL_INFO,
    LEVEL_WARN,
    LEVEL_ERROR,
    LEVEL_OFF,
    parse_level,
    level_name,
)
from komira_log.env_filter import EnvFilter
from komira_log.log_arg import ArgI64, ArgStr, ArgF64, ArgBool, ArgU64, Field
from komira_log.pattern_layout import (
    interpolate,
    render_line,
    format_timestamp_ms,
)
from komira_log.config import LogConfig


# -----------------------------------------------------------------------------
# Levels
# -----------------------------------------------------------------------------


def test_level_ordering() raises:
    assert_true(LEVEL_TRACE < LEVEL_DEBUG, "TRACE < DEBUG")
    assert_true(LEVEL_DEBUG < LEVEL_INFO, "DEBUG < INFO")
    assert_true(LEVEL_INFO < LEVEL_WARN, "INFO < WARN")
    assert_true(LEVEL_WARN < LEVEL_ERROR, "WARN < ERROR")
    assert_true(LEVEL_ERROR < LEVEL_OFF, "ERROR < OFF")
    print("  test_level_ordering PASS")


def test_parse_level() raises:
    assert_equal(parse_level(String("info")).value(), LEVEL_INFO, "info")
    assert_equal(parse_level(String("INFO")).value(), LEVEL_INFO, "INFO")
    assert_equal(parse_level(String("Debug")).value(), LEVEL_DEBUG, "Debug")
    assert_equal(parse_level(String("warn")).value(), LEVEL_WARN, "warn")
    assert_equal(parse_level(String("warning")).value(), LEVEL_WARN, "warning")
    assert_equal(parse_level(String("error")).value(), LEVEL_ERROR, "error")
    assert_equal(parse_level(String("off")).value(), LEVEL_OFF, "off")
    assert_false(parse_level(String("bogus")), "unknown -> None")
    print("  test_parse_level PASS")


def test_level_name() raises:
    assert_equal(String(level_name(LEVEL_INFO)), String("INFO"), "INFO name")
    assert_equal(String(level_name(LEVEL_ERROR)), String("ERROR"), "ERROR")
    assert_equal(String(level_name(LEVEL_TRACE)), String("TRACE"), "TRACE")
    print("  test_level_name PASS")


# -----------------------------------------------------------------------------
# EnvFilter — parse + per-module resolution
# -----------------------------------------------------------------------------


def test_envfilter_global_only() raises:
    var f = EnvFilter(String("info"))
    assert_equal(f.global_level, LEVEL_INFO, "global = INFO")
    assert_equal(f.num_rules(), 0, "no module rules")
    assert_equal(f.effective_level("anything"), LEVEL_INFO, "default to global")
    print("  test_envfilter_global_only PASS")


def test_envfilter_per_module() raises:
    var f = EnvFilter(String("info,komira_pg=debug,komira_http=warn"))
    assert_equal(f.global_level, LEVEL_INFO, "global = INFO")
    assert_equal(f.num_rules(), 2, "two module rules")
    assert_equal(
        f.effective_level("komira_pg"), LEVEL_DEBUG, "komira_pg = DEBUG"
    )
    assert_equal(
        f.effective_level("komira_http"), LEVEL_WARN, "komira_http = WARN"
    )
    assert_equal(
        f.effective_level("komira_job_supervisor"),
        LEVEL_INFO,
        "unmatched module = global INFO",
    )
    print("  test_envfilter_per_module PASS")


def test_envfilter_longest_prefix() raises:
    # A general module rule + a more-specific dotted override coexist; the
    # longest matching prefix wins.
    var f = EnvFilter(
        String("warn,komira_job_supervisor=info,komira_job_supervisor.heartbeat=debug")
    )
    assert_equal(f.global_level, LEVEL_WARN, "global = WARN")
    assert_equal(
        f.effective_level("komira_job_supervisor"),
        LEVEL_INFO,
        "komira_job_supervisor -> INFO (its own rule)",
    )
    assert_equal(
        f.effective_level("komira_job_supervisor.heartbeat"),
        LEVEL_DEBUG,
        "heartbeat -> DEBUG (longer prefix wins over komira_job_supervisor=info)",
    )
    assert_equal(
        f.effective_level("komira_job_supervisor.upload"),
        LEVEL_INFO,
        "komira_job_supervisor.upload -> INFO (parent prefix, no own rule)",
    )
    # A module that merely SHARES a prefix substring (not a dotted boundary)
    # must NOT match: komira_job_supervisorx is not under komira_job_supervisor.
    assert_equal(
        f.effective_level("komira_job_supervisorx"),
        LEVEL_WARN,
        "komira_job_supervisorx -> global WARN (not a dotted-prefix match)",
    )
    print("  test_envfilter_longest_prefix PASS")


def test_envfilter_malformed_tokens_skipped() raises:
    # Empty tokens, an unknown level, and an empty key are all skipped without
    # crashing; the global default stands.
    var f = EnvFilter(String("info,,boguslevel,=debug,komira_x=trace"))
    assert_equal(f.global_level, LEVEL_INFO, "global INFO held")
    assert_equal(f.num_rules(), 1, "only komira_x=trace is valid")
    assert_equal(f.effective_level("komira_x"), LEVEL_TRACE, "komira_x trace")
    print("  test_envfilter_malformed_tokens_skipped PASS")


def test_envfilter_whitespace_tolerant() raises:
    var f = EnvFilter(String(" info , komira_pg = debug "))
    assert_equal(f.global_level, LEVEL_INFO, "trimmed global")
    assert_equal(
        f.effective_level("komira_pg"), LEVEL_DEBUG, "trimmed module rule"
    )
    print("  test_envfilter_whitespace_tolerant PASS")


# -----------------------------------------------------------------------------
# The gate logic — what the facade consults (level >= effective threshold).
# -----------------------------------------------------------------------------


def _admitted(level: UInt8, threshold: UInt8) -> Bool:
    """Mirror the facade gate: a record at `level` is emitted iff
    level >= threshold."""
    return level >= threshold


def test_gate_suppresses_below_threshold() raises:
    # At INFO threshold: DEBUG/TRACE suppressed, INFO/WARN/ERROR admitted.
    assert_false(_admitted(LEVEL_TRACE, LEVEL_INFO), "TRACE suppressed at INFO")
    assert_false(_admitted(LEVEL_DEBUG, LEVEL_INFO), "DEBUG suppressed at INFO")
    assert_true(_admitted(LEVEL_INFO, LEVEL_INFO), "INFO admitted at INFO")
    assert_true(_admitted(LEVEL_WARN, LEVEL_INFO), "WARN admitted at INFO")
    assert_true(_admitted(LEVEL_ERROR, LEVEL_INFO), "ERROR admitted at INFO")
    # At OFF threshold: everything suppressed.
    assert_false(_admitted(LEVEL_ERROR, LEVEL_OFF), "ERROR suppressed at OFF")
    print("  test_gate_suppresses_below_threshold PASS")


def test_config_threshold_api() raises:
    # The LogConfig the facade consults: global + per-module + reconfigure.
    var f = EnvFilter(String("warn,komira_pg=debug"))
    var cfg = LogConfig(f^)
    assert_equal(cfg.global_level(), LEVEL_WARN, "global WARN")
    assert_true(cfg.enabled(), "enabled by default")
    assert_equal(
        cfg.effective_level("komira_pg"), LEVEL_DEBUG, "module override"
    )
    assert_equal(
        cfg.effective_level("komira_other"), LEVEL_WARN, "default to global"
    )
    # Runtime reconfiguration of the global gate.
    cfg.set_global_level(LEVEL_ERROR)
    assert_equal(cfg.global_level(), LEVEL_ERROR, "reconfigured to ERROR")
    # Disable toggle.
    cfg.set_enabled(False)
    assert_false(cfg.enabled(), "disabled")
    print("  test_config_threshold_api PASS")


# -----------------------------------------------------------------------------
# Pattern layout — interpolation, fields, line shape, timestamp.
# -----------------------------------------------------------------------------


def test_interpolate_positional() raises:
    var pos = List[String]()
    pos.append(String("abc"))
    pos.append(String("42"))
    var msg = interpolate(String("job {} started in {}ms"), pos)
    assert_equal(msg, String("job abc started in 42ms"), "two placeholders")
    print("  test_interpolate_positional PASS")


def test_interpolate_escapes_and_extra() raises:
    var pos = List[String]()
    pos.append(String("X"))
    # {{ -> literal {, }} -> literal }, surplus {} stays literal when no arg.
    var msg = interpolate(String("{{literal}} {} and {}"), pos)
    assert_equal(msg, String("{literal} X and {}"), "escapes + surplus")
    print("  test_interpolate_escapes_and_extra PASS")


def test_arg_render() raises:
    assert_equal(ArgI64(Int64(-7)).render(), String("-7"), "i64")
    assert_equal(ArgU64(UInt64(99)).render(), String("99"), "u64")
    assert_equal(ArgStr(String("hi")).render(), String("hi"), "str")
    assert_equal(ArgBool(True).render(), String("true"), "bool true")
    assert_equal(ArgBool(False).render(), String("false"), "bool false")
    print("  test_arg_render PASS")


def test_field_render() raises:
    var fld = Field(String("rows"), ArgI64(Int64(1000)))
    assert_equal(fld.render(), String("rows=1000"), "key=value")
    var fld2 = Field(String("ok"), ArgBool(True))
    assert_equal(fld2.render(), String("ok=true"), "bool field")
    print("  test_field_render PASS")


def test_render_line_shape() raises:
    # Fixed epoch-ms for a deterministic line. 1790812800000 ms =
    # 2026-10-01T00:00:00.000Z.
    var fields = List[String]()
    fields.append(String("phase=DONE"))
    fields.append(String("rows=42"))
    var line = render_line(
        Int64(1790812800000),
        LEVEL_INFO,
        "komira_job_supervisor",
        String("job abc finished"),
        fields,
    )
    assert_equal(
        line,
        String(
            "2026-10-01T00:00:00.000Z INFO [komira_job_supervisor] job abc finished"
            " phase=DONE rows=42"
        ),
        "full rendered line shape",
    )
    print("  test_render_line_shape PASS")


def test_render_line_no_fields() raises:
    var fields = List[String]()
    var line = render_line(
        Int64(1790812800000),
        LEVEL_WARN,
        "komira_pg",
        String("hello"),
        fields,
    )
    assert_equal(
        line,
        String("2026-10-01T00:00:00.000Z WARN [komira_pg] hello"),
        "line with no trailing fields",
    )
    print("  test_render_line_no_fields PASS")


def test_timestamp_format() raises:
    # 0 -> Unix epoch.
    assert_equal(
        format_timestamp_ms(Int64(0)),
        String("1970-01-01T00:00:00.000Z"),
        "epoch",
    )
    # 1790812800000 -> 2026-10-01.
    assert_equal(
        format_timestamp_ms(Int64(1790812800000)),
        String("2026-10-01T00:00:00.000Z"),
        "2026-10-01",
    )
    # Sub-second millis + time-of-day: 1790812861182 ->
    # 2026-10-01T00:01:01.182Z.
    assert_equal(
        format_timestamp_ms(Int64(1790812861182)),
        String("2026-10-01T00:01:01.182Z"),
        "ms + hms",
    )
    print("  test_timestamp_format PASS")


def main() raises:
    print("== test_log_p1 ==")
    test_level_ordering()
    test_parse_level()
    test_level_name()
    test_envfilter_global_only()
    test_envfilter_per_module()
    test_envfilter_longest_prefix()
    test_envfilter_malformed_tokens_skipped()
    test_envfilter_whitespace_tolerant()
    test_gate_suppresses_below_threshold()
    test_config_threshold_api()
    test_interpolate_positional()
    test_interpolate_escapes_and_extra()
    test_arg_render()
    test_field_render()
    test_render_line_shape()
    test_render_line_no_fields()
    test_timestamp_format()
    print("== test_log_p1: ALL PASS ==")
