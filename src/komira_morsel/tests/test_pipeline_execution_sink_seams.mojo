# =============================================================================
# PipelineExecution (cancel, panic, first-error-wins slot), the MorselSinkImpl
# and MorselOperatorImpl defaults, HashAggDecodedRG and its hash helpers, and
# the Morsel payload attachments (ParquetBypassRef, HashAggDecodedRG).
# =============================================================================
#
# What these tests prove (oracles from the docstrings, worked out by hand):
#
#   * A new PipelineExecution reports its worker count, is neither cancelled
#     nor panicked, and holds no error; cancel and panic are separate flags.
#   * The error slot is first-error-wins: the first `set_error_cas` returns
#     True and its error is the one `take_error` returns; a second returns
#     False and is dropped; `take_error` resets the slot so a later poll sees
#     no error and a later `set_error_cas` wins again.
#   * A sink overriding only `consume`/`finalize` gets the trait defaults:
#     `resize_worker_state` and `combine` change nothing, `take_output` raises
#     its documented message. An operator's default `metrics_snapshot` is
#     empty.
#   * `fib_hash_key(k) = (k * 0x9E3779B97F4A7C15) ^ (that >> 32)`, with 0
#     mapped to 1; `fingerprint_for_hash(h) = (h >> 56) | 0x80`;
#     `partition_for_hash(h) = (h >> 32) & 0x3F`. Values worked by hand for
#     k in {0, 1, 2, -1}: see `test_hash_helpers`.
#   * `HashAggDecodedRG` keeps the buffers it is given and reads row `i` of
#     each; `from_key_col` takes `num_rows` from the key array; the accessors
#     read through a buffer's offset.
#
# Single-threaded: the CAS slot is driven in program order (the race arm of
# `take_error` is not reachable from one thread; see the coverage report).
# =============================================================================

from std.memory import ArcPointer, OwnedPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_exec_types.engine_error import EngineError
from komira_exec_types.exec_result import ExecResult, NEED_MORE_INPUT
from komira_metrics.metrics_set import MetricsSnapshot
from komira_morsel.bypass_ref import ParquetBypassRef
from komira_morsel.hash_agg_decoded import (
    N_PARTITIONS,
    HashAggDecodedRG,
    fib_hash_key,
    fingerprint_for_hash,
    partition_for_hash,
)
from komira_morsel.morsel import Morsel
from komira_morsel.morsel_operator import MorselOperatorImpl
from komira_morsel.morsel_sink import MorselSinkImpl
from komira_morsel.pipeline_execution import PipelineExecution


# -----------------------------------------------------------------------------
# PipelineExecution
# -----------------------------------------------------------------------------


def test_new_pipeline_state() raises:
    var p = PipelineExecution(3, 5)
    assert_equal(p.num_workers(), 3)
    assert_false(p.is_cancelled())
    assert_false(p.is_panicked())
    assert_false(p.has_error())
    assert_false(Bool(p.take_error()))
    var p1 = PipelineExecution(1, 0)
    assert_equal(p1.num_workers(), 1)


def test_cancel_and_panic_are_separate_flags() raises:
    var p = PipelineExecution(2, 0)
    p.cancel()
    assert_true(p.is_cancelled())
    assert_false(p.is_panicked())
    assert_false(p.has_error())
    # Cancelling twice keeps it cancelled.
    p.cancel()
    assert_true(p.is_cancelled())

    var q = PipelineExecution(2, 0)
    q.set_panic()
    assert_true(q.is_panicked())
    assert_false(q.is_cancelled())
    assert_false(q.has_error())


def test_first_error_wins_and_take_resets() raises:
    var p = PipelineExecution(4, 0)
    assert_true(p.set_error_cas(EngineError(7, "first")))
    assert_true(p.has_error())
    assert_false(p.set_error_cas(EngineError(9, "second")))
    assert_true(p.has_error())
    var e = p.take_error()
    assert_true(Bool(e))
    assert_equal(e.value().code, 7)
    assert_equal(e.value().message, "first")
    # The slot is reset: nothing more to take.
    assert_false(p.has_error())
    assert_false(Bool(p.take_error()))
    # A later error wins again and is the one returned.
    assert_true(p.set_error_cas(EngineError(11, "third", "op", "d")))
    var e2 = p.take_error()
    assert_equal(e2.value().code, 11)
    assert_equal(e2.value().message, "third")
    assert_equal(e2.value().name, "op")
    assert_equal(e2.value().detail, "d")
    # An error does not touch the cancel or panic flags.
    assert_false(p.is_cancelled())
    assert_false(p.is_panicked())


# -----------------------------------------------------------------------------
# Sink and operator defaults
# -----------------------------------------------------------------------------


struct CountingSink(MorselSinkImpl):
    """Overrides only the required methods."""

    var finalized: Int

    def __init__(out self):
        self.finalized = 0

    def consume(self, worker_id: Int, var morsel: Morsel) raises:
        _ = morsel^

    def finalize(mut self) raises:
        self.finalized += 1


struct PassOp(MorselOperatorImpl):
    var calls: Int

    def __init__(out self):
        self.calls = 0

    def execute(mut self, mut morsel: Morsel) raises -> ExecResult:
        self.calls += 1
        return ExecResult(NEED_MORE_INPUT)


def test_sink_defaults() raises:
    var sink = CountingSink()
    var p = PipelineExecution(2, 0)
    sink.resize_worker_state(8)
    sink.consume(0, Morsel.empty(0, 0))
    sink.combine(p)
    sink.finalize()
    assert_equal(sink.finalized, 1)
    # combine's default leaves the pipeline untouched.
    assert_false(p.is_cancelled())
    assert_false(p.has_error())
    var raised = False
    try:
        _ = sink.take_output()
    except e:
        raised = True
        assert_equal(
            String(e),
            "MorselSinkImpl.take_output: not implemented by this sink type",
        )
    assert_true(raised, "default take_output must raise")


def test_operator_default_metrics_snapshot_is_empty() raises:
    var op = PassOp()
    var m = Morsel.empty(0, 0)
    assert_true(op.execute(m).is_need_more_input())
    assert_equal(op.calls, 1)
    assert_equal(op.metrics_snapshot().count(), 0)


# -----------------------------------------------------------------------------
# Hash helpers and HashAggDecodedRG
# -----------------------------------------------------------------------------


def test_hash_helpers() raises:
    # k = 0: 0 * C = 0, and 0 is the empty sentinel, so the hash is 1.
    assert_equal(fib_hash_key(Int64(0)), UInt64(1))
    # k = 1: h = C = 0x9E3779B97F4A7C15; h ^ (h >> 32) flips the low word
    # by 0x9E3779B9: 0x7F4A7C15 ^ 0x9E3779B9 = 0xE17D05AC.
    assert_equal(fib_hash_key(Int64(1)), UInt64(0x9E3779B9E17D05AC))
    # k = 2: 2C mod 2^64 = 0x3C6EF372FE94F82A; low ^ high = 0xC2FA0B58.
    assert_equal(fib_hash_key(Int64(2)), UInt64(0x3C6EF372C2FA0B58))
    # k = -1: -C mod 2^64 = 0x61C8864680B583EB; low ^ high = 0xE17D05AD.
    assert_equal(fib_hash_key(Int64(-1)), UInt64(0x61C88646E17D05AD))

    # Fingerprint: top byte with the high bit forced on.
    assert_equal(fingerprint_for_hash(UInt64(1)), UInt8(0x80))
    assert_equal(fingerprint_for_hash(UInt64(0x9E3779B9E17D05AC)), UInt8(0x9E))
    assert_equal(fingerprint_for_hash(UInt64(0x3C6EF372C2FA0B58)), UInt8(0xBC))
    assert_equal(fingerprint_for_hash(UInt64(0x61C88646E17D05AD)), UInt8(0xE1))

    # Partition: bits 32..37 of the hash.
    assert_equal(partition_for_hash(UInt64(1)), 0)
    assert_equal(partition_for_hash(UInt64(0x9E3779B9E17D05AC)), 0x39)  # 57
    assert_equal(partition_for_hash(UInt64(0x3C6EF372C2FA0B58)), 0x32)  # 50
    assert_equal(partition_for_hash(UInt64(0x61C88646E17D05AD)), 0x06)
    # Bit 38 and up and bits below 32 never reach the partition.
    assert_equal(partition_for_hash(UInt64(0xFFFFFFC0FFFFFFFF)), 0)
    assert_equal(partition_for_hash(UInt64(0x0000003F00000000)), 63)
    assert_equal(N_PARTITIONS, 64)


def _key_array(keys: List[Int64]) -> PrimitiveArray[DType.int64]:
    var l = List[Scalar[DType.int64]]()
    for k in keys:
        l.append(k)
    return PrimitiveArray[DType.int64].from_list(l)


def _hashes(keys: List[Int64], lead: Int) -> SharedAlignedBuffer[HeapRegion]:
    """`lead` filler UInt64 slots, then one hash per key."""
    var n = lead + len(keys)
    var buf = SharedAlignedBuffer[HeapRegion].heap_owned(max(n * 8, 8))
    for i in range(lead):
        buf.set_typed[UInt64](i, UInt64(0xAAAAAAAAAAAAAAAA))
    for i in range(len(keys)):
        buf.set_typed[UInt64](lead + i, fib_hash_key(keys[i]))
    return buf^


def _fps(keys: List[Int64], lead: Int) -> SharedAlignedBuffer[HeapRegion]:
    var n = lead + len(keys)
    var buf = SharedAlignedBuffer[HeapRegion].heap_owned(max(n, 1))
    for i in range(lead):
        buf.set_typed[UInt8](i, UInt8(0x11))
    for i in range(len(keys)):
        buf.set_typed[UInt8](lead + i, fingerprint_for_hash(fib_hash_key(keys[i])))
    return buf^


def _parts(keys: List[Int64]) -> List[UInt8]:
    var out = List[UInt8]()
    for k in keys:
        out.append(UInt8(partition_for_hash(fib_hash_key(k))))
    return out^


def _int64_column(values: List[Int64]) -> Column[HeapRegion]:
    var n = len(values)
    var buf = OwnedAlignedBuffer(max(n * 8, 1))
    var ptr = buf.view_typed_ro[DType.int64]()
    for i in range(n):
        ptr[i] = values[i]
    buf.set_length(Int64(n * 8))
    return Column[HeapRegion](
        arrow_type=ArrowType.INT64,
        data=buf^,
        offsets=None,
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )


def test_hash_agg_decoded_rows() raises:
    var keys: List[Int64] = [Int64(1), Int64(2), Int64(-1)]
    var cols = Slab[Column[HeapRegion]]()
    cols.append(_int64_column([Int64(10), Int64(20), Int64(30)]))
    cols.append(_int64_column([Int64(4), Int64(5), Int64(6)]))
    var dec = HashAggDecodedRG.from_key_col(
        _key_array(keys), _hashes(keys, 0), _fps(keys, 0), _parts(keys), cols^
    )
    assert_equal(dec.num_rows, 3)
    assert_equal(dec.key_array.length, 3)
    assert_equal(dec.key_array.get(2), Int64(-1))
    assert_equal(dec.hash_at(0), UInt64(0x9E3779B9E17D05AC))
    assert_equal(dec.hash_at(1), UInt64(0x3C6EF372C2FA0B58))
    assert_equal(dec.hash_at(2), UInt64(0x61C88646E17D05AD))
    assert_equal(dec.fingerprint_at(0), UInt8(0x9E))
    assert_equal(dec.fingerprint_at(1), UInt8(0xBC))
    assert_equal(dec.fingerprint_at(2), UInt8(0xE1))
    assert_equal(dec.partition_at(0), 57)
    assert_equal(dec.partition_at(1), 50)
    assert_equal(dec.partition_at(2), 6)
    # Agg-input columns keep their order.
    assert_equal(len(dec.agg_input_columns), 2)
    assert_equal(
        dec.agg_input_columns[0].as_primitive[DType.int64]().get(1), Int64(20)
    )
    assert_equal(
        dec.agg_input_columns[1].as_primitive[DType.int64]().get(2), Int64(6)
    )


def test_hash_agg_decoded_explicit_rows_and_offset_buffers() raises:
    # The explicit constructor keeps the given num_rows; buffers viewed at a
    # byte offset (2 UInt64 / 3 UInt8 filler slots in front) read row 0 at
    # the offset, not at the region start.
    var keys: List[Int64] = [Int64(2), Int64(1)]
    var h_full = _hashes(keys, 2)
    var f_full = _fps(keys, 3)
    var h = SharedAlignedBuffer[HeapRegion](
        ArcPointer[HeapRegion](copy=h_full._region), Int64(16), Int64(16)
    )
    var f = SharedAlignedBuffer[HeapRegion](
        ArcPointer[HeapRegion](copy=f_full._region), Int64(3), Int64(2)
    )
    var dec = HashAggDecodedRG(
        _key_array(keys), h^, f^, _parts(keys), Slab[Column[HeapRegion]](), 2
    )
    assert_equal(dec.num_rows, 2)
    assert_equal(dec.hash_at(0), UInt64(0x3C6EF372C2FA0B58))
    assert_equal(dec.hash_at(1), UInt64(0x9E3779B9E17D05AC))
    assert_equal(dec.fingerprint_at(0), UInt8(0xBC))
    assert_equal(dec.fingerprint_at(1), UInt8(0x9E))
    assert_equal(dec.partition_at(0), 50)
    assert_equal(dec.partition_at(1), 57)
    assert_equal(len(dec.agg_input_columns), 0)
    _ = h_full.len()
    _ = f_full.len()


# -----------------------------------------------------------------------------
# Morsel payload attachments
# -----------------------------------------------------------------------------


def test_bypass_ref_and_morsel_attachments() raises:
    var r = ParquetBypassRef(ArcPointer[UInt64](UInt64(0xDEADBEEF)))
    assert_equal(r._opaque_addr(), UInt64(0xDEADBEEF))
    var r2 = r.copy()
    assert_equal(r2._opaque_addr(), UInt64(0xDEADBEEF))

    var m = Morsel.empty(4, 2)
    assert_false(m.has_raw_chunks())
    assert_false(m.has_hash_agg_decoded())
    m.attach_bypass_ref(r^)
    assert_true(m.has_raw_chunks())
    assert_false(m.has_hash_agg_decoded())
    # A second attachment replaces the first.
    m.attach_bypass_ref(ParquetBypassRef(ArcPointer[UInt64](UInt64(5))))
    assert_equal(m.raw_chunks.value()._opaque_addr(), UInt64(5))

    var keys: List[Int64] = [Int64(0)]
    var dec = HashAggDecodedRG.from_key_col(
        _key_array(keys), _hashes(keys, 0), _fps(keys, 0), _parts(keys),
        Slab[Column[HeapRegion]](),
    )
    m.attach_hash_agg_decoded(OwnedPointer(dec^))
    assert_true(m.has_hash_agg_decoded())
    assert_equal(m.hash_agg_decoded.value()[].hash_at(0), UInt64(1))
    assert_equal(m.hash_agg_decoded.value()[].fingerprint_at(0), UInt8(0x80))
    assert_equal(m.hash_agg_decoded.value()[].partition_at(0), 0)
    # The ids are untouched by attachments.
    assert_equal(m.morsel_id, 4)
    assert_equal(m.partition_id, 2)
    _ = r2^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
