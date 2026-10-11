# =============================================================================
# test_orc_write_edges.mojo — writer refusals, stripe sizing, the zero-row
# file, the NONE-codec finalize arms, and bloom-filter edge sizes.
# =============================================================================
#
#   T1  write_orc_bytes refuses a batch with no columns and a column type it
#       does not write (uint8); build_col_encoders and the per-column emit
#       refuse a kind they do not write (binary), each naming it.
#   T2  A stripe size below the stride is raised to the stride: 25 rows at
#       stride 10, stripe 5 make 3 stripes of 10 / 10 / 5 rows.
#   T3  A zero-row batch writes one empty stripe and reads back as 0 rows.
#   T4  finalize_stripe_streams_serial / _parallel with the NONE codec and
#       collected streams file each stream verbatim, index streams to the
#       index block and data streams to the data block, in collect order.
#   T5  OrcBloomFilter with no bits: add is a no-op and test answers "maybe"
#       (it cannot prove absence); bloom sizing for 0 or fewer entries is one
#       64-bit word and one hash function.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder, Field

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PerCoreAsyncRuntime, PLACEMENT_FIXED

from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    read_orc_bytes,
    OrcFileTail,
    OrcBloomFilter,
    bloom_optimal_num_bits,
    bloom_optimal_num_hash_functions,
    encode_stream,
    ORC_COMPRESSION_NONE,
    ORC_KIND_BINARY,
    ORC_KIND_LONG,
    ORC_STREAM_ROW_INDEX,
    ORC_STREAM_BLOOM_FILTER_UTF8,
    ORC_STREAM_DATA,
    ORC_STREAM_LENGTH,
)
from komira_orc.stripe_emit import (
    build_col_encoders,
    StripeStreams,
    _PendingStream,
    _OrcColEncoder,
    _emit_primitive_column,
    finalize_stripe_streams_serial,
    finalize_stripe_streams_parallel,
)


def _i64_batch(n: Int) raises -> RecordBatch:
    var a = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        a.set(i, Int64(i * 3))
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, True))
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(Column.from_primitive_with_arrow_type[DType.int64](a^, ArrowType.INT64))
    return b.build(sb.build())


# -----------------------------------------------------------------------------
# T1 — refusals.
# -----------------------------------------------------------------------------


def test_writer_refusals() raises:
    var empty = RecordBatchBuilder.with_capacity(0)
    var esb = SchemaBuilder()
    var no_cols = empty.build(esb.build())
    with assert_raises(contains="EMPTY_SCHEMA: RecordBatch has no columns"):
        _ = write_orc_bytes(no_cols, OrcWriterOptions(ORC_COMPRESSION_NONE, 10, "UTC"))

    var u = PrimitiveArray[DType.uint8].allocate(2)
    u.set(0, 1)
    u.set(1, 2)
    var sb = SchemaBuilder()
    sb.add_field(Field("u", ArrowType.UINT8, True))
    var b = RecordBatchBuilder.with_capacity(1)
    b.add_column(Column.from_primitive_with_arrow_type[DType.uint8](u^, ArrowType.UINT8))
    var u8 = b.build(sb.build())
    with assert_raises(contains="is not yet supported by the ORC writer"):
        _ = write_orc_bytes(u8, OrcWriterOptions(ORC_COMPRESSION_NONE, 10, "UTC"))

    var batch = _i64_batch(2)
    var kinds = List[Int]()
    kinds.append(ORC_KIND_BINARY)
    with assert_raises(contains="UNSUPPORTED_TYPE: ORC Type.Kind binary write is not supported"):
        _ = build_col_encoders(batch, kinds)

    var enc = _OrcColEncoder(ORC_KIND_BINARY)
    var result = StripeStreams()
    with assert_raises(contains="UNSUPPORTED_TYPE: ORC Type.Kind binary write is not supported"):
        _emit_primitive_column(enc, 1, ORC_KIND_BINARY, 0, 0, ORC_COMPRESSION_NONE, result)


# -----------------------------------------------------------------------------
# T2 — stripe size below the stride.
# -----------------------------------------------------------------------------


def test_stripe_size_raised_to_stride() raises:
    var opts = OrcWriterOptions.with_stride(ORC_COMPRESSION_NONE, 10, 5, True)
    var bytes = write_orc_bytes(_i64_batch(25), opts)
    var tail = OrcFileTail.parse(Span(bytes))
    assert_equal(tail.footer.num_stripes(), 3)
    assert_equal(tail.footer.stripes[0].number_of_rows, 10)
    assert_equal(tail.footer.stripes[1].number_of_rows, 10)
    assert_equal(tail.footer.stripes[2].number_of_rows, 5)
    var back = read_orc_bytes(Span(bytes))
    assert_equal(back.num_rows(), 25)
    assert_equal(back.column_as_primitive_int64(0).get(24), 72)
    # A stripe size of 0 means "the stride".
    var opts0 = OrcWriterOptions.with_stride(ORC_COMPRESSION_NONE, 10, 0, False)
    var t0 = OrcFileTail.parse(Span(write_orc_bytes(_i64_batch(25), opts0)))
    assert_equal(t0.footer.num_stripes(), 3)


# -----------------------------------------------------------------------------
# T3 — zero rows.
# -----------------------------------------------------------------------------


def test_zero_row_batch() raises:
    var bytes = write_orc_bytes(_i64_batch(0), OrcWriterOptions(ORC_COMPRESSION_NONE, 10, "UTC"))
    var tail = OrcFileTail.parse(Span(bytes))
    assert_equal(tail.footer.num_stripes(), 1)
    assert_equal(tail.footer.stripes[0].number_of_rows, 0)
    assert_equal(tail.num_rows(), 0)
    var back = read_orc_bytes(Span(bytes))
    assert_equal(back.num_rows(), 0)
    assert_equal(back.num_columns(), 1)


# -----------------------------------------------------------------------------
# T4 — NONE-codec finalize over collected streams.
# -----------------------------------------------------------------------------


def _collected() -> StripeStreams:
    var r = StripeStreams()
    var idx = List[UInt8]()
    idx.append(1)
    idx.append(2)
    idx.append(3)
    var dat = List[UInt8]()
    dat.append(9)
    dat.append(8)
    var bloom = List[UInt8]()
    bloom.append(7)
    var len_stream = List[UInt8]()
    len_stream.append(6)
    len_stream.append(5)
    len_stream.append(4)
    len_stream.append(3)
    r.raw_streams.append(idx^)
    r.pending_descs.append(_PendingStream(ORC_STREAM_ROW_INDEX, 1, True))
    r.raw_streams.append(dat^)
    r.pending_descs.append(_PendingStream(ORC_STREAM_DATA, 1, False))
    r.raw_streams.append(bloom^)
    r.pending_descs.append(_PendingStream(ORC_STREAM_BLOOM_FILTER_UTF8, 2, True))
    r.raw_streams.append(len_stream^)
    r.pending_descs.append(_PendingStream(ORC_STREAM_LENGTH, 2, False))
    return r^


def _assert_bytes(got: List[UInt8], want: List[UInt8], label: String) raises:
    assert_equal(len(got), len(want), label + ": length")
    for i in range(len(want)):
        assert_equal(got[i], want[i], label + ": byte " + String(i))


def _check_filed(r: StripeStreams, label: String) raises:
    assert_equal(len(r.raw_streams), 0, label + ": collected streams consumed")
    var want_index = List[UInt8]()
    want_index.append(1)
    want_index.append(2)
    want_index.append(3)
    want_index.append(7)
    var want_data = List[UInt8]()
    for v in range(6):
        want_data.append(UInt8(9 - v) if v < 2 else UInt8(8 - v))
    _assert_bytes(r.index_data, want_index, label + ": index block")
    _assert_bytes(r.data, want_data, label + ": data block")
    assert_equal(len(r.index_stream_protos), 2, label + ": index protos")
    assert_equal(len(r.stream_protos), 2, label + ": data protos")
    _assert_bytes(r.index_stream_protos[0], encode_stream(ORC_STREAM_ROW_INDEX, 1, 3), label + ": index proto 0")
    _assert_bytes(r.index_stream_protos[1], encode_stream(ORC_STREAM_BLOOM_FILTER_UTF8, 2, 1), label + ": index proto 1")
    _assert_bytes(r.stream_protos[0], encode_stream(ORC_STREAM_DATA, 1, 2), label + ": data proto 0")
    _assert_bytes(r.stream_protos[1], encode_stream(ORC_STREAM_LENGTH, 2, 4), label + ": data proto 1")


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def test_none_codec_finalize_files_verbatim() raises:
    var serial = _collected()
    finalize_stripe_streams_serial(serial, ORC_COMPRESSION_NONE)
    _check_filed(serial, "serial")

    var rt = PerCoreAsyncRuntime[NoopSink](
        num_workers=2,
        sink_factory=_noop_sink_factory,
        backend=BACKEND_MOCK,
        placement=PLACEMENT_FIXED,
    )
    ref disp = rt.dispatcher()
    var par = _collected()
    finalize_stripe_streams_parallel[origin_of(disp)](
        par, ORC_COMPRESSION_NONE, Pointer(to=disp), CancellationToken.never()
    )
    _check_filed(par, "parallel")
    _ = rt^


# -----------------------------------------------------------------------------
# T5 — bloom edge sizes.
# -----------------------------------------------------------------------------


def test_bloom_edge_sizes() raises:
    var empty = OrcBloomFilter(3, List[UInt8]())
    assert_equal(empty.num_bits(), 0)
    empty.add_long(42)
    empty.add_double(1.5)
    assert_equal(len(empty.bitset), 0)
    assert_true(empty.test_long(42))
    assert_true(empty.test_long(7))
    assert_true(empty.test_double(2.5))

    assert_equal(bloom_optimal_num_bits(0, 0.01), 64)
    assert_equal(bloom_optimal_num_bits(-5, 0.01), 64)
    assert_equal(bloom_optimal_num_hash_functions(0, 64), 1)
    assert_equal(bloom_optimal_num_hash_functions(-1, 64), 1)
    # One entry is above the 0-entry floor.
    assert_true(bloom_optimal_num_bits(1000, 0.01) > 64)

    # A one-word filter: an added double tests present.
    var one = OrcBloomFilter(7, 1)
    assert_false(one.test_double(1.5))
    one.add_double(1.5)
    assert_true(one.test_double(1.5))


def main() raises:
    test_writer_refusals()
    test_stripe_size_raised_to_stride()
    test_zero_row_batch()
    test_none_codec_finalize_files_verbatim()
    test_bloom_edge_sizes()
    print("test_orc_write_edges: ALL PASS")
