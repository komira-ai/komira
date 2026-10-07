# =============================================================================
# test_jsonl_line_check_branches.mojo -- every branch of line_check.mojo and
# key_unescape.mojo, each refusal one by one
# =============================================================================
#
# Each refusal case asserts the line AND the words of its own message, so a
# case reaching a different branch than the one it names fails. Controls
# assert the read still returns the right values. Cases:
#   - grammar states: each unexpected token per state, both halves of the
#     close check (wrong state; right state but the other container kind);
#   - scalars: every literal and number form, accepted and refused;
#   - strings: every escape, the \u and surrogate branches, every UTF-8
#     lead-byte class accepted and each refusal (bounds, truncation, bad
#     continuation), a control byte; strings of 16 bytes or more, so the
#     16-byte skip passes clean blocks and stops on a block with a
#     backslash, control byte or non-ASCII byte, with faults on both sides
#     of a block edge;
#   - an object not closed at the end of the input (no LF), a string left
#     open at the end of the input;
#   - indexes that do not match their bytes (hand-built tapes): every
#     contract check, and the two branches only such a tape reaches (a
#     string body ending in a backslash, a close quote with no open quote);
#   - row errors and line faults numbered with lines before the slice
#     (streaming) and bytes before it (parallel); an error before any row
#     is not labelled;
#   - key_unescape: every branch, called directly.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_json_index.simd_primitives import (
    TAG_OPEN_BRACE,
    TAG_CLOSE_BRACE,
    TAG_COLON,
    TAG_QUOTE_OPEN,
    TAG_QUOTE_CLOSE,
)
from komira_json_index.structural_index import StructuralIndex
from komira_jsonl.columnar_materializer import (
    materialize_jsonl_to_batch,
    materialize_jsonl_to_batch_parallel,
)
from komira_jsonl.key_unescape import key_has_escape, unescape_key
from komira_jsonl.streaming_source import read_jsonl_streamed_to_one_batch
from komira_runtime_paths import test_tmpdir


comptime _OBJ = "not a JSON object"
comptime _BAD = "not valid JSON"


def _schema_a() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.INT64, True))
    return sb.build()


def _schema_s() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.STRING, True))
    return sb.build()


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _err_of(b: List[UInt8], var schema: Schema) raises -> String:
    var rows = -1
    try:
        var batch = materialize_jsonl_to_batch(Span(b), schema^)
        rows = batch._num_rows
    except e:
        return String(e)
    raise Error("not refused, " + String(rows) + " row(s)")


def _refuse_b(label: String, b: List[UInt8], line: Int, words: String) raises:
    var msg = _err_of(b, _schema_a())
    var want = String("line ") + String(line) + ":"
    if want not in msg or words not in msg:
        raise Error(label + ": want '" + want + "' and '" + words + "', got: " + msg)


def _refuse(label: String, text: String, line: Int, words: String) raises:
    _refuse_b(label, _bytes_of(text), line, words)


def _bad(text: String, words: String) raises:
    """`text` as line 2 after a good line is refused with `words`."""
    _refuse(text, String('{"a":0}\n') + text + "\n", 2, words)


def _bad_str(body: List[UInt8], words: String) raises:
    """A string value with raw body `body` under an unread key, on line 2."""
    var b = _bytes_of(String('{"a":0}\n{"z":"'))
    b.extend(Span(body))
    b.extend(Span(String('"}\n').as_bytes()))
    _refuse_b(String("string body"), b, 2, words)


def _ok(text: String, rows: Int) raises:
    var b = _bytes_of(text)
    var batch = materialize_jsonl_to_batch(Span(b), _schema_a())
    if batch._num_rows != rows:
        raise Error("control: " + text + ": rows " + String(batch._num_rows))


def _string_value(body: List[UInt8]) raises -> String:
    """The STRING column value read from `{"s":"<body>"}`."""
    var b = _bytes_of(String('{"s":"'))
    b.extend(Span(body))
    b.extend(Span(String('"}\n').as_bytes()))
    var batch = materialize_jsonl_to_batch(Span(b), _schema_s())
    return String(batch.column_at(0).as_string().get(0))


def _repeat(c: String, n: Int) -> String:
    var s = String("")
    for _ in range(n):
        s += c
    return s^


# --- grammar states -----------------------------------------------------------


def test_grammar_states() raises:
    print("T1: each unexpected token per state")
    _bad(String('{,}'), "unexpected ','")              # key-or-close
    _bad(String('{"a":1,,"b":2}'), "unexpected ','")   # key
    _bad(String('{"a",1}'), "unexpected ','")          # colon
    _bad(String('{"a":,1}'), "unexpected ','")         # value
    _bad(String('{"z":[,1]}'), "unexpected ','")       # value-or-close
    _bad(String('{:1}'), "unexpected ':'")
    _bad(String('{"a"::1}'), "unexpected ':'")
    _bad(String('{"a":1:2}'), "unexpected ':'")
    _bad(String('{"a"{}}'), "unexpected '{'")
    _bad(String('{"a"[]}'), "unexpected '['")
    _bad(String('{"a":1{}}'), "unexpected '{'")
    _bad(String('{"a":1 "b":2}'), "unexpected string")  # comma-or-close
    _bad(String('{"a" "b"}'), "unexpected string")      # colon
    _bad(String('{"a":}'), "unexpected '}'")            # close in value
    _bad(String('{"z":[1,]}'), "unexpected ']'")
    _bad(String('{"a"}'), "unexpected '}'")             # close in colon
    _bad(String('{"z":[1}'), "'}' closes an array")
    _bad(String('{"z":{"b":1]}'), "']' closes an object")
    _bad(String('{"a" 1}'), "unexpected '1'")           # junk in a gap
    _bad(String('{"z":[1 2]}'), "unexpected '2'")       # after a scalar
    _bad(String('{"a":\t\n1}'), "does not end on its line")  # LF in a value gap
    _bad(String('{"a":1\n}'), "does not end on its line")    # LF after a value
    # Depth 0.
    _refuse("close at line start", String('{"a":0}\n]\n'), 2, _OBJ)
    _refuse("tail junk", String('{"a":0}  x\n'), 1, "content after the object: 'x'")
    _refuse("second object", String('{"a":0}{"a":1}\n'), 1, "content after the object: '{'")
    _refuse("control byte", String('{"a":0}\n\x01\n'), 2, "byte 0x01")
    # Not closed at the end of the input, with no LF after it.
    _refuse("eof", String('{"a":0}\n{"a":[1'), 2, "not closed before the end of the input")
    _refuse("eof after key", String('{"a":0}\n\n{"z"'), 3, "not closed before the end of the input")
    # Controls: nesting both kinds, empty containers, whitespace everywhere.
    _ok(String(' { "z" : [ { } , [ ] , [ [ 1 ] ] , { "y" : [ ] } ] , "a" : 1 } \r\n\n'), 1)
    _ok(String('{}\n{"a":1}\n'), 2)


# --- scalars ------------------------------------------------------------------


def test_scalars() raises:
    print("T2: literals and numbers")
    _ok(String('{"z":[true,false,null,0,-0,12,-12,1.5,-0.25,1e5,1E5,1e+5,1e-5,2.5E-3,0.0e0]}\n'), 1)
    _bad(String('{"z":tru}'), "expected a value, found 't'")
    _bad(String('{"z":truex}'), "unexpected 'x'")
    _bad(String('{"z":fals}'), "expected a value, found 'f'")
    _bad(String('{"z":falsy}'), "expected a value, found 'f'")
    _bad(String('{"z":nul}'), "expected a value, found 'n'")
    _bad(String('{"z":nil}'), "expected a value, found 'n'")
    _bad(String('{"z":-}'), "expected a value, found '-'")
    _bad(String('{"z":-a}'), "expected a value, found '-'")
    _bad(String('{"z":01}'), "unexpected '1'")
    _bad(String('{"z":.5}'), "expected a value, found '.'")
    _bad(String('{"z":1.}'), "expected a value, found '1'")
    _bad(String('{"z":1.e5}'), "expected a value, found '1'")
    _bad(String('{"z":1e}'), "expected a value, found '1'")
    _bad(String('{"z":1e+}'), "expected a value, found '1'")
    _bad(String('{"z":1ex}'), "expected a value, found '1'")
    _bad(String('{"z":+1}'), "expected a value, found '+'")


# --- strings ------------------------------------------------------------------


def _bs(*parts: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for p in parts:
        out.append(UInt8(p))
    return out^


def test_strings() raises:
    print("T3: escapes, \\u, surrogates, UTF-8, control bytes")
    # Every escape and \u form accepted, and decoded right.
    var v = _string_value(_bytes_of(String('q\\"b\\\\s\\/b\\bf\\fn\\nr\\rt\\t|\\u0041\\u00e9\\u00E9\\u20ac\\ud83d\\ude00')))
    assert_equal(v, String('q"b\\s/b\x08f\x0cn\nr\rt\t|Aéé€😀'))
    _bad(String('{"z":"\\x"}'), "the escape '\\x' is not a JSON escape")
    _bad_str(_bs(0x5C, 0x01), "a backslash followed by byte 0x01")
    _bad_str(_bs(0x5C, 0xC3, 0xA9), "a backslash followed by byte 0xC3")
    _bad(String('{"z":"\\u12"}'), "without four hex digits")      # short
    _bad(String('{"z":"\\u12G4"}'), "without four hex digits")    # non-hex
    _bad(String('{"z":"\\udc00"}'), "a lone low surrogate")
    _bad(String('{"z":"\\ud83d"}'), "not followed by a \\u escape")      # at the end
    _bad(String('{"z":"\\ud83dxxxxxx"}'), "not followed by a \\u escape")  # no backslash
    _bad(String('{"z":"\\ud83d\\n"}'), "not followed by a \\u escape")    # backslash, not u
    _bad(String('{"z":"\\ud83d\\u0041"}'), "that is not a low surrogate")
    _bad(String('{"z":"\\ud83d\\uzzzz"}'), "that is not a low surrogate")
    _bad(String('{"z":"\\udbff\\ue000"}'), "that is not a low surrogate")
    _bad_str(_bs(0x09), "a raw control byte 0x09")
    _bad_str(_bs(0x7F, 0x1F), "a raw control byte 0x1F")
    # UTF-8: one well-formed sequence of each lead-byte class reads back.
    var good = List[List[UInt8]]()
    good.append(_bs(0xC2, 0x80))                # C2-DF
    good.append(_bs(0xDF, 0xBF))
    good.append(_bs(0xE0, 0xA0, 0x80))          # E0, low bound A0
    good.append(_bs(0xE1, 0x80, 0x80))          # E1-EC
    good.append(_bs(0xEC, 0xBF, 0xBF))
    good.append(_bs(0xED, 0x9F, 0xBF))          # ED, high bound 9F
    good.append(_bs(0xEE, 0x80, 0x80))          # EE
    good.append(_bs(0xEF, 0xBF, 0xBF))          # EF
    good.append(_bs(0xF0, 0x90, 0x80, 0x80))    # F0, low bound 90
    good.append(_bs(0xF1, 0x80, 0x80, 0x80))    # F1-F3
    good.append(_bs(0xF3, 0xBF, 0xBF, 0xBF))
    good.append(_bs(0xF4, 0x8F, 0xBF, 0xBF))    # F4, high bound 8F
    for i in range(len(good)):
        var got = _string_value(good[i])
        assert_equal(len(got.as_bytes()), len(good[i]), "utf-8 good " + String(i))
    # Each refusal.
    var bad = List[List[UInt8]]()
    bad.append(_bs(0x80))                       # a continuation byte as a lead
    bad.append(_bs(0xC0, 0x80))                 # C0 (overlong)
    bad.append(_bs(0xC1, 0xBF))                 # C1 (overlong)
    bad.append(_bs(0xF5, 0x80, 0x80, 0x80))     # above F4
    bad.append(_bs(0xFF))
    bad.append(_bs(0xE0, 0x9F, 0x80))           # E0 below A0 (overlong)
    bad.append(_bs(0xED, 0xA0, 0x80))           # ED above 9F (surrogate)
    bad.append(_bs(0xF0, 0x8F, 0x80, 0x80))     # F0 below 90 (overlong)
    bad.append(_bs(0xF4, 0x90, 0x80, 0x80))     # F4 above 8F (> U+10FFFF)
    bad.append(_bs(0xC3, 0x28))                 # second byte not a continuation
    bad.append(_bs(0xE2, 0x82, 0x28))           # third byte not a continuation
    bad.append(_bs(0xF0, 0x9F, 0x98, 0xC0))     # fourth byte not a continuation
    bad.append(_bs(0xC3))                       # truncated by the string end
    bad.append(_bs(0xF0, 0x9F, 0x98))           # truncated by the string end
    for i in range(len(bad)):
        _bad_str(bad[i], "ill-formed UTF-8")


def test_long_strings() raises:
    print("T4: strings of 16 bytes and more")
    # Clean 16-byte blocks are skipped; a block holding a backslash or a
    # non-ASCII byte falls back to byte steps and reads right.
    var clean = _repeat(String("abcdefgh"), 6)  # 48 bytes
    assert_equal(_string_value(_bytes_of(clean)), clean)
    var body = _repeat(String("a"), 20) + "\\n" + _repeat(String("b"), 20) + "é" + _repeat(String("c"), 17)
    assert_equal(
        _string_value(_bytes_of(body)),
        _repeat(String("a"), 20) + "\n" + _repeat(String("b"), 20) + "é" + _repeat(String("c"), 17),
    )
    # A fault after clean blocks, on each side of a block edge (the string
    # body starts a block).
    var at16 = _bytes_of(_repeat(String("a"), 16))
    at16.append(0x09)
    at16.extend(Span(_bytes_of(_repeat(String("a"), 16))))
    _bad_str(at16, "a raw control byte 0x09")          # first byte of block 2
    var at15 = _bytes_of(_repeat(String("a"), 15))
    at15.append(0x09)
    at15.extend(Span(_bytes_of(_repeat(String("a"), 16))))
    _bad_str(at15, "a raw control byte 0x09")          # last byte of block 1
    var esc = _bytes_of(_repeat(String("a"), 32) + "\\q" + _repeat(String("a"), 16))
    _bad_str(esc, "the escape '\\q'")
    var hi = _bytes_of(_repeat(String("a"), 47))
    hi.append(0xFF)
    _bad_str(hi, "ill-formed UTF-8 at byte 0xFF")      # last byte of block 3
    var tail = _bytes_of(_repeat(String("a"), 48))
    tail.append(0xFF)
    _bad_str(tail, "ill-formed UTF-8 at byte 0xFF")    # past the last block
    var nul = _bytes_of(_repeat(String("a"), 31))
    nul.append(0x00)
    nul.extend(Span(_bytes_of(_repeat(String("a"), 16))))
    _bad_str(nul, "a raw control byte 0x00")


# --- string left open at the end of the input --------------------------------


def test_unterminated() raises:
    print("T5: a string left open")
    _refuse("open at EOF", String('{"a":0}\n{"z":"abc'), 2, "not closed on its line")
    _refuse(
        "escaped quote, open at EOF", String('{"a":0}\n{"z":"a\\"b'), 2,
        "not closed on its line",
    )
    _refuse(
        "open at LF after closed strings",
        String('{"a":0}\n{"y":"q","z":"abc\n{"a":1}\n'), 2,
        "not closed on its line",
    )


# --- indexes that do not match their bytes ------------------------------------


def _idx(offsets: List[Int], tags: List[UInt8]) -> StructuralIndex:
    var o = List[UInt32]()
    for x in offsets:
        o.append(UInt32(x))
    return StructuralIndex(o^, tags.copy())


def _idx_err(text: String, offsets: List[Int], tags: List[UInt8]) raises -> String:
    var b = _bytes_of(text)
    var idx = _idx(offsets, tags)
    try:
        var batch = materialize_jsonl_to_batch(Span(b), _schema_a(), idx)
        _ = batch^
    except e:
        return String(e)
    raise Error("hand index not refused: " + text)


def test_hand_built_indexes() raises:
    print("T6: index contract checks, and branches only a hand tape reaches")
    var OB = TAG_OPEN_BRACE
    var CB = TAG_CLOSE_BRACE
    var CO = TAG_COLON
    var QO = TAG_QUOTE_OPEN
    var QC = TAG_QUOTE_CLOSE
    # `{"a":1}`: the correct tape reads.
    var b = _bytes_of(String('{"a":1}'))
    var good = _idx([0, 1, 3, 4, 6], [OB, QO, QC, CO, CB])
    assert_equal(materialize_jsonl_to_batch(Span(b), _schema_a(), good)._num_rows, 1)
    var m: String
    m = _idx_err(String('{"a":1}'), [0, 1, 3, 4, 7], [OB, QO, QC, CO, CB])
    assert_true("is not below the input length" in m, m)
    m = _idx_err(String('{"a":1}'), [0, 1, 3, 2, 6], [OB, QO, QC, CO, CB])
    assert_true("out of order" in m, m)
    m = _idx_err(String('{"a":1}'), [0, 1, 3, 9, 6], [OB, QO, QC, CO, CB])
    assert_true("out of order or past the input" in m, m)
    m = _idx_err(String('{"a":1}'), [0, 1, 3, 5, 6], [OB, QO, QC, CO, CB])
    assert_true("does not match the '1'" in m, m)
    m = _idx_err(String('{"a":1}'), [0, 1, 3, 4, 6], [OB, QO, QC, UInt8(99), CB])
    assert_true("tag 99" in m, m)
    m = _idx_err(String('{"a":1}'), [0, 1], [OB, QO])
    assert_true("not followed by a close quote" in m, m)
    m = _idx_err(String('{"a":1}'), [0, 1, 4, 6], [OB, QO, CO, CB])
    assert_true("not followed by a close quote" in m, m)
    m = _idx_err(String('{"a":1}'), [0, 1, 1, 4, 6], [OB, QO, QC, CO, CB])
    assert_true("is not a quote after its open quote" in m, m)
    m = _idx_err(String('{"a":1}'), [0, 1, 9, 4, 6], [OB, QO, QC, CO, CB])
    assert_true("is not a quote after its open quote" in m, m)
    m = _idx_err(String('{"a":1}'), [0, 1, 2, 4, 6], [OB, QO, QC, CO, CB])
    assert_true("is not a quote after its open quote" in m, m)
    # A close quote with no open quote, in an object.
    m = _idx_err(String('{"a":"b"}'), [0, 1, 3, 4, 5, 8], [OB, QO, QC, CO, QC, CB])
    assert_true("a close quote with no open quote" in m, m)
    # A string body ending in a backslash (`x\` closed at the escaped quote).
    m = _idx_err(
        String('{"a":"x\\"}'), [0, 1, 3, 4, 5, 8, 9], [OB, QO, QC, CO, QO, QC, CB]
    )
    assert_true("line 1:" in m and "a string ends in a backslash" in m, m)
    # An empty tape over whitespace reads no rows.
    var ws = _bytes_of(String(" \n"))
    var empty = _idx(List[Int](), List[UInt8]())
    assert_equal(materialize_jsonl_to_batch(Span(ws), _schema_a(), empty)._num_rows, 0)


# --- line numbers with lines or bytes before the slice ------------------------


def _big(n_rows: Int, bad_row: Int, bad: String) -> String:
    var b = String("")
    for i in range(n_rows):
        if i == bad_row:
            b += bad + "\n"
        else:
            b += '{"a":' + String(i) + ',"pad":"' + String(i * 7919) + '"}\n'
    return b^


def test_numbering_before_the_slice() raises:
    print("T7: row errors numbered past the first chunk or partition")
    # Parallel: a row error (duplicate key) in a later partition; `before`
    # is the bytes of the partitions ahead of it.
    var p = _bytes_of(_big(150000, 139999, String('{"a":1,"a":2}')))
    var msg = String()
    try:
        var batch = materialize_jsonl_to_batch_parallel(Span(p), _schema_a(), 8)
        _ = batch^
    except e:
        msg = String(e)
    assert_true("line 140000:" in msg and "duplicate key" in msg, "parallel: " + msg)
    # Streaming: a row error (a string in an INT64 column) and a line fault
    # in a later chunk; `lines_before` is the lines of the chunks before it.
    var dir = test_tmpdir()
    var path = dir + "/row_err.jsonl"
    with open(path, "w") as f:
        f.write(_big(1000, 600, String('{"a":"x"}')))
    msg = String()
    try:
        var batch = read_jsonl_streamed_to_one_batch(path, _schema_a(), 256)
        _ = batch^
    except e:
        msg = String(e)
    assert_true("line 601:" in msg and "non-string Arrow type" in msg, "streaming: " + msg)
    # Serial: a row error on line 3.
    var s = _err_of(_bytes_of(String('{"a":1}\n\n{"a":true}\n')), _schema_a())
    assert_true(s.startswith("komira_jsonl: line 3: "), s)
    # An error before any row (the schema is refused) has no line.
    var sb = SchemaBuilder()
    for i in range(4097):
        sb.add_field(Field(String("c") + String(i), ArrowType.INT64, True))
    var e2 = _err_of(_bytes_of(String('{"a":1}\n')), sb.build())
    assert_true(not e2.startswith("komira_jsonl: line"), e2)


# --- key_unescape --------------------------------------------------------------


def _unesc(raw: String) raises -> String:
    var out = List[UInt8]()
    unescape_key(Span(raw.as_bytes()), out)
    return String(StringSlice(unsafe_from_utf8=Span(out)))


def _unesc_err(raw: String) raises -> String:
    var out = List[UInt8]()
    try:
        unescape_key(Span(raw.as_bytes()), out)
    except e:
        return String(e)
    raise Error("unescape_key did not refuse: " + raw)


def test_key_unescape() raises:
    print("T8: key_unescape, every branch")
    assert_true(not key_has_escape(Span(String("plain").as_bytes())))
    assert_true(key_has_escape(Span(String("a\\n").as_bytes())))
    assert_equal(_unesc(String('x\\"\\\\\\/\\b\\f\\n\\r\\t')), String('x"\\/\x08\x0c\n\r\t'))
    assert_equal(_unesc(String("\\u0041\\u00e9\\u20AC\\uD83D\\uDE00")), String("Aé€😀"))
    var nul = List[UInt8]()
    unescape_key(Span(String("a\\u0000b").as_bytes()), nul)
    assert_equal(len(nul), 3)
    assert_equal(Int(nul[1]), 0)
    assert_true("ends in a backslash" in _unesc_err(String("a\\")))
    assert_true("is short" in _unesc_err(String("\\u12")))
    assert_true("non-hex" in _unesc_err(String("\\u12g4")))
    assert_true("lone high surrogate" in _unesc_err(String("\\ud83d")))
    assert_true("lone high surrogate" in _unesc_err(String("\\ud83dxxxxxx")))
    assert_true("lone high surrogate" in _unesc_err(String("\\ud83d\\n")))
    assert_true("lone high surrogate" in _unesc_err(String("\\ud83d\\u0041")))
    assert_true("lone high surrogate" in _unesc_err(String("\\ud83d\\ue000")))
    assert_true("lone low surrogate" in _unesc_err(String("\\udc00")))
    assert_true("not a JSON escape" in _unesc_err(String("\\x")))


def main() raises:
    print("test_jsonl_line_check_branches")
    var failed = 0
    try:
        test_grammar_states()
    except e:
        print("FAIL T1:", e)
        failed += 1
    try:
        test_scalars()
    except e:
        print("FAIL T2:", e)
        failed += 1
    try:
        test_strings()
    except e:
        print("FAIL T3:", e)
        failed += 1
    try:
        test_long_strings()
    except e:
        print("FAIL T4:", e)
        failed += 1
    try:
        test_unterminated()
    except e:
        print("FAIL T5:", e)
        failed += 1
    try:
        test_hand_built_indexes()
    except e:
        print("FAIL T6:", e)
        failed += 1
    try:
        test_numbering_before_the_slice()
    except e:
        print("FAIL T7:", e)
        failed += 1
    try:
        test_key_unescape()
    except e:
        print("FAIL T8:", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("test_jsonl_line_check_branches: PASSED")
