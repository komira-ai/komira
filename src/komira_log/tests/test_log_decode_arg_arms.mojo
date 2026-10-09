# =============================================================================
# test_log_decode_arg_arms.mojo — every arm of the two arg decoders
# (`decode_one`'s `_decode_args` and `decode_one_to_view`'s `_decode_args_kv`),
# driven by hand-built records so each tag's payload and each truncation stop
# is reached on purpose.
#
# Why hand-built: the producers in this package never write a short payload, so
# the "stop at the end of the blob" guards only run on a record whose bytes are
# wrong. Each truncation case is built so that the NEXT tag's payload IS
# present: a decoder that skipped the short arg and went on (instead of
# stopping) would decode that next arg and the message would show it.
#
# Every case runs through BOTH decoders: they are two copies of one arg walk,
# and a guard on one and not the other is the half fix their header warns of.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_spsc_ring.spsc_ring import OVERFLOW_BLOCK

from komira_log.log_arg import (
    ARG_I64,
    ARG_F64,
    ARG_STR,
    ARG_BOOL,
    ARG_U64,
    ARG_FIELD,
)
from komira_log.levels import LEVEL_INFO
from komira_log.engine.drain import (
    decode_one,
    decode_one_to_view,
    render_record_view,
)
from komira_log.engine.log_event_record import (
    LogEventRecord,
    REC_LOG,
    REC_METRIC,
    FLAG_HAS_ARG_OVERFLOW,
)
from komira_log.engine.log_record_view import LogRecordView
from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.site_dictionary import SiteDictionary, fnv1a_32
from komira_log.engine.calibration import CalibrationAnchor
from komira_log.engine.metric_emit import build_metric_record
from komira_log.engine.span_emit import build_span_open, build_span_close
from komira_log.engine.span_drain import OpenSpanTable, drain_unified

from komira_metrics.metric_point import counter_point


comptime _FMT = "a={} b={}"
comptime _MOD = "cov_decode"


def _anchor() -> CalibrationAnchor:
    return CalibrationAnchor(
        tick0=UInt64(0),
        wall0_ns=UInt64(1_780_272_000) * UInt64(1_000_000_000),
        tick_hz=UInt64(1_000_000_000),
    )


def _dict() -> SiteDictionary:
    var d = SiteDictionary()
    d.register[_FMT, _MOD]()
    return d^


def _rec(n_args: Int, blob: List[UInt8]) -> LogEventRecord:
    """A REC_LOG for `_FMT` whose inline arg blob is exactly `blob`."""
    var rec = LogEventRecord()
    rec.kind = REC_LOG
    rec.level = LEVEL_INFO
    rec.site_id = fnv1a_32(_FMT)
    rec.module_id = fnv1a_32(_MOD)
    rec.n_args = UInt8(n_args)
    for i in range(len(blob)):
        rec.arg_blob[i] = blob[i]
    rec.arg_inline_len = UInt16(len(blob))
    return rec^


def _u64_le(mut b: List[UInt8], v: UInt64):
    for i in range(8):
        b.append(UInt8(Int((v >> (UInt64(i) * 8)) & UInt64(0xFF))))


def _assert_decodes(
    rec: LogEventRecord,
    want_message: String,
    want_fields: List[String],
    what: String,
) raises:
    """Both decoders: the view's message and key=value pairs, and the text
    line's tail (the line starts with a wall-clock timestamp)."""
    var ring = LogRecordRing(capacity=4, overflow_policy=OVERFLOW_BLOCK)
    var d = _dict()
    var view = decode_one_to_view(rec, ring, d, _anchor())
    assert_equal(view.message, want_message, what + String(" (view message)"))
    assert_equal(
        len(view.arg_keys), len(want_fields), what + String(" (view fields)")
    )
    for i in range(len(want_fields)):
        assert_equal(
            view.arg_keys[i] + String("=") + view.arg_vals[i],
            want_fields[i],
            what + String(" (view field)"),
        )
    var line = decode_one(rec, ring, d, _anchor())
    var tail = String(" INFO [") + String(_MOD) + String("] ") + want_message
    for i in range(len(want_fields)):
        tail += String(" ") + want_fields[i]
    assert_true(
        line.endswith(tail),
        what + String(" (text line) got <") + line + String("> want tail <")
        + tail + String(">"),
    )


# -----------------------------------------------------------------------------
# Whole payloads: the U64 and BOOL arms (no other test reaches them through
# the drain) with values that tell the arms apart.
# -----------------------------------------------------------------------------


def test_u64_arm_renders_unsigned_with_the_high_bit_set() raises:
    """All-ones is 18446744073709551615 unsigned and -1 signed: a U64 arm that
    rendered through the I64 path would print -1."""
    var b = List[UInt8]()
    b.append(ARG_U64)
    b.append(ARG_U64)
    _u64_le(b, UInt64(0xFFFFFFFFFFFFFFFF))
    _u64_le(b, UInt64(0x8000000000000001))
    _assert_decodes(
        _rec(2, b),
        String("a=18446744073709551615 b=9223372036854775809"),
        List[String](),
        String("u64"),
    )


def test_f64_arm_renders_the_bit_pattern_as_a_double() raises:
    """2.5 and -0.125: an F64 arm that rendered the bits as an integer would
    print 4612811918334230528."""
    var b = List[UInt8]()
    b.append(ARG_F64)
    b.append(ARG_F64)
    _u64_le(b, UInt64(0x4004000000000000))
    _u64_le(b, UInt64(0xBFC0000000000000))
    _assert_decodes(
        _rec(2, b), String("a=2.5 b=-0.125"), List[String](), String("f64")
    )


def test_bool_arm_reads_any_nonzero_byte_as_true() raises:
    var b = List[UInt8]()
    b.append(ARG_BOOL)
    b.append(ARG_BOOL)
    b.append(UInt8(2))
    b.append(UInt8(0))
    _assert_decodes(
        _rec(2, b), String("a=true b=false"), List[String](), String("bool")
    )


def test_unknown_tag_renders_a_question_mark_and_keeps_going() raises:
    """Pins current behaviour: the decoder cannot know an unknown tag's payload
    length, so it renders `?` and consumes no bytes after the tag. The next
    arg decodes correctly only when the unknown tag carried no payload, as
    here; producer and drain ship in one binary, so a tag the drain does not
    know is not expected in practice."""
    var b = List[UInt8]()
    b.append(UInt8(0x7F))
    b.append(ARG_I64)
    _u64_le(b, UInt64(41))
    _assert_decodes(
        _rec(2, b), String("a=? b=41"), List[String](), String("unknown tag")
    )


# -----------------------------------------------------------------------------
# Truncated payloads. Layout of each: [tag under test, ARG_BOOL] then a payload
# one byte short for the tag under test. A decoder that stops leaves both
# placeholders; one that skipped the short arg would read the BOOL's byte.
# -----------------------------------------------------------------------------


def _truncated(tag: UInt8, short_payload: List[UInt8]) -> LogEventRecord:
    var b = List[UInt8]()
    b.append(tag)
    b.append(ARG_BOOL)
    for i in range(len(short_payload)):
        b.append(short_payload[i])
    return _rec(2, b)


def _ones(n: Int) -> List[UInt8]:
    var p = List[UInt8]()
    for _ in range(n):
        p.append(UInt8(1))
    return p^


def test_short_u64_stops_the_walk() raises:
    _assert_decodes(
        _truncated(ARG_U64, _ones(7)),
        String("a={} b={}"),
        List[String](),
        String("short u64"),
    )


def test_short_f64_stops_the_walk() raises:
    _assert_decodes(
        _truncated(ARG_F64, _ones(7)),
        String("a={} b={}"),
        List[String](),
        String("short f64"),
    )


def test_short_bool_stops_the_walk() raises:
    """A BOOL with no byte at all, then an unknown tag (which needs no
    payload): a decoder that skipped the short BOOL would print `?`."""
    var b = List[UInt8]()
    b.append(ARG_BOOL)
    b.append(UInt8(0x7F))
    _assert_decodes(
        _rec(2, b), String("a={} b={}"), List[String](), String("short bool")
    )


def test_short_str_length_stops_the_walk() raises:
    """One byte where the two-byte length belongs."""
    _assert_decodes(
        _truncated(ARG_STR, _ones(1)),
        String("a={} b={}"),
        List[String](),
        String("short str length"),
    )


def test_short_field_key_length_stops_the_walk() raises:
    _assert_decodes(
        _truncated(ARG_FIELD, _ones(1)),
        String("a={} b={}"),
        List[String](),
        String("short field key length"),
    )


def test_short_field_value_length_stops_the_walk() raises:
    """The key is whole (`k`); one byte where the value's two-byte length
    belongs. The pair is dropped, not emitted with an empty value."""
    var p = List[UInt8]()
    p.append(UInt8(1))
    p.append(UInt8(0))
    p.append(UInt8(ord("k")))
    p.append(UInt8(1))
    _assert_decodes(
        _truncated(ARG_FIELD, p),
        String("a={} b={}"),
        List[String](),
        String("short field value length"),
    )


# -----------------------------------------------------------------------------
# Unregistered site, the view re-render with ragged key/value lists, and the
# two unified-drain arms no other test reaches.
# -----------------------------------------------------------------------------


def test_unregistered_site_renders_its_id_in_both_decoders() raises:
    var rec = _rec(0, List[UInt8]())
    rec.site_id = UInt32(0xDEADBEEF)
    var ring = LogRecordRing(capacity=4, overflow_policy=OVERFLOW_BLOCK)
    var d = _dict()
    var want = String("<unknown site ") + String(Int(UInt32(0xDEADBEEF))) + ">"
    assert_equal(decode_one(rec, ring, d, _anchor()), want)
    assert_equal(decode_one_to_view(rec, ring, d, _anchor()).message, want)


def _view(var keys: List[String], var vals: List[String]) -> LogRecordView:
    return LogRecordView(
        LEVEL_INFO,
        UInt16(0),
        UInt32(0),
        UInt32(0),
        UInt64(0),
        UInt64(0),
        Int64(0),
        String("msg"),
        String("mod"),
        keys^,
        vals^,
    )


def test_render_record_view_pairs_only_complete_fields() raises:
    """Two keys and one value (and the reverse): exactly one `key=value`, never
    a read past the shorter list."""
    var more_keys = render_record_view(
        _view([String("k1"), String("k2")], [String("v1")])
    )
    assert_true(
        more_keys.endswith(String(" INFO [mod] msg k1=v1")),
        String("more keys than values: <") + more_keys + ">",
    )
    var more_vals = render_record_view(
        _view([String("k1")], [String("v1"), String("v2")])
    )
    assert_true(
        more_vals.endswith(String(" INFO [mod] msg k1=v1")),
        String("more values than keys: <") + more_vals + ">",
    )


def test_unified_drain_counts_an_undecodable_metric() raises:
    """A REC_METRIC carrying the overflow flag has no decoder: refused AND
    counted, not half-decoded and not silently dropped."""
    var p = counter_point(
        name_id=UInt32(7),
        scope_id=UInt32(8),
        attrset_id=UInt32(9),
        value=Int64(10),
        start_time_unix_ns=UInt64(1),
        time_unix_ns=UInt64(2),
    )
    var rec = build_metric_record(p, UInt64(5)).value().copy()
    rec.flags = rec.flags | FLAG_HAS_ARG_OVERFLOW
    var ring = LogRecordRing(capacity=4, overflow_policy=OVERFLOW_BLOCK)
    assert_true(ring.try_push(rec), "pushed")
    var spans = OpenSpanTable()
    var res = drain_unified(ring, 0, _dict(), _anchor(), spans)
    assert_equal(len(res.metric_points), 0, "no point decoded")
    assert_equal(
        Int(ring.metric_record_dropped_count()), 1, "the refusal is counted"
    )


def test_unified_drain_names_an_unregistered_span_by_id() raises:
    """A span whose name the dictionary does not hold is still emitted, named
    `__id_<site id>`, rather than dropped."""
    var ring = LogRecordRing(capacity=4, overflow_policy=OVERFLOW_BLOCK)
    var open = build_span_open["cov.unregistered.span", _MOD](
        UInt64(11), UInt64(0), UInt64(1), UInt64(0), LEVEL_INFO, UInt64(100)
    )
    assert_true(ring.try_push(open), "open pushed")
    assert_true(ring.try_push(build_span_close(UInt64(11), UInt64(200))), "close")
    var spans = OpenSpanTable()
    var res = drain_unified(ring, 0, _dict(), _anchor(), spans)
    assert_equal(len(res.span_lines), 1, "one completed span")
    var want = (
        String('"name":"__id_')
        + String(Int(fnv1a_32("cov.unregistered.span")))
        + String('"')
    )
    assert_true(
        want in res.span_lines[0],
        String("got <") + res.span_lines[0] + String("> want ") + want,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
