# =============================================================================
# JOIN-ASSEMBLE PARALLEL GATHER — byte-identity falsifier for
# the parallel join-output assemble (`assemble_join_result` /
# `emit_gather_column_projected` reusing the sort's `_parallel_string_gather` /
# `_parallel_fixedwidth_gather` kernels).
# =============================================================================
#
# The single-STRING-key INNER join runs through the composite leaf
# `materialize_composite_join_over_batches`, whose per-column output assemble
# (`emit_gather_column_projected`) runs on the sort's parallel gather
# kernels — generic over DType + arity, benefiting every join caller +
# INT64 joins. The ONLY net-new code vs the sort gather is the `-1` null-sentinel
# branch (LEFT/FULL outer joins have unmatched output rows -> null), added
# param-gated so the sort path stays byte-unchanged.
#
# ACCEPTANCE GATE: the PARALLEL assemble == the SERIAL assemble, byte-for-byte,
# for every column — INCLUDING the STRING offsets array (a parallel prefix-sum
# off-by-one corrupts every downstream string), the packed data bytes, the
# fixed-width data, and the validity bitmap. Covered: wide-string + INT64
# columns on BOTH sides, INNER (no nulls) AND LEFT-with-unmatched-rows.
#
# KEYSTONE FALSIFIER (`test_left_join_null_sentinel_byte_identical`): a LEFT join
# whose right-side indices contain `-1` (unmatched probe rows). The parallel
# kernels' `allow_null_sentinel` branch MUST reproduce the serial join arm's
# `if idx != -1` behavior EXACTLY: a `-1` STRING row is a zero-length output row
# (offset stays flat), a `-1` fixed-width row leaves a zeroed data slot, and the
# validity bit is cleared. The sort gather test cannot cover this — sort
# permutations never contain `-1`.
#
#   FAILS ON CURRENT CODE (a hypothetical parallel kernel that ignores the `-1`
#   sentinel — e.g. dereferences `src_off_ptr + (col_offset - 1)` for an
#   unmatched row): the STRING offsets diverge from the serial cumulative
#   offsets and the validity bitmap / null-count diverge. With the correct
#   sentinel branch the assemble is byte-identical to serial.
#
# `gather_parallel_min_rows=1` drops the parallel
# min-row gate to 1
# cores — exercising the cross-chunk exclusive scan + the sentinel branch under
# real fan-out.
#
# CROSS-THREAD SAFETY: the test drives only `assemble_join_result`; the
# implementation reads source offset/data buffers RO and writes into PRE-SIZED
# DISJOINT output slices, resolves validity SERIALLY on the main thread, and
# builds the output Column ONCE on the main thread after the fork-join barrier —
# it NEVER constructs a StringArray / Column / ArcPointer on a worker.
#
# Encapsulation: tests use ONLY the public assemble surface — no UnsafePointer,
# no wildcard origin, no unsafe_from_address.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_arrow.arrow_types import ArrowType
from komira_buffer.heap_region import HeapRegion
from komira_join_assembly.compiler_join_assembly import (
    assemble_join_result,
    assemble_join_result_dispatch,
)
from komira_column_kernels.compiler_helpers import GATHER_SERIAL_ONLY

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime


# -----------------------------------------------------------------------------
# Live pool — WHY THIS FILE NEEDS A RUNTIME NOW
# -----------------------------------------------------------------------------
#
# ⚠ BOTH ARMS MUST BE DIFFERENT CODE PATHS. `assemble_join_result` is a
# comptime `has_pool=False` forwarder, so a "parallel" arm driven through it
# compiles to the SAME serial code as the reference arm and the file would
# assert `serial == serial` — green while a production join gather went
# single-threaded. A setting is not a fire-set: an A/B only tests what the
# setting still reaches.
#
# The `par` arm goes through `assemble_join_result_dispatch[True, ...]` on a
# REAL multi-worker `PerCoreAsyncRuntime`, so the two arms are genuinely
# different code paths. `gather_parallel_min_rows=1` is required: these
# fixtures are 200-256 rows, far below the 64K gate, and forcing them parallel
# is what fans the small input across every physical core and exercises the
# cross-chunk exclusive scan + the `-1` sentinel branch under real fan-out.
# The reference arm passes `GATHER_SERIAL_ONLY`.


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _make_started_runtime(
    n_workers: Int,
) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(n_workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^


# -----------------------------------------------------------------------------
# Batch builders — a (string, int64) two-column batch.
# -----------------------------------------------------------------------------


def _build_str_i64_batch(
    s_name: String,
    i_name: String,
    var keys: List[String],
    var vals: List[Scalar[DType.int64]],
) raises -> RecordBatch:
    var sa = StringArray.from_strings(keys^)
    var ck = Column.from_string(sa^)
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var ci = Column.from_primitive[DType.int64](arr^)
    var schema = Schema.from_fields_2(
        Field(s_name, ArrowType.STRING, True),
        Field(i_name, DType.int64, True),
    )
    return RecordBatch.from_typed_columns_2(schema^, ck^, ci^)


# -----------------------------------------------------------------------------
# Byte-identity assertions (read directly from column buffers — no StringArray).
# -----------------------------------------------------------------------------


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


def _assert_str_offsets_byte_identical(
    imm a: RecordBatch, imm b: RecordBatch, col: Int
) raises:
    """Assert the OFFSETS array is byte-for-byte identical. An off-by-one in
    the parallel prefix-sum (or a mishandled `-1` sentinel) manifests HERE
    before the data bytes."""
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


# -----------------------------------------------------------------------------
# Output-schema builder: left (s_l, i_l) ++ right (s_r, i_r).
# -----------------------------------------------------------------------------


def _join_output_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("s_l", ArrowType.STRING, True))
    sb.add_field(Field("i_l", DType.int64, True))
    sb.add_field(Field("s_r", ArrowType.STRING, True))
    sb.add_field(Field("i_r", DType.int64, True))
    return sb.build()


def _build_left() raises -> RecordBatch:
    """Probe (left) batch: 200 rows, variable-width string + int64."""
    var n = 200
    var keys = List[String](capacity=n)
    var vals = List[Scalar[DType.int64]](capacity=n)
    for i in range(n):
        # Variable widths so per-chunk byte totals differ (exclusive scan
        # load-bearing).
        var rep = i % 23
        var s = String("L")
        for _ in range(rep):
            s += chr(ord("a") + (i % 26))
        keys.append(s)
        vals.append(Int64(i * 3 - 7))
    return _build_str_i64_batch("s_l", "i_l", keys^, vals^)


def _build_right() raises -> RecordBatch:
    """Build (right) batch: 200 rows, variable-width string + int64."""
    var n = 200
    var keys = List[String](capacity=n)
    var vals = List[Scalar[DType.int64]](capacity=n)
    for i in range(n):
        var rep = i % 19
        var s = String("R")
        for _ in range(rep):
            s += chr(ord("A") + (i % 26))
        keys.append(s)
        vals.append(Int64(i * 5 + 11))
    return _build_str_i64_batch("s_r", "i_r", keys^, vals^)


# A scattered (probe-order) match permutation that fans across many chunks.
def _scatter_indices(n: Int, src_n: Int) -> List[Int]:
    var idx = List[Int](capacity=n)
    for i in range(n):
        # Interleave + reverse so adjacent outputs draw from far-apart source
        # rows (the hash-join scatter shape) — exercises random-access gather.
        idx.append((src_n - 1 - ((i * 7) % src_n)))
    return idx^


# =============================================================================
# Tests
# =============================================================================


def test_inner_join_str_int_byte_identical() raises:
    """INNER join (no -1): wide-string + INT64 on both sides. The parallel
    assemble must be byte-identical to the serial assemble across all 4 output
    columns (2 string + 2 int64)."""
    var n = 256
    var li = _scatter_indices(n, 200)
    var ri = _scatter_indices(n, 200)

    var out_schema = _join_output_schema()

    var l_ser = _build_left()
    var r_ser = _build_right()
    var ser = assemble_join_result(
        l_ser, r_ser, li.copy(), ri.copy(), out_schema,
        gather_parallel_min_rows=GATHER_SERIAL_ONLY,
    )

    var l_par = _build_left()
    var r_par = _build_right()
    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var par = assemble_join_result_dispatch[
        True, LocalDispatcher[NoopSink], origin_of(disp)
    ](
        l_par, r_par, li^, ri^, out_schema,
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
            Pointer(to=disp)
        ),
        gather_parallel_min_rows=1,
    )
    rt.shutdown()

    assert_equal(par.num_columns(), 4)
    assert_equal(par.num_rows(), ser.num_rows())
    # col 0 = s_l (string), col 1 = i_l (int64), col 2 = s_r (string),
    # col 3 = i_r (int64).
    _assert_str_offsets_byte_identical(par, ser, 0)
    _assert_str_data_byte_identical(par, ser, 0)
    _assert_i64_byte_identical(par, ser, 1)
    _assert_str_offsets_byte_identical(par, ser, 2)
    _assert_str_data_byte_identical(par, ser, 2)
    _assert_i64_byte_identical(par, ser, 3)


def test_left_join_null_sentinel_byte_identical() raises:
    """KEYSTONE: LEFT join where the RIGHT-side indices contain `-1`
    (unmatched probe rows). `right_nullable=True`. The parallel kernels'
    `allow_null_sentinel` branch must reproduce the serial join arm EXACTLY:
    `-1` STRING rows are zero-length (offset flat, validity cleared) and `-1`
    INT64 rows are zeroed (validity cleared). Asserts offsets + data +
    validity + null_count byte-identical for every column."""
    var n = 256
    # Left side: every probe row appears, in scattered order, NEVER -1.
    var li = _scatter_indices(n, 200)
    # Right side: ~1/3 of the rows are unmatched (-1).
    var ri = List[Int](capacity=n)
    for i in range(n):
        if i % 3 == 0:
            ri.append(-1)
        else:
            ri.append((200 - 1 - ((i * 11) % 200)))

    var out_schema = _join_output_schema()

    var l_ser = _build_left()
    var r_ser = _build_right()
    var ser = assemble_join_result(
        l_ser, r_ser, li.copy(), ri.copy(), out_schema, right_nullable=True,
        gather_parallel_min_rows=GATHER_SERIAL_ONLY,
    )

    var l_par = _build_left()
    var r_par = _build_right()
    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var par = assemble_join_result_dispatch[
        True, LocalDispatcher[NoopSink], origin_of(disp)
    ](
        l_par, r_par, li^, ri^, out_schema,
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
            Pointer(to=disp)
        ),
        right_nullable=True,
        gather_parallel_min_rows=1,
    )
    rt.shutdown()

    assert_equal(par.num_columns(), 4)
    assert_equal(par.num_rows(), ser.num_rows())

    # Left columns (no -1): byte-identical.
    _assert_str_offsets_byte_identical(par, ser, 0)
    _assert_str_data_byte_identical(par, ser, 0)
    _assert_i64_byte_identical(par, ser, 1)

    # Right columns (carry -1 -> null): the keystone. Offsets, data, AND
    # validity bitmap + null_count must match the serial sentinel handling.
    _assert_str_offsets_byte_identical(par, ser, 2)
    _assert_str_data_byte_identical(par, ser, 2)
    _assert_validity_identical(par, ser, 2)
    _assert_i64_byte_identical(par, ser, 3)
    _assert_validity_identical(par, ser, 3)


def test_left_join_all_unmatched_byte_identical() raises:
    """Edge case: LEFT join where EVERY right index is -1 (zero matches). The
    right STRING column must be all zero-length / all-null; the right INT64
    column all-zero / all-null. Byte-identical to serial."""
    var n = 200
    var li = _scatter_indices(n, 200)
    var ri = List[Int](capacity=n)
    for _ in range(n):
        ri.append(-1)

    var out_schema = _join_output_schema()

    var l_ser = _build_left()
    var r_ser = _build_right()
    var ser = assemble_join_result(
        l_ser, r_ser, li.copy(), ri.copy(), out_schema, right_nullable=True,
        gather_parallel_min_rows=GATHER_SERIAL_ONLY,
    )

    var l_par = _build_left()
    var r_par = _build_right()
    var rt = _make_started_runtime(4)
    ref disp = rt.dispatcher()
    var par = assemble_join_result_dispatch[
        True, LocalDispatcher[NoopSink], origin_of(disp)
    ](
        l_par, r_par, li^, ri^, out_schema,
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](
            Pointer(to=disp)
        ),
        right_nullable=True,
        gather_parallel_min_rows=1,
    )
    rt.shutdown()

    _assert_str_offsets_byte_identical(par, ser, 2)
    _assert_str_data_byte_identical(par, ser, 2)
    _assert_validity_identical(par, ser, 2)
    _assert_i64_byte_identical(par, ser, 3)
    _assert_validity_identical(par, ser, 3)
    # The right string column has zero data bytes (all rows zero-length).
    assert_equal(ser.column_at(2).null_count(), n)
    assert_equal(par.column_at(2).null_count(), n)


def main() raises:
    var suite = TestSuite()
    suite.test[test_inner_join_str_int_byte_identical]()
    suite.test[test_left_join_null_sentinel_byte_identical]()
    suite.test[test_left_join_all_unmatched_byte_identical]()
    suite^.run()
