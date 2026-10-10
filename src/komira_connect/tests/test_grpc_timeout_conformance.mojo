# =============================================================================
# test_grpc_timeout_conformance.mojo — `grpc-timeout` against the grpc-go bar
# =============================================================================
#
# The `Grpc-Timeout` header is a
# WIRE CONTRACT with a peer we do not control, so the bar is not "our encoder
# agrees with our parser about the cases we happened to think of", it is
# grpc-go's own test tables. Two of them are ported here verbatim:
#
#   * `TestEncodeDuration`  (grpc-go `internal/transport/http_util_test.go`)
#   * `TestDecodeTimeout`   (same file)
#
# ⚠ WHAT THIS FILE PINS. It is the file whose subject is `parse_grpc_timeout`
# (test_L5_deadline.mojo covers 6 of its arms in passing) and the encoder's
# 8-digit cap: `encode_grpc_timeout_us` must keep every value it emits within
# the spec's `1*8DIGIT`, and without the tests below nothing would assert it.
#
# THE SPEC (grpc/doc/PROTOCOL-HTTP2.md):
#
#     Timeout          -> "grpc-timeout" TimeoutValue TimeoutUnit
#     TimeoutValue     -> {positive integer as ASCII string of at most 8 digits}
#     TimeoutUnit      -> Hour / Minute / Second / Millisecond / Microsecond /
#                         Nanosecond
#     Hour -> "H"   Minute -> "M"   Second -> "S"
#     Millisecond -> "m"   Microsecond -> "u"   Nanosecond -> "n"
#
# "at most 8 digits" is the whole point: a 9-digit value is a MALFORMED REQUEST
# to a conformant server, answered with INTERNAL + HTTP 400, never with the
# deadline the caller asked for.
#
# ⚠ UNIT ADAPTATION. grpc-go's encoder takes a `time.Duration` (nanoseconds);
# ours takes MICROSECONDS. Every ported row is restated in micros and the
# original grpc-go row is quoted beside it. The ns-input row of
# `TestEncodeDuration` (123456789ns -> "123457u") is INEXPRESSIBLE through a
# micros-taking API and is omitted rather than faked.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_connect import (
    DEADLINE_UNSET_MICROS,
    parse_grpc_timeout,
    encode_grpc_timeout_us,
)


# =============================================================================
# §1 — Helpers.
# =============================================================================


def _digit_count(s: String) -> Int:
    """The number of leading DIGIT bytes of an encoded grpc-timeout value —
    i.e. its `TimeoutValue`, the thing the spec caps at 8."""
    var n = s.byte_length()
    var i = 0
    while i < n:
        var b = ord(s[byte=i])
        if b < ord("0") or b > ord("9"):
            break
        i = i + 1
    return i


# =============================================================================
# §2 — ★ THE 8-DIGIT CAP. The encoder must never emit a 9-digit value.
# =============================================================================


def test_encode_never_exceeds_8_digits_single_repro() raises:
    """★ ONE VALUE, NO NETWORK.

    An encoder that promoted to a larger unit ONLY when the value divides
    EXACTLY, falling back to `String(micros) + "u"` with no digit cap, would
    render any deadline >= 100_000_000us (100s) that is not a whole number of
    milliseconds with 9+ digits. `encode_grpc_timeout_us` caps the digits in
    its second pass (see its docstring); this row pins that pass.

    200_000_001us == 200.000001 seconds — an utterly ordinary deadline for a
    long poll — falls into that gap; uncapped it would render `200000001u`.

    A conformant server (grpc-go's `decodeTimeout` rejects any string longer
    than 9 chars; OUR OWN `parse_grpc_timeout` rejects >8 digits) answers such
    a request with INTERNAL 'malformed grpc-timeout' + HTTP 400. The deadline
    the caller asked for is never applied.
    """
    var got = encode_grpc_timeout_us(200_000_001)
    assert_true(
        _digit_count(got) <= 8,
        String("200_000_001us must render <= 8 digits; got '") + got + "'",
    )


def test_encode_never_exceeds_8_digits_over_a_range() raises:
    """The cap holds for EVERY duration, not just the one repro.

    Sampled over 17 decades x 5 offsets so the failure surface is visible
    rather than a single point. Reports the count before asserting, because
    "one value is wrong" and "the whole upper half of the range is wrong" are
    different bugs with different fixes.
    """
    var failures = 0
    var first_bad = String("")
    var first_bad_in: Int = 0
    var k = 0
    while k < 17:
        var base = 1
        var e = 0
        while e < k:
            base = base * 10
            e = e + 1
        var offsets = List[Int]()
        offsets.append(0)
        offsets.append(1)
        offsets.append(7)
        offsets.append(999)
        offsets.append(1001)
        var oi = 0
        while oi < len(offsets):
            var d = base + offsets[oi]
            var enc = encode_grpc_timeout_us(d)
            if _digit_count(enc) > 8:
                failures = failures + 1
                if failures == 1:
                    first_bad = enc
                    first_bad_in = d
            oi = oi + 1
        k = k + 1
    if failures > 0:
        print(
            "  encode_grpc_timeout_us: ",
            failures,
            " of 85 sampled durations render >8 digits; first:",
            first_bad_in,
            "->",
            first_bad,
        )
    assert_equal(failures, 0, "durations rendering an over-long TimeoutValue")


# =============================================================================
# §3 — grpc-go `TestEncodeDuration`, restated in microseconds.
# =============================================================================


def test_encode_matches_grpc_go_table() raises:
    """grpc-go `TestEncodeDuration`, the rows a micros-taking API can express.

    grpc-go's ladder is: take the SMALLEST unit whose ROUND-UP quotient still
    fits in 8 digits. Round-UP, never down — a deadline that is silently
    SHORTENED makes a call fail early for no reason the caller can see.

        func div(d, r time.Duration) int64 {
            if d%r > 0 { return int64(d/r + 1) }
            return int64(d / r)
        }

    Ours promotes only on EXACT divisibility and then falls off the end into
    an uncapped `u`, so every row below is currently an over-long value.
    """
    # grpc-go: {123456789 * time.Microsecond, "123457m"}
    assert_equal(
        encode_grpc_timeout_us(123_456_789),
        String("123457m"),
        "123456789us -> 123457m (round UP to millis)",
    )
    # grpc-go: {123456789 * time.Millisecond, "123457S"}
    assert_equal(
        encode_grpc_timeout_us(123_456_789_000),
        String("123457S"),
        "123456789ms -> 123457S",
    )
    # grpc-go: {123456789 * time.Second, "2057614M"}
    assert_equal(
        encode_grpc_timeout_us(123_456_789_000_000),
        String("2057614M"),
        "123456789s -> 2057614M",
    )
    # grpc-go: {123456789 * time.Minute, "2057614H"}
    assert_equal(
        encode_grpc_timeout_us(7_407_407_340_000_000),
        String("2057614H"),
        "123456789min -> 2057614H",
    )


def test_encode_rounds_up_never_down() raises:
    """A deadline must never be SILENTLY SHORTENED by encoding.

    Stated as the property rather than as a spelling, so it holds for any
    conformant unit ladder: whatever string the encoder emits, decoding it
    must yield AT LEAST the duration that went in.

    (The sub-microsecond half of grpc-go's rule — `1ns -> "1n"`, not `"0n"` —
    is not expressible here: our encoder's input unit IS the microsecond, so
    there is no value it can round to zero. Its decoder half is covered by
    `test_decode_matches_grpc_go_table`'s `00000001n` row.)
    """
    var probes = List[Int]()
    probes.append(1)
    probes.append(999)
    probes.append(1001)
    probes.append(1_000_001)
    probes.append(60_000_001)
    probes.append(100_000_001)
    probes.append(200_000_001)
    probes.append(3_600_000_001)
    var i = 0
    while i < len(probes):
        var d = probes[i]
        var enc = encode_grpc_timeout_us(d)
        var back = parse_grpc_timeout(enc)
        assert_true(
            back >= d,
            String("encode(")
            + String(d)
            + ") = '"
            + enc
            + "' decodes to "
            + String(back)
            + " which SHORTENS the deadline",
        )
        i = i + 1


# =============================================================================
# §4 — ★ SELF-CONSISTENCY. The one property a half-fix cannot satisfy.
# =============================================================================


def test_encoder_output_is_accepted_by_our_own_decoder() raises:
    """★ Our own decoder must accept every value our own encoder emits.

    This is the assertion that cannot be satisfied by capping the digits
    without fixing the rounding, nor by fixing the rounding without capping
    the digits. `parse_grpc_timeout` returning DEADLINE_UNSET_MICROS means
    "no deadline" downstream, so a round-trip that lands on 0 does not merely
    lose precision — it converts a bounded call into an UNBOUNDED one.
    """
    var failures = 0
    var first_bad_in: Int = 0
    var first_bad = String("")
    var k = 0
    while k < 17:
        var base = 1
        var e = 0
        while e < k:
            base = base * 10
            e = e + 1
        var offsets = List[Int]()
        offsets.append(0)
        offsets.append(1)
        offsets.append(7)
        offsets.append(999)
        offsets.append(1001)
        var oi = 0
        while oi < len(offsets):
            var d = base + offsets[oi]
            var enc = encode_grpc_timeout_us(d)
            var back = parse_grpc_timeout(enc)
            if back == DEADLINE_UNSET_MICROS or back < d:
                failures = failures + 1
                if failures == 1:
                    first_bad_in = d
                    first_bad = enc
            oi = oi + 1
        k = k + 1
    if failures > 0:
        print(
            "  decode(encode(d)) broken for ",
            failures,
            " of 85 sampled durations; first:",
            first_bad_in,
            "->",
            first_bad,
        )
    assert_equal(failures, 0, "durations whose own encoding we reject")


# =============================================================================
# §5 — grpc-go `TestDecodeTimeout`, verbatim.
# =============================================================================


def test_decode_matches_grpc_go_table() raises:
    """grpc-go `TestDecodeTimeout` — the ACCEPT rows.

    Leading zeros are legal (the ABNF is 1*8DIGIT, not a canonical form), and
    a peer that pads to a fixed width is conformant. `n` ceils to the next
    microsecond so a 1ns deadline is not silently turned into "no deadline".
    """
    assert_equal(parse_grpc_timeout(String("00000001n")), 1, "1ns -> 1us ceil")
    assert_equal(parse_grpc_timeout(String("10u")), 10, "10u")
    assert_equal(parse_grpc_timeout(String("00000010m")), 10_000, "10ms")
    assert_equal(
        parse_grpc_timeout(String("1234S")), 1_234_000_000, "1234 seconds"
    )
    assert_equal(
        parse_grpc_timeout(String("00000001M")), 60_000_000, "1 minute"
    )
    assert_equal(
        parse_grpc_timeout(String("09999999S")),
        9_999_999_000_000,
        "9999999 seconds, zero-padded to 8",
    )
    assert_equal(
        parse_grpc_timeout(String("99999999S")),
        99_999_999_000_000,
        "the largest legal seconds value",
    )
    assert_equal(
        parse_grpc_timeout(String("99999999M")),
        5_999_999_940_000_000,
        "the largest legal minutes value",
    )
    assert_equal(
        parse_grpc_timeout(String("2562047H")),
        9_223_369_200_000_000,
        "grpc-go's int64-nanosecond ceiling, in micros",
    )


def test_decode_large_hours_do_not_overflow() raises:
    """grpc-go CLAMPS `2562048H` and `99999999H` to MaxInt64 because its unit
    is the NANOSECOND and 2562048 hours overflows an int64 of them.

    Our unit is the MICROSECOND, so the same inputs are three orders of
    magnitude from the ceiling and no clamp is needed — but the value must
    still come back POSITIVE and MONOTONE. A silent wrap here would turn the
    longest deadline a peer can express into a negative or tiny one.

    ⚠ This is the ADAPTED form of grpc-go's clamp rows, not a weakened one:
    the property under test (a legal 8-digit hours value never wraps) is the
    property the clamp exists to protect.
    """
    var h_2562048 = parse_grpc_timeout(String("2562048H"))
    assert_equal(
        h_2562048, 9_223_372_800_000_000, "2562048H in micros, no wrap"
    )
    var h_max = parse_grpc_timeout(String("99999999H"))
    assert_equal(
        h_max, 359_999_996_400_000_000, "99999999H in micros, no wrap"
    )
    assert_true(h_max > h_2562048, "monotone in the hours value")


def test_decode_rejects_grpc_go_reject_table() raises:
    """grpc-go `TestDecodeTimeout` — the REJECT rows.

    ⚠ `1234s` is in this table on purpose: LOWERCASE `s` is NOT a unit. The
    six units are `H` hours, `M` minutes, `S` seconds, `m` MILLIseconds, `u`
    micros, `n` nanos — so `M`/`m` and `S`/`s` are a case-sensitive trap that
    a 60000x error hides behind.
    """
    assert_equal(
        parse_grpc_timeout(String("-1S")), DEADLINE_UNSET_MICROS, "negative"
    )
    assert_equal(
        parse_grpc_timeout(String("1234x")), DEADLINE_UNSET_MICROS, "bad unit"
    )
    assert_equal(
        parse_grpc_timeout(String("1234s")),
        DEADLINE_UNSET_MICROS,
        "lowercase s is not a unit",
    )
    assert_equal(
        parse_grpc_timeout(String("1234")), DEADLINE_UNSET_MICROS, "no unit"
    )
    assert_equal(
        parse_grpc_timeout(String("1")), DEADLINE_UNSET_MICROS, "one digit, no unit"
    )
    assert_equal(
        parse_grpc_timeout(String("")), DEADLINE_UNSET_MICROS, "empty"
    )
    assert_equal(
        parse_grpc_timeout(String("9a1S")),
        DEADLINE_UNSET_MICROS,
        "non-digit inside the value",
    )
    assert_equal(
        parse_grpc_timeout(String("000000000S")),
        DEADLINE_UNSET_MICROS,
        "9 digits exceeds 1*8DIGIT even when they are zeros",
    )
    # ⚠ THE ALL-ZERO ROW ABOVE CANNOT CARRY THIS ASSERTION ALONE, and that
    # is a demonstrated property, not a precaution: deleting the
    # `digit_count > 8` guard in `parse_grpc_timeout` leaves "000000000S"
    # parsing to 0 * 1_000_000 == 0 == DEADLINE_UNSET_MICROS, so the row stays
    # GREEN over a decoder with no length check at all. A NON-ZERO 9-digit
    # value is what makes the guard's absence observable.
    assert_equal(
        parse_grpc_timeout(String("123456789S")),
        DEADLINE_UNSET_MICROS,
        "9 NON-ZERO digits rejected -- the row that actually pins the guard",
    )
    assert_equal(
        parse_grpc_timeout(String("999999999n")),
        DEADLINE_UNSET_MICROS,
        "9 non-zero digits rejected on the nanosecond arm too",
    )


def test_decode_unit_multipliers_are_not_transposed() raises:
    """`M` (minute) and `m` (millisecond) differ by 60000x and are one SHIFT
    key apart. Pin both, adjacently, so a transposition cannot land quietly.
    """
    assert_equal(parse_grpc_timeout(String("1M")), 60_000_000, "1 minute")
    assert_equal(parse_grpc_timeout(String("1m")), 1_000, "1 millisecond")
    assert_equal(parse_grpc_timeout(String("1S")), 1_000_000, "1 second")
    assert_equal(parse_grpc_timeout(String("1H")), 3_600_000_000, "1 hour")
    assert_equal(parse_grpc_timeout(String("1u")), 1, "1 microsecond")
    assert_equal(parse_grpc_timeout(String("1n")), 1, "1 nanosecond, ceiled")


# =============================================================================
# §6 — ★ THE FAIL-OPEN DIRECTION. Absent-vs-empty, in a different costume.
# =============================================================================


def test_malformed_timeout_is_indistinguishable_from_no_deadline() raises:
    """★ THIS TEST PASSING IS THE DEFECT. Do not "fix" it by deleting it.

    `parse_grpc_timeout` returns DEADLINE_UNSET_MICROS (0) for THREE
    semantically different inputs:

      (a) no `grpc-timeout` header at all   -> correctly "no deadline"
      (b) a MALFORMED header value          -> should be INTERNAL + HTTP 400
      (c) a legitimate `0S` / `0u`          -> "already expired", deadline NOW

    and 0 means NO DEADLINE downstream, i.e. INFINITE. So a peer that sends
    us garbage, or a peer whose deadline has already expired, both get an
    UNBOUNDED call. That is the fail-OPEN direction — an absent-vs-empty
    collision, reached here through a sentinel return.

    grpc-go does not have this collision: `decodeTimeout` returns
    `(time.Duration, error)` and the transport answers a malformed value with
    `status.Errorf(codes.Internal, "malformed grpc-timeout: %v")` + HTTP 400.

    THE ASSERTIONS BELOW STATE THE COLLISION. They are deliberately written so
    that CLOSING it turns this file RED and forces the fix to be a decision.

    ⚠ THE FOURTH ASSERTION IS NOT PART OF THE COLLISION. A value OUR OWN
    ENCODER PRODUCES must never land in class (b): `encode_grpc_timeout_us`
    emits only legal `1*8DIGIT` values, and the fourth assertion pins that our
    own decoder accepts everything our own encoder emits. THE COLLISION ITSELF
    IS UNCHANGED and
    the three assertions above still state it — `parse_grpc_timeout` still
    returns one sentinel for absent / malformed / already-expired.

    The h2 serve loop does not read this sentinel: it enforces grpc-timeout
    through `komira_http_core`'s three-state `parse_grpc_timeout_value`
    (absent / set, zero included / malformed), which `parse_grpc_timeout`
    wraps. komira_http_core/tests/test_grpc_timeout_parse.mojo and
    test_grpc_timeout_enforced.mojo pin that side.
    """
    # (b) and (a) are the same bytes.
    assert_equal(
        parse_grpc_timeout(String("1234x")),
        parse_grpc_timeout(String("")),
        "malformed and absent are indistinguishable",
    )
    # (c) and (a) are the same bytes.
    assert_equal(
        parse_grpc_timeout(String("0S")),
        DEADLINE_UNSET_MICROS,
        "an already-expired '0S' reads as NO deadline",
    )
    assert_equal(
        parse_grpc_timeout(String("0u")),
        DEADLINE_UNSET_MICROS,
        "an already-expired '0u' reads as NO deadline",
    )
    # ★ And the half that would make the collision DANGEROUS rather than
    # merely lossy: if our own encoder emitted a value landing in class (b), a
    # deadline we set ourselves would be dropped by a conformant peer. No
    # output of ours may read as "no deadline".
    var ours = encode_grpc_timeout_us(200_000_001)
    assert_true(
        parse_grpc_timeout(ours) != DEADLINE_UNSET_MICROS,
        String("our own encoder emits '")
        + ours
        + "', which our own parser must NOT read as NO DEADLINE",
    )
    assert_true(
        parse_grpc_timeout(ours) >= 200_000_001,
        String("'") + ours + "' must not SHORTEN the 200_000_001us deadline",
    )


# =============================================================================
# §N — The run harness.
# =============================================================================
#
# ⚠ EVERY CASE RUNS, EVEN AFTER ONE FAILS. A sequential `main()` that lets the
# first `assert_*` abort reports ONE finding per run, and this file was written
# to enumerate a conformance surface — "the first row of the table is wrong" and
# "every row of the table is wrong" are different bugs with different fixes.
# The overall verdict is unchanged: one RED case fails the target.
# =============================================================================


def main() raises:
    var failed = List[String]()
    var passed = 0
    try:
        test_encode_never_exceeds_8_digits_single_repro()
        passed = passed + 1
    except e:
        failed.append(String("test_encode_never_exceeds_8_digits_single_repro -- ") + String(e))
    try:
        test_encode_never_exceeds_8_digits_over_a_range()
        passed = passed + 1
    except e:
        failed.append(String("test_encode_never_exceeds_8_digits_over_a_range -- ") + String(e))
    try:
        test_encode_matches_grpc_go_table()
        passed = passed + 1
    except e:
        failed.append(String("test_encode_matches_grpc_go_table -- ") + String(e))
    try:
        test_encode_rounds_up_never_down()
        passed = passed + 1
    except e:
        failed.append(String("test_encode_rounds_up_never_down -- ") + String(e))
    try:
        test_encoder_output_is_accepted_by_our_own_decoder()
        passed = passed + 1
    except e:
        failed.append(String("test_encoder_output_is_accepted_by_our_own_decoder -- ") + String(e))
    try:
        test_decode_matches_grpc_go_table()
        passed = passed + 1
    except e:
        failed.append(String("test_decode_matches_grpc_go_table -- ") + String(e))
    try:
        test_decode_large_hours_do_not_overflow()
        passed = passed + 1
    except e:
        failed.append(String("test_decode_large_hours_do_not_overflow -- ") + String(e))
    try:
        test_decode_rejects_grpc_go_reject_table()
        passed = passed + 1
    except e:
        failed.append(String("test_decode_rejects_grpc_go_reject_table -- ") + String(e))
    try:
        test_decode_unit_multipliers_are_not_transposed()
        passed = passed + 1
    except e:
        failed.append(String("test_decode_unit_multipliers_are_not_transposed -- ") + String(e))
    try:
        test_malformed_timeout_is_indistinguishable_from_no_deadline()
        passed = passed + 1
    except e:
        failed.append(String("test_malformed_timeout_is_indistinguishable_from_no_deadline -- ") + String(e))

    var total = passed + len(failed)
    if len(failed) > 0:
        print("")
        print("==== test_grpc_timeout_conformance: RED ====")
        var i = 0
        while i < len(failed):
            print("  [FAIL]", failed[i])
            i = i + 1
        print("")
        raise Error(
            String("test_grpc_timeout_conformance: ")
            + String(len(failed))
            + " of "
            + String(total)
            + " conformance cases FAILED (see [FAIL] lines above)"
        )
    print("test_grpc_timeout_conformance: ", total, "/", total, " PASS")
