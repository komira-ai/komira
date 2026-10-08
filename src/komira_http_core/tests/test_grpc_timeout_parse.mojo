# =============================================================================
# test_grpc_timeout_parse.mojo: the server's grpc-timeout parse and deadline
# =============================================================================
#
# Spec: grpc/doc/PROTOCOL-HTTP2.md
#     Timeout      -> "grpc-timeout" TimeoutValue TimeoutUnit
#     TimeoutValue -> {positive integer as ASCII string of at most 8 digits}
#     TimeoutUnit  -> "H" / "M" / "S" / "m" / "u" / "n"
# The reject rules follow grpc-go's `decodeTimeout`
# (internal/transport/http_util.go): shorter than 2 bytes, longer than 9, an
# unknown unit, a non-digit value. The reason texts are komira's own; unlike
# grpc-go's they do not echo the peer's value.
#
# What each case catches:
#   units         a wrong multiplier for any of the six units.
#   bound         a 9-digit value accepted, or the 8-digit maximum refused.
#   zero          a legal zero read as "no deadline" (it is already expired).
#   malformed     each reject arm, with its exact reason, and that a
#                 malformed value is never ABSENT (absent = unbounded call).
#   find          absent header -> ABSENT; several valid fields -> the last;
#                 any malformed field -> MALFORMED even when a valid one
#                 follows (grpc-go's operateHeaders keeps the error).
#   content-type  only application/grpc and application/grpc+* are subject.
#   deadline      arrival + timeout, expiry at `now >= deadline`, and
#                 saturation for 99999999H (a wrap would expire at once).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_core.codec.h2.hpack import HpackHeader
from komira_http_core.transport.grpc_timeout import (
    GRPC_TIMEOUT_ABSENT,
    GRPC_TIMEOUT_MALFORMED,
    GRPC_TIMEOUT_SET,
    GrpcTimeout,
    find_grpc_timeout,
    grpc_deadline_at_arrival,
    is_grpc_h2_content_type,
    parse_grpc_timeout_value,
)


def _set(value: String, micros: Int) raises:
    var t = parse_grpc_timeout_value(value)
    assert_equal(Int(t.state), Int(GRPC_TIMEOUT_SET), value + ": state")
    assert_equal(t.micros, micros, value + ": micros")
    assert_equal(t.error, String(""), value + ": no error")


def _bad(value: String, reason: String) raises:
    var t = parse_grpc_timeout_value(value)
    assert_equal(Int(t.state), Int(GRPC_TIMEOUT_MALFORMED), value + ": state")
    assert_equal(t.error, reason, value + ": reason")
    assert_equal(t.micros, 0, value + ": micros")


def test_units() raises:
    _set(String("1H"), 3_600_000_000)
    _set(String("7H"), 25_200_000_000)
    _set(String("1M"), 60_000_000)
    _set(String("3M"), 180_000_000)
    _set(String("1S"), 1_000_000)
    _set(String("10S"), 10_000_000)
    _set(String("1m"), 1_000)
    _set(String("500m"), 500_000)
    _set(String("1u"), 1)
    _set(String("250u"), 250)
    _set(String("1000n"), 1)
    _set(String("1001n"), 2)  # rounded up, never shortened
    _set(String("1n"), 1)


def test_eight_digit_bound() raises:
    _set(String("99999999S"), 99_999_999_000_000)
    _set(String("99999999H"), 359_999_996_400_000_000)
    _set(String("00000001m"), 1_000)
    _set(String("99999999n"), 100_000)
    _bad(String("123456789S"), String("timeout string is too long"))
    _bad(String("000000001S"), String("timeout string is too long"))
    _bad(String("999999999n"), String("timeout string is too long"))


def test_zero_is_set_not_absent() raises:
    _set(String("0S"), 0)
    _set(String("0n"), 0)
    _set(String("00000000H"), 0)


def test_malformed_reasons() raises:
    _bad(String(""), String("timeout string is too short"))
    _bad(String("S"), String("timeout string is too short"))
    _bad(String("1"), String("timeout string is too short"))
    _bad(String("1234"), String("timeout unit is not recognized"))
    _bad(String("1s"), String("timeout unit is not recognized"))
    _bad(String("5X"), String("timeout unit is not recognized"))
    _bad(String("-1S"), String("timeout value is not a decimal number"))
    _bad(String("+1S"), String("timeout value is not a decimal number"))
    _bad(String("9a1S"), String("timeout value is not a decimal number"))
    _bad(String(" 1S"), String("timeout value is not a decimal number"))
    _bad(String("é1S"), String("timeout value is not a decimal number"))
    _bad(String("1Sé"), String("timeout unit is not recognized"))


def _req(timeouts: List[String]) -> List[HpackHeader]:
    var hs = List[HpackHeader]()
    hs.append(HpackHeader(String(":path"), String("/a.B/C")))
    hs.append(HpackHeader(String("content-type"), String("application/grpc")))
    for i in range(len(timeouts)):
        hs.append(HpackHeader(String("grpc-timeout"), timeouts[i]))
    return hs^


def test_find() raises:
    var none = find_grpc_timeout(_req(List[String]()))
    assert_equal(Int(none.state), Int(GRPC_TIMEOUT_ABSENT), "absent")
    var one = find_grpc_timeout(_req([String("5S")]))
    assert_equal(one.micros, 5_000_000, "one field")
    var last = find_grpc_timeout(_req([String("5S"), String("7m")]))
    assert_equal(Int(last.state), Int(GRPC_TIMEOUT_SET), "last wins: state")
    assert_equal(last.micros, 7_000, "last wins: value")
    var last_bad = find_grpc_timeout(_req([String("5S"), String("7x")]))
    assert_equal(
        Int(last_bad.state), Int(GRPC_TIMEOUT_MALFORMED), "last wins: malformed"
    )
    var bad_first = find_grpc_timeout(_req([String("7x"), String("5S")]))
    assert_equal(
        Int(bad_first.state),
        Int(GRPC_TIMEOUT_MALFORMED),
        "a malformed field wins over a later valid one",
    )
    assert_equal(
        bad_first.error,
        String("timeout unit is not recognized"),
        "malformed then valid: reason",
    )
    assert_equal(bad_first.micros, 0, "malformed then valid: no duration")
    var two_bad = find_grpc_timeout(
        _req([String("S"), String("5S"), String("7x")])
    )
    assert_equal(
        two_bad.error,
        String("timeout unit is not recognized"),
        "several malformed fields: the last one's reason",
    )


def test_content_types() raises:
    assert_true(is_grpc_h2_content_type(String("application/grpc")))
    assert_true(is_grpc_h2_content_type(String("application/grpc+proto")))
    assert_true(is_grpc_h2_content_type(String("application/grpc+json")))
    assert_true(
        is_grpc_h2_content_type(String("application/grpc+proto; charset=x"))
    )
    assert_false(is_grpc_h2_content_type(String("application/grpc-web")))
    assert_false(is_grpc_h2_content_type(String("application/grpc-web+proto")))
    assert_false(is_grpc_h2_content_type(String("application/json")))
    assert_false(is_grpc_h2_content_type(String("application/connect+proto")))


def test_deadline() raises:
    var ct = String("application/grpc+proto")
    var arrival = UInt64(1_000_000_000)
    var d = grpc_deadline_at_arrival(_req([String("250m")]), ct, arrival)
    assert_equal(Int(d.state), Int(GRPC_TIMEOUT_SET), "250m: state")
    assert_equal(d.at_ns, UInt64(1_250_000_000), "250m: arrival + 250ms")
    assert_false(d.expired(UInt64(1_249_999_999)), "1ns before: live")
    assert_true(d.expired(UInt64(1_250_000_000)), "at the deadline: expired")
    assert_true(d.expired(UInt64(1_250_000_001)), "after: expired")

    var z = grpc_deadline_at_arrival(_req([String("0S")]), ct, arrival)
    assert_true(z.expired(arrival), "0S expires at arrival")

    var none = grpc_deadline_at_arrival(_req(List[String]()), ct, arrival)
    assert_equal(Int(none.state), Int(GRPC_TIMEOUT_ABSENT), "no header")
    assert_false(none.expired(~UInt64(0)), "no header never expires")

    var bad = grpc_deadline_at_arrival(_req([String("1s")]), ct, arrival)
    assert_equal(Int(bad.state), Int(GRPC_TIMEOUT_MALFORMED), "malformed")
    assert_equal(bad.error, String("timeout unit is not recognized"))
    assert_false(bad.expired(~UInt64(0)), "malformed is not 'expired'")

    var web = grpc_deadline_at_arrival(
        _req([String("0S")]), String("application/grpc-web+proto"), arrival
    )
    assert_equal(Int(web.state), Int(GRPC_TIMEOUT_ABSENT), "gRPC-Web: none")

    # 99999999H is 3.6e20 ns: past UInt64. It must saturate, not wrap.
    var far = grpc_deadline_at_arrival(_req([String("99999999H")]), ct, arrival)
    assert_equal(far.at_ns, ~UInt64(0), "99999999H saturates")
    assert_false(far.expired(arrival), "99999999H is not expired")
    # 2562047H fits: 2562047 * 3.6e12 ns = 9223369200000000000.
    var fits = grpc_deadline_at_arrival(_req([String("2562047H")]), ct, UInt64(0))
    assert_equal(fits.at_ns, UInt64(9_223_369_200_000_000_000), "2562047H")


def main() raises:
    # Every case runs, so one run reports every failing case.
    var failed = List[String]()
    try:
        test_units()
    except e:
        failed.append(String("test_units -- ") + String(e))
    try:
        test_eight_digit_bound()
    except e:
        failed.append(String("test_eight_digit_bound -- ") + String(e))
    try:
        test_zero_is_set_not_absent()
    except e:
        failed.append(String("test_zero_is_set_not_absent -- ") + String(e))
    try:
        test_malformed_reasons()
    except e:
        failed.append(String("test_malformed_reasons -- ") + String(e))
    try:
        test_find()
    except e:
        failed.append(String("test_find -- ") + String(e))
    try:
        test_content_types()
    except e:
        failed.append(String("test_content_types -- ") + String(e))
    try:
        test_deadline()
    except e:
        failed.append(String("test_deadline -- ") + String(e))
    for i in range(len(failed)):
        print("FAILED " + failed[i])
    if len(failed) > 0:
        raise Error(String(len(failed)) + " of 7 cases failed")
    print("test_grpc_timeout_parse: PASSED (7 cases)")
