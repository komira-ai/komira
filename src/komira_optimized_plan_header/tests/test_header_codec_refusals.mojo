# =============================================================================
# test_header_codec_refusals.mojo
# =============================================================================
#
# Steps 1 and 2 of §7.2 (docs/design/optimized_plan.md), one hostile header
# per refusal, built byte by byte so each carries exactly one defect. Each
# test names the defect it catches; the refusal must begin with its token.
#
#   test_size_limit: OPTIMIZED_PLAN_LIMIT_EXCEEDED one byte over
#     OPTIMIZED_PLAN_MAX_BYTES, and a header of exactly that size decodes.
#     Catches `>=` for `>`, a smaller budget, and a size check after parsing.
#   test_format_version_not_accepted: an absent version (0) and version 2 are
#     refused, OPTIMIZED_PLAN_VERSION_UNSUPPORTED. Catches `>=` membership.
#   test_understated_fields: the whole version-1 field table. In each of the
#     seven header messages, every number from 1 to one above the highest
#     declared or held number that version 1 does not include (held,
#     reserved, never declared) is refused as understated, naming it.
#     Catches a walk that skips unknown fields, proto3-style, and any one
#     held or reserved row made known.
#   test_understated_enum_values: `write_target.format` 4 and `codec` 6 are
#     refused, 3 and 5 accepted. Catches an off-by-one or unbounded enum.
#   test_malformed_framing: truncated varints, lengths and fixed-width values,
#     a varint that runs past its submessage, an 11-byte varint, field number
#     0 and above 2^29-1, wire type 3: OPTIMIZED_PLAN_HEADER_MALFORMED.
#   test_malformed_fields: a known field under the wrong wire type, a singular
#     field twice (top level and nested), a uint32 above 2^32-1, a bool of 2,
#     and format_version at 2^32 (malformed) and 2^32-1 (a uint32 that is not
#     an accepted version, OPTIMIZED_PLAN_VERSION_UNSUPPORTED).
#     Catches the parser differentials proto3 resolves silently.
#   test_malformed_utf8: a boundary sweep of the Unicode well-formed table:
#     each lead-byte range at both ends, each second-byte range of E0, ED,
#     F0 and F4 just inside (accepted) and just outside (refused), a
#     continuation byte of 7F or C0 in the second, third and fourth place,
#     and a 2-, 3- and 4-byte lead cut short at the end of the string, then
#     each followed in the buffer by a continuation byte (80 and BF) and
#     each as the last bytes of the whole header. Then
#     one ill-formed value in every `string` field of the header (kind,
#     path, the second data_scopes entry, runtime, runtime_abi), each
#     refused naming its field, and a `bytes` field never checked as UTF-8.
#     Catches a lead range one byte too wide or too narrow, a dropped range,
#     a length check one byte short, and a field whose check was dropped.
#   test_body_never_parsed: a body that is not protobuf decodes untouched.
#     Catches a walk that descends into `body`.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_optimized_plan_header import (
    OPTIMIZED_PLAN_HEADER_MALFORMED,
    OPTIMIZED_PLAN_LIMIT_EXCEEDED,
    OPTIMIZED_PLAN_MAX_BYTES,
    OPTIMIZED_PLAN_VERSION_UNSUPPORTED,
    decode_optimized_plan_header,
)

# ---- protobuf by hand ----------------------------------------------------------


def _varint(mut out: List[UInt8], v: UInt64):
    var x = v
    while x >= 0x80:
        out.append(UInt8(Int(x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(Int(x)))


def _vf(mut out: List[UInt8], n: Int, v: UInt64):
    _varint(out, UInt64(n << 3))
    _varint(out, v)


def _lf(mut out: List[UInt8], n: Int, payload: List[UInt8]):
    _varint(out, UInt64((n << 3) | 2))
    _varint(out, UInt64(len(payload)))
    out.extend(payload.copy())


def _sf(mut out: List[UInt8], n: Int, s: String):
    var b = List[UInt8]()
    for c in s.as_bytes():
        b.append(c)
    _lf(out, n, b)


def _bytes(n: Int, v: UInt8) -> List[UInt8]:
    var b = List[UInt8]()
    for _ in range(n):
        b.append(v)
    return b^


def _cat(a: List[UInt8], b: List[UInt8]) -> List[UInt8]:
    var out = a.copy()
    out.extend(b.copy())
    return out^


# ---- a valid header, each message with room for one more field -----------------


def _e() -> List[UInt8]:
    return List[UInt8]()


def _stamp(extra: List[UInt8]) -> List[UInt8]:
    var m = List[UInt8]()
    _lf(m, 1, _bytes(32, 0xAB))
    _vf(m, 2, 1)
    _sf(m, 5, "komira/mojo-sdk")
    return _cat(m, extra)


def _runtime(extra: List[UInt8]) -> List[UInt8]:
    var m = List[UInt8]()
    _sf(m, 1, "komira/python")
    _sf(m, 2, "cp312")
    return _cat(m, extra)


def _needs(extra: List[UInt8], runtime: List[UInt8]) -> List[UInt8]:
    var m = List[UInt8]()
    _sf(m, 5, "orders")
    _sf(m, 5, "customers")
    _vf(m, 8, 1)
    _lf(m, 9, runtime)
    return _cat(m, extra)


def _write(extra: List[UInt8], format: UInt64, codec: UInt64) -> List[UInt8]:
    var m = List[UInt8]()
    _sf(m, 1, "out/")
    _vf(m, 2, format)
    _vf(m, 3, codec)
    return _cat(m, extra)


def _stats(extra: List[UInt8]) -> List[UInt8]:
    var m = List[UInt8]()
    _vf(m, 1, 0)
    _vf(m, 2, 10)
    return _cat(m, extra)


def _advice(extra: List[UInt8], stats: List[UInt8]) -> List[UInt8]:
    var m = List[UInt8]()
    _lf(m, 2, stats)
    return _cat(m, extra)


struct _P(Movable):
    """A valid header's parts; a test replaces one and takes `bytes()`."""

    var extra: List[UInt8]
    var stamp: List[UInt8]
    var needs: List[UInt8]
    var write: List[UInt8]
    var advice: List[UInt8]
    var body: List[UInt8]

    def __init__(out self):
        self.extra = _e()
        self.stamp = _stamp(_e())
        self.needs = _needs(_e(), _runtime(_e()))
        self.write = _write(_e(), 1, 3)
        self.advice = _advice(_e(), _stats(_e()))
        self.body = _bytes(3, 0x01)

    def bytes(self) -> List[UInt8]:
        var m = List[UInt8]()
        _vf(m, 1, 1)
        _lf(m, 2, self.stamp)
        _lf(m, 3, _bytes(32, 0xCD))
        _lf(m, 5, self.needs)
        _lf(m, 6, self.write)
        _lf(m, 7, self.advice)
        _lf(m, 8, self.body)
        return _cat(m, self.extra)


def _plan() -> List[UInt8]:
    return _P().bytes()


def _with_extra(extra: List[UInt8]) -> List[UInt8]:
    var p = _P()
    p.extra = extra.copy()
    return p.bytes()


def _with_stamp(stamp: List[UInt8]) -> List[UInt8]:
    var p = _P()
    p.stamp = stamp.copy()
    return p.bytes()


def _with_needs(needs: List[UInt8]) -> List[UInt8]:
    var p = _P()
    p.needs = needs.copy()
    return p.bytes()


def _with_write(write: List[UInt8]) -> List[UInt8]:
    var p = _P()
    p.write = write.copy()
    return p.bytes()


def _with_advice(advice: List[UInt8]) -> List[UInt8]:
    var p = _P()
    p.advice = advice.copy()
    return p.bytes()


def _with_body(body: List[UInt8]) -> List[UInt8]:
    var p = _P()
    p.body = body.copy()
    return p.bytes()


# ---- expectations --------------------------------------------------------------


def _refused(var bytes: List[UInt8], token: String, needle: String, what: String) raises:
    var refused = False
    try:
        _ = decode_optimized_plan_header(bytes^)
    except e:
        refused = True
        var text = String(e)
        assert_true(text.startswith(token + ":"), what + ": refused with another token: " + text)
        assert_true(needle in text, what + ": the refusal does not say `" + needle + "`: " + text)
    assert_true(refused, what + ": decoded, expected " + token)


def _malformed(var bytes: List[UInt8], needle: String, what: String) raises:
    _refused(bytes^, OPTIMIZED_PLAN_HEADER_MALFORMED, needle, what)


def _understated(var bytes: List[UInt8], needle: String, what: String) raises:
    _refused(bytes^, OPTIMIZED_PLAN_VERSION_UNSUPPORTED, needle, what)


def _one(n: Int, wt: Int) -> List[UInt8]:
    """A field `n` of wire type `wt` with a small value."""
    var m = List[UInt8]()
    _varint(m, UInt64((n << 3) | wt))
    if wt == 0:
        _varint(m, 1)
    elif wt == 2:
        _varint(m, 1)
        m.append(0x41)
    elif wt == 1:
        m.extend(_bytes(8, 0))
    else:
        m.extend(_bytes(4, 0))
    return m^


# ---- the tests -----------------------------------------------------------------


def test_size_limit() raises:
    # The budget itself: 16 MiB of plan and a 1 MiB header allowance (§7.2 step 1).
    assert_equal(OPTIMIZED_PLAN_MAX_BYTES, 16777216 + 1048576, "OPTIMIZED_PLAN_MAX_BYTES")
    # A valid header grown, through its body, to exactly the limit.
    var head = _with_body(_e())
    var fixed = len(head) - 2  # the empty body field: tag and a zero length
    var body_len = OPTIMIZED_PLAN_MAX_BYTES - fixed - 1 - 4  # tag, 4-byte length
    var at_limit = _with_body(_bytes(body_len, 0x07))
    assert_equal(len(at_limit), OPTIMIZED_PLAN_MAX_BYTES, "the at-limit header's size")
    var h = decode_optimized_plan_header(at_limit^)
    assert_equal(len(h.body), body_len, "the at-limit body")
    var over = _with_body(_bytes(body_len + 1, 0x07))
    assert_equal(len(over), OPTIMIZED_PLAN_MAX_BYTES + 1, "the over-limit header's size")
    _refused(over^, OPTIMIZED_PLAN_LIMIT_EXCEEDED, String(OPTIMIZED_PLAN_MAX_BYTES + 1) + " bytes", "one byte over")
    # Refused on the length alone: bytes that do not parse are still LIMIT.
    _refused(_bytes(OPTIMIZED_PLAN_MAX_BYTES + 1, 0xFF), OPTIMIZED_PLAN_LIMIT_EXCEEDED, "at most", "unparsed")


def test_format_version_not_accepted() raises:
    var absent = List[UInt8]()
    _lf(absent, 2, _stamp(_e()))
    _understated(absent^, "format_version 0 is not in this reader's accepted set {1}", "absent version")
    var two = List[UInt8]()
    _vf(two, 1, 2)
    _lf(two, 5, _needs(_e(), _runtime(_e())))
    _understated(two^, "format_version 2 is not in this reader's accepted set {1}", "version 2")
    # Version 2 is refused even when it carries a field version 1 lacks.
    var two_more = List[UInt8]()
    _vf(two_more, 1, 2)
    two_more.extend(_one(9, 0))
    _understated(two_more^, "format_version 2 is not in", "version 2 with field 9")


def _in_message(m: String, extra: List[UInt8]) -> List[UInt8]:
    """A valid header with `extra` appended to header message `m`."""
    if m == "OptimizedPlan":
        return _with_extra(extra)
    if m == "ProducerStamp":
        return _with_stamp(_stamp(extra))
    if m == "DeclaredNeeds":
        return _with_needs(_needs(extra, _runtime(_e())))
    if m == "RuntimeNeed":
        return _with_needs(_needs(_e(), _runtime(extra)))
    if m == "WireWriteTarget":
        return _with_write(_write(extra, 1, 3))
    if m == "PlanAdvice":
        return _with_advice(_advice(extra, _stats(_e())))
    return _with_advice(_advice(_e(), _stats(extra)))


def test_understated_fields() raises:
    # Every number version 1 does not include, from 1 to one above the
    # highest declared or held number of each message (optimized_plan.proto,
    # plan.proto for WireWriteTarget).
    var messages: List[String] = [
        "OptimizedPlan",  # 1-8 declared
        "ProducerStamp",  # 1, 2, 3, 5 declared; 4 reserved
        "DeclaredNeeds",  # 1, 2, 4, 10 held; 3, 6, 7 reserved; 5, 8, 9 declared
        "RuntimeNeed",  # 1, 2 declared
        "WireWriteTarget",  # 1, 2, 3 declared
        "PlanAdvice",  # 1, 3, 4 held; 2 declared
        "ScanStats",  # 3, 4 held; 1, 2 declared
    ]
    var numbers: List[List[Int]] = [
        [9],
        [4, 6],
        [1, 2, 3, 4, 6, 7, 10, 11],
        [3],
        [4],
        [1, 3, 4, 5],
        [3, 4, 5],
    ]
    for i in range(len(messages)):
        for j in range(len(numbers[i])):
            var n = numbers[i][j]
            var what = messages[i] + " field " + String(n)
            var needle = messages[i] + " this field (field " + String(n) + ")"
            _understated(_in_message(messages[i], _one(n, 0)), needle, what + " as a varint")
            _understated(_in_message(messages[i], _one(n, 2)), needle, what + " length-delimited")
    _understated(_with_extra(_one(10, 1)), "OptimizedPlan this field (field 10)", "a fixed64 field")
    _understated(_with_extra(_one(11, 5)), "OptimizedPlan this field (field 11)", "a fixed32 field")


def test_understated_enum_values() raises:
    _understated(_with_write(_write(_e(), 4, 3)), "the format value 4 (field 2)", "format 4")
    _understated(_with_write(_write(_e(), 1, 6)), "the codec value 6 (field 3)", "codec 6")
    var h = decode_optimized_plan_header(_with_write(_write(_e(), 3, 5)))
    assert_equal(h.write_target.value().format.number(), 3, "format 3 (WFMT_JSONL)")
    assert_equal(h.write_target.value().codec.number(), 5, "codec 5 (WCOMP_LZ4)")


def test_malformed_framing() raises:
    _malformed([UInt8(0x08)], "OptimizedPlan field 1 at byte 1", "a varint with no bytes")
    _malformed([UInt8(0x08), 0x80], "OptimizedPlan field 1 at byte 1", "a varint cut short")
    _malformed(_bytes(11, 0x80), "a field tag at byte 0", "an 11-byte varint")
    _malformed([UInt8(0x1A), 0x05, 0x00], "OptimizedPlan field 3: a length of 5 runs past", "a length past the end")
    _malformed([UInt8(0x1A)], "OptimizedPlan field 3: a length at byte 1", "a length with no bytes")
    _malformed([UInt8(0x51), 0, 0, 0], "a fixed-width value runs past", "a fixed64 cut short")
    _malformed([UInt8(0x5D), 0], "a fixed-width value runs past", "a fixed32 cut short")
    _malformed([UInt8(0x4B)], "wire type 3 is not one proto3 writes", "a group start")
    _malformed([UInt8(0x00)], "field number 0", "field number 0")
    var big = List[UInt8]()
    _varint(big, UInt64(536870912) << 3)
    _varint(big, 1)
    _malformed(big^, "field number 536870912", "a field number above 2^29-1")
    # producer's length is 1, and its varint value is outside it.
    var past = List[UInt8]()
    _vf(past, 1, 1)
    past.extend([UInt8(0x12), 0x01, 0x10, 0x22, 0x00])
    _malformed(past^, "ProducerStamp field 2 at byte 5 runs past the end of its message", "a varint past its submessage")


def test_malformed_fields() raises:
    var lenver = List[UInt8]()
    _lf(lenver, 1, _bytes(1, 1))
    _malformed(lenver^, "OptimizedPlan.format_version (field 1) arrives with wire type 2", "format_version as bytes")
    var stamp = List[UInt8]()
    _vf(stamp, 1, 7)
    _malformed(_with_stamp(stamp), "ProducerStamp.engine_build (field 1) arrives with wire type 0", "engine_build as varint")
    # Two versions, the last not accepted: last-one-wins would read 2.
    var twice = List[UInt8]()
    _vf(twice, 1, 2)
    _malformed(_cat(_plan(), twice), "OptimizedPlan.format_version occurs twice", "format_version twice")
    var producer_twice = List[UInt8]()
    _lf(producer_twice, 2, _stamp(_e()))
    _malformed(_with_extra(producer_twice), "OptimizedPlan.producer occurs twice", "producer twice")
    var path_twice = List[UInt8]()
    _sf(path_twice, 1, "elsewhere/")
    _malformed(_with_write(_write(path_twice, 1, 3)), "WireWriteTarget.path occurs twice", "path twice")
    # 2^32 + 2 truncates to 2, which a 32-bit read would refuse as a version instead.
    var wide = List[UInt8]()
    _vf(wide, 1, UInt64(4294967296) + 2)
    _malformed(wide^, "OptimizedPlan.format_version is 4294967298, above the uint32 range", "format_version above uint32")
    # Both sides of the uint32 bound: 2^32 is malformed, 2^32-1 is a uint32
    # that is not an accepted version.
    var just_over = List[UInt8]()
    _vf(just_over, 1, UInt64(4294967296))
    _malformed(just_over^, "OptimizedPlan.format_version is 4294967296, above the uint32 range", "format_version 2^32")
    var max_version = List[UInt8]()
    _vf(max_version, 1, 4294967295)
    _understated(max_version^, "format_version 4294967295 is not in", "format_version 2^32-1")
    var contract = List[UInt8]()
    _lf(contract, 1, _bytes(32, 0xAB))
    _vf(contract, 2, UInt64(4294967296))
    _malformed(_with_stamp(contract), "ProducerStamp.optimizer_contract_version is 4294967296", "contract above uint32")
    var bool2 = List[UInt8]()
    _sf(bool2, 5, "orders")
    _vf(bool2, 8, 2)
    _malformed(_with_needs(bool2), "DeclaredNeeds.unbounded is 2; a bool is 0 or 1", "a bool of 2")
    # The largest uint32 is accepted, and repeated fields may repeat.
    var max32 = List[UInt8]()
    _vf(max32, 1, 4294967295)
    _vf(max32, 2, 4294967295)
    var h = decode_optimized_plan_header(_with_advice(_advice(_e(), max32)))
    assert_equal(h.advice.value().stats_basis[0].pin_index, UInt32(4294967295), "pin_index 2^32-1")
    assert_equal(len(h.needs.value().data_scopes), 2, "data_scopes, a repeated field, twice")


def _kind(raw: List[UInt8]) -> List[UInt8]:
    var m = List[UInt8]()
    _lf(m, 1, _bytes(32, 0xAB))
    _lf(m, 5, raw)
    return _with_stamp(m)


def test_malformed_utf8() raises:
    var bad: List[List[UInt8]] = [
        [UInt8(0x80)],  # a continuation byte as a lead
        [UInt8(0xBF)],  # the last continuation byte as a lead
        [UInt8(0xC0), 0x80],  # overlong
        [UInt8(0xC1), 0xBF],  # overlong, the last 2-byte lead below C2
        [UInt8(0xE0), 0x80, 0x80],  # overlong 3-byte
        [UInt8(0xE0), 0x9F, 0xBF],  # overlong 3-byte, just below E0 A0
        [UInt8(0xED), 0xA0, 0x80],  # an encoded surrogate, just above ED 9F
        [UInt8(0xF0), 0x80, 0x80, 0x80],  # overlong 4-byte
        [UInt8(0xF0), 0x8F, 0xBF, 0xBF],  # overlong 4-byte, just below F0 90
        [UInt8(0xF4), 0x90, 0x80, 0x80],  # above U+10FFFF, just above F4 8F
        [UInt8(0xF5), 0x80, 0x80, 0x80],  # no such lead byte
        [UInt8(0xFF)],  # no such lead byte
        [UInt8(0xC3), 0x7F],  # a second byte below 80
        [UInt8(0xC3), 0xC0],  # a second byte above BF
        [UInt8(0xE2), 0x28, 0xA1],  # a bad second byte
        [UInt8(0xE1), 0x80, 0x7F],  # a third byte below 80
        [UInt8(0xE2), 0x82, 0xC0],  # a third byte above BF
        [UInt8(0xF1), 0x80, 0x80, 0x7F],  # a fourth byte below 80
        [UInt8(0xF1), 0x80, 0x80, 0xC0],  # a fourth byte above BF
        [UInt8(0x61), 0xC3],  # a 2-byte lead at the end
        [UInt8(0xE2), 0x82],  # a 3-byte lead cut short
        [UInt8(0x61), 0xF0, 0x9F, 0x98],  # a 4-byte lead cut short at the end
    ]
    for i in range(len(bad)):
        _malformed(_kind(bad[i]), "ProducerStamp.kind is not well-formed UTF-8", "ill-formed UTF-8 #" + String(i))
    # A lead cut short where the string ends, with a continuation byte right
    # after it in the buffer: 80 and BF, the first byte of a tag for field 16
    # and field 23 of ProducerStamp. The string's own end refuses it, not the
    # byte that follows. Then the same leads as the last bytes of the whole
    # header (`producer` written last), where nothing follows.
    var cut: List[List[UInt8]] = [
        [UInt8(0x61), 0xC3],  # a 2-byte lead, one byte short
        [UInt8(0xE2), 0x82],  # a 3-byte lead, one byte short
        [UInt8(0x61), 0xF0, 0x9F, 0x98],  # a 4-byte lead, one byte short
    ]
    var after: List[List[UInt8]] = [[UInt8(0x80), 0x01, 0x00], [UInt8(0xBF), 0x01]]
    for i in range(len(cut)):
        for j in range(len(after)):
            var m = List[UInt8]()
            _lf(m, 1, _bytes(32, 0xAB))
            _lf(m, 5, cut[i])
            m.extend(after[j].copy())
            var what = "cut-short lead #" + String(i) + " before byte " + String(Int(after[j][0]))
            _malformed(_with_stamp(m), "ProducerStamp.kind is not well-formed UTF-8", what)
        var stamp = List[UInt8]()
        _lf(stamp, 1, _bytes(32, 0xAB))
        _lf(stamp, 5, cut[i])
        var last = List[UInt8]()
        _vf(last, 1, 1)
        _lf(last, 3, _bytes(32, 0xCD))
        _lf(last, 5, _needs(_e(), _runtime(_e())))
        _lf(last, 8, _bytes(3, 0x01))
        _lf(last, 2, stamp)
        assert_equal(last[len(last) - 1], cut[i][len(cut[i]) - 1], "the cut-short lead ends the header")
        _malformed(last^, "ProducerStamp.kind is not well-formed UTF-8", "cut-short lead #" + String(i) + " at the end")
    var good: List[List[UInt8]] = [
        [UInt8(0x61), 0x01, 0x7F],  # ASCII up to 7F
        [UInt8(0xC2), 0x80],  # U+0080, the first 2-byte lead
        [UInt8(0xC3), 0xA9],  # U+00E9
        [UInt8(0xDF), 0xBF],  # U+07FF, the last 2-byte lead
        [UInt8(0xE0), 0xA0, 0x80],  # U+0800
        [UInt8(0xE0), 0xBF, 0xBF],  # U+0FFF
        [UInt8(0xE1), 0x80, 0x80],  # U+1000, the first of E1..EC
        [UInt8(0xE2), 0x82, 0xAC],  # U+20AC
        [UInt8(0xEC), 0xBF, 0xBF],  # U+CFFF, the last of E1..EC
        [UInt8(0xED), 0x80, 0x80],  # U+D000
        [UInt8(0xED), 0x9F, 0xBF],  # U+D7FF
        [UInt8(0xEE), 0x80, 0x80],  # U+E000
        [UInt8(0xEF), 0xBF, 0xBD],  # U+FFFD
        [UInt8(0xF0), 0x90, 0x80, 0x80],  # U+10000
        [UInt8(0xF0), 0x9F, 0x98, 0x80],  # U+1F600
        [UInt8(0xF1), 0x80, 0x80, 0x80],  # U+40000, the first of F1..F3
        [UInt8(0xF3), 0xBF, 0xBF, 0xBF],  # U+FFFFF, the last of F1..F3
        [UInt8(0xF4), 0x80, 0x80, 0x80],  # U+100000
        [UInt8(0xF4), 0x8F, 0xBF, 0xBF],  # U+10FFFF
    ]
    for i in range(len(good)):
        var h = decode_optimized_plan_header(_kind(good[i]))
        assert_equal(h.producer.value().kind.byte_length(), len(good[i]), "well-formed UTF-8 #" + String(i))

    # Every `string` field of the header is checked, not only `kind`.
    var ill: List[UInt8] = [0xC0, 0x80]
    var path = List[UInt8]()
    _lf(path, 1, ill)
    _vf(path, 2, 1)
    _vf(path, 3, 3)
    _malformed(_with_write(path), "WireWriteTarget.path is not well-formed UTF-8", "path")
    var scopes = List[UInt8]()
    _sf(scopes, 5, "orders")
    _lf(scopes, 5, ill)
    _lf(scopes, 9, _runtime(_e()))
    _malformed(_with_needs(scopes), "DeclaredNeeds.data_scopes is not well-formed UTF-8", "the second data_scopes entry")
    var runtime = List[UInt8]()
    _lf(runtime, 1, ill)
    _sf(runtime, 2, "cp312")
    _malformed(_with_needs(_needs(_e(), runtime)), "RuntimeNeed.runtime is not well-formed UTF-8", "runtime")
    var abi = List[UInt8]()
    _sf(abi, 1, "komira/python")
    _lf(abi, 2, ill)
    _malformed(_with_needs(_needs(_e(), abi)), "RuntimeNeed.runtime_abi is not well-formed UTF-8", "runtime_abi")

    # `bytes` fields carry any bytes.
    var raw = List[UInt8]()
    _lf(raw, 1, [UInt8(0xFF), 0xC0, 0x80])
    _ = decode_optimized_plan_header(_with_stamp(raw))


def test_body_never_parsed() raises:
    var junk: List[UInt8] = [0xFF, 0xFF, 0xFF, 0x0F, 0x4B, 0x00]
    var h = decode_optimized_plan_header(_with_body(junk))
    assert_equal(len(h.body), len(junk), "the body's length")
    for i in range(len(junk)):
        assert_equal(h.body[i], junk[i], "body byte " + String(i))


def main() raises:
    test_size_limit()
    test_format_version_not_accepted()
    test_understated_fields()
    test_understated_enum_values()
    test_malformed_framing()
    test_malformed_fields()
    test_malformed_utf8()
    test_body_never_parsed()
    print("every step 1 and step 2 refusal of the header codec, by name")
