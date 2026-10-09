# =============================================================================
# The streaming source's file paths and helpers, the line splitters, the
# line check's re-raise, and the materializer's null-bitmap helpers.
# =============================================================================
#
#   * test_stream_one_batch_counts -- `read_jsonl_streamed_to_one_batch` on
#     an empty file (no batch: an empty RecordBatch), on a file that fits
#     one chunk and ends in LF (its one batch returned as is), and on the
#     same rows without the last LF (a chunk batch and a tail batch joined),
#     values in order.
#   * test_stream_batches_eof_without_carry -- a file ending in LF read in
#     chunks: no carry is left at EOF, every row is read.
#   * test_file_size_and_trim -- `_file_size_bytes` of a 1234-byte and an
#     empty file; `_trim_chunk_to_complete_lines` at 0 (empty), inside the
#     chunk (its prefix) and at or past its end (the chunk).
#   * test_split_lines_in_buffer -- `split_lines_in_buffer` on lines with an
#     LF inside a string, an escaped quote and an escaped backslash before a
#     closing quote, and a trailing partial line ending inside a string: the
#     line bounds, the partial's start and the state at the end.
#   * test_next_newline_outside_string -- the same text one LF at a time,
#     the state carried across calls, and a buffer with no LF outside a
#     string (its length).
#   * test_index_error_other_than_unterminated -- `build_jsonl_index` passes
#     an index error that is not an unterminated string through unchanged
#     (here the input-size ceiling, reached with a Span whose length passes
#     it; the size check raises before any byte is read).
#   * test_null_bitmap_helpers -- `_bitmap_from_nulls` (None when no row is
#     null; else bit i is clear exactly for null rows) and `_null_count`.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_runtime_paths import test_tmpdir

from komira_json_index.input_limits import MAX_STRUCTURAL_INDEX_BYTES
from komira_jsonl.columnar_materializer import _bitmap_from_nulls, _null_count
from komira_jsonl.line_check import build_jsonl_index
from komira_jsonl.line_splitter import (
    next_newline_outside_string,
    split_lines_in_buffer,
)
from komira_jsonl.streaming_source import (
    _file_size_bytes,
    _trim_chunk_to_complete_lines,
    read_jsonl_streamed_to_batches,
    read_jsonl_streamed_to_one_batch,
)


def _write_file(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def _schema_a() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    return sb.build()


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def test_stream_one_batch_counts() raises:
    var dir = test_tmpdir()
    var empty = dir + "/empty.jsonl"
    _write_file(empty, "")
    var e = read_jsonl_streamed_to_one_batch(empty, _schema_a())
    assert_equal(e.num_rows(), 0)
    assert_equal(e.num_columns(), 0)
    # Ends in LF: one chunk of complete lines, no tail, one batch.
    var one = dir + "/one_chunk.jsonl"
    _write_file(one, '{"a":4}\n{"a":-2}\n{"a":9}\n')
    var b = read_jsonl_streamed_to_one_batch(one, _schema_a())
    assert_equal(b.num_rows(), 3)
    var col = b.column_at(0).as_primitive[DType.int64]()
    assert_equal(col.get(0), Int64(4))
    assert_equal(col.get(1), Int64(-2))
    assert_equal(col.get(2), Int64(9))
    var tail = dir + "/one_chunk_tail.jsonl"
    _write_file(tail, '{"a":4}\n{"a":-2}\n{"a":9}')
    var t = read_jsonl_streamed_to_one_batch(tail, _schema_a())
    assert_equal(t.num_rows(), 3)
    var tcol = t.column_at(0).as_primitive[DType.int64]()
    assert_equal(tcol.get(0), Int64(4))
    assert_equal(tcol.get(2), Int64(9))


def test_stream_batches_eof_without_carry() raises:
    var dir = test_tmpdir()
    var path = dir + "/lf_end.jsonl"
    var text = String()
    for i in range(10):
        text += '{"a":' + String(i) + "}\n"
    _write_file(path, text)
    var batches = read_jsonl_streamed_to_batches(path, _schema_a(), 24)
    var rows = 0
    for i in range(len(batches)):
        ref bt = batches[i]
        var col = bt.column_at(0).as_primitive[DType.int64]()
        for r in range(bt.num_rows()):
            assert_equal(Int(col.get(r)), rows)
            rows += 1
    assert_equal(rows, 10)


def test_file_size_and_trim() raises:
    var dir = test_tmpdir()
    var p = dir + "/size.bin"
    var text = String()
    for _ in range(1234):
        text += "x"
    _write_file(p, text)
    assert_equal(_file_size_bytes(p), 1234)
    var q = dir + "/size0.bin"
    _write_file(q, "")
    assert_equal(_file_size_bytes(q), 0)
    assert_equal(len(_trim_chunk_to_complete_lines(_b("ab\ncd"), 0)), 0)
    var pre = _trim_chunk_to_complete_lines(_b("ab\ncd"), 3)
    assert_equal(String(unsafe_from_utf8=Span(pre)), "ab\n")
    var whole = _trim_chunk_to_complete_lines(_b("ab\ncd"), 5)
    assert_equal(String(unsafe_from_utf8=Span(whole)), "ab\ncd")
    var past = _trim_chunk_to_complete_lines(_b("ab\ncd"), 9)
    assert_equal(String(unsafe_from_utf8=Span(past)), "ab\ncd")


# Line 0: `{"k":"a<LF>b"}` (bytes 0..11; its LF inside the string at 7),
# LF at 11. Line 1: `{"q":"x\"y\\"}` (12..26), LF at 26. Partial:
# `{"r":"open` from 27 to the end (37), inside a string.
comptime _TEXT = '{"k":"a\nb"}\n{"q":"x\\"y\\\\"}\n{"r":"open'


def test_split_lines_in_buffer() raises:
    var b = _b(_TEXT)
    assert_equal(len(b), 37)
    var r = split_lines_in_buffer(Span(b))
    assert_equal(len(r.starts), 2)
    assert_equal(r.starts[0], 0)
    assert_equal(r.ends[0], 11)
    assert_equal(r.starts[1], 12)
    assert_equal(r.ends[1], 26)
    assert_equal(r.trailing_partial_start, 27)
    assert_true(r.in_string_at_end)
    assert_false(r.prev_was_backslash_at_end)
    var none = List[UInt8]()
    var z = split_lines_in_buffer(Span(none))
    assert_equal(len(z.starts), 0)
    assert_equal(z.trailing_partial_start, 0)
    assert_false(z.in_string_at_end)


def test_next_newline_outside_string() raises:
    var b = _b(_TEXT)
    var in_string = False
    var bs = False
    var first = next_newline_outside_string(Span(b), 0, in_string, bs)
    assert_equal(first, 11)
    assert_false(in_string)
    var second = next_newline_outside_string(Span(b), first + 1, in_string, bs)
    assert_equal(second, 26)
    var third = next_newline_outside_string(Span(b), second + 1, in_string, bs)
    assert_equal(third, 37)
    assert_true(in_string)
    assert_false(bs)
    # Carried in: inside a string after a backslash, the quote is escaped,
    # the next one closes, then the LF ends the line.
    var c = _b('"x"\n')
    var s2 = True
    var bs2 = True
    assert_equal(next_newline_outside_string(Span(c), 0, s2, bs2), 3)
    assert_false(s2)
    assert_false(bs2)


def test_index_error_other_than_unterminated() raises:
    var one = _b("{")
    var before = List[UInt8]()
    var msg = String()
    try:
        # SAFETY: the Span claims one byte more than the structural index
        # accepts, over a 1-byte buffer. `build_structural_index` checks
        # the length first and raises before reading any byte, so no byte
        # past `one` is touched; `one` outlives the call.
        var big = Span[UInt8, origin_of(one)](
            unsafe_ptr=one.unsafe_ptr(), length=MAX_STRUCTURAL_INDEX_BYTES + 1
        )
        _ = build_jsonl_index(big, Span(before), 0)
    except e:
        msg = String(e)
    assert_true(
        msg.startswith(
            "JSON structural index: input buffer is "
            + String(MAX_STRUCTURAL_INDEX_BYTES + 1) + " bytes"
        ),
        msg,
    )


def test_null_bitmap_helpers() raises:
    var none = List[Bool]()
    assert_false(Bool(_bitmap_from_nulls(none)))
    assert_equal(_null_count(none), 0)
    var valid = List[Bool]()
    valid.append(False)
    valid.append(False)
    assert_false(Bool(_bitmap_from_nulls(valid)))
    assert_equal(_null_count(valid), 0)
    var mixed = List[Bool]()
    for i in range(11):
        mixed.append(i % 3 == 1)
    var bm = _bitmap_from_nulls(mixed)
    assert_true(Bool(bm))
    for i in range(11):
        assert_equal(bm.value().test(i), i % 3 != 1, String(i))
    assert_equal(_null_count(mixed), 4)


def main() raises:
    test_stream_one_batch_counts()
    test_stream_batches_eof_without_carry()
    test_file_size_and_trim()
    test_split_lines_in_buffer()
    test_next_newline_outside_string()
    test_index_error_other_than_unterminated()
    test_null_bitmap_helpers()
    print("test_stream_split_helpers: all passed")
