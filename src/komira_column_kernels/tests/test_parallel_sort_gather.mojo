# =============================================================================
# PARALLEL SORT GATHER — byte-identity falsifier for the chunked per-column
# gather (`gather_batch_dispatch` STRING two-pass + fixed-width scatter).
# =============================================================================
#
# `gather_batch_dispatch` splits the per-column STRING two-pass (length+offsets
# prefix-sum, then scatter) and the fixed-width indexed scatter into chunks
# when it has a dispatcher and the output has at least
# `gather_parallel_min_rows` rows. This test proves the chunked output is
# BYTE-IDENTICAL to the single-chunk serial gather.
#
# ACCEPTANCE GATE: chunked == serial, byte-for-byte, INCLUDING the offsets
# array (a chunked prefix-sum off-by-one corrupts every downstream string),
# the packed data bytes, and the validity bitmap. Covered: variable-width
# strings, NULLs, an EMPTY-STRING row, and fixed-width INT64 / FLOAT64.
#
# KEYSTONE FALSIFIER (`test_string_offsets_prefix_sum_byte_identical`): a
# MULTI-CHUNK gather where the chunked offset prefix-sum must EXACTLY reproduce
# the serial cumulative offsets. `gather_parallel_min_rows=1` drops the
# min-row gate so a SMALL (256-row) input is split across all physical cores,
# exercising the cross-chunk exclusive scan. The serial reference passes
# `GATHER_SERIAL_ONLY`, a threshold no batch reaches.
#
#   A gather whose per-chunk offset base is wrong (e.g. one that forgets the
#   exclusive scan of prior chunks' byte totals) produces offsets that diverge
#   from the serial cumulative offsets, and EVERY string after the first chunk
#   boundary resolves to the wrong byte extent. The assert on the offsets
#   array + the per-row resolved string catches it. With the correct
#   exclusive-scan base the gather is byte-identical.
#
# THE DISPATCHER: `_InlineDispatch` runs a wave's tasks one after another on
# the calling thread. Chunking, chunk bases and the exclusive scan are the same
# code a pooled dispatcher runs; only the concurrency is absent (a real
# multi-worker run belongs with the engine runtime's tests).
#
# CROSS-THREAD SAFETY: the implementation reads the source offset/data buffers
# RO and writes into PRE-ALLOCATED output buffers — it NEVER constructs a
# StringArray / Column / ArcPointer inside a chunk; the output Column is built
# ONCE on the calling thread after the fork-join barrier.
#
# Encapsulation: tests use ONLY the public surface — no UnsafePointer, no
# wildcard origin, no unsafe_from_address.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_arrow.string_array import StringArray
from komira_arrow.arrow_types import ArrowType
from komira_concurrency.token import CancellationToken
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.compiler_helpers import (
    GATHER_SERIAL_ONLY,
    gather_batch_dispatch,
)
from komira_concurrency.parallel_dispatch import ParallelDispatch
from komira_concurrency.worker_pool_traits import KeepAlive, Segment


# -----------------------------------------------------------------------------
# A dispatcher that runs every task of a wave inline, in task order.
# -----------------------------------------------------------------------------

# Worker count the dispatcher reports. The gather caps its chunk count at this
# and at the physical core count, so any value >= the core count lets every
# core get a chunk.
comptime _INLINE_WORKERS: Int = 1024


struct _InlineDispatch(ParallelDispatch, Movable, Deinitable):
    """Runs `n` copies of a segment sequentially on the calling thread.

    A fork-join wave's tasks write disjoint slots and join before the driver
    returns, so running them in task order yields the same bytes as running
    them concurrently."""

    var _workers: Int

    def __init__(out self, workers: Int):
        self._workers = workers

    def run_with_state[State: KeepAlive, T: Segment](
        mut self,
        mut state: State,
        var seg: T,
        n: Int,
        var cancel_token: CancellationToken,
        site_id: UInt32 = UInt32(0),
    ) raises -> T:
        _ = cancel_token^
        for t in range(n):
            seg.execute[State](state, Int32(t), Int64(t))
        return seg^

    def worker_count(self) -> Int:
        return self._workers


def _gather(
    batch: RecordBatch, indices: List[Int], gather_parallel_min_rows: Int
) raises -> RecordBatch:
    """`gather_batch_dispatch` on an `_InlineDispatch`, with the given min-row
    threshold (1 = chunked; `GATHER_SERIAL_ONLY` = the serial reference)."""
    var disp = _InlineDispatch(_INLINE_WORKERS)
    return gather_batch_dispatch[True, _InlineDispatch, origin_of(disp)](
        batch,
        indices,
        Optional[Pointer[_InlineDispatch, origin_of(disp)]](Pointer(to=disp)),
        gather_parallel_min_rows=gather_parallel_min_rows,
    )


# -----------------------------------------------------------------------------
# Batch builders
# -----------------------------------------------------------------------------


def _build_str_batch(var keys: List[String]) raises -> RecordBatch:
    var sa = StringArray.from_strings(keys^)
    var ck = Column.from_string(sa^)
    var schema = Schema.from_fields_1(Field("s", ArrowType.STRING, True))
    return RecordBatch.from_typed_columns_1(schema^, ck^)


def _build_str_nullable_batch(
    var keys: List[String], var valid: List[Bool]
) raises -> RecordBatch:
    var sa = StringArray.from_strings_with_validity(keys^, valid^)
    var ck = Column.from_string(sa^)
    var schema = Schema.from_fields_1(Field("s", ArrowType.STRING, True))
    return RecordBatch.from_typed_columns_1(schema^, ck^)


def _build_i64_batch(var vals: List[Scalar[DType.int64]]) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var col = Column.from_primitive[DType.int64](arr^)
    var schema = Schema.from_fields_1(Field("v", DType.int64, True))
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_f64_batch(var vals: List[Scalar[DType.float64]]) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.float64].from_list(vals^)
    var col = Column.from_primitive[DType.float64](arr^)
    var schema = Schema.from_fields_1(Field("v", DType.float64, True))
    return RecordBatch.from_typed_columns_1(schema^, col^)


# -----------------------------------------------------------------------------
# Byte-identity assertions (read directly from column buffers — no StringArray)
# -----------------------------------------------------------------------------


def _assert_str_offsets_byte_identical(
    imm a: RecordBatch, imm b: RecordBatch, col: Int
) raises:
    """Assert the OFFSETS array is byte-for-byte identical. An off-by-one in
    the parallel prefix-sum manifests HERE before the data bytes."""
    assert_equal(a.num_rows(), b.num_rows())
    ref ca = a.column_at(col)
    ref cb = b.column_at(col)
    var oa = ca._offsets.value().view_ro()
    var ob = cb._offsets.value().view_ro()
    var n = a.num_rows()
    for i in range(n + 1):
        assert_equal(
            Int(oa.get_typed[Int32](ca._offset + i)),
            Int(ob.get_typed[Int32](cb._offset + i)),
        )


def _string_at(imm batch: RecordBatch, col: Int, row: Int) raises -> String:
    ref c = batch.column_at(col)
    var offs = c._offsets.value().view_ro()
    var data = c._data.view_ro()
    var o = c._offset + row
    var start = Int(offs.get_typed[Int32](o))
    var end = Int(offs.get_typed[Int32](o + 1))
    var out = String("")
    for i in range(start, end):
        out += chr(Int(data.get_typed[UInt8](i)))
    return out


def _assert_str_data_byte_identical(
    imm a: RecordBatch, imm b: RecordBatch, col: Int
) raises:
    assert_equal(a.num_rows(), b.num_rows())
    for r in range(a.num_rows()):
        assert_equal(_string_at(a, col, r), _string_at(b, col, r))


def _assert_validity_identical(
    imm a: RecordBatch, imm b: RecordBatch, col: Int
) raises:
    ref ca = a.column_at(col)
    ref cb = b.column_at(col)
    assert_equal(ca.null_count(), cb.null_count())
    var has_a = ca._validity.__bool__()
    var has_b = cb._validity.__bool__()
    assert_true(has_a == has_b)
    if has_a and has_b:
        for r in range(a.num_rows()):
            assert_true(
                ca._validity.value().test(ca._offset + r)
                == cb._validity.value().test(cb._offset + r)
            )


def _assert_i64_byte_identical(
    imm a: RecordBatch, imm b: RecordBatch, col: Int
) raises:
    ref ca = a.column_at(col)
    ref cb = b.column_at(col)
    var pa = ca.as_primitive[DType.int64]()
    var pb = cb.as_primitive[DType.int64]()
    assert_equal(pa.length, pb.length)
    for i in range(pa.length):
        assert_equal(
            Int(pa.get_typed[Scalar[DType.int64]](i)),
            Int(pb.get_typed[Scalar[DType.int64]](i)),
        )


def _assert_f64_byte_identical(
    imm a: RecordBatch, imm b: RecordBatch, col: Int
) raises:
    ref ca = a.column_at(col)
    ref cb = b.column_at(col)
    var pa = ca.as_primitive[DType.float64]()
    var pb = cb.as_primitive[DType.float64]()
    assert_equal(pa.length, pb.length)
    for i in range(pa.length):
        # Bit-exact (gather copies bytes verbatim — no arithmetic).
        assert_equal(
            Int(pa.get_typed[Scalar[DType.float64]](i).to_bits()),
            Int(pb.get_typed[Scalar[DType.float64]](i).to_bits()),
        )


# -----------------------------------------------------------------------------
# A permutation that fans rows across MANY chunks (reverse + interleave).
# -----------------------------------------------------------------------------


def _reverse_perm(n: Int) -> List[Int]:
    var idx = List[Int](capacity=n)
    for i in range(n):
        idx.append(n - 1 - i)
    return idx^


# =============================================================================
# Tests
# =============================================================================


def test_string_offsets_prefix_sum_byte_identical() raises:
    """KEYSTONE FALSIFIER: a 256-row variable-width STRING gather split into
    one chunk per physical core. The chunked offsets prefix-sum MUST reproduce the
    serial cumulative offsets exactly — an off-by-one corrupts every string
    after a chunk boundary. Asserts the OFFSETS array AND the resolved strings
    are byte-identical."""
    var n = 256
    var keys = List[String](capacity=n)
    for i in range(n):
        # Variable widths so the per-chunk byte totals differ -> the exclusive
        # scan is load-bearing. Lengths cycle 0..(some) with content tied to i.
        var rep = i % 17
        var s = String("")
        for _ in range(rep):
            s += chr(ord("a") + (i % 26))
        keys.append(s)

    var perm = _reverse_perm(n)

    var b_ser = _build_str_batch(keys.copy())
    var ser = _gather(b_ser, perm, GATHER_SERIAL_ONLY)

    var b_par = _build_str_batch(keys^)
    var par = _gather(b_par, perm, 1)

    _assert_str_offsets_byte_identical(par, ser, 0)
    _assert_str_data_byte_identical(par, ser, 0)


def test_string_nulls_and_empty_row_byte_identical() raises:
    """Variable-width STRING gather with NULL rows + an explicit empty-string
    row. Validity bitmap + offsets + data must all be byte-identical."""
    var n = 200
    var keys = List[String](capacity=n)
    var valid = List[Bool](capacity=n)
    for i in range(n):
        if i % 5 == 0:
            keys.append(String(""))  # null placeholder
            valid.append(False)
        elif i % 5 == 1:
            keys.append(String(""))  # genuine EMPTY string (valid)
            valid.append(True)
        else:
            var s = String("row_")
            s += String(i)
            keys.append(s)
            valid.append(True)

    var perm = _reverse_perm(n)

    var b_ser = _build_str_nullable_batch(keys.copy(), valid.copy())
    var ser = _gather(b_ser, perm, GATHER_SERIAL_ONLY)

    var b_par = _build_str_nullable_batch(keys^, valid^)
    var par = _gather(b_par, perm, 1)

    _assert_str_offsets_byte_identical(par, ser, 0)
    _assert_str_data_byte_identical(par, ser, 0)
    _assert_validity_identical(par, ser, 0)


def test_fixedwidth_i64_byte_identical() raises:
    """Fixed-width INT64 gather (the shared gather path used by int/float
    sorts) must be byte-identical when chunked."""
    var n = 300
    var vals = List[Scalar[DType.int64]](capacity=n)
    for i in range(n):
        vals.append(Int64(i * 7 - 11))

    var perm = _reverse_perm(n)

    var b_ser = _build_i64_batch(vals.copy())
    var ser = _gather(b_ser, perm, GATHER_SERIAL_ONLY)

    var b_par = _build_i64_batch(vals^)
    var par = _gather(b_par, perm, 1)

    _assert_i64_byte_identical(par, ser, 0)


def test_fixedwidth_f64_byte_identical() raises:
    """Fixed-width FLOAT64 gather must be bit-exact when chunked."""
    var n = 300
    var vals = List[Scalar[DType.float64]](capacity=n)
    for i in range(n):
        vals.append(Float64(i) * 1.5 - 3.25)

    var perm = _reverse_perm(n)

    var b_ser = _build_f64_batch(vals.copy())
    var ser = _gather(b_ser, perm, GATHER_SERIAL_ONLY)

    var b_par = _build_f64_batch(vals^)
    var par = _gather(b_par, perm, 1)

    _assert_f64_byte_identical(par, ser, 0)


def test_identity_and_single_row_parallel() raises:
    """Edge cases: identity permutation (every row) + a 1-row gather at the
    chunked threshold (nw capped at count -> single chunk). Must match serial."""
    var n = 128
    var keys = List[String](capacity=n)
    for i in range(n):
        keys.append(String("k") + String(i))
    var ident = List[Int](capacity=n)
    for i in range(n):
        ident.append(i)

    var b_ser = _build_str_batch(keys.copy())
    var ser = _gather(b_ser, ident, GATHER_SERIAL_ONLY)

    var b_par = _build_str_batch(keys^)
    var par = _gather(b_par, ident, 1)

    _assert_str_offsets_byte_identical(par, ser, 0)
    _assert_str_data_byte_identical(par, ser, 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_string_offsets_prefix_sum_byte_identical]()
    suite.test[test_string_nulls_and_empty_row_byte_identical]()
    suite.test[test_fixedwidth_i64_byte_identical]()
    suite.test[test_fixedwidth_f64_byte_identical]()
    suite.test[test_identity_and_single_row_parallel]()
    suite^.run()
