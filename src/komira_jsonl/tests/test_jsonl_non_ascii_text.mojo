# =============================================================================
# test_jsonl_non_ascii_text.mojo -- non-ASCII text through the record codec
# and `write_batch_jsonl`
# =============================================================================
#
# Refs #1116. JSON text is UTF-8 (RFC 8259 section 8.1); every byte of a
# multi-byte character must pass through unchanged.
#
#   * test_write_record_copies_utf8_bytes -- `write_record` on a record whose
#     `to_json()` holds 2-, 3- and 4-byte characters appends exactly those
#     bytes plus LF. Before the fix it stopped the process at the first
#     continuation byte ("does not lie on a codepoint boundary").
#   * test_write_batch_jsonl_copies_utf8_bytes -- a STRING column holding
#     the same characters through `encode.write_batch_jsonl`: the cell is
#     written byte for byte (the same abort before the fix), and agrees
#     with `write_batch_jsonl_direct`.
#   * test_split_lines_keeps_utf8_bytes -- `split_lines` returns each line's
#     bytes as they are, for lines shorter than a 16-byte chunk, longer
#     than one, and with no final LF; `parse_jsonl` hands `from_json` the
#     same bytes. Before the fix each byte >= 0x80 became its own code
#     point (`C3 A9` came back as `C3 83 C2 A9`).
#   * test_split_lines_refuses_invalid_utf8 -- a line that is not UTF-8
#     (a lone 0xFF, a truncated 2-byte sequence) is refused naming the
#     line's first byte, rather than turned into a String that is not
#     UTF-8. Before the fix each byte became a code point and nothing was
#     refused.
# =============================================================================

from std.testing import assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray

from komira_jsonl.decode import parse_jsonl, split_lines
from komira_jsonl.encode import write_batch_jsonl, write_record
from komira_jsonl.json_compatible import JsonCompatible
from komira_jsonl.json_writer import write_batch_jsonl_direct


def _utf8_text() -> List[UInt8]:
    """`é` (C3 A9), `€` (E2 82 AC), U+1F600 (F0 9F 98 80), then `a`."""
    var b = List[UInt8]()
    b.append(0xC3)
    b.append(0xA9)
    b.append(0xE2)
    b.append(0x82)
    b.append(0xAC)
    b.append(0xF0)
    b.append(0x9F)
    b.append(0x98)
    b.append(0x80)
    b.append(0x61)
    return b^


def _str(b: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(b))


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _assert_bytes(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(len(got), len(want), what + " length")
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), what + " byte " + String(i))


@fieldwise_init
struct _Text(JsonCompatible):
    """`{"t":"<text>"}` with the text copied as it is (no escaping needed
    for the characters used here)."""

    var text: String

    def to_json(self) raises -> String:
        return '{"t":"' + self.text + '"}'

    @staticmethod
    def from_json(s: String) raises -> Self:
        if not s.startswith('{"t":"') or not s.endswith('"}'):
            raise Error("_Text.from_json: not a t record: " + s)
        var b = s.as_bytes()
        return Self(String(unsafe_from_utf8=b[6 : len(b) - 2]))



def _record_line(text: List[UInt8]) -> List[UInt8]:
    var want = _bytes(String('{"t":"'))
    want.extend(Span(text))
    want.extend(Span(String('"}').as_bytes()))
    return want^


def test_write_record_copies_utf8_bytes() raises:
    var text = _utf8_text()
    var buf = List[UInt8]()
    write_record(buf, _Text(_str(text)))
    var want = _record_line(text)
    want.append(0x0A)
    _assert_bytes(buf, want, "write_record")


def test_write_batch_jsonl_copies_utf8_bytes() raises:
    var text = _utf8_text()
    var v = List[String]()
    v.append(_str(text))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_string(StringArray.from_strings(v)))
    var sb = SchemaBuilder()
    sb.add_field(Field("t", ArrowType.STRING, True))
    var batch = rbb.build(sb.build())
    var out = List[UInt8]()
    write_batch_jsonl(out, batch)
    var want = _record_line(text)
    want.append(0x0A)
    _assert_bytes(out, want, "write_batch_jsonl")
    var direct = List[UInt8]()
    write_batch_jsonl_direct(direct, batch)
    _assert_bytes(direct, want, "write_batch_jsonl_direct")


def test_split_lines_keeps_utf8_bytes() raises:
    var text = _utf8_text()
    # Short line, then a line longer than one 16-byte chunk, then a last
    # line with no LF.
    var input = text.copy()
    input.append(0x0A)
    var long_line = List[UInt8]()
    for _ in range(4):
        long_line.extend(Span(text))
    input.extend(Span(long_line))
    input.append(0x0A)
    input.extend(Span(text))
    var lines = split_lines(Span(input))
    assert_equal(len(lines), 3)
    _assert_bytes(_bytes(lines[0]), text, "line 0")
    _assert_bytes(_bytes(lines[1]), long_line, "line 1")
    _assert_bytes(_bytes(lines[2]), text, "line 2")

    var doc = _record_line(text)
    doc.append(0x0A)
    doc.extend(Span(_record_line(long_line)))
    var recs = parse_jsonl[_Text](Span(doc))
    assert_equal(len(recs), 2)
    _assert_bytes(_bytes(recs[0].text), text, "record 0")
    _assert_bytes(_bytes(recs[1].text), long_line, "record 1")


def _refusal(var input: List[UInt8]) -> String:
    try:
        _ = split_lines(Span(input))
    except e:
        return String(e)
    return String("not refused")


def test_split_lines_refuses_invalid_utf8() raises:
    var lone = List[UInt8]()
    lone.append(0x61)
    lone.append(0xFF)
    lone.append(0x0A)
    assert_equal(
        _refusal(lone^), "split_lines: the line at byte 0 is not UTF-8"
    )
    var cut = List[UInt8]()
    cut.append(0x61)
    cut.append(0x0A)
    cut.append(0xC3)
    assert_equal(
        _refusal(cut^), "split_lines: the line at byte 2 is not UTF-8"
    )


def main() raises:
    test_write_record_copies_utf8_bytes()
    test_write_batch_jsonl_copies_utf8_bytes()
    test_split_lines_keeps_utf8_bytes()
    test_split_lines_refuses_invalid_utf8()
    print("test_jsonl_non_ascii_text: all passed")
