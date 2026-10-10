# =============================================================================
# ORC files another implementation wrote, read by value.
# =============================================================================
#
# Every other ORC test in this repo reads bytes komira_orc's own writer
# produced, so a writer and reader that agree on a wrong layout pass. These
# six files were written by pyarrow's bundled ORC C++ writer (provenance and
# the data rules: tests/fixtures/orc/gen_pyarrow_orc_fixtures.py). Expected
# values are recomputed here from the generator's rules, never from a komira
# read. The ORC C++ layout (decoded by hand from the stripe footer of
# pyarrow_nullable_mixed.orc): a ROW_INDEX stream for every column, root
# STRUCT and DOUBLE encoded DIRECT, the integer and STRING columns DIRECT_V2
# (strings with a LENGTH stream, not a dictionary), writerTimezone "GMT";
# the compressed files frame each stream in ORC C++'s chunks.
#
# What each test proves, and the defect it catches:
#   * test_mixed_<codec> (none, zlib, snappy, zstd, lz4) -- the PostScript's
#     compression field (walked here byte by byte, not by komira's parser)
#     is the codec the generator asked for; for the files whose footer is
#     stored raw, the footer ends in writer=ORC_CPP, softwareVersion "2.3.0"
#     (so the file is foreign, not a komira re-write). The full read has 1200
#     rows; columns id/label/nint/nflt in order with types INT64/STRING/
#     INT64/FLOAT64; every row's value and every NULL position as the
#     generator's rules give them; null counts 0/400/240/172. A projected
#     read [nflt, label] gives the same cells in the caller's order.
#     Catches: a codec misdecoded or misdetected, NULL rows dropped or
#     shifted, a string LENGTH/DATA pair misread, an encoding kind taken
#     from the wrong ColumnEncoding entry, a projection mapping the wrong
#     column.
#   * test_multistripe -- 3000 rows across 3 stripes (1024, 1024, 952 rows;
#     decoded by hand from the footer bytes: three StripeInformation entries
#     with numberOfRows 0x80 0x08, 0x80 0x08, 0xB8 0x07); every row of id,
#     label and flag (BOOL) with its NULLs; null counts 0/750/500. Catches a
#     reader that loses rows or PRESENT state at a stripe boundary.
#   * test_failed_read_leaves_reader_usable / test_failed_parallel_read_
#     leaves_reader_usable -- one encoding byte changed so `id` fails while
#     the other columns decode; the read raises naming column 0, and two
#     reads of the unchanged file after it are correct (serial; 4-worker
#     dispatcher). Catches an error path that drops the accumulator slab
#     with slots already moved out (a double free: the next read crashes).
#   * test_cancelled_parallel_read_leaves_reader_usable -- a pre-cancelled
#     token makes the dispatched read raise CancelledError, and the next
#     reads are correct.
#
# Mutants planted and seen red here are listed in the BUCK file header.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PerCoreAsyncRuntime, PLACEMENT_FIXED
from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_orc import (
    OrcFileTail,
    read_orc_bytes,
    read_orc_bytes_projected,
    read_orc_bytes_with_dispatcher,
    read_orc_file,
)

from komira_formats_e2e import Mismatches, hex_of

# orc_proto.proto CompressionKind, spelled here rather than imported.
comptime _NONE: Int = 0
comptime _ZLIB: Int = 1
comptime _SNAPPY: Int = 2
comptime _LZ4: Int = 4
comptime _ZSTD: Int = 5

comptime _MIXED_ROWS: Int = 1200
comptime _MULTI_ROWS: Int = 3000

# Report at most this many wrong cells per column; the count says the rest.
comptime _SHOW: Int = 6


def _cat(i: Int) -> String:
    var c = List[String]()
    c.append("x")
    c.append("y")
    c.append("z")
    c.append("w")
    return c[i % 4]


struct _Col(Movable):
    """Wrong cells of one column: the first few spelled, the rest counted."""

    var label: String
    var shown: List[String]
    var wrong: Int

    def __init__(out self, label: String):
        self.label = label
        self.shown = List[String]()
        self.wrong = 0

    def add(mut self, msg: String):
        self.wrong += 1
        if len(self.shown) < _SHOW:
            self.shown.append(msg)

    def flush(self, mut m: Mismatches):
        for i in range(len(self.shown)):
            m.add(self.label + " " + self.shown[i])
        if self.wrong > len(self.shown):
            m.add(
                self.label + ": " + String(self.wrong - len(self.shown))
                + " more wrong cells"
            )


# ---- the PostScript and footer bytes, walked without komira_orc ----------


def _varint(b: Span[UInt8, _], mut pos: Int) raises -> UInt64:
    var v: UInt64 = 0
    var shift = 0
    while True:
        if pos >= len(b) or shift > 63:
            raise Error("varint runs off the PostScript")
        var x = b[pos]
        pos += 1
        v |= UInt64(x & 0x7F) << UInt64(shift)
        if x < 0x80:
            return v
        shift += 7


def _postscript_compression(b: Span[UInt8, _]) raises -> Int:
    """Field 2 (compression) of the PostScript: the last byte of the file is
    the PostScript length; fields are varints except version (packed) and
    magic (bytes), both length-delimited. -1 when the field is absent."""
    var n = len(b)
    var end = n - 1
    var pos = end - Int(b[n - 1])
    var codec = -1
    while pos < end:
        var tag = _varint(b, pos)
        var field = Int(tag >> 3)
        var wire = Int(tag & 7)
        if wire == 0:
            var v = _varint(b, pos)
            if field == 2:
                codec = Int(v)
        elif wire == 2:
            pos += Int(_varint(b, pos))
        else:
            raise Error("PostScript: wire type " + String(wire))
    if pos != end:
        raise Error("PostScript: fields overrun the length byte")
    return codec


def _footer_tail(b: Span[UInt8, _]) -> List[UInt8]:
    """The 9 bytes before the PostScript: the end of the footer."""
    var n = len(b)
    var end = n - 1 - Int(b[n - 1])
    var out = List[UInt8]()
    for i in range(end - 9, end):
        out.append(b[i])
    return out^


def _orc_cpp_2_3_0() -> List[UInt8]:
    # Footer field 9 (writer) = 1 ORC_CPP: tag 0x48, 0x01; field 12
    # (softwareVersion) = "2.3.0": tag 0x62, length 5, the ASCII.
    var out = List[UInt8]()
    for x in [0x48, 0x01, 0x62, 0x05, 0x32, 0x2E, 0x33, 0x2E, 0x30]:
        out.append(UInt8(x))
    return out^


# ---- the generator's rules ------------------------------------------------


def _label_mixed(r: Int) -> Optional[String]:
    if r % 3 == 0:
        return None
    return _cat(r)


def _nint(r: Int) -> Optional[Int64]:
    if r % 5 == 0:
        return None
    return Int64(r * 10)


def _nflt(r: Int) -> Optional[Float64]:
    if r % 7 == 0:
        return None
    return Float64(r) + 0.5


def _label_multi(r: Int) -> Optional[String]:
    if r % 4 == 0:
        return None
    return _cat(r)


def _flag(r: Int) -> Optional[Bool]:
    if r % 6 == 0:
        return None
    return r % 2 == 0


# ---- column checks ----------------------------------------------------------


def _check_shape(
    mut m: Mismatches,
    batch: RecordBatch,
    rows: Int,
    names: List[String],
    types: List[ArrowType],
    at: String,
) raises -> Bool:
    var ok = True
    if batch.num_rows() != rows:
        m.add(at + ": " + String(batch.num_rows()) + " rows, want " + String(rows))
        ok = False
    if batch.num_columns() != len(names):
        m.add(
            at + ": " + String(batch.num_columns()) + " columns, want "
            + String(len(names))
        )
        return False
    for c in range(len(names)):
        if batch.schema.field_name(c) != names[c]:
            m.add(at + " column " + String(c) + ": named " + batch.schema.field_name(c) + ", want " + names[c])
            ok = False
        if batch.schema.field_arrow_type(c) != types[c]:
            m.add(at + " " + names[c] + ": type " + String(batch.schema.field_arrow_type(c)) + ", want " + String(types[c]))
            ok = False
    return ok


def _check_i64(
    mut m: Mismatches,
    batch: RecordBatch,
    c: Int,
    want: List[Optional[Int64]],
    want_nulls: Int,
    at: String,
) raises:
    var col = _Col(at + " " + batch.schema.field_name(c))
    var a = batch.column_as_primitive_int64(c)
    var nulls = 0
    for r in range(len(want)):
        if a.is_null(r):
            nulls += 1
            if want[r]:
                col.add("row " + String(r) + ": NULL, want " + String(want[r].value()))
        elif not want[r]:
            col.add("row " + String(r) + ": got " + String(a.get(r)) + ", want NULL")
        elif a.get(r) != want[r].value():
            col.add("row " + String(r) + ": got " + String(a.get(r)) + " want " + String(want[r].value()))
    if nulls != want_nulls:
        col.add("null count " + String(nulls) + ", want " + String(want_nulls))
    col.flush(m)


def _check_f64(
    mut m: Mismatches,
    batch: RecordBatch,
    c: Int,
    want: List[Optional[Float64]],
    want_nulls: Int,
    at: String,
) raises:
    var col = _Col(at + " " + batch.schema.field_name(c))
    var a = batch.column_as_primitive_float64(c)
    var nulls = 0
    for r in range(len(want)):
        if a.is_null(r):
            nulls += 1
            if want[r]:
                col.add("row " + String(r) + ": NULL, want " + String(want[r].value()))
        elif not want[r]:
            col.add("row " + String(r) + ": got " + String(a.get(r)) + ", want NULL")
        elif a.get(r) != want[r].value():
            col.add("row " + String(r) + ": got " + String(a.get(r)) + " want " + String(want[r].value()))
    if nulls != want_nulls:
        col.add("null count " + String(nulls) + ", want " + String(want_nulls))
    col.flush(m)


def _check_str(
    mut m: Mismatches,
    batch: RecordBatch,
    c: Int,
    want: List[Optional[String]],
    want_nulls: Int,
    at: String,
) raises:
    var col = _Col(at + " " + batch.schema.field_name(c))
    var a = batch.column_as_string(c)
    var nulls = 0
    for r in range(len(want)):
        if a.is_null(r):
            nulls += 1
            if want[r]:
                col.add("row " + String(r) + ": NULL, want '" + want[r].value() + "'")
        elif not want[r]:
            col.add("row " + String(r) + ": got '" + a.get(r) + "', want NULL")
        elif a.get(r) != want[r].value():
            col.add("row " + String(r) + ": got '" + a.get(r) + "' want '" + want[r].value() + "'")
    if nulls != want_nulls:
        col.add("null count " + String(nulls) + ", want " + String(want_nulls))
    col.flush(m)


def _check_bool(
    mut m: Mismatches,
    batch: RecordBatch,
    c: Int,
    want: List[Optional[Bool]],
    want_nulls: Int,
    at: String,
) raises:
    var col = _Col(at + " " + batch.schema.field_name(c))
    var a = batch.column_as_boolean(c)
    var nulls = 0
    for r in range(len(want)):
        if a.is_null(r):
            nulls += 1
            if want[r]:
                col.add("row " + String(r) + ": NULL, want " + String(want[r].value()))
        elif not want[r]:
            col.add("row " + String(r) + ": got " + String(a.get(r)) + ", want NULL")
        elif a.get(r) != want[r].value():
            col.add("row " + String(r) + ": got " + String(a.get(r)) + " want " + String(want[r].value()))
    if nulls != want_nulls:
        col.add("null count " + String(nulls) + ", want " + String(want_nulls))
    col.flush(m)


# ---- the files --------------------------------------------------------------


def _check_mixed(name: String, codec: Int, raw_footer: Bool) raises:
    var path = "orc/" + name
    var m = Mismatches()
    var bytes = Path(path).read_bytes()
    var got_codec = _postscript_compression(Span(bytes))
    m.check(
        got_codec == codec,
        name + ": PostScript compression " + String(got_codec) + ", want " + String(codec),
    )
    if raw_footer:
        var tail = _footer_tail(Span(bytes))
        var want = _orc_cpp_2_3_0()
        m.check(
            tail == want,
            name + ": footer ends [" + hex_of(Span(tail)) + "], want writer=ORC_CPP softwareVersion 2.3.0 ["
            + hex_of(Span(want)) + "]",
        )

    var ids = List[Optional[Int64]]()
    var labels = List[Optional[String]]()
    var nints = List[Optional[Int64]]()
    var nflts = List[Optional[Float64]]()
    for r in range(_MIXED_ROWS):
        ids.append(Int64(r))
        labels.append(_label_mixed(r))
        nints.append(_nint(r))
        nflts.append(_nflt(r))

    var batch = read_orc_file(path)
    var names = List[String]()
    names.append("id")
    names.append("label")
    names.append("nint")
    names.append("nflt")
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.STRING)
    types.append(ArrowType.INT64)
    types.append(ArrowType.FLOAT64)
    if _check_shape(m, batch, _MIXED_ROWS, names, types, name):
        _check_i64(m, batch, 0, ids, 0, name)
        _check_str(m, batch, 1, labels, 400, name)
        _check_i64(m, batch, 2, nints, 240, name)
        _check_f64(m, batch, 3, nflts, 172, name)

    # A projection in a different order: [nflt, label].
    var proj = List[Int]()
    proj.append(3)
    proj.append(1)
    var pb = read_orc_bytes_projected(Span(bytes), proj)
    var pnames = List[String]()
    pnames.append("nflt")
    pnames.append("label")
    var ptypes = List[ArrowType]()
    ptypes.append(ArrowType.FLOAT64)
    ptypes.append(ArrowType.STRING)
    var pat = name + " [nflt, label]"
    if _check_shape(m, pb, _MIXED_ROWS, pnames, ptypes, pat):
        _check_f64(m, pb, 0, nflts, 172, pat)
        _check_str(m, pb, 1, labels, 400, pat)
    m.raise_if_any(name)


def test_mixed_none() raises:
    _check_mixed("pyarrow_nullable_mixed.orc", _NONE, True)


def test_mixed_zlib() raises:
    _check_mixed("pyarrow_nullable_codec_zlib.orc", _ZLIB, False)


def test_mixed_snappy() raises:
    _check_mixed("pyarrow_nullable_codec_snappy.orc", _SNAPPY, True)


def test_mixed_zstd() raises:
    _check_mixed("pyarrow_nullable_codec_zstd.orc", _ZSTD, False)


def test_mixed_lz4() raises:
    _check_mixed("pyarrow_nullable_codec_lz4.orc", _LZ4, True)


def test_multistripe() raises:
    var name = String("pyarrow_multistripe_nullable.orc")
    var path = "orc/" + name
    var m = Mismatches()
    var bytes = Path(path).read_bytes()
    var got_codec = _postscript_compression(Span(bytes))
    m.check(got_codec == _NONE, name + ": PostScript compression " + String(got_codec) + ", want 0 (NONE)")
    var tail = _footer_tail(Span(bytes))
    m.check(tail == _orc_cpp_2_3_0(), name + ": footer ends [" + hex_of(Span(tail)) + "], want ORC_CPP 2.3.0")

    # The stripe directory (NONE codec, so the footer parses as stored).
    var t = OrcFileTail.parse(Span(bytes))
    var want_rows = List[Int]()
    want_rows.append(1024)
    want_rows.append(1024)
    want_rows.append(952)
    var stripes = len(t.footer.stripes)
    if stripes != 3:
        m.add(name + ": " + String(stripes) + " stripes, want 3")
    else:
        for s in range(3):
            var got = t.footer.stripes[s].number_of_rows
            m.check(
                got == want_rows[s],
                name + " stripe " + String(s) + ": " + String(got) + " rows, want " + String(want_rows[s]),
            )
    m.check(
        t.footer.number_of_rows == _MULTI_ROWS,
        name + ": footer numberOfRows " + String(t.footer.number_of_rows),
    )

    var ids = List[Optional[Int64]]()
    var labels = List[Optional[String]]()
    var flags = List[Optional[Bool]]()
    for r in range(_MULTI_ROWS):
        ids.append(Int64(r))
        labels.append(_label_multi(r))
        flags.append(_flag(r))

    var batch = read_orc_file(path)
    var names = List[String]()
    names.append("id")
    names.append("label")
    names.append("flag")
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.STRING)
    types.append(ArrowType.BOOL)
    if _check_shape(m, batch, _MULTI_ROWS, names, types, name):
        _check_i64(m, batch, 0, ids, 0, name)
        _check_str(m, batch, 1, labels, 750, name)
        _check_bool(m, batch, 2, flags, 500, name)
    m.raise_if_any(name)


# Offset of column 1's ColumnEncoding.kind in pyarrow_nullable_mixed.orc,
# decoded by hand: the one stripe's footer starts at 10604 (offset 3 +
# indexLength 134 + dataLength 10467); its encodings are `12 04 08 k 10 00`
# per column, column 0 (the STRUCT) at 10714 and column 1 (`id`) at 10720, so
# the kind byte of `id` is 10723 (2, DIRECT_V2).
comptime _ID_KIND_AT: Int = 10723


def _crafted_id_direct() raises -> List[UInt8]:
    """pyarrow_nullable_mixed.orc with `id`'s encoding kind set to DIRECT."""
    var bad = Path("orc/pyarrow_nullable_mixed.orc").read_bytes()
    assert_equal(Int(bad[_ID_KIND_AT]), 2, "fixture: id's encoding is DIRECT_V2")
    assert_equal(Int(bad[_ID_KIND_AT - 1]), 0x08, "fixture: the kind tag precedes it")
    bad[_ID_KIND_AT] = 0
    return bad^


def _check_failed(raised: Bool, msg: String) raises:
    assert_true(raised, "id's RLE v2 bytes read as RLE v1 must fail")
    assert_true(
        msg.find("column 0") >= 0,
        "the failure names output column 0 (id): " + msg,
    )


def _check_good(batch: RecordBatch, label: String) raises:
    assert_equal(batch.num_rows(), _MIXED_ROWS, label)
    var ids = batch.column_as_primitive_int64(0)
    var nint = batch.column_as_primitive_int64(2)
    for r in range(_MIXED_ROWS):
        assert_equal(ids.get(r), Int64(r), label + ": id")
        assert_equal(nint.is_null(r), r % 5 == 0, label + ": nint NULL")


def test_failed_read_leaves_reader_usable() raises:
    """A read that fails in one column must not damage the next read.

    The crafted file is pyarrow_nullable_mixed.orc with one byte changed:
    `id`'s encoding says DIRECT (RLE v1) over RLE v2 bytes, so decoding `id`
    fails while label/nint/nflt decode. Before the fix, the reader's error
    path dropped its accumulator slab with the three decoded columns' slots
    already moved out (a double free), and the next read of the unchanged
    file died with SIGSEGV (exit 139). Serial decode (`read_orc_bytes`)."""
    var good = Path("orc/pyarrow_nullable_mixed.orc").read_bytes()
    var bad = _crafted_id_direct()
    var raised = False
    var msg = String()
    try:
        _ = read_orc_bytes(Span(bad))
    except e:
        raised = True
        msg = String(e)
    _check_failed(raised, msg)
    for k in range(2):
        _check_good(read_orc_bytes(Span(good)), "serial read after a failed read #" + String(k))


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def test_failed_parallel_read_leaves_reader_usable() raises:
    """The same through the column-parallel decode on a 4-worker
    LocalDispatcher (`read_orc_bytes_with_dispatcher`), whose workers take
    each column's slot out themselves."""
    var good = Path("orc/pyarrow_nullable_mixed.orc").read_bytes()
    var bad = _crafted_id_direct()
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = rt.dispatcher()
    var raised = False
    var msg = String()
    try:
        _ = read_orc_bytes_with_dispatcher[origin_of(disp)](
            Span(bad), Pointer(to=disp), CancellationToken.never()
        )
    except e:
        raised = True
        msg = String(e)
    _check_failed(raised, msg)
    for k in range(2):
        var batch = read_orc_bytes_with_dispatcher[origin_of(disp)](
            Span(good), Pointer(to=disp), CancellationToken.never()
        )
        _check_good(batch, "parallel read after a failed read #" + String(k))
    _ = rt^


def test_cancelled_parallel_read_leaves_reader_usable() raises:
    """A dispatch that raises (here: a token cancelled before the read)
    surfaces as an error and leaves the next read intact.

    Reach: the token is cancelled before dispatch, so the dispatcher
    refuses the work before anything is queued and no column task runs;
    no accumulator slot has been taken when the decode state drops. A cancel
    landing BETWEEN two column tasks (some slots taken, the state dropped)
    cannot be produced deterministically through the public API: the token
    is only cancelled from outside the decode, and the dispatcher polls it
    between tasks on worker threads. That state is the one the column-error
    tests above drop, through the same slab type."""
    var good = Path("orc/pyarrow_nullable_mixed.orc").read_bytes()
    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=4,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = rt.dispatcher()
    var tok = CancellationToken.new()
    tok.cancel("cancelled by the test")
    var raised = False
    var msg = String()
    try:
        _ = read_orc_bytes_with_dispatcher[origin_of(disp)](
            Span(good), Pointer(to=disp), tok^
        )
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "a cancelled read must raise")
    assert_true(msg.find("CancelledError") >= 0, "the error says cancelled: " + msg)
    for k in range(2):
        var batch = read_orc_bytes_with_dispatcher[origin_of(disp)](
            Span(good), Pointer(to=disp), CancellationToken.never()
        )
        _check_good(batch, "parallel read after a cancelled read #" + String(k))
    _ = rt^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
