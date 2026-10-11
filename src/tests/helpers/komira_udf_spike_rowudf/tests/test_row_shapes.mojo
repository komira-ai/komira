# What python_row.so (komira-test/python-row) declares, and the UDF
# references validate and open_instance accept or refuse, through the C ABI
# only (komira_udf_spike_abi's harness).
#
# What it proves, and the defect each part catches:
#   - describe's every field, so a runtime that declares another class,
#     transport, hosting, device, feature or descriptor version is caught;
#   - the spec checks that need no interpreter: code form VALUE and an
#     unknown form refused, PACKAGE and BUNDLE accepted; an entry with no
#     colon, an empty module or function, or two colons; a descriptor version
#     past 0 or descriptor bytes; a state type; a read-set field or a result
#     of a type it does not map (int32); an empty read set accepted. Each
#     refusal by its exact message, with row and group -1 (a refusal that
#     reports a row);
#   - the source checks (validate reads the source, never runs it): return
#     hints as a name, a string, `X | None`, Optional[X] and typing.Optional
#     accepted; None, str, a list, `float & None`, `float | 3` and an
#     unparsable string refused; *args, **kwargs and keyword-only
#     parameters refused; async refused; a module not on the path and one
#     that does not parse refused; a function found in a package's
#     __init__.py and in a submodule;
#   - open_instance checks the imported object: a name rebound after its def
#     to a function of two rows, one hinted list[float] or int | str, one
#     whose hint does not resolve, or a value, and a module that raises on
#     import: each ERR_LOAD by its exact message (a runtime that trusts
#     validate's reading of the source).
#
# Every single-point mutant of the runtime and the adapter was run against
# the runtime tests (the PR's mutation scorecard). One that this file kills:
# komira_udf_rowrt.py's `_check` without its `has_varargs` arm (with_varargs
# accepted): red.

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import (
    CLASS_MANAGED,
    CONTEXT_PER_THREAD,
    DEVICE_CPU,
    FORM_BUNDLE,
    FORM_PACKAGE,
    FORM_VALUE,
    HOSTING_EMBEDDED,
    SHAPE_ROW,
    TRANSPORT_IN_PROCESS,
    status_name,
)
from komira_udf_spike_abi.runtime import Outcome, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, ColumnType, TYPE_FLOAT64, TYPE_INT32, TYPE_INT64
from komira_udf_spike_python.calls import call_once
from komira_udf_spike_rowudf.read_sets import row_spec

comptime LIB = "./python_row.so"


def price(entry: String, result: Int = TYPE_FLOAT64) -> UdfSpec:
    var p: List[String] = ["price"]
    return row_spec(entry, p, TYPE_FLOAT64, result)


def refused_exactly(o: Outcome, status: String, message: String, what: String) raises:
    var w = what + ": " + String(o)
    assert_equal(status_name(o.status), status, w)
    assert_equal(o.message, message, w)
    assert_equal(o.row, Int64(-1), w)
    assert_equal(o.group, Int64(-1), w)


def refused_starting(o: Outcome, status: String, prefix: String, what: String) raises:
    var w = what + ": " + String(o)
    assert_equal(status_name(o.status), status, w)
    assert_true(o.message.startswith(prefix), w)
    assert_equal(o.row, Int64(-1), w)


def accepted(mut rt: UdfRuntime, spec: UdfSpec, what: String) raises:
    var o = rt.validate(spec)
    assert_equal(status_name(o.status), "OK", what + ": " + String(o))


def opened(mut rt: UdfRuntime, spec: UdfSpec) raises -> Outcome:
    """open_instance's outcome for `spec` (validate and load must pass)."""
    var u = rt.load(spec)
    assert_true(u.outcome.is_ok(), spec.entry + ": load: " + String(u.outcome))
    var ctx = rt.open_context(0)
    assert_true(ctx.outcome.is_ok(), String(ctx.outcome))
    var inst = rt.open_instance(ctx.handle, u.handle)
    var o = inst.outcome.copy()
    if o.is_ok():
        rt.close_instance(inst.handle)
    rt.close_context(ctx.handle)
    rt.unload(u.handle)
    return o^


def one_price(v: Float64) -> Batch:
    var b = Batch(1)
    var c = Column(TYPE_FLOAT64)
    c.append_float(v)
    b.columns.append(c^)
    return b^


def test_describe(mut rt: UdfRuntime) raises:
    var c = rt.describe()
    assert_equal(c.runtime_id, "komira-test/python-row")
    assert_equal(c.runtime_abi, "cp313")
    assert_equal(c.max_descriptor_version, 0)
    assert_equal(c.shapes, SHAPE_ROW)
    assert_equal(c.threading, CONTEXT_PER_THREAD)
    assert_equal(c.thread_affine, 1)
    assert_equal(c.transports, TRANSPORT_IN_PROCESS)
    assert_equal(c.hosting, HOSTING_EMBEDDED)
    assert_equal(c.devices, DEVICE_CPU)
    assert_equal(c.features, 0)
    assert_equal(c.udf_class, CLASS_MANAGED)
    assert_equal(c.global_lock, 0)
    assert_true(not c.has_memory_report)


def test_spec(mut rt: UdfRuntime) raises:
    var ok = price("udf_rows:price_qty")
    accepted(rt, ok, "BUNDLE")
    var s = ok.copy()
    s.form = FORM_PACKAGE
    accepted(rt, s, "PACKAGE")
    s.form = FORM_VALUE
    refused_exactly(
        rt.validate(s), "ERR_UNSUPPORTED", "code form VALUE (a serialized function) is not read by this runtime", "VALUE"
    )
    s.form = 7
    refused_exactly(rt.validate(s), "ERR_DESCRIPTOR", "code form is not PACKAGE, BUNDLE or VALUE", "form 7")
    for entry in ["udf_rows", ":price_qty", "udf_rows:", "udf_rows:price_qty:x"]:
        s = ok.copy()
        s.entry = entry
        refused_exactly(rt.validate(s), "ERR_DESCRIPTOR", "entry is not <module>:<function>", "entry " + entry)
    s = ok.copy()
    s.descriptor_version = 1
    refused_exactly(rt.validate(s), "ERR_DESCRIPTOR", "descriptor_version is newer than 0, the newest read here", "v1")
    s = ok.copy()
    s.descriptor.append(1)
    refused_exactly(
        rt.validate(s), "ERR_DESCRIPTOR", "descriptor version 0 is empty; these bytes are not canonical", "descriptor"
    )
    s = ok.copy()
    s.state = ColumnType(TYPE_INT64, True)
    refused_exactly(rt.validate(s), "ERR_UNSUPPORTED", "a state type is for aggregates", "state")
    var pq: List[String] = ["price", "qty"]
    s = row_spec("udf_rows:price_qty", pq, TYPE_FLOAT64, TYPE_FLOAT64)
    s.args[1] = ColumnType(TYPE_INT32, True)
    refused_exactly(rt.validate(s), "ERR_UNSUPPORTED", "a read-set field's type is not int64 or float64", "int32 field")
    s = ok.copy()
    s.result[0] = ColumnType(TYPE_INT32, True)
    refused_exactly(rt.validate(s), "ERR_UNSUPPORTED", "the result type is not int64 or float64", "int32 result")
    # A function that reads no field: an empty read set, and rows with no
    # column.
    var none = List[String]()
    s = row_spec("udf_checks:const_one", none, TYPE_FLOAT64, TYPE_FLOAT64)
    accepted(rt, s, "empty read set")
    var r = call_once(rt, s, Batch(3))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    assert_equal(len(r.column), 3)
    assert_equal(r.column.as_float(2), 1.0)


def test_hints(mut rt: UdfRuntime) raises:
    for name in ["str_hint", "str_optional", "optional_hint"]:
        accepted(rt, price("udf_shapes:" + name), name)
    accepted(rt, price("udf_shapes:typing_optional", TYPE_INT64), "typing_optional")
    var r = call_once(rt, price("udf_shapes:str_hint"), one_price(2.5))
    assert_true(r.outcome.is_ok() and r.column.as_float(0) == 2.5, String(r.outcome))
    for name in ["none_hint", "str_unparsable", "str_hinted", "str_and", "list_hint", "str_const_union"]:
        refused_exactly(
            rt.validate(price("udf_shapes:" + name)),
            "ERR_UNSUPPORTED",
            "udf_shapes:" + name + " has no return type hint this runtime maps to an Arrow type",
            name,
        )
    refused_exactly(
        rt.validate(price("udf_rows:price_qty", TYPE_INT64)),
        "ERR_UNSUPPORTED",
        "udf_rows:price_qty: the return type is hinted float64, declared int64",
        "result type",
    )
    refused_exactly(
        rt.validate(price("udf_shapes:typing_optional")),
        "ERR_UNSUPPORTED",
        "udf_shapes:typing_optional: the return type is hinted int64, declared float64",
        "result type int",
    )


def test_signatures(mut rt: UdfRuntime) raises:
    for name in ["with_varargs", "with_kwargs", "with_kwonly"]:
        refused_exactly(
            rt.validate(price("udf_shapes:" + name)),
            "ERR_UNSUPPORTED",
            "udf_shapes:" + name + ": a ROW function takes exactly one positional parameter, the row",
            name,
        )
    refused_exactly(
        rt.validate(price("udf_shapes:coroutine")),
        "ERR_UNSUPPORTED",
        "udf_shapes:coroutine is async; this runtime calls plain functions",
        "async",
    )


def test_modules(mut rt: UdfRuntime) raises:
    refused_exactly(
        rt.validate(price("nomod:f")), "ERR_DESCRIPTOR", "module nomod is not on the runtime's path", "no module"
    )
    refused_starting(rt.validate(price("not_python:f")), "ERR_DESCRIPTOR", "module not_python does not parse: ", "parse")
    refused_exactly(
        rt.validate(price("udf_shapes:absent")), "ERR_DESCRIPTOR", "module udf_shapes has no top-level function absent",
        "absent",
    )
    var r = call_once(rt, price("rowpkg:pkg_double"), one_price(1.5))
    assert_true(r.outcome.is_ok() and r.column.as_float(0) == 3.0, "package: " + String(r.outcome))
    r = call_once(rt, price("rowpkg.fns:fns_triple"), one_price(1.5))
    assert_true(r.outcome.is_ok() and r.column.as_float(0) == 4.5, "submodule: " + String(r.outcome))


def test_open_instance(mut rt: UdfRuntime) raises:
    refused_exactly(
        opened(rt, price("udf_shapes:rebound_two")),
        "ERR_LOAD",
        "udf_shapes:rebound_two: a ROW function takes exactly one positional parameter, the row",
        "rebound_two",
    )
    for name in ["rebound_list", "rebound_union"]:
        refused_exactly(
            opened(rt, price("udf_shapes:" + name)),
            "ERR_LOAD",
            "udf_shapes:" + name + " has no return type hint this runtime maps to an Arrow type",
            name,
        )
    refused_exactly(
        opened(rt, price("udf_shapes:rebound_unresolved")),
        "ERR_LOAD",
        "udf_shapes:rebound_unresolved: NameError: name 'Undefined' is not defined",
        "rebound_unresolved",
    )
    refused_exactly(
        opened(rt, price("udf_shapes:rebound_value")), "ERR_LOAD", "module udf_shapes has no function rebound_value",
        "rebound_value",
    )
    refused_exactly(
        opened(rt, price("bad_import:f")), "ERR_LOAD", "import bad_import: RuntimeError: refused at import", "import"
    )


def main() raises:
    var rt = UdfRuntime.open(LIB)
    test_describe(rt)
    test_spec(rt)
    test_hints(rt)
    test_signatures(rt)
    test_modules(rt)
    test_open_instance(rt)
    rt.shutdown()
    print("test_row_shapes: ok")
