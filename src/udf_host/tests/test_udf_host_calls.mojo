# One worker's calls of a column-kind UDF (instance.mojo) on the reference
# runtime komira-test/echo (echo.so): its fixtures are fixed functions named
# by the entry (`double`, `add_strict` raises on any NULL argument it is
# given, `raise_on_row_3` raises on the value 3 naming its row, ...), and it
# reports every breach of the host contract it can see as ERR_HOST_CONTRACT,
# so a host that exports its arguments wrongly fails here.
#
# What it proves:
#   - rows in equal rows out: each row's answer is the fixture's, in order,
#     NULLs kept under MANUAL; a zero-argument call over N rows answers N
#     rows; an empty batch answers no row;
#   - NULL_PROPAGATE: a row with a NULL argument (in either argument) is not
#     given to the runtime (the strict fixture, which raises on a NULL it
#     sees, answers) and its answer is NULL; a batch of NULL rows only makes
#     no call at all;
#   - a raise is UDF_RAISED with the runtime's message and the row in the
#     caller's numbering, mapped back through the compaction and through the
#     row ceiling's cuts;
#   - the row ceiling cuts a batch into calls and the answers come back in
#     order;
#   - a lost context (the worker of a call is gone) is UDF_WORKER_CRASHED and
#     every later call on the instance refuses without calling the runtime;
#   - each post-condition: the row count (UDF_BATCH_LENGTH_MISMATCH), a NULL
#     in a non-nullable result (UDF_RETURN_TYPE_MISMATCH), an argument of
#     another type or count (OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH);
#   - each output the runtime breaks the ABI with is UDF_RUNTIME_FAULT naming
#     it: a layout the importer refuses, an output on another device, no
#     output on OK, an output left set on a failure, args never moved;
#   - a context or instance the runtime refuses is a named error.
# Catches: a compaction that passes a NULL row to the runtime or misplaces an
# answer; a row number reported in the runtime's numbering; a lost instance
# that calls again; a post-condition skipped; an output read without its
# checks; a host contract breach in the exported arguments.

from std.memory import ArcPointer
from std.os import setenv, unsetenv
from std.testing import TestSuite, assert_equal, assert_true

from arrow.column import Column
from arrow.column_builder import ColumnBuilder
from byte_buffer.heap_region import HeapRegion
from plan_expr.udf_data import UDF_NULL_PROPAGATE
from plan_ir.udf_ref import UDF_REF_KIND_MAP_BATCHES_COLUMN, UdfRef

from komira_test_udf_host.echo_udfs import ECHO_LIBRARY, echo_ref, int64_column, read_int64, render
from udf_host.instance import UdfInstance
from udf_host.runtime import UdfBinding, UdfRuntime, UdfRuntimeConfig


def _binding(var u: UdfRef, library: String = ECHO_LIBRARY) raises -> ArcPointer[UdfBinding]:
    var rt = ArcPointer(UdfRuntime.open(UdfRuntimeConfig(library, List[String](), "")))
    var refs = List[UdfRef]()
    refs.append(u^)
    return ArcPointer(UdfBinding.bind(rt, refs))


def _instance(var u: UdfRef) raises -> UdfInstance:
    return UdfInstance(_binding(u^), 0, 0)


def _cols(var a: Column[HeapRegion]) -> List[Column[HeapRegion]]:
    var out = List[Column[HeapRegion]]()
    out.append(a^)
    return out^


def _cols2(var a: Column[HeapRegion], var b: Column[HeapRegion]) -> List[Column[HeapRegion]]:
    var out = List[Column[HeapRegion]]()
    out.append(a^)
    out.append(b^)
    return out^


def _call(mut inst: UdfInstance, ref args: List[Column[HeapRegion]], rows: Int) raises -> String:
    return render(read_int64(inst.call(args, rows)))


def _error(mut inst: UdfInstance, ref args: List[Column[HeapRegion]], rows: Int) -> String:
    try:
        _ = inst.call(args, rows)
    except e:
        return String(e)
    return String("answered")


def test_rows_in_equal_rows_out_with_nulls_kept_under_manual() raises:
    var inst = _instance(echo_ref("double", 1))
    var args = _cols(int64_column([Int64(1), 0, 3, 0, -5], [False, True]))
    assert_equal(_call(inst, args, 5), "[2, NULL, 6, 0, -10]")
    var none = _cols(int64_column(List[Int64](), List[Bool]()))
    assert_equal(_call(inst, none, 0), "[]")


def test_a_zero_argument_call_answers_every_row() raises:
    var inst = _instance(echo_ref("const7", 0))
    var args = List[Column[HeapRegion]]()
    assert_equal(_call(inst, args, 3), "[7, 7, 7]")


def test_propagate_gives_the_runtime_no_null_row() raises:
    var inst = _instance(echo_ref("add_strict", 2, null_mode=UDF_NULL_PROPAGATE))
    var args = _cols2(
        int64_column([Int64(1), 0, 3, 4, 5], [False, True]),
        int64_column([Int64(10), 20, 0, 40, 50], [False, False, True]),
    )
    assert_equal(_call(inst, args, 5), "[11, NULL, NULL, 44, 55]")
    # Without NULLs the columns go as they are.
    var full = _cols2(int64_column([Int64(1), 2], List[Bool]()), int64_column([Int64(3), 4], List[Bool]()))
    assert_equal(_call(inst, full, 2), "[4, 6]")


def test_manual_hands_the_null_row_to_the_runtime() raises:
    var inst = _instance(echo_ref("add_strict", 2))
    var args = _cols2(int64_column([Int64(1), 0], [False, True]), int64_column([Int64(1), 2], List[Bool]()))
    assert_equal(
        _error(inst, args, 2),
        "UDF_RAISED: UDF 0 (add_strict, komira-test/echo) (ERR_RAISED): a strict fixture got a null argument"
        " (row 1 of the batch)",
    )


def test_a_batch_of_null_rows_makes_no_call() raises:
    # lost_on_call loses its context on any call: an answer here is one
    # that never called it.
    var inst = _instance(echo_ref("lost_on_call", 1, null_mode=UDF_NULL_PROPAGATE, kind=UDF_REF_KIND_MAP_BATCHES_COLUMN))
    var args = _cols(int64_column([Int64(0), 0], [True, True]))
    assert_equal(_call(inst, args, 2), "[NULL, NULL]")


def test_a_raise_names_the_callers_row_through_the_compaction() raises:
    var inst = _instance(echo_ref("raise_on_row_3", 1, null_mode=UDF_NULL_PROPAGATE))
    # The runtime sees [1, 3] and raises on its row 1, which is row 3 here.
    var args = _cols(int64_column([Int64(0), 1, 0, 3], [True, False, True]))
    assert_equal(
        _error(inst, args, 4),
        "UDF_RAISED: UDF 0 (raise_on_row_3, komira-test/echo) (ERR_RAISED): raise_on_row_3: the value 3"
        " (row 3 of the batch)",
    )


def test_the_row_ceiling_cuts_the_batch_in_order() raises:
    var inst = _instance(echo_ref("double", 1, max_batch_rows=2))
    var args = _cols(int64_column([Int64(1), 2, 3, 4, 5], List[Bool]()))
    assert_equal(_call(inst, args, 5), "[2, 4, 6, 8, 10]")
    var raising = _instance(echo_ref("raise_on_row_3", 1, max_batch_rows=2))
    var three = _cols(int64_column([Int64(1), 2, 3, 4, 5], List[Bool]()))
    # 3 is row 0 of the second call, row 2 of the batch.
    assert_true(_error(raising, three, 5).endswith("the value 3 (row 2 of the batch)"))


def test_a_lost_context_refuses_every_later_call() raises:
    var inst = _instance(echo_ref("lost_on_call", 1, kind=UDF_REF_KIND_MAP_BATCHES_COLUMN))
    var args = _cols(int64_column([Int64(1)], List[Bool]()))
    var first = _error(inst, args, 1)
    assert_true(
        first.startswith("UDF_WORKER_CRASHED: UDF 0 (lost_on_call, komira-test/echo) (ERR_INSTANCE_LOST): "), first
    )
    assert_true(inst.lost() != "")
    var second = _error(inst, args, 1)
    assert_true(
        second.startswith("UDF_WORKER_CRASHED: UDF 0 (lost_on_call, komira-test/echo): the worker of this call is lost (ERR_INSTANCE_LOST: "),
        second,
    )


def test_each_post_condition_is_named() raises:
    var short = _instance(echo_ref("short_by_one", 1, kind=UDF_REF_KIND_MAP_BATCHES_COLUMN))
    var three = _cols(int64_column([Int64(1), 2, 3], List[Bool]()))
    assert_equal(
        _error(short, three, 3),
        "UDF_BATCH_LENGTH_MISMATCH: UDF 0 (short_by_one, komira-test/echo) returned 2 rows for a batch of 3",
    )
    var nulls = _instance(echo_ref("null_out", 1, nullable_result=False))
    assert_equal(
        _error(nulls, three, 3),
        "UDF_RETURN_TYPE_MISMATCH: UDF 0 (null_out, komira-test/echo) returned 3 NULL rows, and its return"
        " type int64 is not nullable",
    )
    var inst = _instance(echo_ref("double", 1))
    var b = ColumnBuilder[DType.int32].with_capacity(0)
    b.append(1)
    var narrow = _cols(b^.materialize())
    assert_true(
        _error(inst, narrow, 1).startswith("OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH: UDF 0 (double, komira-test/echo): argument 0 is "),
    )
    var two = _cols2(int64_column([Int64(1)], List[Bool]()), int64_column([Int64(1)], List[Bool]()))
    assert_equal(
        _error(inst, two, 1),
        "OPTIMIZED_UDF_ARGUMENT_TYPE_MISMATCH: UDF 0 (double, komira-test/echo) takes 1 arguments, and the call"
        " passes 2",
    )


def test_each_abi_fault_of_the_output_is_named() raises:
    var one = _cols(int64_column([Int64(1), 2], List[Bool]()))
    var layout = _instance(echo_ref("bad_layout", 1))
    assert_true(_error(layout, one, 2).startswith("UDF_RUNTIME_FAULT: UDF 0 (bad_layout, komira-test/echo): "))
    var device = _instance(echo_ref("device_not_cpu", 1))
    assert_equal(
        _error(device, one, 2),
        "UDF_RUNTIME_FAULT: UDF 0 (device_not_cpu, komira-test/echo): the output is on device 2/-1, not the CPU",
    )
    var empty = _instance(echo_ref("ok_without_output", 1))
    assert_equal(
        _error(empty, one, 2),
        "UDF_RUNTIME_FAULT: UDF 0 (ok_without_output, komira-test/echo): call_batch returned OK with no output array",
    )
    var kept = _instance(echo_ref("args_kept", 1))
    assert_equal(
        _error(kept, one, 2),
        "UDF_RUNTIME_FAULT: UDF 0 (args_kept, komira-test/echo): call_batch did not move its args",
    )
    var set_out = _instance(echo_ref("out_set_on_error", 1))
    assert_equal(
        _error(set_out, one, 2),
        "UDF_RAISED: UDF 0 (out_set_on_error, komira-test/echo) (ERR_RAISED): out_set_on_error: raised with out"
        " still set; and call_batch set its output on a failure",
    )


def _instance_error(variant: String) -> String:
    _ = setenv("KOMIRA_UDF_ECHO_VARIANT", variant)
    var got = String("opened")
    try:
        var b = _binding(echo_ref("double", 1), "./echo_variant.so")
        _ = UdfInstance(b, 0, 0)
    except e:
        got = String(e)
    _ = unsetenv("KOMIRA_UDF_ECHO_VARIANT")
    return got^


def test_a_refused_context_or_instance_is_named() raises:
    var got = _instance_error("context_refused")
    assert_true(got.startswith("UDF_RUNTIME_FAULT: UDF 0 (double, komira-test/echo): open_context refused ("), got)
    got = _instance_error("instance_refused")
    assert_true(got.startswith("UDF_RUNTIME_FAULT: UDF 0 (double, komira-test/echo): open_instance refused ("), got)


def main() raises:
    var suite = TestSuite()
    suite.test[test_rows_in_equal_rows_out_with_nulls_kept_under_manual]()
    suite.test[test_a_zero_argument_call_answers_every_row]()
    suite.test[test_propagate_gives_the_runtime_no_null_row]()
    suite.test[test_manual_hands_the_null_row_to_the_runtime]()
    suite.test[test_a_batch_of_null_rows_makes_no_call]()
    suite.test[test_a_raise_names_the_callers_row_through_the_compaction]()
    suite.test[test_the_row_ceiling_cuts_the_batch_in_order]()
    suite.test[test_a_lost_context_refuses_every_later_call]()
    suite.test[test_each_post_condition_is_named]()
    suite.test[test_each_abi_fault_of_the_output_is_named]()
    suite.test[test_a_refused_context_or_instance_is_named]()
    suite^.run()
