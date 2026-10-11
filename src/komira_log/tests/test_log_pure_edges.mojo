# =============================================================================
# test_log_pure_edges.mojo — the edge arms of komira_log's pure helpers: the
# lone-brace arms of `interpolate`, the OFF and out-of-range level names, the
# sticky `LineWrite` verdict, the time and composite rotation policies, the
# trailing partial line of a merged segment file, the constructor refusals,
# module-only registration, the redaction rules' spacing / auth-scheme /
# e-mail / UTF-8 cap arms, and the trace header helpers.
#
# Each case states the defect it catches; none depends on wall-clock time or
# on another case's state.
# =============================================================================

from std.io import FileHandle
from std.os import remove
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_runtime_paths import test_tmpdir

from komira_log.env_filter import EnvFilter
from komira_log.levels import (
    LEVEL_TRACE,
    LEVEL_DEBUG,
    LEVEL_INFO,
    LEVEL_WARN,
    LEVEL_ERROR,
    LEVEL_OFF,
    level_name,
)
from komira_log.log_arg import ArgU64, ArgBool
from komira_log.log_write import (
    LineWrite,
    LOG_WRITE_COMPLETE,
    LOG_WRITE_FATAL,
)
from komira_log.pattern_layout import interpolate
from komira_log.structured_log import (
    redact_log_text,
    _truncate_utf8,
    trace_id_from_header,
    qualified_trace,
    REDACTED,
    REDACTED_EMAIL,
    TRUNCATED_SUFFIX,
)
from komira_log.engine.merge import merge_segment_files
from komira_log.engine.output_sink import LogSink
from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.rotation import RotationPolicy
from komira_log.engine.shared_engine import SharedEngine
from komira_log.engine.site_dictionary import SiteDictionary, fnv1a_32


def _scratch(name: String) raises -> String:
    """A path under this run's private $TEST_TMPDIR. Raises when it is unset:
    a fixed /tmp path would be shared by concurrent runs."""
    return test_tmpdir() + String("/komira_log_pure_") + name


def _rm(path: String):
    try:
        remove(path)
    except:
        pass


# -----------------------------------------------------------------------------
# pattern_layout / levels / log_write
# -----------------------------------------------------------------------------


def test_interpolate_copies_lone_braces_verbatim() raises:
    """A `{` that is not `{{`/`{}` and a `}` that is not `}}` are literal
    text: dropping or doubling either would corrupt every message that holds
    a JSON fragment."""
    var no_args = List[String]()
    assert_equal(interpolate(String("a{b}c"), no_args), String("a{b}c"))
    assert_equal(interpolate(String("{"), no_args), String("{"))
    assert_equal(interpolate(String("}"), no_args), String("}"))
    assert_equal(interpolate(String("x}}y{{z"), no_args), String("x}y{z"))


def test_level_name_of_every_level_and_of_an_unknown_one() raises:
    """Runtime values (a list, not literals), so the compiler cannot fold the
    comparison chain away and every arm is the one that runs in production."""
    var levels: List[UInt8] = [
        LEVEL_TRACE, LEVEL_DEBUG, LEVEL_INFO, LEVEL_WARN, LEVEL_ERROR,
        LEVEL_OFF, UInt8(200),
    ]
    var want: List[String] = [
        String("TRACE"), String("DEBUG"), String("INFO"), String("WARN"),
        String("ERROR"), String("OFF"), String("?"),
    ]
    for i in range(len(levels)):
        assert_equal(String(level_name(levels[i])), want[i])


def test_line_write_verdict_is_sticky() raises:
    """Once a line is COMPLETE a later failure observation must not rewrite
    the verdict or the errno: the loop is over."""
    var lw = LineWrite(4)
    assert_equal(lw.observe(4, Int32(0)), LOG_WRITE_COMPLETE)
    assert_equal(lw.observe(-1, Int32(9)), LOG_WRITE_COMPLETE)
    assert_equal(Int(lw.last_errno), 0, "the stale failure is not recorded")
    assert_equal(lw.written, 4, "nothing more is counted")
    var dead = LineWrite(4)
    assert_equal(dead.observe(-1, Int32(9)), LOG_WRITE_FATAL)
    assert_equal(dead.observe(4, Int32(0)), LOG_WRITE_FATAL, "fatal sticks")
    assert_equal(dead.written, 0)


# -----------------------------------------------------------------------------
# rotation / merge / constructor refusals
# -----------------------------------------------------------------------------


def test_rotation_none_never_fires() raises:
    var p = RotationPolicy.none()
    assert_false(p.should_rotate(1 << 40, Int64(0), Int64(1) << 40))


def test_rotation_by_time_fires_at_the_interval_not_before() raises:
    var p = RotationPolicy.by_time(1000)
    assert_false(p.should_rotate(1 << 40, Int64(5), Int64(1004)), "999 ms")
    assert_true(p.should_rotate(0, Int64(5), Int64(1005)), "exactly 1000 ms")
    assert_equal(p.keep, -1, "keep defaults to RETAIN_ALL")


def test_rotation_composite_fires_on_either_bound() raises:
    var p = RotationPolicy.composite(100, 1000, keep=3)
    assert_false(p.should_rotate(99, Int64(0), Int64(999)), "neither bound")
    assert_true(p.should_rotate(100, Int64(0), Int64(0)), "size bound")
    assert_true(p.should_rotate(0, Int64(0), Int64(1000)), "time bound")
    assert_equal(p.keep, 3)


def test_rotation_by_time_ignores_size() raises:
    var p = RotationPolicy.by_time(1000)
    assert_false(p.should_rotate(1 << 40, Int64(0), Int64(0)))


def test_merge_keeps_a_trailing_line_with_no_newline() raises:
    var path = _scratch("partial.core0.log")
    var f = FileHandle(path, "w")
    f.write(String("2026-10-01T00:00:00.000Z a\n2026-10-01T00:00:01.000Z b"))
    f.close()
    var got = merge_segment_files([path])
    _rm(path)
    assert_equal(len(got), 2, "the unterminated last line is a record")
    assert_equal(got[1], String("2026-10-01T00:00:01.000Z b"))


def test_a_ring_of_no_capacity_is_refused() raises:
    """Refused by `LogRecordRing` itself (its message names it), before the
    SPSC ring underneath is built; 0 and a negative capacity alike."""
    for cap in [0, -1]:
        var refused = False
        try:
            _ = LogRecordRing(capacity=cap)
        except e:
            refused = True
            assert_true(
                String("LogRecordRing: capacity must be > 0") in String(e),
                String(e),
            )
        assert_true(refused, String("capacity ") + String(cap) + " must raise")


def test_an_engine_of_no_workers_is_refused() raises:
    var refused = False
    try:
        _ = SharedEngine(num_workers=0, filter=EnvFilter())
    except e:
        refused = True
        assert_true(String("num_workers must be > 0") in String(e), String(e))
    assert_true(refused, "num_workers 0 must raise")


def test_per_core_segments_of_no_cores_is_refused() raises:
    var refused = False
    try:
        _ = LogSink.per_core_segments(_scratch("nocores"), 0, RotationPolicy.none())
    except e:
        refused = True
        assert_true(String("num_cores must be > 0") in String(e), String(e))
    assert_true(refused, "num_cores 0 must raise")


# -----------------------------------------------------------------------------
# site dictionary / arg encoders
# -----------------------------------------------------------------------------


def test_register_module_alone_is_idempotent() raises:
    var d = SiteDictionary()
    d.register_module["cov_module_only"]()
    d.register_module["cov_module_only"]()
    assert_equal(len(d.modules), 1, "registered once")
    var got = d.lookup_module(fnv1a_32("cov_module_only"))
    assert_true(got.__bool__(), "the module resolves")
    assert_equal(got.value(), String("cov_module_only"))
    assert_false(d.lookup_module(UInt32(1)).__bool__(), "a miss is None")
    assert_false(d.lookup_fmt(UInt32(1)).__bool__(), "a fmt miss is None")


def test_list_encoders_of_u64_and_bool() raises:
    var buf = List[UInt8]()
    ArgU64(UInt64(0x8877665544332211)).encode_into(buf)
    ArgBool(True).encode_into(buf)
    ArgBool(False).encode_into(buf)
    assert_equal(len(buf), 10)
    for i in range(8):
        assert_equal(Int(buf[i]), 0x11 * (i + 1), String("byte ") + String(i))
    assert_equal(Int(buf[8]), 1, "true is 1")
    assert_equal(Int(buf[9]), 0, "false is 0")


# -----------------------------------------------------------------------------
# structured_log: redaction and trace helpers (ASCII inputs)
# -----------------------------------------------------------------------------


def test_redaction_allows_spaces_around_the_separator() raises:
    """`token = abc` and `Token : abc` are bindings too; the mixed-case key is
    matched on the lower-cased shadow and printed as written."""
    assert_equal(
        redact_log_text(String("token = abc rest")),
        String("token = ") + String(REDACTED) + String(" rest"),
    )
    assert_equal(
        redact_log_text(String("x Token :  ABC rest")),
        String("x Token :  ") + String(REDACTED) + String(" rest"),
    )


def test_redaction_keeps_the_auth_scheme_and_hides_the_credential() raises:
    """`authorization: Bearer X` keeps `Bearer` (which scheme failed is half
    the diagnosis) and redacts X; a scheme with nothing after it has nothing
    to redact."""
    assert_equal(
        redact_log_text(String("authorization: Bearer eyJ.x.y done")),
        String("authorization: Bearer ") + String(REDACTED) + String(" done"),
    )
    assert_equal(
        redact_log_text(String("authorization: Negotiate")),
        String("authorization: Negotiate"),
    )


def test_redaction_of_emails_with_digits_capitals_and_a_full_stop() raises:
    """Digits and capitals belong to the address; the sentence's full stop
    does not."""
    assert_equal(
        redact_log_text(String("mail Ann9@Mail1.Example.COM.")),
        String("mail ") + String(REDACTED_EMAIL) + String("."),
    )


def test_utf8_cap_backs_off_a_split_code_point() raises:
    """Cap 2 lands inside the two-byte `é` after `a`: the cut moves back to 1
    rather than emitting half a code point."""
    var got = _truncate_utf8(String("aé"), 2)
    assert_equal(got, String("a") + String(TRUNCATED_SUFFIX))
    assert_equal(_truncate_utf8(String("aé"), 3), String("aé"), "fits")


def test_trace_id_from_header_and_qualified_trace() raises:
    assert_equal(trace_id_from_header(String("abc123/45;o=1")), String("abc123"))
    assert_equal(trace_id_from_header(String("abc;o=1")), String("abc"))
    assert_equal(trace_id_from_header(String("abc def")), String("abc"))
    assert_equal(trace_id_from_header(String("/45")), String(""))
    assert_equal(trace_id_from_header(String("")), String(""))
    assert_equal(
        qualified_trace(String("abc"), String("proj")),
        String("projects/proj/traces/abc"),
    )
    assert_equal(qualified_trace(String(""), String("proj")), String(""))
    assert_equal(qualified_trace(String("abc"), String("")), String(""))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
