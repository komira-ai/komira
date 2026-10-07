# =============================================================================
# test_ipc_fuzz_corpus.mojo: Apache arrow-testing's IPC fuzz regression corpus
# through every komira_arrow_ipc RecordBatch decode path.
# =============================================================================
#
# The corpus (third_party/arrow-testing, staged at `arrow-testing/data/`) is
# 80 IPC streams and 56 IPC files that once crashed or misled the Arrow C++
# reader; upstream calls them "usually invalid". komira_arrow_ipc decodes one
# message at a time and ships no whole-stream or whole-file reader, so this
# test carries one (`_read_stream`, `_read_file`). It frames each stream
# message with the library's `parse_ipc_message`, finds a file's Footer from
# the trailing magic (like Arrow C++, it does not require the leading one),
# reads Footer, Schema and Fields with the library's flatbuffer readers, and
# hands every DictionaryBatch and RecordBatch frame to the library. Its own
# refusals (a bodyLength or Block past the end, no Schema first, a Field type
# it cannot map, a dictionary id with no field) raise with the prefix
# `reader:`; every other error is the library's.
#
# Each file is read once per decode mode, each mode one product entry point:
#   flat    decode_record_batch_message (schemas of flat columns)
#   nested  decode_record_batch_message_nested (no dictionary fields)
#   dicts   decode_record_batch_message_with_dicts (flat or dictionary
#           columns at the top level)
#   mmap    decode_record_batch_message_mmap over the file mapped read-only
#           (flat, dictionary-free schemas)
# A mode that cannot express a file's schema (a big-endian Schema, a
# dictionary field inside a nested type, a nested field for a flat mode) is
# `n/a` for that file. A DictionaryBatch is decompressed by the library
# (peek_dictionary_batch_codec_from_frame, decompress_dictionary_batch_frame)
# and its data, re-framed as a RecordBatch message, decoded by
# decode_record_batch_message_nested.
#
# What each test asserts:
#   test_every_corpus_file_raises: every (mode, file) raises or is n/a, unless
#     ipc_fuzz_corpus_gate.txt lists it as ACCEPTED with a reason; the list is
#     shrink-only (a listed pair that now raises is STALE). Each NAMED entry
#     there (a file declaring a length of 1 GiB or more) raises naming that
#     length, i.e. at the check, before an allocation of that size. No file
#     grows the peak resident size by `_HWM_CEILING_KIB` or the peak virtual
#     size by `_VM_PEAK_CEILING_KIB`. The directories hold exactly the pinned
#     counts. A crash, abort or hang fails this build action outright; one
#     line per file prints as it lands, in name order, so the log ends at the
#     file before it.
#   test_decode_errors_repeat_50: the whole corpus, every mode, 50 times in
#     one process, each pass's verdicts equal to the first. An error path that
#     drops a value twice (the dictionary-slot drain on the unwind path of
#     decode_record_batch_message_with_dicts was one) corrupts the allocator
#     and crashes or changes a later verdict, which one pass can miss.
# =============================================================================

from std.io import FileHandle
from std.memory import ArcPointer
from std.os import listdir
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_buffer.mmap_region import MmapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_compression.compression_codecs import Lz4Frame, Zstd
from komira_arrow_ipc.ipc_body_compression import (
    decompress_dictionary_batch_frame,
    peek_dictionary_batch_codec_from_frame,
)
from komira_arrow_ipc.ipc_decoder_dispatch import (
    ColumnTypeSpec,
    decode_record_batch_message,
    decode_record_batch_message_mmap,
    decode_record_batch_message_nested,
    decode_record_batch_message_with_dicts,
)
from komira_arrow_ipc.ipc_flatbuf import (
    Block, DATE_UNIT_DAY, DATE_UNIT_MILLISECOND, ENDIANNESS_LITTLE,
    FlatbufReader, FlatbufWriter, FooterDescriptor, INTERVAL_UNIT_DAY_TIME,
    INTERVAL_UNIT_MONTH_DAY_NANO, INTERVAL_UNIT_YEAR_MONTH,
    MESSAGE_HEADER_DICTIONARY_BATCH, MESSAGE_HEADER_RECORD_BATCH,
    MESSAGE_HEADER_SCHEMA, MessageDescriptor, PRECISION_DOUBLE, PRECISION_HALF,
    PRECISION_SINGLE, TIME_UNIT_MICROSECOND, TIME_UNIT_MILLISECOND,
    TIME_UNIT_NANOSECOND, TIME_UNIT_SECOND, TYPE_BINARY, TYPE_BINARY_VIEW,
    TYPE_BOOL, TYPE_DATE, TYPE_DECIMAL, TYPE_DURATION, TYPE_FIXED_SIZE_BINARY,
    TYPE_FIXED_SIZE_LIST, TYPE_FLOATING_POINT, TYPE_INT, TYPE_INTERVAL,
    TYPE_LARGE_BINARY, TYPE_LARGE_LIST, TYPE_LARGE_LIST_VIEW, TYPE_LARGE_UTF8,
    TYPE_LIST, TYPE_LIST_VIEW, TYPE_MAP, TYPE_NULL, TYPE_RUN_END_ENCODED,
    TYPE_STRUCT_, TYPE_TIME, TYPE_TIMESTAMP, TYPE_UNION, TYPE_UTF8,
    TYPE_UTF8_VIEW, UNION_MODE_DENSE, UNION_MODE_SPARSE, flatbuf_reader_over,
    parse_ipc_message, read_dictionary_batch, read_field, read_footer,
    read_message, read_record_batch, read_schema, read_type_date,
    read_type_decimal, read_type_duration, read_type_fixed_size_binary,
    read_type_fixed_size_list, read_type_floating_point, read_type_int,
    read_type_interval, read_type_time, read_type_timestamp, read_type_union,
    write_message, write_record_batch,
)


# Where the test declares the extracted tree (BUCK, test_data), relative to
# the test's working directory.
comptime DATA = "arrow-testing/data/"
comptime STREAM_DIR = "arrow-ipc-stream"
comptime FILE_DIR = "arrow-ipc-file"
# The pinned corpus's size (third_party/arrow-testing/ipc_fuzz_files.bzl).
comptime STREAM_FILES = 80
comptime FILE_FILES = 56

comptime MODE_FLAT = 0
comptime MODE_NESTED = 1
comptime MODE_DICTS = 2
comptime MODE_MMAP = 3
comptime N_MODES = 4

comptime V_RAISED = 0
comptime V_NA = 1
comptime V_ACCEPTED = 2

# Arrow C++'s own bound on Field nesting.
comptime MAX_DEPTH = 64
# Largest growth of the peak resident size (VmHWM) and of the peak virtual
# size (VmPeak) one file may cause. Every corpus file is under 64 KiB, so a
# decode that allocates what a file declares before checking it against the
# bytes present shows here: touched, as resident growth; untouched, as
# virtual growth. The virtual bound sits above the 1 GiB hunks in which the
# allocator reserves address space (one such step is seen on this corpus).
comptime _HWM_CEILING_KIB = 262144
comptime _VM_PEAK_CEILING_KIB = 4194304
comptime _PASSES = 50


# The reviewed accepted files and declared-size refusals (BUCK, test_data).
comptime GATE = "ipc_fuzz_corpus_gate.txt"


def _gate_lines(kind: String) raises -> List[String]:
    """The entries of GATE that start with `kind` and a space, without it."""
    var out = List[String]()
    with open(GATE, "r") as f:
        for line in f.read().split("\n"):
            if line.startswith(kind + " "):
                out.append(String(line[byte=kind.byte_length() + 1 :]))
    return out^


def _mode_name(mode: Int) -> String:
    if mode == MODE_FLAT:
        return "flat"
    if mode == MODE_NESTED:
        return "nested"
    if mode == MODE_DICTS:
        return "dicts"
    return "mmap"


# ---------------------------------------------------------------------------
# Bytes
# ---------------------------------------------------------------------------


def _load(path: String) raises -> SharedAlignedBuffer[HeapRegion]:
    var f = FileHandle(path, "r")
    _ = f.seek(0, 2)
    var n = Int(f.seek(0, 1))
    _ = f.seek(0, 0)
    var raw = f.read_bytes(n)
    f.close()
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(n, 1))
    out.copy_from_bytes_list(raw)
    return out^


def _slice(
    src: SharedAlignedBuffer[HeapRegion], start: Int, n: Int
) raises -> SharedAlignedBuffer[HeapRegion]:
    """A copy of `src[start, start + n)`; `reader:` error when it is not
    inside `src`."""
    if start < 0 or n < 0 or start > src.len() or n > src.len() - start:
        raise Error(
            "reader: bytes [" + String(start) + ", +" + String(n)
            + ") lie outside the " + String(src.len()) + " present"
        )
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(n, 1))
    if n > 0:
        out.copy_from_view_at(0, src.view_range_ro(start, n))
    out.set_length(n)
    return out^


def _message(md: SharedAlignedBuffer[HeapRegion]) raises -> MessageDescriptor:
    var r = flatbuf_reader_over(md)
    return read_message(r, r.read_root_offset())


# ---------------------------------------------------------------------------
# Schema: Field tables to the decoders' column types
# ---------------------------------------------------------------------------


def _slot[
    bo: Origin[mut=False]
](r: FlatbufReader[bo], table_pos: Int, field_id: Int) raises -> Int:
    """The target of offset field `field_id` of the table at `table_pos`, or
    -1 when absent (every read bounds-checked by the reader)."""
    var vt = table_pos - Int(r.read_i32_le(table_pos))
    if vt < 0:
        raise Error("reader: vtable position " + String(vt) + " is negative")
    var vt_size = Int(r.read_u16_le(vt))
    var slot = 4 + field_id * 2
    if slot + 2 > vt_size:
        return -1
    var inl = Int(r.read_u16_le(vt + slot))
    if inl == 0:
        return -1
    return r.read_offset_u32(table_pos + inl)


def _tables[
    bo: Origin[mut=False]
](r: FlatbufReader[bo], vec_pos: Int) raises -> List[Int]:
    """The table positions of a vector of tables (empty when absent)."""
    var out = List[Int]()
    if vec_pos < 0:
        return out^
    var n = Int(r.read_u32_le(vec_pos))
    if n > (r.length() - vec_pos - 4) // 4:
        raise Error(
            "reader: a vector of " + String(n) + " offsets at "
            + String(vec_pos) + " runs past the metadata"
        )
    for i in range(n):
        out.append(r.read_offset_u32(vec_pos + 4 + 4 * i))
    return out^


def _unit_type(u: UInt8, units: List[UInt8], types: List[ArrowType], what: String) raises -> ArrowType:
    for i in range(len(units)):
        if u == units[i]:
            return types[i]
    raise Error("reader: " + what + " " + String(Int(u)))


def _leaf_type[
    bo: Origin[mut=False]
](r: FlatbufReader[bo], tag: UInt8, tp: Int) raises -> ArrowType:
    """The ArrowType of a leaf Field type, from its Type table."""
    var plain: List[UInt8] = [
        TYPE_NULL, TYPE_BOOL, TYPE_BINARY, TYPE_UTF8, TYPE_LARGE_BINARY,
        TYPE_LARGE_UTF8, TYPE_BINARY_VIEW, TYPE_UTF8_VIEW,
    ]
    var plain_types: List[ArrowType] = [
        ArrowType.NULL, ArrowType.BOOL, ArrowType.BINARY, ArrowType.STRING,
        ArrowType.LARGE_BINARY, ArrowType.LARGE_STRING, ArrowType.BINARY_VIEW,
        ArrowType.UTF8_VIEW,
    ]
    for i in range(len(plain)):
        if tag == plain[i]:
            return plain_types[i]
    var time_units: List[UInt8] = [
        TIME_UNIT_SECOND, TIME_UNIT_MILLISECOND, TIME_UNIT_MICROSECOND,
        TIME_UNIT_NANOSECOND,
    ]
    if tag == TYPE_INT:
        var d = read_type_int(r, tp)
        var w: List[UInt8] = [8, 16, 32, 64]
        var signed: List[ArrowType] = [ArrowType.INT8, ArrowType.INT16, ArrowType.INT32, ArrowType.INT64]
        var unsigned: List[ArrowType] = [ArrowType.UINT8, ArrowType.UINT16, ArrowType.UINT32, ArrowType.UINT64]
        if d.bit_width < 0 or d.bit_width > 255:
            raise Error("reader: Int bitWidth " + String(d.bit_width))
        return _unit_type(UInt8(d.bit_width), w, signed if d.is_signed else unsigned, "Int bitWidth")
    if tag == TYPE_FLOATING_POINT:
        var p: List[UInt8] = [PRECISION_HALF, PRECISION_SINGLE, PRECISION_DOUBLE]
        var t: List[ArrowType] = [ArrowType.FLOAT16, ArrowType.FLOAT32, ArrowType.FLOAT64]
        return _unit_type(read_type_floating_point(r, tp).precision, p, t, "FloatingPoint precision")
    if tag == TYPE_DECIMAL:
        var d = read_type_decimal(r, tp)
        if d.bit_width != 128 and d.bit_width != 256:
            raise Error("n/a: Decimal bitWidth " + String(d.bit_width))
        # Arrow C++ and arrow-rs refuse a precision outside 1..38 (128-bit)
        # or 1..76 (256-bit).
        var most = 38 if d.bit_width == 128 else 76
        if d.precision < 1 or d.precision > most:
            raise Error("reader: Decimal precision " + String(d.precision))
        return ArrowType.DECIMAL128 if d.bit_width == 128 else ArrowType.DECIMAL256
    if tag == TYPE_DATE:
        var u: List[UInt8] = [DATE_UNIT_DAY, DATE_UNIT_MILLISECOND]
        var t: List[ArrowType] = [ArrowType.DATE32, ArrowType.DATE64]
        return _unit_type(read_type_date(r, tp).unit, u, t, "Date unit")
    if tag == TYPE_TIME:
        var d = read_type_time(r, tp)
        var t: List[ArrowType] = [ArrowType.TIME32_S, ArrowType.TIME32_MS, ArrowType.TIME64_US, ArrowType.TIME64_NS]
        var got = _unit_type(d.unit, time_units, t, "Time unit")
        var w = 32 if d.unit == TIME_UNIT_SECOND or d.unit == TIME_UNIT_MILLISECOND else 64
        if d.bit_width != w:
            raise Error("reader: Time bitWidth " + String(d.bit_width) + " for unit " + String(Int(d.unit)))
        return got
    if tag == TYPE_TIMESTAMP:
        var t: List[ArrowType] = [ArrowType.TIMESTAMP_S, ArrowType.TIMESTAMP_MS, ArrowType.TIMESTAMP_US, ArrowType.TIMESTAMP_NS]
        return _unit_type(read_type_timestamp(r, tp).unit, time_units, t, "Timestamp unit")
    if tag == TYPE_DURATION:
        var t: List[ArrowType] = [ArrowType.DURATION_S, ArrowType.DURATION_MS, ArrowType.DURATION_US, ArrowType.DURATION_NS]
        return _unit_type(read_type_duration(r, tp).unit, time_units, t, "Duration unit")
    if tag == TYPE_INTERVAL:
        var u: List[UInt8] = [INTERVAL_UNIT_YEAR_MONTH, INTERVAL_UNIT_DAY_TIME, INTERVAL_UNIT_MONTH_DAY_NANO]
        var t: List[ArrowType] = [ArrowType.INTERVAL_YEAR_MONTH, ArrowType.INTERVAL_DAY_TIME, ArrowType.INTERVAL_MONTH_DAY_NANO]
        return _unit_type(read_type_interval(r, tp).unit, u, t, "Interval unit")
    if tag == TYPE_RUN_END_ENCODED:
        raise Error("n/a: RunEndEncoded has no komira column type")
    raise Error("reader: Field type tag " + String(Int(tag)))


def _with_children(
    t: ArrowType, var kids: Slab[ColumnTypeSpec], var type_ids: List[Int]
) -> ColumnTypeSpec:
    return ColumnTypeSpec(
        arrow_type=t,
        children=kids^,
        field_names=List[String](),
        type_ids=type_ids^,
        inner_size=0,
    )


def _spec[
    bo: Origin[mut=False]
](r: FlatbufReader[bo], field_pos: Int, depth: Int) raises -> ColumnTypeSpec:
    """The decoder's column type for the Field table at `field_pos` (for a
    dictionary-encoded field, its value type)."""
    if depth > MAX_DEPTH:
        raise Error("reader: Fields nest deeper than " + String(MAX_DEPTH))
    var fd = read_field(r, field_pos)
    if fd.dictionary_encoding and depth > 0:
        raise Error("n/a: a dictionary-encoded field inside a nested type")
    var kids = _tables(r, _slot(r, field_pos, 5))
    var tag = fd.type_tag
    var tp = fd.type_table_pos
    if (
        tag == TYPE_LIST
        or tag == TYPE_LARGE_LIST
        or tag == TYPE_FIXED_SIZE_LIST
        or tag == TYPE_MAP
        or tag == TYPE_LIST_VIEW
        or tag == TYPE_LARGE_LIST_VIEW
    ):
        if len(kids) != 1:
            raise Error(
                "reader: type tag " + String(Int(tag)) + " with "
                + String(len(kids)) + " children (one required)"
            )
        var inner = _spec(r, kids[0], depth + 1)
        if tag == TYPE_LIST:
            return ColumnTypeSpec.list_of(inner^)
        if tag == TYPE_LARGE_LIST:
            return ColumnTypeSpec.large_list_of(inner^)
        if tag == TYPE_MAP:
            return ColumnTypeSpec.map_of(inner^)
        if tag == TYPE_FIXED_SIZE_LIST:
            var n = read_type_fixed_size_list(r, tp).list_size
            if n <= 0:
                raise Error("reader: FixedSizeList listSize " + String(n))
            return ColumnTypeSpec.fixed_size_list_of(inner^, n)
        var one = Slab[ColumnTypeSpec]()
        one.append(inner^)
        var t = ArrowType.LIST_VIEW if tag == TYPE_LIST_VIEW else ArrowType.LARGE_LIST_VIEW
        return _with_children(t, one^, List[Int]())
    if tag == TYPE_STRUCT_:
        var ch = Slab[ColumnTypeSpec]()
        var names = List[String]()
        for k in kids:
            names.append(read_field(r, k).name)
            ch.append(_spec(r, k, depth + 1))
        return ColumnTypeSpec.struct_of(ch^, names^)
    if tag == TYPE_UNION:
        var u = read_type_union(r, tp)
        var ids = List[Int]()
        if len(u.type_ids) == 0:
            for i in range(len(kids)):
                ids.append(i)
        elif len(u.type_ids) != len(kids):
            raise Error(
                "reader: Union with " + String(len(u.type_ids))
                + " typeIds and " + String(len(kids)) + " children"
            )
        else:
            for i in range(len(u.type_ids)):
                ids.append(Int(u.type_ids[i]))
        var t: ArrowType
        if u.mode == UNION_MODE_SPARSE:
            t = ArrowType.UNION_SPARSE
        elif u.mode == UNION_MODE_DENSE:
            t = ArrowType.UNION_DENSE
        else:
            raise Error("reader: Union mode " + String(Int(u.mode)))
        var ch = Slab[ColumnTypeSpec]()
        for k in kids:
            ch.append(_spec(r, k, depth + 1))
        return _with_children(t, ch^, ids^)
    if tag == TYPE_FIXED_SIZE_BINARY:
        var w = read_type_fixed_size_binary(r, tp).byte_width
        if w <= 0:
            raise Error("reader: FixedSizeBinary byteWidth " + String(w))
        return ColumnTypeSpec.fixed_size_binary(w)
    return ColumnTypeSpec.leaf(_leaf_type(r, tag, tp))


def _takes_flat(spec: ColumnTypeSpec) -> Bool:
    """Whether the flat decoders take a column of this type: every leaf type
    `_leaf_type` maps to except the view types."""
    var t = spec.arrow_type
    if len(spec.children) > 0 or t == ArrowType.BINARY_VIEW or t == ArrowType.UTF8_VIEW:
        return False
    return not (
        t == ArrowType.FIXED_SIZE_BINARY or t == ArrowType.STRUCT
        or t == ArrowType.UNION_SPARSE or t == ArrowType.UNION_DENSE
    )


@fieldwise_init
struct _Top(Copyable, Movable):
    """One top-level field, as the modes need it."""
    var field_pos: Int
    var arrow_type: ArrowType
    var flat: Bool
    var is_dict: Bool
    var dict_id: Int64
    var index_width: Int


struct _Schema(Movable):
    """A Schema table and the metadata bytes it lies in."""
    var md: SharedAlignedBuffer[HeapRegion]
    var tops: List[_Top]

    def __init__(out self, var md: SharedAlignedBuffer[HeapRegion], schema_pos: Int) raises:
        var tops = List[_Top]()
        var r = flatbuf_reader_over(md)
        var sd = read_schema(r, schema_pos)
        if sd.endianness != ENDIANNESS_LITTLE:
            raise Error("n/a: a big-endian Schema (komira decodes little-endian)")
        for p in _tables(r, _slot(r, schema_pos, 1)):
            var spec = _spec(r, p, 0)
            var fd = read_field(r, p)
            var is_dict = Bool(fd.dictionary_encoding)
            var id = Int64(0)
            var width = 32
            if is_dict:
                id = fd.dictionary_encoding.value().id
                width = fd.dictionary_encoding.value().index_type_bit_width
            tops.append(
                _Top(
                    field_pos=p,
                    arrow_type=spec.arrow_type,
                    flat=_takes_flat(spec),
                    is_dict=is_dict,
                    dict_id=id,
                    index_width=width,
                )
            )
        self.md = md^
        self.tops = tops^

    def specs(self) raises -> Slab[ColumnTypeSpec]:
        var out = Slab[ColumnTypeSpec]()
        var r = flatbuf_reader_over(self.md)
        for t in self.tops:
            out.append(_spec(r, t.field_pos, 0))
        return out^

    def spec_of(self, i: Int) raises -> ColumnTypeSpec:
        var r = flatbuf_reader_over(self.md)
        return _spec(r, self.tops[i].field_pos, 0)

    def check_mode(self, mode: Int) raises:
        """Raises `n/a:` when `mode` cannot express this schema."""
        for i in range(len(self.tops)):
            ref t = self.tops[i]
            if t.is_dict and mode != MODE_DICTS:
                raise Error("n/a: field " + String(i) + " is dictionary-encoded")
            if mode != MODE_NESTED and not t.is_dict and not t.flat:
                raise Error(
                    "n/a: field " + String(i) + " (type "
                    + String(Int(t.arrow_type.type_id)) + ") is not flat"
                )

    def types(self) -> List[ArrowType]:
        var out = List[ArrowType]()
        for t in self.tops:
            out.append(ArrowType.STRING if t.is_dict else t.arrow_type)
        return out^


# ---------------------------------------------------------------------------
# Dictionaries
# ---------------------------------------------------------------------------


struct _Dicts(Movable):
    """Decoded dictionaries by id; a later replacement shadows an earlier
    one."""
    var ids: List[Int64]
    var cols: Slab[Column[HeapRegion]]

    def __init__(out self):
        self.ids = List[Int64]()
        self.cols = Slab[Column[HeapRegion]]()

    def find(self, id: Int64) -> Int:
        var at = -1
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                at = i
        return at


def _reframe_as_record_batch(
    plain: SharedAlignedBuffer[HeapRegion],
) raises -> SharedAlignedBuffer[HeapRegion]:
    """The DictionaryBatch frame `plain` (uncompressed) as a RecordBatch
    frame over the same body: its data RecordBatch's length, nodes and
    buffers, written by the library's writers."""
    var f = parse_ipc_message(plain)
    var md = _slice(plain, f.metadata_pos, f.metadata_size)
    var r = flatbuf_reader_over(md)
    var msg = read_message(r, r.read_root_offset())
    var db = read_dictionary_batch(r, msg.header_table_pos)
    var rb = read_record_batch(r, db.data_table_pos)
    var body = plain.len() - f.body_pos
    var w = FlatbufWriter(4 * f.metadata_size + 4096)
    var rb_pos = write_record_batch(w, rb.length, rb.nodes, rb.buffers)
    var msg_pos = write_message(
        w, Int16(4), MESSAGE_HEADER_RECORD_BATCH, rb_pos, Int64(body)
    )
    var fb = w^.finalize(msg_pos)
    var fb_size = fb.len()
    var fb_al = ((fb_size + 7) // 8) * 8
    var total = 8 + fb_al + body
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(total, 1))
    out.write_u32_le_at(0, UInt32(0xFFFFFFFF))
    out.write_u32_le_at(4, UInt32(fb_al))
    out.copy_from_aligned_buffer_at(8, fb, 0, fb_size)
    for i in range(fb_size, fb_al):
        out.write_u8_at(8 + i, UInt8(0))
    if body > 0:
        out.copy_from_aligned_buffer_at(8 + fb_al, plain, f.body_pos, body)
    out.set_length(total)
    return out^


def _decode_dictionary(
    s: _Schema, mut d: _Dicts, var frame: SharedAlignedBuffer[HeapRegion]
) raises:
    var codec = peek_dictionary_batch_codec_from_frame(frame)
    var plain: SharedAlignedBuffer[HeapRegion]
    if codec == Int8(-1):
        plain = frame^
    elif codec == Int8(0):
        plain = decompress_dictionary_batch_frame[Lz4Frame](frame^)
    elif codec == Int8(1):
        plain = decompress_dictionary_batch_frame[Zstd[3]](frame^)
    else:
        raise Error("reader: BodyCompression codec " + String(Int(codec)))
    var f = parse_ipc_message(plain)
    var md = _slice(plain, f.metadata_pos, f.metadata_size)
    var r = flatbuf_reader_over(md)
    var msg = read_message(r, r.read_root_offset())
    var db = read_dictionary_batch(r, msg.header_table_pos)
    var k = -1
    for i in range(len(s.tops)):
        if s.tops[i].is_dict and s.tops[i].dict_id == db.id:
            k = i
    if k < 0:
        raise Error(
            "reader: DictionaryBatch id " + String(db.id)
            + " names no dictionary field"
        )
    if db.is_delta:
        if d.find(db.id) < 0:
            raise Error("reader: delta DictionaryBatch before any for its id")
        raise Error("n/a: delta DictionaryBatch (this reader replaces only)")
    var specs = Slab[ColumnTypeSpec]()
    specs.append(s.spec_of(k))
    var cols = decode_record_batch_message_nested(
        _reframe_as_record_batch(plain), specs^
    )
    if len(cols) != 1:
        raise Error("reader: dictionary decoded to " + String(len(cols)) + " columns")
    d.ids.append(db.id)
    d.cols.append(cols.take_at(0))


# ---------------------------------------------------------------------------
# RecordBatches, per mode
# ---------------------------------------------------------------------------


def _decode_batch(
    mode: Int,
    s: _Schema,
    d: _Dicts,
    var frame: SharedAlignedBuffer[HeapRegion],
    path: String,
    abs_offset: Int,
) raises:
    if mode == MODE_FLAT:
        _ = decode_record_batch_message(frame^, s.types())
    elif mode == MODE_NESTED:
        _ = decode_record_batch_message_nested(frame^, s.specs())
    elif mode == MODE_MMAP:
        var region = ArcPointer[MmapRegion](MmapRegion.open_readonly(path))
        _ = decode_record_batch_message_mmap(frame^, s.types(), region, abs_offset)
    else:
        var is_dict = List[Bool]()
        var widths = List[Int]()
        var values = Slab[Column[HeapRegion]]()
        for t in s.tops:
            is_dict.append(t.is_dict)
            widths.append(t.index_width)
            if t.is_dict:
                var at = d.find(t.dict_id)
                if at < 0:
                    raise Error(
                        "reader: no DictionaryBatch for id " + String(t.dict_id)
                    )
                values.append(d.cols[at].deep_copy())
            else:
                values.append(Column[HeapRegion]())
        _ = decode_record_batch_message_with_dicts(
            frame^, s.types(), is_dict, values^, widths
        )


# ---------------------------------------------------------------------------
# The stream and file readers
# ---------------------------------------------------------------------------


@fieldwise_init
struct _Span(Copyable, Movable):
    var offset: Int
    var length: Int
    var tag: UInt8


def _walk_stream(buf: SharedAlignedBuffer[HeapRegion]) raises -> List[_Span]:
    """Every encapsulated message up to the end-of-stream marker or the end
    of the bytes (both end a stream). Each message's prefix and metadata
    length are the library's to check (`parse_ipc_message`, over the rest
    of the stream); its bodyLength is this reader's."""
    var out = List[_Span]()
    var n = buf.len()
    var pos = 0
    while pos < n:
        if n - pos == 4 and buf.read_u32_le_at(pos) == 0:
            break  # the pre-0.15 end-of-stream marker
        var rest = _slice(buf, pos, n - pos)
        var f = parse_ipc_message(rest)
        if f.metadata_size == 0:
            break
        var msg = _message(_slice(rest, f.metadata_pos, f.metadata_size))
        var body = Int(msg.body_length)
        if body < 0 or body > f.body_size:
            raise Error(
                "reader: bodyLength " + String(body) + " at " + String(pos)
                + " runs past the end"
            )
        out.append(_Span(offset=pos, length=f.body_pos + body, tag=msg.header_tag))
        pos += f.body_pos + body
    return out^


def _read_stream(mode: Int, path: String, buf: SharedAlignedBuffer[HeapRegion]) raises -> Int:
    """Decode a stream in `mode`; returns the RecordBatches decoded."""
    var spans = _walk_stream(buf)
    if len(spans) == 0 or spans[0].tag != MESSAGE_HEADER_SCHEMA:
        raise Error("reader: the stream does not start with a Schema message")
    var sframe = _slice(buf, spans[0].offset, spans[0].length)
    var f = parse_ipc_message(sframe)
    var md = _slice(sframe, f.metadata_pos, f.metadata_size)
    var pos = _message(md).header_table_pos
    var s = _Schema(md^, pos)
    s.check_mode(mode)
    var d = _Dicts()
    var batches = 0
    for i in range(1, len(spans)):
        ref sp = spans[i]
        var frame = _slice(buf, sp.offset, sp.length)
        if sp.tag == MESSAGE_HEADER_DICTIONARY_BATCH:
            _decode_dictionary(s, d, frame^)
        elif sp.tag == MESSAGE_HEADER_RECORD_BATCH:
            _decode_batch(mode, s, d, frame^, path, sp.offset)
            batches += 1
        else:
            raise Error("reader: message type " + String(Int(sp.tag)) + " after the Schema")
    return batches


def _footer(fmd: SharedAlignedBuffer[HeapRegion]) raises -> FooterDescriptor:
    var r = flatbuf_reader_over(fmd)
    return read_footer(r, r.read_root_offset())


def _block(
    buf: SharedAlignedBuffer[HeapRegion], b: Block, limit: Int
) raises -> SharedAlignedBuffer[HeapRegion]:
    """The message a Footer Block names; `reader:` error unless it lies
    before the footer."""
    var off = Int(b.offset)
    var ml = Int(b.meta_data_length)
    var bl = Int(b.body_length)
    if off < 0 or ml <= 0 or bl < 0 or off > limit or ml > limit - off or bl > limit - off - ml:
        raise Error(
            "reader: Block (offset " + String(off) + ", metaDataLength "
            + String(ml) + ", bodyLength " + String(bl)
            + ") lies outside the file's " + String(limit) + " data bytes"
        )
    return _slice(buf, off, ml + bl)


def _read_file(mode: Int, path: String, buf: SharedAlignedBuffer[HeapRegion]) raises -> Int:
    """Decode a file in `mode` from its Footer; returns the RecordBatches
    decoded."""
    var n = buf.len()
    if n < 18:
        raise Error("reader: " + String(n) + " bytes cannot hold two magics and a footer")
    # Only the trailing magic is required, as Arrow C++ requires it: the
    # Footer is found from the end, and a file whose leading magic is
    # damaged still reaches the library's Footer, Schema and batch readers.
    var magic: List[UInt8] = [0x41, 0x52, 0x52, 0x4F, 0x57, 0x31]
    for i in range(6):
        if buf.read_u8_at(n - 6 + i) != magic[i]:
            raise Error("reader: the trailing ARROW1 magic is missing")
    var flen = Int(buf.read_i32_le_at(n - 10))
    if flen <= 0 or flen > n - 18:
        raise Error("reader: footer length " + String(flen) + " in a file of " + String(n))
    var fmd = _slice(buf, n - 10 - flen, flen)
    var foot = _footer(fmd)
    var s = _Schema(fmd^, foot.schema_table_pos)
    s.check_mode(mode)
    var limit = n - 10 - flen
    var d = _Dicts()
    for b in foot.dictionaries:
        _decode_dictionary(s, d, _block(buf, b, limit))
    var batches = 0
    for b in foot.record_batches:
        _decode_batch(mode, s, d, _block(buf, b, limit), path, Int(b.offset))
        batches += 1
    return batches


# ---------------------------------------------------------------------------
# Verdicts and the gate
# ---------------------------------------------------------------------------


@fieldwise_init
struct _Verdict(Copyable, Movable):
    var name: String
    var mode: Int
    var code: Int
    var detail: String

    def key(self) -> String:
        return _mode_name(self.mode) + " " + self.name

    def describe(self) -> String:
        var c = "RAISED"
        if self.code == V_NA:
            c = "N/A"
        elif self.code == V_ACCEPTED:
            c = "ACCEPTED"
        var d = self.detail
        if len(d.codepoints()) > 160:
            d = String(d[codepoint=0:160]) + "..."
        return self.key() + " " + c + ": " + d


def _run(mode: Int, rel: String, buf: SharedAlignedBuffer[HeapRegion]) -> _Verdict:
    var path = String(DATA) + rel
    try:
        var n: Int
        if rel.startswith(STREAM_DIR):
            n = _read_stream(mode, path, buf)
        else:
            n = _read_file(mode, path, buf)
        return _Verdict(name=rel, mode=mode, code=V_ACCEPTED, detail=String(n) + " RecordBatches decoded")
    except e:
        var msg = String(e)
        var code = V_NA if msg.startswith("n/a:") else V_RAISED
        return _Verdict(name=rel, mode=mode, code=code, detail=msg^)


def _sorted(var names: List[String]) -> List[String]:
    for i in range(1, len(names)):
        var j = i
        while j > 0 and names[j] < names[j - 1]:
            names.swap_elements(j, j - 1)
            j -= 1
    return names^


def _corpus() raises -> List[String]:
    """Every corpus file as `<dir>/<name>`, by directory then name; raises
    unless the directories hold exactly the pinned counts."""
    var out = List[String]()
    var dirs: List[String] = [String(FILE_DIR), String(STREAM_DIR)]
    var want: List[Int] = [FILE_FILES, STREAM_FILES]
    for k in range(2):
        var names = List[String]()
        for n in listdir(String(DATA) + dirs[k]):
            names.append(String(n))
        if len(names) != want[k]:
            raise Error(
                dirs[k] + " holds " + String(len(names)) + " files; the pin has "
                + String(want[k])
            )
        for n in _sorted(names^):
            out.append(dirs[k] + "/" + n)
    return out^


def _kib(text: String, key: String) raises -> Int:
    """The `<key> <n> kB` value of a /proc/self/status text."""
    var i = text.find(key)
    if i < 0:
        raise Error("/proc/self/status has no " + key)
    var b = text.as_bytes()
    var j = i + key.byte_length()
    while j < len(b) and (b[j] == 32 or b[j] == 9):
        j += 1
    var v = 0
    while j < len(b) and b[j] >= 48 and b[j] <= 57:
        v = v * 10 + Int(b[j] - 48)
        j += 1
    return v


def _vm_kib(key: String) raises -> Int:
    with open("/proc/self/status", "r") as f:
        return _kib(f.read(), key)


def _letter(v: _Verdict) -> String:
    if v.code == V_NA:
        return "-"
    if v.code == V_ACCEPTED:
        return "A"
    return "r" if v.detail.startswith("reader:") else "R"


def _load_corpus(names: List[String]) raises -> Slab[SharedAlignedBuffer[HeapRegion]]:
    """Every file's bytes, read once (opening a file on a build worker is
    slow next to decoding it)."""
    var out = Slab[SharedAlignedBuffer[HeapRegion]]()
    for rel in names:
        out.append(_load(String(DATA) + rel))
    return out^


def _run_corpus(
    names: List[String], bufs: Slab[SharedAlignedBuffer[HeapRegion]], loud: Bool
) raises -> List[_Verdict]:
    """Every mode over every file. With `loud`: one line per file as it
    lands (a letter per mode in the order flat, nested, dicts, mmap; then the
    first verdict that is not n/a; R the library raised, r this test's
    reader, - n/a, A accepted), its VmPeak and VmHWM growth when 1 MiB or
    more, and both ceilings enforced per file."""
    var out = List[_Verdict]()
    var base = _vm_kib("VmPeak:")
    var base_hwm = _vm_kib("VmHWM:")
    for k in range(len(names)):
        ref rel = names[k]
        ref buf = bufs[k]
        var before = _vm_kib("VmPeak:") if loud else 0
        var before_hwm = _vm_kib("VmHWM:") if loud else 0
        var letters = String("")
        var shown = -1
        for m in range(N_MODES):
            var v = _run(m, rel, buf)
            letters += _letter(v)
            if shown < 0 and v.code != V_NA:
                shown = len(out)
            out.append(v^)
        if not loud:
            continue
        var grew = _vm_kib("VmPeak:") - before
        var grew_hwm = _vm_kib("VmHWM:") - before_hwm
        var line = letters + " " + rel
        if grew >= 1024:
            line += " [VmPeak +" + String(grew // 1024) + " MiB]"
        if grew_hwm >= 1024:
            line += " [VmHWM +" + String(grew_hwm // 1024) + " MiB]"
        if shown < 0:
            shown = len(out) - 1
        var d = out[shown].detail
        if len(d.codepoints()) > 110:
            d = String(d[codepoint=0:110]) + "..."
        print(line + ": " + d, flush=True)
        if grew >= _VM_PEAK_CEILING_KIB or grew_hwm >= _HWM_CEILING_KIB:
            raise Error(
                rel + " grew VmPeak by " + String(grew) + " KiB and VmHWM by "
                + String(grew_hwm) + " KiB (ceilings "
                + String(_VM_PEAK_CEILING_KIB) + ", "
                + String(_HWM_CEILING_KIB) + ")"
            )
    if loud:
        print(
            "VmPeak", base, "->", _vm_kib("VmPeak:"), "KiB; VmHWM", base_hwm,
            "->", _vm_kib("VmHWM:"), "KiB", flush=True,
        )
    return out^


def _gate(verdicts: List[_Verdict]) raises -> List[String]:
    var problems = List[String]()
    var listed = _gate_lines("ACCEPTED")
    var used = List[Bool]()
    for _ in range(len(listed)):
        used.append(False)
    for v in verdicts:
        var at = -1
        for i in range(len(listed)):
            if listed[i].startswith(v.key() + ":"):
                at = i
        if at >= 0:
            used[at] = True
            if v.code != V_ACCEPTED:
                problems.append("STALE: " + listed[at] + " -- now " + v.describe())
        elif v.code == V_ACCEPTED:
            problems.append("ACCEPTED (not listed): " + v.describe())
    for i in range(len(listed)):
        if not used[i]:
            problems.append("UNKNOWN entry: " + listed[i])
    for ref n in _gate_lines("NAMED"):
        var bar = n.find("|")
        var key = String(n[byte=0:bar])
        var text = String(n[byte=bar + 1 :])
        var found = False
        for v in verdicts:
            if v.key() == key:
                found = True
                if v.code != V_RAISED or v.detail.find(text) < 0:
                    problems.append("SIZE NOT NAMED: " + key + " must raise naming `" + text + "`, now " + v.describe())
        if not found:
            problems.append("UNKNOWN size entry: " + key)
    return problems^


def test_every_corpus_file_raises() raises:
    var names = _corpus()
    assert_equal(len(names), STREAM_FILES + FILE_FILES)
    var verdicts = _run_corpus(names, _load_corpus(names), True)
    var counts: List[Int] = [0, 0, 0]
    var by_reader = 0
    for v in verdicts:
        counts[v.code] += 1
        if v.code == V_RAISED and v.detail.startswith("reader:"):
            by_reader += 1
    print(
        len(names), "files x", N_MODES, "modes:", counts[V_RAISED], "RAISED (",
        by_reader, "by the test's reader,", counts[V_RAISED] - by_reader,
        "by komira_arrow_ipc ),", counts[V_NA], "N/A,", counts[V_ACCEPTED],
        "ACCEPTED", flush=True,
    )
    var problems = _gate(verdicts)
    if len(problems) > 0:
        var text = String(len(problems)) + " corpus problems:"
        for p in problems:
            text += "\n  " + p
        raise Error(text)


def test_decode_errors_repeat_50() raises:
    var names = _corpus()
    var bufs = _load_corpus(names)
    var first = _run_corpus(names, bufs, False)
    for p in range(1, _PASSES):
        var again = _run_corpus(names, bufs, False)
        assert_equal(len(again), len(first))
        for i in range(len(first)):
            if again[i].code != first[i].code or again[i].detail != first[i].detail:
                raise Error(
                    "pass " + String(p) + " changed a verdict: was "
                    + first[i].describe() + "; now " + again[i].describe()
                )
    print(_PASSES, "passes over", len(names), "files x", N_MODES, "modes, verdicts stable", flush=True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
