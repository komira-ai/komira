# =============================================================================
# test_ipc_body_compression_dispatch.mojo: the dispatcher-aware compress and
# decompress entry points, run through an inline dispatcher
# =============================================================================
#
# Every `*_with_dispatcher` entry hands its per-buffer work to
# `D.run_with_state` once a message has at least four non-empty buffers.
# `InlineDispatch` (below) is a ParallelDispatch that runs the n tasks one
# after another on the calling thread, task ids 0..n-1, as the real
# dispatcher's contract gives them; so the State/Task code of every
# parallel arm runs here, deterministically. The oracle is the serial
# entry: the bytes a dispatcher-aware call produces must equal the bytes
# its serial sibling produces for the same input, and the decoded values
# must be the input's. A stride or slot bug in a Task (a buffer skipped,
# written twice or at another buffer's offset) changes the bytes.
#
# Also here: the entries' refusals of zero columns, columns of different
# lengths and a non-STRING dictionary, and an empty frame list.
# =============================================================================

from std.memory import Pointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_compression.compression_codecs import Lz4Frame, Zstd
from komira_async_api.parallel_dispatch import ParallelDispatch
from komira_async_api.token import CancellationToken
from komira_async_api.worker_pool_traits import KeepAlive, Segment
from komira_arrow_ipc.ipc_body_compression import (
    decompress_all_rbs_into_with_dispatcher,
    decompress_dictionary_batch_frame,
    decompress_dictionary_batch_frame_with_dispatcher,
    decompress_record_batch_frame,
    decompress_record_batch_frame_with_dispatcher,
    encode_dictionary_batch_message_from_string_column_compressed,
    encode_dictionary_batch_message_from_string_column_compressed_with_dispatcher,
    encode_record_batch_message_compressed,
    encode_record_batch_message_compressed_with_dispatcher,
)
from komira_arrow_ipc.ipc_decoder_dispatch import (
    ColumnTypeSpec,
    decode_record_batch_message_nested_with_dispatcher,
    decode_record_batch_message_with_dicts_with_dispatcher,
    decode_record_batch_message_with_dispatcher,
)


struct InlineDispatch(ParallelDispatch, Movable, Deinitable):
    """Runs the n tasks of a dispatch in order on the calling thread."""

    var dispatches: Int

    def __init__(out self):
        self.dispatches = 0

    def run_with_state[State: KeepAlive, T: Segment](
        mut self,
        mut state: State,
        var seg: T,
        n: Int,
        var cancel_token: CancellationToken,
        site_id: UInt32 = UInt32(0),
    ) raises -> T:
        _ = cancel_token^
        self.dispatches += 1
        for t in range(n):
            seg.execute[State](state, Int32(0), Int64(t))
        return seg^

    def worker_count(self) -> Int:
        return 4


# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

comptime ROWS = 200


def _int_col(seed: Int) -> Column[HeapRegion]:
    var vals = List[Int64]()
    for i in range(ROWS):
        vals.append(Int64((i * seed) % 7 + seed))
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(vals)
    )


def _str_col() raises -> Column[HeapRegion]:
    var vals = List[String]()
    for i in range(ROWS):
        vals.append(String("v") + String(i % 5))
    return Column.from_string(StringArray.from_strings(vals))


def _columns() raises -> Slab[Column[HeapRegion]]:
    """Four INT64 columns and a STRING one: seven non-empty buffers."""
    var cols = Slab[Column[HeapRegion]]()
    for s in range(1, 5):
        cols.append(_int_col(s))
    cols.append(_str_col())
    return cols^


def _types() -> List[ArrowType]:
    var t = List[ArrowType]()
    for _ in range(4):
        t.append(ArrowType.INT64)
    t.append(ArrowType.STRING)
    return t^


def _same_bytes(
    a: SharedAlignedBuffer[HeapRegion], b: SharedAlignedBuffer[HeapRegion]
) raises:
    assert_equal(a.len(), b.len())
    for i in range(a.len()):
        if a.read_u8_at(i) != b.read_u8_at(i):
            assert_equal(Int(a.read_u8_at(i)), Int(b.read_u8_at(i)), String(i))


def _check_columns(cols: Slab[Column[HeapRegion]]) raises:
    assert_equal(len(cols), 5)
    for s in range(1, 5):
        ref c = cols[s - 1]
        assert_equal(c._length, ROWS)
        for i in range(0, ROWS, 37):
            assert_equal(
                c._data.read_i64_le_at(i * 8), Int64((i * s) % 7 + s)
            )
    var strs = cols[4].as_string()
    assert_equal(strs.get(0), String("v0"))
    assert_equal(strs.get(ROWS - 1), String("v") + String((ROWS - 1) % 5))


def _placeholders(n: Int) -> Slab[Column[HeapRegion]]:
    """One (unused) dictionary slot per column, as with_dicts requires."""
    var s = Slab[Column[HeapRegion]]()
    for _ in range(n):
        s.append(Column[HeapRegion]())
    return s^


# ---------------------------------------------------------------------------
# Record batches
# ---------------------------------------------------------------------------


def test_parallel_encode_equals_serial_encode() raises:
    var d = InlineDispatch()
    var par = encode_record_batch_message_compressed_with_dispatcher[Lz4Frame](
        _columns(), Pointer(to=d), CancellationToken.never()
    )
    assert_equal(d.dispatches, 1)
    var ser = encode_record_batch_message_compressed[Lz4Frame](_columns())
    _same_bytes(par, ser)


def test_parallel_decompress_equals_serial_decompress() raises:
    var d = InlineDispatch()
    var frame = encode_record_batch_message_compressed[Zstd[3]](_columns())
    var par = decompress_record_batch_frame_with_dispatcher[Zstd[3]](
        frame.share(), Pointer(to=d), CancellationToken.never()
    )
    assert_equal(d.dispatches, 1)
    var ser = decompress_record_batch_frame[Zstd[3]](frame^)
    _same_bytes(par, ser)


def test_dispatcher_decoders_read_lz4_and_zstd_frames() raises:
    """The three dispatcher-aware decoders, each on an LZ4 and a ZSTD
    frame (their decompress step picks the codec off the wire)."""
    var d = InlineDispatch()
    _check_columns(
        decode_record_batch_message_with_dispatcher(
            encode_record_batch_message_compressed[Lz4Frame](_columns()),
            _types(),
            Pointer(to=d),
            CancellationToken.never(),
        )
    )
    _check_columns(
        decode_record_batch_message_with_dispatcher(
            encode_record_batch_message_compressed[Zstd[3]](_columns()),
            _types(),
            Pointer(to=d),
            CancellationToken.never(),
        )
    )
    var flags = List[Bool]()
    for _ in range(5):
        flags.append(False)
    _check_columns(
        decode_record_batch_message_with_dicts_with_dispatcher(
            encode_record_batch_message_compressed[Zstd[3]](_columns()),
            _types(),
            flags,
            _placeholders(5),
            List[Int](),
            Pointer(to=d),
            CancellationToken.never(),
        )
    )
    var specs = Slab[ColumnTypeSpec]()
    for _ in range(4):
        specs.append(ColumnTypeSpec.leaf(ArrowType.INT64))
    specs.append(ColumnTypeSpec.leaf(ArrowType.STRING))
    _check_columns(
        decode_record_batch_message_nested_with_dispatcher(
            encode_record_batch_message_compressed[Lz4Frame](_columns()),
            specs^,
            Pointer(to=d),
            CancellationToken.never(),
        )
    )
    assert_equal(d.dispatches, 4)


def test_dispatcher_decoder_reads_an_uncompressed_frame() raises:
    """No BodyCompression: nothing to decompress, nothing dispatched."""
    from komira_arrow_ipc.ipc_encoder_dispatch import (
        encode_record_batch_message,
    )
    var d = InlineDispatch()
    _check_columns(
        decode_record_batch_message_with_dispatcher(
            encode_record_batch_message(_columns()),
            _types(),
            Pointer(to=d),
            CancellationToken.never(),
        )
    )
    assert_equal(d.dispatches, 0)


def test_few_buffers_stay_serial_under_a_dispatcher() raises:
    """One INT64 column: one non-empty buffer, below the threshold of
    four, so the dispatcher is never called and the bytes still equal the
    serial encode."""
    var d = InlineDispatch()
    var one = Slab[Column[HeapRegion]]()
    one.append(_int_col(3))
    var par = encode_record_batch_message_compressed_with_dispatcher[Lz4Frame](
        one^, Pointer(to=d), CancellationToken.never()
    )
    var one2 = Slab[Column[HeapRegion]]()
    one2.append(_int_col(3))
    _same_bytes(par, encode_record_batch_message_compressed[Lz4Frame](one2^))
    var back = decompress_record_batch_frame_with_dispatcher[Lz4Frame](
        par^, Pointer(to=d), CancellationToken.never()
    )
    assert_equal(d.dispatches, 0)
    assert_true(back.len() > 0)


# ---------------------------------------------------------------------------
# The coalesced multi-frame decompress
# ---------------------------------------------------------------------------


def _decompress_all(
    var frames: Slab[SharedAlignedBuffer[HeapRegion]], mut d: InlineDispatch
) raises -> Slab[SharedAlignedBuffer[HeapRegion]]:
    return decompress_all_rbs_into_with_dispatcher[Lz4Frame](
        frames^, Pointer(to=d), CancellationToken.never()
    )


def test_coalesced_decompress_of_one_frame_equals_serial() raises:
    """One frame of seven non-empty buffers: the dispatch strides over
    buffers (the n_rbs == 1 arm)."""
    var frame = encode_record_batch_message_compressed[Lz4Frame](_columns())
    var frames = Slab[SharedAlignedBuffer[HeapRegion]]()
    frames.append(frame.share())
    var d = InlineDispatch()
    var outs = _decompress_all(frames^, d)
    assert_equal(d.dispatches, 1)
    assert_equal(len(outs), 1)
    _same_bytes(outs[0], decompress_record_batch_frame[Lz4Frame](frame^))


def test_coalesced_decompress_of_three_frames_equals_serial() raises:
    """Three frames: the dispatch strides over frames; each output equals
    that frame's serial decompress, in order."""
    var frames = Slab[SharedAlignedBuffer[HeapRegion]]()
    var serial = List[SharedAlignedBuffer[HeapRegion]]()
    for k in range(3):
        var cols = Slab[Column[HeapRegion]]()
        cols.append(_int_col(k + 2))
        cols.append(_int_col(k + 5))
        var f = encode_record_batch_message_compressed[Lz4Frame](cols^)
        serial.append(decompress_record_batch_frame[Lz4Frame](f.share()))
        frames.append(f^)
    var d = InlineDispatch()
    var outs = _decompress_all(frames^, d)
    assert_equal(d.dispatches, 1)
    assert_equal(len(outs), 3)
    for k in range(3):
        _same_bytes(outs[k], serial[k])


def test_coalesced_decompress_of_no_frames_is_empty() raises:
    var d = InlineDispatch()
    var outs = _decompress_all(Slab[SharedAlignedBuffer[HeapRegion]](), d)
    assert_equal(len(outs), 0)
    assert_equal(d.dispatches, 0)


# ---------------------------------------------------------------------------
# Dictionary batches
# ---------------------------------------------------------------------------


def _dict_col(n: Int) raises -> Column[HeapRegion]:
    var vals = List[String]()
    for i in range(n):
        vals.append(String("dict-value-") + String(i))
    return Column.from_string(StringArray.from_strings(vals))


def test_dictionary_batch_through_a_dispatcher_equals_serial() raises:
    var d = InlineDispatch()
    var par = encode_dictionary_batch_message_from_string_column_compressed_with_dispatcher[
        Zstd[3]
    ](Int64(7), _dict_col(300), False, Pointer(to=d), CancellationToken.never())
    var ser = encode_dictionary_batch_message_from_string_column_compressed[
        Zstd[3]
    ](Int64(7), _dict_col(300), False)
    _same_bytes(par, ser)
    var back_par = decompress_dictionary_batch_frame_with_dispatcher[Zstd[3]](
        par^, Pointer(to=d), CancellationToken.never()
    )
    var back_ser = decompress_dictionary_batch_frame[Zstd[3]](ser^)
    _same_bytes(back_par, back_ser)


# ---------------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------------


def test_compressed_encode_refuses_zero_columns_and_ragged_columns() raises:
    var msg = String("")
    try:
        _ = encode_record_batch_message_compressed[Lz4Frame](
            Slab[Column[HeapRegion]]()
        )
    except e:
        msg = String(e)
    assert_equal(msg, "encode_record_batch_message_compressed: zero columns")
    var ragged = Slab[Column[HeapRegion]]()
    ragged.append(_int_col(1))
    var short = List[Int64]()
    short.append(1)
    ragged.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(short)
        )
    )
    msg = String("")
    try:
        _ = encode_record_batch_message_compressed[Lz4Frame](ragged^)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "encode_record_batch_message_compressed: row count mismatch at"
        " column 1",
    )


def test_compressed_dictionary_refuses_a_non_string_column() raises:
    var msg = String("")
    try:
        _ = encode_dictionary_batch_message_from_string_column_compressed[
            Lz4Frame
        ](Int64(1), _int_col(1), False)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "encode_dictionary_batch_message_from_string_column_compressed:"
        " dict_col.arrow_type must be STRING; got 5 (only STRING-valued"
        " dictionaries are supported)",
    )


# ---------------------------------------------------------------------------
# Buffers the codec does not touch
# ---------------------------------------------------------------------------


def _random_col(seed: Int, rows: Int = 64) -> Column[HeapRegion]:
    """INT64 values from a 64-bit LCG: LZ4 cannot shrink them, so the
    encoder stores the buffer raw behind the -1 prefix."""
    var v = List[Int64]()
    var x = UInt64(seed) * UInt64(0x9E3779B97F4A7C15) + UInt64(1)
    for _ in range(rows):
        x = x * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        v.append(Int64(x >> 1))
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(v)
    )


def _random_cols(n: Int, seed: Int) -> Slab[Column[HeapRegion]]:
    var cols = Slab[Column[HeapRegion]]()
    for k in range(n):
        cols.append(_random_col(seed + k))
    return cols^


def test_stored_raw_buffer_under_a_dispatcher_below_the_threshold() raises:
    """One raw-stored buffer: the dispatcher-aware decompress copies it
    without the codec and without dispatching."""
    var d = InlineDispatch()
    var frame = encode_record_batch_message_compressed[Lz4Frame](
        _random_cols(1, 7)
    )
    var par = decompress_record_batch_frame_with_dispatcher[Lz4Frame](
        frame.share(), Pointer(to=d), CancellationToken.never()
    )
    assert_equal(d.dispatches, 0)
    _same_bytes(par, decompress_record_batch_frame[Lz4Frame](frame^))


def test_coalesced_uncompressed_frame_is_copied_verbatim() raises:
    """A frame with no BodyCompression and seven non-empty buffers: the
    dispatched copy (one frame: strided over buffers) decodes to the
    input values."""
    from komira_arrow_ipc.ipc_encoder_dispatch import (
        encode_record_batch_message,
    )
    var frames = Slab[SharedAlignedBuffer[HeapRegion]]()
    frames.append(encode_record_batch_message(_columns()))
    var d = InlineDispatch()
    var outs = _decompress_all(frames^, d)
    assert_equal(d.dispatches, 1)
    var last = outs.pop()
    _check_columns(decode_record_batch_message_with_dispatcher(
        last.take(), _types(), Pointer(to=d), CancellationToken.never()
    ))


def test_coalesced_frames_mixing_verbatim_and_raw_stored_buffers() raises:
    """Two frames: one uncompressed (copied verbatim), one LZ4 frame of
    raw-stored buffers (copied past the -1 prefix); dispatched over
    frames. Each output equals that frame's serial result."""
    from komira_arrow_ipc.ipc_encoder_dispatch import (
        encode_record_batch_message,
    )
    var plain = encode_record_batch_message(_random_cols(3, 1))
    var raw = encode_record_batch_message_compressed[Lz4Frame](
        _random_cols(3, 1)
    )
    var frames = Slab[SharedAlignedBuffer[HeapRegion]]()
    frames.append(plain.share())
    frames.append(raw.share())
    var d = InlineDispatch()
    var outs = _decompress_all(frames^, d)
    assert_equal(d.dispatches, 1)
    assert_equal(len(outs), 2)
    var three = List[ArrowType]()
    for _ in range(3):
        three.append(ArrowType.INT64)
    var d2 = InlineDispatch()
    var got_plain = decode_record_batch_message_with_dispatcher(
        outs[0].share(), three, Pointer(to=d2), CancellationToken.never()
    )
    var want = decode_record_batch_message_with_dispatcher(
        plain^, three, Pointer(to=d2), CancellationToken.never()
    )
    for c in range(3):
        for i in range(64):
            assert_equal(
                got_plain[c]._data.read_i64_le_at(i * 8),
                want[c]._data.read_i64_le_at(i * 8),
            )
    _same_bytes(outs[1], decompress_record_batch_frame[Lz4Frame](raw^))


# ---------------------------------------------------------------------------
# More buffers (and frames) than workers
# ---------------------------------------------------------------------------
#
# The dispatchers cap the worker count at 16 and at the number of buffers
# (or frames), so with fewer than 17 each task handles exactly one and a
# task that strode wrongly past its first would go unnoticed. These have
# 24 non-empty buffers, and 20 frames.


def _wide() -> Slab[Column[HeapRegion]]:
    var cols = Slab[Column[HeapRegion]]()
    for s in range(24):
        cols.append(_int_col(s + 1))
    return cols^


def test_wide_batch_parallel_encode_and_decompress_equal_serial() raises:
    var d = InlineDispatch()
    var par = encode_record_batch_message_compressed_with_dispatcher[Lz4Frame](
        _wide(), Pointer(to=d), CancellationToken.never()
    )
    var ser = encode_record_batch_message_compressed[Lz4Frame](_wide())
    _same_bytes(par, ser)
    var back_par = decompress_record_batch_frame_with_dispatcher[Lz4Frame](
        par^, Pointer(to=d), CancellationToken.never()
    )
    var back_ser = decompress_record_batch_frame[Lz4Frame](ser.share())
    _same_bytes(back_par, back_ser)
    var frames = Slab[SharedAlignedBuffer[HeapRegion]]()
    frames.append(ser^)
    var outs = _decompress_all(frames^, d)
    _same_bytes(outs[0], back_ser)
    assert_equal(d.dispatches, 3)


def test_more_frames_than_workers_decompress_in_order() raises:
    var frames = Slab[SharedAlignedBuffer[HeapRegion]]()
    var serial = List[SharedAlignedBuffer[HeapRegion]]()
    for k in range(20):
        var cols = Slab[Column[HeapRegion]]()
        cols.append(_int_col(k + 1))
        var f = encode_record_batch_message_compressed[Lz4Frame](cols^)
        serial.append(decompress_record_batch_frame[Lz4Frame](f.share()))
        frames.append(f^)
    var d = InlineDispatch()
    var outs = _decompress_all(frames^, d)
    assert_equal(d.dispatches, 1)
    assert_equal(len(outs), 20)
    for k in range(20):
        _same_bytes(outs[k], serial[k])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
