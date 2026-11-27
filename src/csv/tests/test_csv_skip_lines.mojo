# =============================================================================
# `skip`: the first n raw lines of a CSV file are dropped before the header.
# =============================================================================
#
# A line is a raw line: it ends at LF, CRLF (one end) or a bare CR, a quote
# inside a skipped line opens no field, and a UTF-8 BOM is part of line 1. A
# skip that leaves no line to read is refused by name. The single-thread
# decode, the schema entry and both arms of the parallel reader apply the same
# skip, and a refusal after a skip names the file's own line and byte offset.
# =============================================================================

from std.testing import assert_equal, assert_true

from async_rt.cancellation.token import CancellationToken
from async_rt.ops.waker_sink import NoopSink
from async_rt.reactor.reactor import BACKEND_MOCK
from async_rt.runtime.runtime import (
    PLACEMENT_FIXED,
    PerCoreAsyncRuntime,
)

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch

from csv import (
    CsvReadOptions,
    Rfc4180,
    csv_skip_lines_end,
    read_csv_bytes_to_batch,
    read_csv_bytes_to_batch_parallel,
)
from csv.parallel_reader import read_csv_bytes_to_batch_parallel_with_dispatcher
from csv.reader import read_csv_bytes_to_schema


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _skip_end(data: String, skip: Int) raises -> Int:
    var buf = _bytes(data)
    return csv_skip_lines_end(Span(buf), skip)


def _skip_error(data: String, skip: Int) raises -> String:
    var buf = _bytes(data)
    try:
        _ = csv_skip_lines_end(Span(buf), skip)
    except e:
        return String(e)
    assert_true(False, "skip " + String(skip) + " was accepted")
    return String("")


def _past_end_text(skip: Int, m: Int) -> String:
    return (
        String("CSV_SKIP_PAST_END: skip=")
        + String(skip)
        + " skips every line of the file, which has "
        + String(m)
        + (" line" if m == 1 else " lines")
        + "; no header or record is left to read"
    )


def _read(data: String, skip: Int, has_header: Bool = True) raises -> RecordBatch:
    var buf = _bytes(data)
    var o = CsvReadOptions()
    o.skip = skip
    o.has_header = has_header
    return read_csv_bytes_to_batch[Rfc4180](Span(buf), o)


# ---- csv_skip_lines_end ------------------------------------------------------


def test_skip_end_after_lf_lines() raises:
    assert_equal(_skip_end("a\nb\nc\n", 1), 2)
    assert_equal(_skip_end("a\nb\nc\n", 2), 4)


def test_skip_end_counts_crlf_as_one_line_end() raises:
    assert_equal(_skip_end("a\r\nb\r\nc\r\n", 1), 3)
    assert_equal(_skip_end("a\r\nb\r\nc\r\n", 2), 6)


def test_skip_end_after_bare_cr_lines() raises:
    assert_equal(_skip_end("a\rb\rc\r", 2), 4)


def test_skip_end_with_no_final_line_end() raises:
    assert_equal(_skip_end("a\nb\nc", 2), 4)


def test_skip_end_ignores_a_quote_in_the_skipped_line() raises:
    assert_equal(_skip_end("say \"hi\nid,name\n1,Ana\n", 1), 8)


def test_skip_zero_is_offset_zero() raises:
    assert_equal(_skip_end("a\nb\n", 0), 0)
    assert_equal(_skip_end("", 0), 0)


def test_negative_skip_is_refused_by_name() raises:
    assert_equal(
        _skip_error("a\nb\n", -2),
        String(
            "CSV_SKIP_NEGATIVE: skip=-2 is negative; skip is the number of"
            " lines to skip at the start of the file and must be 0 or more"
        ),
    )


def test_skip_past_the_last_line_is_refused() raises:
    assert_equal(_skip_error("a\nb\n", 3), _past_end_text(3, 2))


def test_skip_of_every_line_is_refused() raises:
    assert_equal(_skip_error("a\nb\n", 2), _past_end_text(2, 2))
    assert_equal(_skip_error("a\nb", 2), _past_end_text(2, 2))


def test_past_end_names_a_single_line_in_the_singular() raises:
    assert_equal(_skip_error("a\n", 1), _past_end_text(1, 1))
    assert_equal(_skip_error("a", 1), _past_end_text(1, 1))


def test_skip_of_an_empty_file_is_refused() raises:
    assert_equal(_skip_error("", 1), _past_end_text(1, 0))


# ---- single-thread decode ----------------------------------------------------


def test_skip_one_note_line_reads_header_and_rows_after_it() raises:
    var rb = _read("exported by the till\nid,name\n1,Ana\n2,Bo\n", 1)
    assert_equal(rb.num_rows(), 2)
    assert_equal(rb.num_columns(), 2)
    assert_equal(rb.schema.field_at(0).name, String("id"))
    assert_equal(rb.schema.field_at(1).name, String("name"))
    ref ids = rb.column_at(0)
    var ida = ids.as_primitive[DType.int64]()
    assert_equal(Int(ida.get(0)), 1)
    assert_equal(Int(ida.get(1)), 2)
    ref names = rb.column_at(1)
    assert_equal(names.as_string().get(1), String("Bo"))


def test_skip_three_lines_of_mixed_width_notes() raises:
    var rb = _read("title\nrun 7, 2026\nsee, the, till, log\nid,name\n1,Ana\n", 3)
    assert_equal(rb.num_rows(), 1)
    assert_equal(rb.num_columns(), 2)
    assert_equal(rb.schema.field_at(0).name, String("id"))


def test_skip_without_a_header_makes_the_first_line_after_it_a_record() raises:
    var rb = _read("note\n1,Ana\n2,Bo\n", 1, False)
    assert_equal(rb.num_rows(), 2)
    assert_equal(rb.schema.field_at(0).name, String("col_0"))
    assert_equal(rb.schema.field_at(1).name, String("col_1"))
    ref ids = rb.column_at(0)
    assert_equal(Int(ids.as_primitive[DType.int64]().get(0)), 1)


def test_skip_with_a_semicolon_delimiter() raises:
    var buf = _bytes("note; not a field\nid;name\n1;Ana\n")
    var o = CsvReadOptions()
    o.skip = 1
    o.delimiter = UInt8(ord(";"))
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), o)
    assert_equal(rb.num_rows(), 1)
    assert_equal(rb.num_columns(), 2)
    assert_equal(rb.schema.field_at(1).name, String("name"))


def test_quoted_newline_after_the_skip_reads_as_one_cell() raises:
    var rb = _read("skip me\nid,note\n1,\"a\nb\"\n", 1)
    assert_equal(rb.num_rows(), 1)
    ref notes = rb.column_at(1)
    assert_equal(notes.as_string().get(0), String("a\nb"))


def test_quote_in_a_skipped_line_does_not_open_a_field() raises:
    var rb = _read("say \"hi\nid,name\n1,Ana\n", 1)
    assert_equal(rb.num_rows(), 1)
    assert_equal(rb.schema.field_at(0).name, String("id"))


def test_bom_on_the_skipped_first_line_does_not_reach_the_header() raises:
    var buf = List[UInt8]()
    buf.append(UInt8(0xEF))
    buf.append(UInt8(0xBB))
    buf.append(UInt8(0xBF))
    for b in String("exported\nid,name\n1,Ana\n").as_bytes():
        buf.append(b)
    var o = CsvReadOptions()
    o.skip = 1
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), o)
    assert_equal(rb.schema.field_at(0).name, String("id"))
    assert_equal(rb.num_rows(), 1)


def test_skip_with_crlf_and_bare_cr_note_lines() raises:
    var rb = _read("one\r\ntwo\rid,name\r\n1,Ana\r\n", 2)
    assert_equal(rb.num_rows(), 1)
    assert_equal(rb.schema.field_at(0).name, String("id"))


def test_skip_zero_reads_the_file_as_before() raises:
    var rb = _read("id,name\n1,Ana\n", 0)
    assert_equal(rb.num_rows(), 1)
    assert_equal(rb.schema.field_at(0).name, String("id"))


def test_skip_past_the_end_is_refused_by_the_decode() raises:
    var msg = String("")
    try:
        _ = _read("id,name\n1,Ana\n", 2)
    except e:
        msg = String(e)
    assert_equal(msg, _past_end_text(2, 2))


def test_skip_of_an_empty_file_is_refused_by_the_decode() raises:
    var msg = String("")
    try:
        _ = _read("", 1)
    except e:
        msg = String(e)
    assert_equal(msg, _past_end_text(1, 0))


def test_negative_skip_is_refused_by_the_decode() raises:
    var msg = String("")
    try:
        _ = _read("id\n1\n", -1)
    except e:
        msg = String(e)
    assert_true(msg.startswith("CSV_SKIP_NEGATIVE: skip=-1 "), msg)


# ---- schema entry ------------------------------------------------------------


def test_schema_after_a_skip_infers_from_the_line_after_it() raises:
    var buf = _bytes("exported by the till\nid,name\n1,Ana\n")
    var o = CsvReadOptions()
    o.skip = 1
    var schema = read_csv_bytes_to_schema[Rfc4180](Span(buf), o)
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_at(0).name, String("id"))
    assert_equal(schema.field_at(1).name, String("name"))
    assert_true(schema.field_at(0).arrow_type == ArrowType.INT64)
    assert_true(schema.field_at(1).arrow_type == ArrowType.STRING)


def test_schema_sample_budget_counts_after_the_skip() raises:
    # The notes alone are larger than the 256 KiB sample budget; the header
    # and rows after them must still be sampled.
    var s = String("")
    for _ in range(6000):
        s += String("a note line that is long enough to fill the budget fast\n")
    var skip = 6000
    s += "id,name\n1,Ana\n2,Bo\n"
    var buf = _bytes(s)
    var o = CsvReadOptions()
    o.skip = skip
    var schema = read_csv_bytes_to_schema[Rfc4180](Span(buf), o)
    assert_equal(schema.num_columns(), 2)
    assert_equal(schema.field_at(0).name, String("id"))
    assert_true(schema.field_at(0).arrow_type == ArrowType.INT64)


def test_schema_skip_past_the_end_is_refused() raises:
    var buf = _bytes("a\nb\n")
    var o = CsvReadOptions()
    o.skip = 5
    var msg = String("")
    try:
        _ = read_csv_bytes_to_schema[Rfc4180](Span(buf), o)
    except e:
        msg = String(e)
    assert_equal(msg, _past_end_text(5, 2))


# ---- refusals name the file's own line and byte offset ----------------------


def test_record_shape_refusal_after_a_skip_names_the_files_line_and_offset() raises:
    # 18 bytes of notes + "a,b\n" put the bad record on file line 4 at byte 22.
    var msg = String("")
    try:
        _ = _read("note one\nnote two\na,b\n1,2,3\n", 2)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        String(
            "CSV record 2 (line 4, byte offset 22) has 3 fields but the header"
            " has 2: field 3 has no column to go to. RFC 4180 requires every"
            " record to have the same number of fields; the reader refuses"
            " rather than drop or pad cells."
        ),
    )


def test_quote_violation_after_a_skip_names_the_files_line_and_offset() raises:
    var msg = String("")
    try:
        _ = _read("note\na,b\n1,\"x\"y\n", 1)
    except e:
        msg = String(e)
    assert_true(msg.startswith("CSV record 2 (line 3, byte offset 9), field 2"), msg)
    assert_true(msg.find("at byte offset 14 follows the field's closing quote") >= 0, msg)


# ---- parallel reader ---------------------------------------------------------

comptime _N_ROWS = 80000  # ~1.1 MiB of rows, clears the 1 MiB parallel gate
comptime _NOTES = "exported by the till\nrun 7\n"


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _wide_input(notes: String, bad_row: Int, bad: String) -> List[UInt8]:
    var s = notes + String("a,b,c\n")
    for i in range(_N_ROWS):
        if i == bad_row:
            s += bad
        else:
            s += String(i) + "," + String(i * 2) + ",row" + String(i) + "\n"
    return _bytes(s)


def _assert_rows(rb: RecordBatch, label: String) raises:
    assert_equal(rb.num_rows(), _N_ROWS, label + ": rows")
    assert_equal(rb.schema.field_at(0).name, String("a"), label)
    ref c0 = rb.column_at(0)
    var a = c0.as_primitive[DType.int64]()
    ref c1 = rb.column_at(1)
    var b = c1.as_primitive[DType.int64]()
    ref c2 = rb.column_at(2)
    var c = c2.as_string()
    for i in range(0, _N_ROWS, 997):
        assert_equal(Int(a.get(i)), i, label + ": a")
        assert_equal(Int(b.get(i)), i * 2, label + ": b")
        assert_equal(c.get(i), String("row") + String(i), label + ": c")
    assert_equal(Int(a.get(_N_ROWS - 1)), _N_ROWS - 1, label + ": last a")


def test_parallel_reader_after_a_skip_matches_the_single_thread_reader() raises:
    var data = _wide_input(String(_NOTES), -1, String(""))
    var o = CsvReadOptions()
    o.skip = 2
    _assert_rows(
        read_csv_bytes_to_batch[Rfc4180](Span(data), o), String("single")
    )
    _assert_rows(
        read_csv_bytes_to_batch_parallel[Rfc4180](Span(data), o, 4),
        String("parallel serial arm"),
    )
    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    var ct = CancellationToken.new()
    var rb = read_csv_bytes_to_batch_parallel_with_dispatcher[
        Rfc4180, origin_of(disp)
    ](Span(data), o, Pointer(to=disp), ct.clone(), 4)
    _ = ct^
    _assert_rows(rb, String("parallel dispatcher arm"))


def test_parallel_skip_past_the_end_is_refused() raises:
    var data = _wide_input(String(""), -1, String(""))
    var o = CsvReadOptions()
    o.skip = _N_ROWS + 1
    var msg = String("")
    try:
        _ = read_csv_bytes_to_batch_parallel[Rfc4180](Span(data), o, 4)
    except e:
        msg = String(e)
    assert_equal(msg, _past_end_text(_N_ROWS + 1, _N_ROWS + 1))


def _bad_offset(bad_row: Int) -> Int:
    var n = String(_NOTES).byte_length() + String("a,b,c\n").byte_length()
    for i in range(bad_row):
        n += (
            String(i) + "," + String(i * 2) + ",row" + String(i) + "\n"
        ).byte_length()
    return n


def _assert_late_refusal(msg: String, bad_row: Int) raises:
    # Record 1 is the header after the skip; the file's line is 2 more.
    var where = (
        String("record ")
        + String(bad_row + 2)
        + " (line "
        + String(bad_row + 4)
        + ", byte offset "
        + String(_bad_offset(bad_row))
        + ")"
    )
    assert_true(msg.find(where) >= 0, "expected `" + where + "` in: " + msg)
    assert_true(msg.find("has 4 fields but the header has 3") >= 0, msg)


def test_late_worker_refusal_after_a_skip_names_the_files_line() raises:
    var bad_row = 70000
    var data = _wide_input(String(_NOTES), bad_row, String("1,1,row,extra\n"))
    var o = CsvReadOptions()
    o.skip = 2
    var msg = String("")
    try:
        _ = read_csv_bytes_to_batch_parallel[Rfc4180](Span(data), o, 4)
    except e:
        msg = String(e)
    assert_true(msg.find("csv.parallel_reader: worker ") >= 0, msg)
    _assert_late_refusal(msg, bad_row)

    var runtime = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = runtime.dispatcher()
    var ct = CancellationToken.new()
    var msg2 = String("")
    try:
        _ = read_csv_bytes_to_batch_parallel_with_dispatcher[
            Rfc4180, origin_of(disp)
        ](Span(data), o, Pointer(to=disp), ct.clone(), 4)
    except e:
        msg2 = String(e)
    _ = ct^
    assert_true(msg2.find("csv.parallel_reader: worker ") >= 0, msg2)
    _assert_late_refusal(msg2, bad_row)


def main() raises:
    test_skip_end_after_lf_lines()
    test_skip_end_counts_crlf_as_one_line_end()
    test_skip_end_after_bare_cr_lines()
    test_skip_end_with_no_final_line_end()
    test_skip_end_ignores_a_quote_in_the_skipped_line()
    test_skip_zero_is_offset_zero()
    test_negative_skip_is_refused_by_name()
    test_skip_past_the_last_line_is_refused()
    test_skip_of_every_line_is_refused()
    test_past_end_names_a_single_line_in_the_singular()
    test_skip_of_an_empty_file_is_refused()
    test_skip_one_note_line_reads_header_and_rows_after_it()
    test_skip_three_lines_of_mixed_width_notes()
    test_skip_without_a_header_makes_the_first_line_after_it_a_record()
    test_skip_with_a_semicolon_delimiter()
    test_quoted_newline_after_the_skip_reads_as_one_cell()
    test_quote_in_a_skipped_line_does_not_open_a_field()
    test_bom_on_the_skipped_first_line_does_not_reach_the_header()
    test_skip_with_crlf_and_bare_cr_note_lines()
    test_skip_zero_reads_the_file_as_before()
    test_skip_past_the_end_is_refused_by_the_decode()
    test_skip_of_an_empty_file_is_refused_by_the_decode()
    test_negative_skip_is_refused_by_the_decode()
    test_schema_after_a_skip_infers_from_the_line_after_it()
    test_schema_sample_budget_counts_after_the_skip()
    test_schema_skip_past_the_end_is_refused()
    test_record_shape_refusal_after_a_skip_names_the_files_line_and_offset()
    test_quote_violation_after_a_skip_names_the_files_line_and_offset()
    test_parallel_reader_after_a_skip_matches_the_single_thread_reader()
    test_parallel_skip_past_the_end_is_refused()
    test_late_worker_refusal_after_a_skip_names_the_files_line()
    print("test_csv_skip_lines: PASS")
