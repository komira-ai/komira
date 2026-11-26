"""A user function the SDK captured and the plan encoder wrote runs in the
komira/python runtime and gives the values the function gives when called
directly. The runtime's spec is built from the plan's UdfRef alone (entry,
shape, descriptor, code digest, argument and return types), the code object is
written to the code root by `write_code`, and no engine sits between them.

    test_udf_plan_run.py --lib-dir <dir>

`<dir>/libkomira_udf_python.so` (`libkomira_udf_python.dylib` on macOS) is
`//src/udf_python:komira_udf_python`.
"""

import datetime
import decimal
import hashlib
import math
import os
import sys

import pyarrow as pa

import udf_host as h
from fixtures.udfs import runtime as fx
from komira._capture import write_code
from komira._ops import ColRef, Field, Project, Scan
from komira._plan import encode_plan, parquet_source
from komira.plan.v1 import plan_pb2 as pb
from komira.plan.v1 import plan_vocabulary_pb2 as vocab

I64, F64 = pa.int64(), pa.float64()
I64_MIN, I64_MAX = -(2**63), 2**63 - 1

_SHAPES = {
    pb.SCALAR: h.SHAPE_SCALAR,
    pb.ROW: h.SHAPE_ROW,
    pb.MAP_BATCHES_COLUMN: h.SHAPE_MAP_BATCHES_COLUMN,
    pb.MAP_BATCHES_FRAME: h.SHAPE_MAP_BATCHES_FRAME,
}
_NULL_MODES = {pb.UDF_NULL_MANUAL: h.NULL_MANUAL, pb.UDF_NULL_PROPAGATE: h.NULL_PROPAGATE}
_FORMS = {pb.PACKAGE: h.FORM_PACKAGE, pb.BUNDLE: h.FORM_BUNDLE}
_LEAVES = {
    "bool": pa.bool_(), "int8": pa.int8(), "int16": pa.int16(), "int32": pa.int32(), "int64": I64,
    "float32": pa.float32(), "float64": F64, "string": pa.string(), "large_string": pa.large_string(),
    "binary": pa.binary(), "large_binary": pa.large_binary(), "date32": pa.date32(),
}
_NUMERIC = ("bool", "int8", "int16", "int32", "int64", "float32", "float64")


def type_id(name):
    """The raw Arrow type id of the plan wire's type `name`."""
    return getattr(vocab, "ARROW_TYPE_" + name.upper()) - 1


def type_name(t):
    """The plan wire's name of the pyarrow type `t`."""
    if pa.types.is_timestamp(t):
        return "timestamp_" + t.unit
    if pa.types.is_decimal(t):
        return "decimal128"
    if pa.types.is_large_list(t):
        return "large_list"
    if pa.types.is_list(t):
        return "list"
    if pa.types.is_struct(t):
        return "struct"
    for name, leaf in _LEAVES.items():
        if t == leaf:
            return name
    raise AssertionError("no plan wire name for %s" % t)


def column(name, t):
    """The WireField of a scan column of the pyarrow type `t`: its decimal
    precision and scale, its time zone and, for a list or struct, its flat
    children."""
    kind = type_name(t)
    if kind in _NUMERIC:
        code = getattr(vocab, "_DT_" + kind.upper())
    elif kind.startswith("timestamp_"):
        code = vocab._DT_INT64
    else:
        code = vocab._DT_INVALID
    f = pb.WireField(name=name, arrow_type_id=type_id(kind), nullable=True, dict_index_type_id=4, dtype_code=code)
    if pa.types.is_decimal(t):
        f.decimal_precision, f.decimal_scale = t.precision, t.scale
    if pa.types.is_timestamp(t) and t.tz is not None:
        f.tz = t.tz
    if pa.types.is_list(t) or pa.types.is_large_list(t):
        children = [t.value_field]
    elif pa.types.is_struct(t):
        children = [t.field(i) for i in range(t.num_fields)]
    else:
        children = []
    for child in children:
        f.child_names.append(child.name)
        f.child_type_ids.append(type_id(type_name(child.type)))
        f.child_nullables.append(child.nullable)
    return f


def scan(path, *columns):
    fields = tuple(Field(n, type_name(t)) for n, t in columns)
    schema = pb.WireSchema(fields=[column(n, t) for n, t in columns])
    return Scan(path, "parquet", fields), {path: parquet_source(path, schema.SerializeToString())}


def arrow_type(wire_field):
    """The pyarrow type of a WireField: its type id, its parameters and its flat
    children."""
    name = vocab.ArrowType.Name(wire_field.arrow_type_id + 1).removeprefix("ARROW_TYPE_").lower()
    if name.startswith("timestamp_"):
        return pa.timestamp(name.removeprefix("timestamp_"), tz=wire_field.tz or None)
    if name == "decimal128":
        return pa.decimal128(wire_field.decimal_precision, wire_field.decimal_scale)
    if name in ("list", "large_list", "struct"):
        children = [
            pa.field(n, arrow_type(pb.WireField(arrow_type_id=i)), nullable=null)
            for n, i, null in zip(wire_field.child_names, wire_field.child_type_ids, wire_field.child_nullables)
        ]
        if name == "struct":
            return pa.struct(children)
        return (pa.large_list if name == "large_list" else pa.list_)(children[0])
    return _LEAVES[name]


def planned_ref(env, fn, *columns, scan_columns=(("a", I64), ("b", I64))):
    """The only UdfRef of `Project(scan, fn.expr(columns))`, encoded, with the
    function's code written to the env's code root."""
    node, sources = scan(env.path("t.parquet"), *scan_columns)
    plan = Project(node, (("out", fn.expr(*[ColRef(c) for c in columns])),))
    envelope = encode_plan(plan, sources)
    assert len(envelope.udfs) == 1
    write_code(env.code_root, fn)
    return envelope.udfs[0]


def spec_from(env, ref, desc=None, code_root=None):
    """The runtime's spec of `ref`, from nothing but the UdfRef."""
    return h.Spec(
        ref.code.entry,
        shape=_SHAPES[ref.kind],
        form=_FORMS[ref.code.form],
        args=[("a%d" % i, arrow_type(f)) for i, f in enumerate(ref.arg_types)],
        result=arrow_type(ref.return_type),
        null_mode=_NULL_MODES[ref.null_mode],
        code=[(c.role, c.sha256) for c in ref.code.code],
        code_root=env.code_root if code_root is None else code_root,
        desc=ref.code.descriptor if desc is None else desc,
        descriptor_version=ref.code.descriptor_version,
    )


def instance_of(env, ref):
    rt = env.runtime()
    udf = rt.load_ok(spec_from(env, ref))
    return rt, rt.open_context_ok().open_instance_ok(udf)


def same(got, want):
    """Equal lists, a NaN equal to a NaN."""
    assert len(got) == len(want), (got, want)
    for g, w in zip(got, want):
        if isinstance(w, float) and math.isnan(w):
            assert isinstance(g, float) and math.isnan(g), (got, want)
        else:
            assert g == w, (got, want)


def a_scalar_int64_function_gives_what_the_function_gives(env):
    ref = planned_ref(env, fx.double, "a")
    assert ref.kind == pb.SCALAR and ref.code.runtime == "komira/python"
    rt, inst = instance_of(env, ref)
    values = [0, 1, -1, 7, -300, I64_MAX // 2, I64_MIN // 2, None]
    out = inst.call_ok([pa.array(values, I64)])
    assert out.type == I64
    assert out.to_pylist() == [0, 2, -2, 14, -600, I64_MAX - 1, I64_MIN, None]
    assert out.to_pylist() == [fx.double(v) for v in values]
    assert inst.call_ok([pa.array([], I64)]).to_pylist() == []
    assert inst.call_ok([pa.array([None, None], I64)]).to_pylist() == [None, None]


def a_scalar_result_past_int64_is_refused_by_value_and_the_instance_goes_on(env):
    rt, inst = instance_of(env, planned_ref(env, fx.double, "a"))
    r = inst.call([pa.array([1, I64_MAX, I64_MIN], I64)])
    assert r.status == h.ERR_RETURN_TYPE and r.array is None, r.err
    assert r.err.message == "row 1 returned int 18446744073709551614, which is not int64 without loss", r.err
    assert r.err.row == 1
    assert inst.call_ok([pa.array([3], I64)]).to_pylist() == [6]


def a_scalar_float64_function_gives_what_the_function_gives(env):
    ref = planned_ref(env, fx.halve, "z", scan_columns=(("z", F64),))
    assert ref.return_type.arrow_type_id == ref.arg_types[0].arrow_type_id
    rt, inst = instance_of(env, ref)
    inf = float("inf")
    values = [0.0, 1.0, -3.0, 0.5, 1e308, -1e308, 5e-324, inf, -inf, float("nan"), None]
    out = inst.call_ok([pa.array(values, F64)])
    assert out.type == F64
    same(out.to_pylist(), [0.0, 0.5, -1.5, 0.25, 5e307, -5e307, 0.0, inf, -inf, float("nan"), None])
    same(out.to_pylist(), [fx.halve(v) for v in values])


def a_column_function_over_arrow_arrays_gives_what_the_function_gives(env):
    ref = planned_ref(env, fx.mapped_double, "a")
    assert ref.kind == pb.MAP_BATCHES_COLUMN
    rt, inst = instance_of(env, ref)
    values = [0, 5, -5, I64_MAX // 2, I64_MIN // 2, None]
    out = inst.call_ok([pa.array(values, I64)])
    assert out.type == I64
    assert out.to_pylist() == [0, 10, -10, I64_MAX - 1, I64_MIN, None]
    assert out.equals(fx.mapped_double(pa.array(values, I64)))
    assert inst.call_ok([pa.array([], I64)]).to_pylist() == []


def one_changed_byte_of_the_entry_in_the_descriptor_is_refused(env):
    ref = planned_ref(env, fx.double, "a")
    entry = ref.code.entry
    desc = bytearray(ref.code.descriptor)
    assert bytes(desc[2:2 + len(entry)]) == entry.encode()
    desc[1 + len(entry)] ^= 0x01
    changed = bytes(desc[2:2 + len(entry)]).decode()
    assert changed != entry
    rt = env.runtime()
    status, err = rt.validate(spec_from(env, ref, desc=bytes(desc)))
    assert status == h.ERR_DESCRIPTOR
    assert err.message == "descriptor entry '%s' differs from the UDF's entry '%s'" % (changed, entry), err
    status, udf, err = rt.load(spec_from(env, ref, desc=bytes(desc)))
    assert status == h.ERR_DESCRIPTOR and udf is None, err
    assert rt.validate(spec_from(env, ref))[0] == h.OK


def a_code_object_with_other_bytes_than_its_digest_is_not_loaded(env):
    ref = planned_ref(env, fx.double, "a")
    digest = ref.code.code[0].sha256
    path = os.path.join(env.code_root, digest.hex())
    other = h.make_zip({"fixtures/udfs/runtime.py": "raise SystemExit\n"})
    with open(path, "wb") as f:
        f.write(other)
    rt = env.runtime()
    status, udf, err = rt.load(spec_from(env, ref))
    assert (status, udf) == (h.ERR_CODE_DIGEST, None)
    assert err.message == "code object bundle %s: the bytes' sha256 is %s" % (
        digest.hex(), hashlib.sha256(other).hexdigest()), err


def the_row_function_descriptor_is_refused_by_the_field_it_writes(env):
    ref = planned_ref(env, fx.row_sum, scan_columns=(("a", I64), ("b", I64)))
    assert ref.kind == pb.ROW
    rt = env.runtime()
    status, err = rt.validate(spec_from(env, ref))
    assert status == h.ERR_UNSUPPORTED
    assert err.message == "descriptor field 6 (recorded_fields) is not read by this build of komira/python", err


def check_return(ref, name, precision=0, scale=0, tz="", children=()):
    """The facts of the UdfRef's return field: its type id, its parameters and
    its flat child lists, and no `children` (a column type has none)."""
    r = ref.return_type
    assert (r.name, r.arrow_type_id, r.nullable) == ("out", type_id(name), True), r
    assert (r.decimal_precision, r.decimal_scale, r.tz) == (precision, scale, tz), r
    assert list(zip(r.child_names, r.child_type_ids, r.child_nullables)) == [
        (n, type_id(t), True) for n, t in children], r
    assert len(r.children) == 0, r


def gives(inst, fn, columns, want_type):
    """Call `inst` on the `columns` ([(values, pyarrow type)]), and check the
    output has `want_type` and the values `fn` gives called directly on each row."""
    out = inst.call_ok([pa.array(v, t) for v, t in columns])
    rows = list(zip(*[v for v, _ in columns]))
    want = pa.array([fn(*row) for row in rows], want_type)
    assert out.type == want_type, out.type
    assert out.equals(want), (out.to_pylist(), want.to_pylist())
    return out


def a_str_function_returns_large_string_and_gives_what_the_function_gives(env):
    ref = planned_ref(env, fx.shout, "s", scan_columns=(("s", pa.string()),))
    check_return(ref, "large_string")
    rt, inst = instance_of(env, ref)
    values = ["abc", "", None, "h\u00e9llo w\u00f6rld", "\u65e5\u672c\u8a9e", "\U0001F600", "x" * 1000]
    out = gives(inst, fx.shout, [(values, pa.string())], pa.large_string())
    assert out.to_pylist()[0] == "ABC!"
    gives(inst, fx.shout, [([], pa.string())], pa.large_string())


def a_bytes_function_returns_large_binary_and_gives_what_the_function_gives(env):
    ref = planned_ref(env, fx.tagged, "s", scan_columns=(("s", pa.string()),))
    check_return(ref, "large_binary")
    rt, inst = instance_of(env, ref)
    out = gives(inst, fx.tagged, [(["a", "", None, "\u00e9"], pa.string())], pa.large_binary())
    assert out.to_pylist() == [b"a\x00", b"\x00", None, b"\xc3\xa9\x00"]


def a_bool_function_returns_bool_and_gives_what_the_function_gives(env):
    ref = planned_ref(env, fx.is_positive, "a")
    check_return(ref, "bool")
    rt, inst = instance_of(env, ref)
    out = gives(inst, fx.is_positive, [([1, 0, -1, None, I64_MAX, I64_MIN], I64)], pa.bool_())
    assert out.to_pylist() == [True, False, False, None, True, False]
    gives(inst, fx.is_positive, [([i - 10 for i in range(20)], I64)], pa.bool_())


def a_date_function_returns_date32_and_gives_what_the_function_gives(env):
    ref = planned_ref(env, fx.next_day, "d", scan_columns=(("d", pa.date32()),))
    check_return(ref, "date32")
    assert arrow_type(ref.arg_types[0]) == pa.date32()
    rt, inst = instance_of(env, ref)
    days = [datetime.date(2027, 2, 28), datetime.date(2028, 2, 28), None, datetime.date(1969, 12, 31)]
    out = gives(inst, fx.next_day, [(days, pa.date32())], pa.date32())
    assert out.to_pylist() == [datetime.date(2027, 3, 1), datetime.date(2028, 2, 29), None,
                               datetime.date(1970, 1, 1)]


def a_datetime_function_returns_a_microsecond_timestamp_and_gives_what_the_function_gives(env):
    ref = planned_ref(env, fx.at_noon, "d", scan_columns=(("d", pa.date32()),))
    check_return(ref, "timestamp_us")
    assert arrow_type(ref.return_type) == pa.timestamp("us")
    rt, inst = instance_of(env, ref)
    days = [datetime.date(2027, 2, 28), None, datetime.date(1, 1, 1), datetime.date(9999, 12, 31)]
    out = gives(inst, fx.at_noon, [(days, pa.date32())], pa.timestamp("us"))
    assert out.to_pylist()[0] == datetime.datetime(2027, 2, 28, 12)


def a_decimal_function_with_a_declared_return_type_gives_what_the_function_gives(env):
    d = decimal.Decimal
    ref = planned_ref(env, fx.with_fee, "p", scan_columns=(("p", pa.decimal128(10, 2)),))
    check_return(ref, "decimal128", precision=12, scale=2)
    assert arrow_type(ref.arg_types[0]) == pa.decimal128(10, 2)
    assert arrow_type(ref.return_type) == pa.decimal128(12, 2)
    rt, inst = instance_of(env, ref)
    prices = [d("0.00"), d("12.34"), d("-99999999.99"), None, d("99999999.99"), d("0.01")]
    out = gives(inst, fx.with_fee, [(prices, pa.decimal128(10, 2))], pa.decimal128(12, 2))
    assert out.to_pylist() == [d("0.50"), d("25.18"), d("-199999999.48"), None, d("200000000.48"), d("0.52")]


def a_list_function_returns_large_list_and_gives_what_the_function_gives(env):
    ref = planned_ref(env, fx.three_from, "a")
    check_return(ref, "large_list", children=[("item", "int64")])
    assert arrow_type(ref.return_type) == pa.large_list(pa.int64())
    rt, inst = instance_of(env, ref)
    out = gives(inst, fx.three_from, [([0, -5, None, I64_MAX - 2], I64)], pa.large_list(pa.int64()))
    assert out.to_pylist() == [[0, 1, 2], [-5, -4, -3], None, [I64_MAX - 2, I64_MAX - 1, I64_MAX]]
    gives(inst, fx.three_from, [([], I64)], pa.large_list(pa.int64()))


def a_typed_dict_function_returns_a_struct_and_gives_what_the_function_gives(env):
    ref = planned_ref(env, fx.pair_of, "a", "s", scan_columns=(("a", I64), ("s", pa.string())))
    check_return(ref, "struct", children=[("a", "int64"), ("b", "large_string")])
    want = pa.struct([("a", pa.int64()), ("b", pa.large_string())])
    assert arrow_type(ref.return_type) == want
    rt, inst = instance_of(env, ref)
    out = gives(inst, fx.pair_of, [([1, None, 3, 4], I64), (["x", "y", None, ""], pa.string())], want)
    assert out.to_pylist() == [{"a": 1, "b": "x"}, None, None, {"a": 4, "b": ""}]


def a_declared_zoned_timestamp_gives_what_the_function_gives(env):
    ref = planned_ref(env, fx.instant, "a")
    check_return(ref, "timestamp_ms", tz="UTC")
    want = pa.timestamp("ms", tz="UTC")
    assert arrow_type(ref.return_type) == want
    rt, inst = instance_of(env, ref)
    out = gives(inst, fx.instant, [([0, 1700000000123, -1, None], I64)], want)
    assert out.cast(pa.int64()).to_pylist() == [0, 1700000000123, -1, None]


def a_function_of_three_columns_gives_what_the_function_gives(env):
    d = decimal.Decimal
    columns = (("a", I64), ("s", pa.string()), ("p", pa.decimal128(10, 2)))
    ref = planned_ref(env, fx.label, "a", "s", "p", scan_columns=columns)
    check_return(ref, "large_string")
    assert [arrow_type(f) for f in ref.arg_types] == [t for _, t in columns]
    rt, inst = instance_of(env, ref)
    data = [
        ([1, 2, None, 4, 5], I64),
        (["x", None, "z", "", "w\u00e9"], pa.string()),
        ([d("1.50"), d("2.00"), d("3.00"), None, d("-0.01")], pa.decimal128(10, 2)),
    ]
    out = gives(inst, fx.label, data, pa.large_string())
    assert out.to_pylist() == ["1/x/1.50", None, None, None, "5/w\u00e9/-0.01"]


def list_and_struct_columns_are_carried_as_arguments(env):
    items = pa.list_(pa.int64())
    ref = planned_ref(env, fx.total_of, "xs", scan_columns=(("xs", items),))
    assert arrow_type(ref.arg_types[0]) == items
    assert list(ref.arg_types[0].child_names) == ["item"]
    rt, inst = instance_of(env, ref)
    gives(inst, fx.total_of, [([[1, 2], [], None, [None, 5]], items)], pa.int64())
    rec = pa.struct([("a", pa.int64()), ("b", pa.string())])
    ref = planned_ref(env, fx.pair_label, "p", scan_columns=(("p", rec),))
    assert arrow_type(ref.arg_types[0]) == rec
    rt, inst = instance_of(env, ref)
    out = gives(inst, fx.pair_label, [([{"a": 1, "b": "k"}, None, {"a": 2, "b": "j"}], rec)], pa.large_string())
    assert out.to_pylist() == ["k=1", None, "j=2"]


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    me = sys.modules["__main__"]
    cases = [f for f in (getattr(me, n) for n in dir(me))
             if getattr(f, "__module__", None) == "__main__" and callable(f)
             and getattr(f, "__code__", None) is not None
             and f.__code__.co_argcount == 1 and f.__code__.co_varnames[0] == "env"]
    for case in cases:
        with h.Env(lib_dir) as env:
            case(env)
        print("ok", case.__name__)


if __name__ == "__main__":
    main(sys.argv[1:])
