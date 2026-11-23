"""A user function the SDK captured and the plan encoder wrote runs in the
komira/python runtime and gives the values the function gives when called
directly. The runtime's spec is built from the plan's UdfRef alone (entry,
shape, descriptor, code digest, argument and return types), the code object is
written to the code root by `write_code`, and no engine sits between them.

    test_udf_plan_run.py --lib-dir <dir>

`<dir>/libkomira_udf_python.so` is `//src/udf_python:komira_udf_python`.
"""

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
_ARROW = {"int32": pa.int32(), "int64": pa.int64(), "float64": pa.float64()}


def column(name, arrow):
    type_id = getattr(vocab, "ARROW_TYPE_" + arrow.upper()) - 1
    dtype = getattr(vocab, "_DT_" + arrow.upper())
    return pb.WireField(name=name, arrow_type_id=type_id, nullable=True, dict_index_type_id=4, dtype_code=dtype)


def scan(path, *columns):
    fields = tuple(Field(n, t) for n, t in columns)
    schema = pb.WireSchema(fields=[column(n, t) for n, t in columns])
    return Scan(path, "parquet", fields), {path: parquet_source(path, schema.SerializeToString())}


def arrow_type(wire_field):
    return _ARROW[vocab.ArrowType.Name(wire_field.arrow_type_id + 1).removeprefix("ARROW_TYPE_").lower()]


def planned_ref(env, fn, *columns, scan_columns=(("a", "int64"), ("b", "int64"))):
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
    ref = planned_ref(env, fx.halve, "z", scan_columns=(("z", "float64"),))
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
    ref = planned_ref(env, fx.row_sum, scan_columns=(("a", "int64"), ("b", "int64")))
    assert ref.kind == pb.ROW
    rt = env.runtime()
    status, err = rt.validate(spec_from(env, ref))
    assert status == h.ERR_UNSUPPORTED
    assert err.message == "descriptor field 6 (recorded_fields) is not read by this build of komira/python", err


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
