# =============================================================================
# test_log_level_config.mojo — the log level must be CONFIGURABLE, and a
#   misconfiguration must be VISIBLE.
# =============================================================================
#
# ── THE CLAIMS, AND WHY EACH IS A SEPARATE TEST ──────────────────────────────
#   1. The flag a binary takes the directive from, and the source strings the
#      banner prints, are spelled ONCE, so prose and code cannot drift.
#   2. A MALFORMED directive REPORTS itself. It is still skipped — a logging
#      config must never crash the process — but a typo'd level must not take
#      effect as nothing with no evidence anywhere. `EnvFilter` RECORDS what it
#      skipped and the startup banner prints it.
#   3. The startup banner SAYS what it resolved — level, the SOURCE of that
#      level, and the spec — in ONE line, and an unconfigured process says it
#      is unconfigured and how to change that.
#
# ⚠ THESE TESTS INSTALL NOTHING. The process-global config installs ONCE and is
# an intentional forever-leak, so they exercise the pure pieces
# (`EnvFilter`, `log_config_banner_lines`) that the init path composes.
# =============================================================================

from std.testing import assert_true, assert_false, assert_equal

from komira_log.env_filter import (
    EnvFilter,
    LOG_SPEC_FLAG,
    LOG_SPEC_SOURCE_DEFAULT,
    LOG_SPEC_SOURCE_FLAG,
)
from komira_log.config import log_config_banner_lines
from komira_log.levels import (
    LEVEL_DEBUG,
    LEVEL_INFO,
    LEVEL_TRACE,
    LEVEL_WARN,
)


# =============================================================================
# §1 — THE NAMES. Spelled once, asserted here, so prose and code cannot drift.
# =============================================================================


def test_the_flag_and_source_names() raises:
    assert_equal(
        String(LOG_SPEC_FLAG),
        String("--log-level"),
        "the flag the banner tells an operator to pass",
    )
    assert_equal(
        String(LOG_SPEC_SOURCE_FLAG),
        String("--log-level"),
        "the source a binary passes when the spec came from its flag",
    )
    assert_true(
        String(LOG_SPEC_SOURCE_DEFAULT).find(String("built-in default")) >= 0,
        "the default source must say NOBODY CONFIGURED THIS",
    )
    print("  test_the_flag_and_source_names PASS")


def test_an_empty_spec_is_the_built_in_default() raises:
    var f = EnvFilter()
    assert_equal(f.global_level, LEVEL_INFO, "the built-in floor")
    assert_equal(f.num_rules(), 0, "no overrides")
    var g = EnvFilter(String("debug"))
    assert_equal(g.global_level, LEVEL_DEBUG, "a supplied spec takes effect")
    print("  test_an_empty_spec_is_the_built_in_default PASS")


# =============================================================================
# §3 — A MALFORMED DIRECTIVE MUST LEAVE EVIDENCE.
# =============================================================================
def test_malformed_tokens_are_recorded_not_merely_skipped() raises:
    """Still skipped (the process must not crash), but no longer SILENT.

    `boguslevel` is the case that cost the time: an operator types it, the
    global level does NOT change, and nothing anywhere says why."""
    var f = EnvFilter(String("info,,boguslevel,=debug,komira_x=trace,komira_y=verbose"))

    # UNCHANGED behaviour — pinned so this cannot regress into a crash or a
    # silently-different level.
    assert_equal(f.global_level, LEVEL_INFO, "the global default still stands")
    assert_equal(f.num_rules(), 1, "only komira_x=trace is a valid rule")
    assert_equal(f.effective_level("komira_x"), LEVEL_TRACE, "komira_x trace")

    # NEW behaviour — the evidence.
    assert_equal(
        f.num_malformed(),
        3,
        "`boguslevel`, `=debug` and `komira_y=verbose` are the three malformed"
        " tokens; the EMPTY token is not one (a trailing/doubled comma is"
        " formatting, not a typo, and reporting it would be noise)",
    )
    var rep = f.malformed_report()
    assert_true(rep.find(String("boguslevel")) >= 0, "names the bad bare token")
    assert_true(rep.find(String("komira_y=verbose")) >= 0, "names the bad level")
    assert_true(rep.find(String("=debug")) >= 0, "names the empty-key token")
    print("  test_malformed_tokens_are_recorded_not_merely_skipped PASS")


def test_a_wholly_valid_directive_reports_nothing() raises:
    """The CONTROL. A report that fires on a good directive is noise an operator
    learns to ignore, which would cost exactly what silence costs."""
    var f = EnvFilter(String(" info , komira_pg = debug ,komira_http=warn"))
    assert_equal(f.num_malformed(), 0, "nothing malformed here")
    assert_equal(
        f.malformed_report(), String(""), "and therefore NOTHING to report"
    )
    assert_equal(f.effective_level("komira_http"), LEVEL_WARN, "still parses")
    print("  test_a_wholly_valid_directive_reports_nothing PASS")


# =============================================================================
# §4 — THE STARTUP LINE. One line that says what the logging is doing.
# =============================================================================
def test_the_banner_states_level_source_and_spec() raises:
    var f = EnvFilter(String("debug,komira_pg=warn"))
    var lines = log_config_banner_lines(
        f, String(LOG_SPEC_SOURCE_FLAG), String("debug,komira_pg=warn")
    )
    assert_equal(len(lines), 1, "a clean config is exactly ONE line")
    var b = lines[0]
    assert_true(b.find(String("komira_log:")) >= 0, "prefixed, so it is greppable")
    assert_true(b.find(String("level=DEBUG")) >= 0, "the RESOLVED level")
    assert_true(b.find(String("source=--log-level")) >= 0, "WHERE it came from")
    assert_true(b.find(String("debug,komira_pg=warn")) >= 0, "the spec verbatim")
    assert_true(b.find(String("module_overrides=1")) >= 0, "and the override count")
    print("  test_the_banner_states_level_source_and_spec PASS")


def test_the_banner_names_the_default_when_nothing_configured() raises:
    """A process nobody configured is here, and this line is the cheapest
    possible answer to "why is nothing being logged"."""
    var f = EnvFilter()
    var lines = log_config_banner_lines(
        f, String(LOG_SPEC_SOURCE_DEFAULT), String("")
    )
    assert_equal(len(lines), 1, "one line")
    assert_true(lines[0].find(String("level=INFO")) >= 0, "the compiled floor")
    assert_true(
        lines[0].find(String("built-in default")) >= 0,
        "and it must say NOBODY CONFIGURED THIS, not merely report INFO",
    )
    assert_true(
        lines[0].find(String("--log-level")) >= 0,
        "naming the flag an operator would pass is the whole point of the"
        " line — a level with no instruction is a dead end",
    )
    print("  test_the_banner_names_the_default_when_nothing_configured PASS")


def test_the_banner_adds_a_second_line_for_a_malformed_directive() raises:
    var f = EnvFilter(String("info,boguslevel"))
    var lines = log_config_banner_lines(
        f, String(LOG_SPEC_SOURCE_FLAG), String("info,boguslevel")
    )
    assert_equal(
        len(lines), 2, "the malformed report is its OWN line, never appended to"
        " the status line — an operator greps for one or the other"
    )
    assert_true(lines[1].find(String("boguslevel")) >= 0, "names the token")
    assert_true(
        lines[1].find(String("trace")) >= 0 and lines[1].find(String("error")) >= 0,
        "and names the accepted vocabulary, so the fix is in the message",
    )
    print("  test_the_banner_adds_a_second_line_for_a_malformed_directive PASS")


def main() raises:
    print("test_log_level_config")
    test_the_flag_and_source_names()
    test_an_empty_spec_is_the_built_in_default()
    test_malformed_tokens_are_recorded_not_merely_skipped()
    test_a_wholly_valid_directive_reports_nothing()
    test_the_banner_states_level_source_and_spec()
    test_the_banner_names_the_default_when_nothing_configured()
    test_the_banner_adds_a_second_line_for_a_malformed_directive()
    print("test_log_level_config: ALL PASS")
