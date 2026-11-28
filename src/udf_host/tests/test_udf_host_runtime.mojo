# Opening a UDF runtime and binding a plan's UDFs on it (runtime.mojo), on
# the reference runtime komira-test/echo (echo.so) and on echo_variant.so,
# which breaks one thing in its table or answers, chosen by
# KOMIRA_UDF_ECHO_VARIANT (the fixture library's own selector: it has no
# argv). Every refusal is asserted by its code and the facts its text names.
#
# What it proves:
#   - a runtime opens, and its describe answer is kept: runtime id and the
#     shape bits;
#   - each way opening refuses is a named error, not a crash or a runtime
#     left half open: a library that is not there, an init that refuses, a
#     table of another major or too short, a describe that fails;
#   - binding admits a UDF only when it names this runtime, is a kind this
#     engine hosts and the runtime reports, has a return type, a
#     NULL_PROPAGATE return type the host can place, and every code object
#     it names is a file of the code root, all before the runtime is asked;
#     then validate and load refusals carry the runtime's message under the
#     error table's code;
#   - a UDF bound with its code object present loads, and the binding hands
#     out copies of its UdfRefs by index.
# Catches: an admission check skipped (the runtime would then be asked about
# a UDF of another runtime, or a worker would start for code that is not
# there); a status mapped to the wrong code; an open that leaves the
# runtime running after a refusal it raises.

from std.memory import ArcPointer
from std.os import setenv, unsetenv
from std.testing import TestSuite, assert_equal, assert_true

from plan_expr.udf_data import UDF_NULL_PROPAGATE
from plan_expr.udf_type import UdfType
from arrow.arrow_types import ArrowType
from plan_ir.udf_ref import UDF_REF_KIND_AGGREGATE, UdfRef
from runtime_paths import test_tmpdir

from komira_test_udf_host.echo_udfs import ECHO_LIBRARY, bundle_ref, echo_ref
from udf_host.runtime import UdfBinding, UdfRuntime, UdfRuntimeConfig, spec_values

comptime VARIANT_LIBRARY = "./echo_variant.so"


def _open(library: String, code_root: String = "") raises -> UdfRuntime:
    return UdfRuntime.open(UdfRuntimeConfig(library, List[String](), code_root))


def _open_error(library: String) -> String:
    try:
        _ = _open(library)
    except e:
        return String(e)
    return String("opened")


def _variant_error(variant: String) -> String:
    _ = setenv("KOMIRA_UDF_ECHO_VARIANT", variant)
    var got = _open_error(VARIANT_LIBRARY)
    _ = unsetenv("KOMIRA_UDF_ECHO_VARIANT")
    return got^


def _bind_error(var u: UdfRef, code_root: String = "") raises -> String:
    var rt = ArcPointer(_open(ECHO_LIBRARY, code_root))
    var refs = List[UdfRef]()
    refs.append(u^)
    try:
        _ = UdfBinding.bind(rt, refs)
    except e:
        return String(e)
    return String("bound")


def test_a_runtime_opens_with_its_describe_answer() raises:
    var rt = _open(ECHO_LIBRARY)
    assert_equal(rt.runtime_id, "komira-test/echo")
    assert_true((rt.shapes & 1) != 0, "SCALAR")
    assert_true((rt.shapes & 4) != 0, "MAP_BATCHES_COLUMN")
    assert_equal(rt.config.deadline_ms(), 600000)
    var bounded = UdfRuntimeConfig(ECHO_LIBRARY, List[String](), "", 5)
    assert_equal(bounded.deadline_ms(), 5)


def test_a_library_that_does_not_load_is_refused_by_name() raises:
    var got = _open_error("./no_such_runtime.so")
    assert_true(got.startswith("UDF_RUNTIME_OPEN_FAILED: ./no_such_runtime.so: "), got)


def test_each_refusal_of_opening_is_named() raises:
    # No variant named: the variant init refuses with ERR_INTERNAL.
    var got = _open_error(VARIANT_LIBRARY)
    assert_true(
        got.startswith("UDF_RUNTIME_INIT_REFUSED: the UDF runtime ./echo_variant.so refused init (ERR_INTERNAL): "),
        got,
    )
    got = _variant_error("table_major_2")
    assert_true(got.startswith("UDF_RUNTIME_ABI_MISMATCH: the UDF runtime ./echo_variant.so has a table of major 2 and "), got)
    got = _variant_error("table_short")
    assert_true(got.startswith("UDF_RUNTIME_ABI_MISMATCH: the UDF runtime ./echo_variant.so has a table of major 1 and "), got)
    assert_true(got.endswith("this engine needs major 1 and 176 bytes"), got)
    got = _variant_error("describe_fails")
    assert_equal(got, "UDF_RUNTIME_FAULT: the UDF runtime ./echo_variant.so answered describe with ERR_INTERNAL")


def test_admission_refuses_before_the_runtime_is_asked() raises:
    var got = _bind_error(echo_ref("double", 1, runtime="komira/python"))
    assert_equal(
        got,
        "OPTIMIZED_ENV_RUNTIME_MISSING: UDF 0 (double, komira/python) needs the runtime komira/python,"
        " and this session holds komira-test/echo",
    )
    got = _bind_error(echo_ref("sum", 1, kind=UDF_REF_KIND_AGGREGATE))
    assert_equal(
        got,
        "OPTIMIZED_UDF_KIND_UNSUPPORTED: UDF 0 (sum, komira-test/echo) is a AGGREGATE call; this engine runs"
        " SCALAR and MAP_BATCHES_COLUMN calls the runtime reports",
    )
    var no_return = echo_ref("double", 1)
    no_return.return_type = None
    got = _bind_error(no_return^)
    assert_equal(got, "OPTIMIZED_UDF_RETURN_TYPE_MISSING: UDF 0 (double, komira-test/echo) has no return type")
    var decimal = echo_ref("double", 1, null_mode=UDF_NULL_PROPAGATE)
    decimal.return_type = Optional(UdfType("out", ArrowType.DECIMAL128, DType.int64, True))
    got = _bind_error(decimal^)
    assert_true(got.startswith("UDF_NULL_PROPAGATE_UNSUPPORTED: UDF 0 (double, komira-test/echo) returns "), got)


def test_a_missing_code_object_is_named_by_its_digest() raises:
    var root = test_tmpdir()
    var digest: List[UInt8] = [UInt8(0xAB), UInt8(0x01)]
    var got = _bind_error(bundle_ref("double", digest), root)
    assert_equal(
        got,
        "OPTIMIZED_ENV_CODE_MISSING: UDF 0 (double, komira-test/echo) needs the code object ab01 (bundle),"
        " and the code root " + root + " has no such file",
    )
    # With the file there, the UDF loads (echo finds its code by the entry).
    with open(root + "/ab01", "w") as f:
        f.write("code")
    assert_equal(_bind_error(bundle_ref("double", digest), root), "bound")


def test_validate_and_load_refusals_carry_the_runtimes_message() raises:
    var bad = echo_ref("double", 1)
    bad.code.descriptor = List[UInt8]()
    var got = _bind_error(bad^)
    assert_true(
        got.startswith("OPTIMIZED_UDF_DESCRIPTOR_INVALID: UDF 0 (double, komira-test/echo) was refused by validate (ERR_DESCRIPTOR): "),
        got,
    )
    got = _bind_error(echo_ref("no_such_fixture", 1))
    assert_equal(
        got,
        "OPTIMIZED_UDF_CODE_UNLOADABLE: UDF 0 (no_such_fixture, komira-test/echo) did not load (ERR_LOAD):"
        " no code object holds the entry 'no_such_fixture'",
    )


def test_a_binding_holds_its_udfs_by_index() raises:
    var rt = ArcPointer(_open(ECHO_LIBRARY))
    var refs = List[UdfRef]()
    refs.append(echo_ref("double", 1))
    refs.append(echo_ref("add_strict", 2, null_mode=UDF_NULL_PROPAGATE))
    var b = UdfBinding.bind(rt, refs)
    assert_equal(b.count(), 2)
    assert_equal(b.ref_at(1).code.entry, "add_strict")
    assert_equal(b.name_of(0), "UDF 0 (double, komira-test/echo)")
    assert_equal(len(b.refs()), 2)
    assert_equal(b.runtime()[].runtime_id, "komira-test/echo")
    var empty = UdfBinding()
    assert_equal(empty.count(), 0)


def test_a_spec_is_in_the_abis_numbering() raises:
    var v = spec_values(echo_ref("add_strict", 2, null_mode=UDF_NULL_PROPAGATE), "/code")
    assert_equal(v.shape, 1)
    assert_equal(v.form, 1, "PACKAGE")
    assert_equal(v.null_mode, 2, "PROPAGATE")
    assert_equal(v.stability, 2, "STABLE")
    assert_equal(v.args.num_columns(), 2)
    assert_equal(v.code_root, "/code")
    var b = spec_values(bundle_ref("double", [UInt8(7)]), "")
    assert_equal(b.form, 2, "BUNDLE")
    assert_equal(b.null_mode, 1, "MANUAL")
    assert_equal(len(b.digests), 1)


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_runtime_opens_with_its_describe_answer]()
    suite.test[test_a_library_that_does_not_load_is_refused_by_name]()
    suite.test[test_each_refusal_of_opening_is_named]()
    suite.test[test_admission_refuses_before_the_runtime_is_asked]()
    suite.test[test_a_missing_code_object_is_named_by_its_digest]()
    suite.test[test_validate_and_load_refusals_carry_the_runtimes_message]()
    suite.test[test_a_binding_holds_its_udfs_by_index]()
    suite.test[test_a_spec_is_in_the_abis_numbering]()
    suite^.run()
