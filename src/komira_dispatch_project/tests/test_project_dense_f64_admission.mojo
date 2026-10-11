# =============================================================================
# test_project_dense_f64_admission.mojo: what the dense FLOAT64 evaluator
# admits, its literal folding, and its answer against the walker called
# directly
# =============================================================================
#
# SUBJECT: `project_dense_f64` called directly with hand-built pools:
# `try_eval_dense_f64`, `try_eval_dense_f64_pooled` and a pool task.
#
# 1. Admission: each reason the walk declines (a slot out of range, a column
#    index past the name table, a name the batch lacks, a column of another
#    type, a numeric dictionary, a column shorter than the batch, a node
#    outside the envelope) answers None.
# 2. Folding: an operator over two literals folds to one scalar for each of
#    the four operators, and a literal-only expression fills the column.
# 3. The oracle: for each operator, the dense column is compared bit for bit
#    with `ExpressionExecutor.eval_to_list_f64_from_view` called directly
#    over the identity selection. This comparison does not go through the
#    evaluator's `dense_f64` switch, so it holds whatever that switch does.
# 4. The pooled form: a pool that is not admitted answers None, and a task
#    whose range is empty writes nothing.
#
# Each test names the mutant that turns it red.
# =============================================================================

from std.collections import Optional
from std.memory import bitcast
from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.selection_vector_row import RowSelectionVector
from komira_arrow.string_array import StringArray
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.local_dispatcher import LocalDispatcher
from komira_async.runtime.parallel_fork_join_shared import SharedForkJoinHandle
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_eval.expression_executor import ExpressionExecutor
from komira_kernels.runtime_expr import (
    RuntimeExpr,
    make_add_f64,
    make_col,
    make_div_f64,
    make_lit_f64,
    make_lit_i64,
    make_mul_f64,
    make_sqrt_f64,
    make_sub_f64,
)

from komira_dispatch_project.project_dense_f64 import (
    DENSE_PAR_MIN_ROWS,
    _DenseF64Work,
    _DenseIn,
    _DenseOut,
    try_eval_dense_f64,
    try_eval_dense_f64_pooled,
)


comptime _N: Int = 37


def _batch(n: Int) raises -> RecordBatch:
    """`f` FLOAT64, `i` INT64, `n` INT32, `s` STRING, `dc` a numeric
    dictionary declared DICTIONARY. Values vary per row."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("f"), ArrowType.FLOAT64, False))
    sb.add_field(Field(String("i"), ArrowType.INT64, False))
    sb.add_field(Field(String("n"), ArrowType.INT32, False))
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    sb.add_field(Field(String("dc"), ArrowType.DICTIONARY, False))
    var f = List[Scalar[DType.float64]]()
    var i = List[Scalar[DType.int64]]()
    var nn = List[Scalar[DType.int32]]()
    var s = List[String]()
    var codes = List[Scalar[DType.int32]]()
    for r in range(n):
        f.append(Scalar[DType.float64](Float64(r) * 0.75 - 3.0))
        i.append(Scalar[DType.int64](r * 1000003 - 17))
        nn.append(Scalar[DType.int32](r))
        s.append(String("s"))
        codes.append(Scalar[DType.int32](r % 2))
    var dict_vals = List[Int64]()
    dict_vals.append(Int64(5))
    dict_vals.append(Int64(6))
    var rbb = RecordBatchBuilder.with_capacity(5)
    rbb.add_column(Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(f)))
    rbb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(i)))
    rbb.add_column(Column.from_primitive[DType.int32](PrimitiveArray[DType.int32].from_list(nn)))
    rbb.add_column(Column.from_string(StringArray.from_strings(s)))
    rbb.add_column(
        Column.from_numeric_dict[DType.int32, DType.int64](
            PrimitiveArray[DType.int32].from_list(codes), dict_vals^
        )
    )
    return rbb.build(sb.build())


def _names() -> List[String]:
    """The walker's name table: slot k names the batch column `k`, plus one
    name the batch does not hold."""
    var out = List[String]()
    out.append(String("f"))
    out.append(String("i"))
    out.append(String("n"))
    out.append(String("s"))
    out.append(String("dc"))
    out.append(String("absent"))
    return out^


def _bin(mk: Int, l: Int, r: Int) -> RuntimeExpr:
    if mk == 0:
        return make_add_f64(l, r)
    if mk == 1:
        return make_sub_f64(l, r)
    if mk == 2:
        return make_mul_f64(l, r)
    return make_div_f64(l, r)


def _admitted(imm pool: List[RuntimeExpr], root: Int, imm batch: RecordBatch) raises -> Bool:
    return Bool(try_eval_dense_f64(pool, root, _names(), batch))


# =============================================================================
# 1. Admission
# =============================================================================


def test_each_admission_failure_declines() raises:
    """Mutant: the `if lk == 0: return False` check removed (the INT32 leaf is
    then admitted). (The `is_numeric_dict()` operand of `_leaf_kind` is
    subsumed by its type test: a numeric dictionary's tag is DICTIONARY, which
    is not a dense leaf type, so removing the operand changes no answer.)"""
    var b = _batch(_N)
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    assert_true(_admitted(pool, 0, b), "a FLOAT64 column is admitted")
    assert_false(_admitted(pool, 1, b), "a root slot past the pool")
    assert_false(_admitted(pool, -1, b), "a negative root slot")
    var cases = List[Int]()
    cases.append(2)  # INT32: not a dense leaf type
    cases.append(3)  # STRING
    cases.append(4)  # numeric dictionary
    cases.append(5)  # a name the batch does not hold
    cases.append(6)  # past the name table
    cases.append(-1)  # a negative column index
    for k in range(len(cases)):
        var p = List[RuntimeExpr]()
        p.append(make_col(cases[k]))
        assert_false(_admitted(p, 0, b), "leaf case " + String(cases[k]))
    var sq = List[RuntimeExpr]()
    sq.append(make_col(0))
    sq.append(make_sqrt_f64(0))
    assert_false(_admitted(sq, 1, b), "a node outside the envelope")
    var bad_right = List[RuntimeExpr]()
    bad_right.append(make_col(0))
    bad_right.append(make_col(2))
    bad_right.append(make_add_f64(0, 1))
    assert_false(_admitted(bad_right, 2, b), "a declined right operand")


def test_a_column_shorter_than_the_batch_declines() raises:
    """The walk reads `_length` rows from `_offset`; a column holding fewer
    rows than the batch is not admitted. Mutant: that check removed (the
    kernel then reads past the column)."""
    var b = _batch(_N)
    b._num_rows = _N + 5
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    assert_false(_admitted(pool, 0, b))


def test_a_column_whose_type_differs_from_its_field_declines() raises:
    """An INT64 column under a TIMESTAMP_US field: the field's type is not a
    dense leaf type, and the column's tag is not the field's, so the leaf is
    not admitted (the walker resolves it as it always did)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("t"), ArrowType.TIMESTAMP_US, False))
    var v = List[Scalar[DType.int64]]()
    for r in range(5):
        v.append(Scalar[DType.int64](r))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(v)))
    var b = rbb.build(sb.build())
    var names = List[String]()
    names.append(String("t"))
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    assert_false(Bool(try_eval_dense_f64(pool, 0, names, b)))


def test_a_layout_conflict_declines_rather_than_raises() raises:
    """A STRING column under an INT64 field is a layout conflict:
    `RecordBatch.column_arrow_type` raises on it, and the admission walk
    answers None instead of raising, so the walker meets the batch as it
    would have. Mutant: the walk's `try` removed (the raise then escapes
    `try_eval_dense_f64`)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("t"), ArrowType.INT64, False))
    var strs = List[String]()
    strs.append(String("a"))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_string(StringArray.from_strings(strs)))
    var b = rbb.build(sb.build())
    var names = List[String]()
    names.append(String("t"))
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    assert_false(Bool(try_eval_dense_f64(pool, 0, names, b)))


def test_a_cyclic_pool_declines() raises:
    """A node whose operand is itself recurses until the depth bound. Mutant:
    the depth bound removed (the walk then never ends)."""
    var b = _batch(_N)
    var pool = List[RuntimeExpr]()
    pool.append(make_add_f64(0, 0))
    assert_false(_admitted(pool, 0, b))


# =============================================================================
# 2. Literal folding
# =============================================================================


def test_each_operator_folds_two_literals_and_a_literal_fills_the_column() raises:
    """`(6 op 4) + f` folds `6 op 4` to one scalar for each operator (the
    INT64 literal widened), and `2.5 op 0.5` alone fills every row. Mutant:
    the MUL fold computing `l + r`."""
    var b = _batch(_N)
    var f = b.column_as_primitive_float64(0)
    var folded = List[Float64]()
    folded.append(10.0)
    folded.append(2.0)
    folded.append(24.0)
    folded.append(1.5)
    var whole = List[Float64]()
    whole.append(3.0)
    whole.append(2.0)
    whole.append(1.25)
    whole.append(5.0)
    for mk in range(4):
        var pool = List[RuntimeExpr]()
        pool.append(make_lit_i64(Int64(6)))
        pool.append(make_lit_f64(4.0))
        pool.append(_bin(mk, 0, 1))
        pool.append(make_col(0))
        pool.append(make_add_f64(2, 3))
        var got = try_eval_dense_f64(pool, 4, _names(), b)
        assert_true(Bool(got))
        var col = got.take().as_primitive[DType.float64]()
        for r in range(_N):
            assert_equal(col.get(r), folded[mk] + f.get(r), "folded op " + String(mk))
        var lp = List[RuntimeExpr]()
        lp.append(make_lit_f64(2.5))
        lp.append(make_lit_f64(0.5))
        lp.append(_bin(mk, 0, 1))
        var lit = try_eval_dense_f64(lp, 2, _names(), b)
        assert_true(Bool(lit))
        var lcol = lit.take().as_primitive[DType.float64]()
        assert_equal(lcol.length, _N)
        for r in range(_N):
            assert_equal(lcol.get(r), whole[mk], "literal-only op " + String(mk))


# =============================================================================
# 3. The walker oracle, called directly
# =============================================================================


def _walker(var pool: List[RuntimeExpr], root: Int, imm batch: RecordBatch) raises -> List[Float64]:
    var ex = ExpressionExecutor(pool^, root, _names())
    var n = batch.num_rows()
    var sel = RowSelectionVector(n)
    for r in range(n):
        sel.append(UInt32(r))
    var out = List[Scalar[DType.float64]]()
    ex.eval_to_list_f64_from_view(batch_view_over(batch), root, sel, out)
    var vals = List[Float64]()
    for r in range(len(out)):
        vals.append(Float64(out[r]))
    return vals^


def test_each_operator_matches_the_walker_bit_for_bit() raises:
    """`f op i`, `i op 1.5` and `-2 op f` for each operator over 4,101 rows
    (two chunks and a ragged tail), against the walker run directly. Mutant:
    `_leaf_chunk` reading INT64 rows as float64 bits."""
    var n = 4101
    var b = _batch(n)
    for mk in range(4):
        var shapes = List[List[RuntimeExpr]]()
        var p0 = List[RuntimeExpr]()
        p0.append(make_col(0))
        p0.append(make_col(1))
        p0.append(_bin(mk, 0, 1))
        shapes.append(p0^)
        var p1 = List[RuntimeExpr]()
        p1.append(make_col(1))
        p1.append(make_lit_f64(1.5))
        p1.append(_bin(mk, 0, 1))
        shapes.append(p1^)
        var p2 = List[RuntimeExpr]()
        p2.append(make_lit_i64(Int64(-2)))
        p2.append(make_col(0))
        p2.append(_bin(mk, 0, 1))
        shapes.append(p2^)
        for sh in range(len(shapes)):
            var want = _walker(shapes[sh].copy(), 2, b)
            var got = try_eval_dense_f64(shapes[sh], 2, _names(), b)
            assert_true(Bool(got))
            var col = got.take().as_primitive[DType.float64]()
            assert_equal(len(want), n)
            for r in range(n):
                var wb = bitcast[DType.uint64](want[r])
                var db = bitcast[DType.uint64](col.get(r))
                if wb != db:
                    assert_equal(db, wb, "op " + String(mk) + " shape " + String(sh) + " row " + String(r))


# =============================================================================
# 4. The pooled form
# =============================================================================


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def test_the_pooled_form_declines_what_it_does_not_admit() raises:
    """Above the row floor with two workers, a pool outside the envelope
    answers None, and one inside answers the serial bits. Mutant: the pooled
    admission's `return None` made a fall-through to the wave."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(2, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var h = SharedForkJoinHandle[True, origin_of(disp)](
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](Pointer(to=disp))
    )
    var b = _batch(DENSE_PAR_MIN_ROWS + 3)
    var sq = List[RuntimeExpr]()
    sq.append(make_col(0))
    sq.append(make_sqrt_f64(0))
    assert_false(Bool(try_eval_dense_f64_pooled(h, sq, 1, _names(), b)))
    var ok = List[RuntimeExpr]()
    ok.append(make_col(0))
    ok.append(make_col(1))
    ok.append(make_mul_f64(0, 1))
    var par = try_eval_dense_f64_pooled(h, ok, 2, _names(), b)
    var ser = try_eval_dense_f64(ok, 2, _names(), b)
    assert_true(Bool(par) and Bool(ser))
    var pc = par.take().as_primitive[DType.float64]()
    var sc = ser.take().as_primitive[DType.float64]()
    for r in range(b.num_rows()):
        assert_equal(
            bitcast[DType.uint64](pc.get(r)), bitcast[DType.uint64](sc.get(r))
        )
    rt.shutdown()


def test_a_one_worker_pool_runs_the_serial_form() raises:
    """With one worker the pooled form runs `try_eval_dense_f64` on the
    calling thread: same admission, same bits. Mutant: the `nw < 2` operand
    removed (a one-task wave then runs; the bits agree, so this case covers
    the operand rather than catching a value change)."""
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(1, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var h = SharedForkJoinHandle[True, origin_of(disp)](
        Optional[Pointer[LocalDispatcher[NoopSink], origin_of(disp)]](Pointer(to=disp))
    )
    var b = _batch(DENSE_PAR_MIN_ROWS + 3)
    var ok = List[RuntimeExpr]()
    ok.append(make_col(0))
    ok.append(make_col(1))
    ok.append(make_sub_f64(0, 1))
    var par = try_eval_dense_f64_pooled(h, ok, 2, _names(), b)
    var ser = try_eval_dense_f64(ok, 2, _names(), b)
    assert_true(Bool(par) and Bool(ser))
    var pc = par.take().as_primitive[DType.float64]()
    var sc = ser.take().as_primitive[DType.float64]()
    assert_equal(
        bitcast[DType.uint64](pc.get(b.num_rows() - 1)),
        bitcast[DType.uint64](sc.get(b.num_rows() - 1)),
    )
    rt.shutdown()


def test_a_task_with_an_empty_range_writes_nothing() raises:
    """A task whose first row is at the end returns before it allocates
    scratch, and writes nothing; task 0 writes its rows. The guard saves the
    allocation only: without it the range loop runs no chunk, so no mutant
    of the guard changes an output. This case covers it and pins that an
    empty task leaves the output untouched."""
    var b = _batch(8)
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    var leaf_ci = List[Int]()
    leaf_ci.append(0)
    var leaf_kind = List[Int]()
    leaf_kind.append(1)
    var work = _DenseF64Work[origin_of(b)](pool^, leaf_ci^, leaf_kind^, 0, 8, 8)
    var inp = _DenseIn[origin_of(b)](b)
    var arr = PrimitiveArray[DType.float64].allocate(8)
    arr.store[1](0, SIMD[DType.float64, 1](-1.0))
    var out = _DenseOut(arr^)
    work.process(1, 2, inp, out)
    assert_equal(Float64(out.arr.value().get(0)), -1.0, "the task wrote nothing")
    work.process(0, 2, inp, out)
    assert_equal(Float64(out.arr.value().get(0)), -3.0, "task 0 wrote row 0")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
