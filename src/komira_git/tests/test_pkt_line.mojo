# =============================================================================
# komira_git/tests/test_pkt_line.mojo -- pkt-line framing.
# =============================================================================
#
# WHERE THE VECTORS COME FROM: git v2.47.0 Documentation/
# gitprotocol-common.txt, "pkt-line Format": the example table ("0006a\n",
# "0005a", "000bfoobar\n", "0004"), the 65516-byte payload and 65520-byte
# line limits, and flush-pkt "0000"; gitprotocol-v2.txt for "0001"
# (delim-pkt) and "0002" (response-end-pkt).
#
# WHAT EACH TEST CATCHES:
#   * test_doc_examples: a length that excludes its own four digits, an
#     upper-case or unpadded length on output.
#   * test_limits: an off-by-one at 65516 / 65520 on either side.
#   * test_need_more: a reader that raises (or consumes) on a short buffer
#     instead of asking for more input.
#   * test_refusals: each refusal by its exact message.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_git import (
    PKT_DATA,
    PKT_DELIM,
    PKT_FLUSH,
    PKT_MAX_LENGTH,
    PKT_MAX_PAYLOAD,
    PKT_NEED_MORE,
    PKT_RESPONSE_END,
    append_pkt_data,
    append_pkt_delim,
    append_pkt_flush,
    append_pkt_response_end,
    append_pkt_text,
    read_pkt_line,
)


def _b(s: String) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def _text(b: List[UInt8]) -> String:
    var s = String()
    for i in range(len(b)):
        s += chr(Int(b[i]))
    return s^


def _read_err(s: String) -> String:
    var b = _b(s)
    try:
        _ = read_pkt_line(Span(b), 0)
    except e:
        return String(e)
    return String("OK")


def _encoded(payload: String) raises -> String:
    var out = List[UInt8]()
    append_pkt_text(out, payload)
    return _text(out)


def test_doc_examples() raises:
    assert_equal(_encoded("a\n"), "0006a\n")
    assert_equal(_encoded("a"), "0005a")
    assert_equal(_encoded("foobar\n"), "000bfoobar\n")
    assert_equal(_encoded(""), "0004")
    var cases = List[String]()
    cases.append("0006a\n")
    cases.append("0005a")
    cases.append("000bfoobar\n")
    cases.append("0004")
    var want = List[String]()
    want.append("a\n")
    want.append("a")
    want.append("foobar\n")
    want.append("")
    for i in range(len(cases)):
        var bytes = _b(cases[i])
        var line = read_pkt_line(Span(bytes), 0)
        assert_equal(line.kind, PKT_DATA)
        assert_equal(_text(line.payload), want[i])
        assert_equal(line.consumed, cases[i].byte_length())


def test_special_packets() raises:
    var out = List[UInt8]()
    append_pkt_flush(out)
    append_pkt_delim(out)
    append_pkt_response_end(out)
    assert_equal(_text(out), "000000010002")
    var kinds = List[Int]()
    kinds.append(PKT_FLUSH)
    kinds.append(PKT_DELIM)
    kinds.append(PKT_RESPONSE_END)
    var pos = 0
    for i in range(3):
        var line = read_pkt_line(Span(out), pos)
        assert_equal(line.kind, kinds[i])
        assert_equal(line.consumed, 4)
        assert_equal(len(line.payload), 0)
        pos += line.consumed


def test_sequence() raises:
    var out = List[UInt8]()
    append_pkt_text(out, "command=ls-refs\n")
    append_pkt_delim(out)
    append_pkt_text(out, "peel\n")
    append_pkt_flush(out)
    var pos = 0
    var seen = List[String]()
    while pos < len(out):
        var line = read_pkt_line(Span(out), pos)
        assert_true(line.kind != PKT_NEED_MORE)
        if line.kind == PKT_DATA:
            seen.append(_text(line.payload))
        else:
            seen.append("<" + String(line.kind) + ">")
        pos += line.consumed
    assert_equal(len(seen), 4)
    assert_equal(seen[0], "command=ls-refs\n")
    assert_equal(seen[1], "<1>")
    assert_equal(seen[2], "peel\n")
    assert_equal(seen[3], "<0>")
    # Upper-case length digits are read too.
    var up = _b("000Afoobar")
    var upper = read_pkt_line(Span(up), 0)
    assert_equal(_text(upper.payload), "foobar")


def test_need_more() raises:
    var b3 = _b("000")
    var short = read_pkt_line(Span(b3), 0)
    assert_equal(short.kind, PKT_NEED_MORE)
    assert_equal(short.consumed, 0)
    var b5 = _b("0006a")
    var partial = read_pkt_line(Span(b5), 0)
    assert_equal(partial.kind, PKT_NEED_MORE)
    assert_equal(partial.consumed, 0)
    var b6 = _b("0005a")
    var at_end = read_pkt_line(Span(b6), 5)
    assert_equal(at_end.kind, PKT_NEED_MORE)


def test_limits() raises:
    assert_equal(PKT_MAX_PAYLOAD, 65516)
    assert_equal(PKT_MAX_LENGTH, 65520)
    var big = List[UInt8](length=65516, fill=UInt8(0x61))
    var out = List[UInt8]()
    append_pkt_data(out, Span(big))
    assert_equal(len(out), 65520)
    assert_equal(Int(out[0]), 0x66)  # "fff0"
    assert_equal(Int(out[3]), 0x30)
    var line = read_pkt_line(Span(out), 0)
    assert_equal(line.kind, PKT_DATA)
    assert_equal(len(line.payload), 65516)
    big.append(UInt8(0x61))
    try:
        append_pkt_data(out, Span(big))
        assert_true(False)
    except e:
        assert_equal(
            String(e), "komira_git: pkt-line: payload of 65517 bytes exceeds 65516"
        )


def test_refusals() raises:
    assert_equal(_read_err("0003"), "komira_git: pkt-line: bad length 3")
    assert_equal(_read_err("fff1"), "komira_git: pkt-line: length 65521 exceeds 65520")
    assert_equal(_read_err("00x5abcd"), "komira_git: pkt-line: length is not four hex digits")
    assert_equal(_read_err(" 005a"), "komira_git: pkt-line: length is not four hex digits")


def main() raises:
    test_doc_examples()
    test_special_packets()
    test_sequence()
    test_need_more()
    test_limits()
    test_refusals()
    print("komira_git pkt-line tests passed")
