"""The komira/python runtime's contract before any process exists: init and its
options, describe, validate on every refusal of the descriptor subset, and the
calls that need a load first.

    test_udf_contract.py --lib-dir <dir>

`<dir>/libkomira_udf_python.so` (`libkomira_udf_python.dylib` on macOS) is
`//src/udf_python:komira_udf_python`.
"""

import os
import sys

import pyarrow as pa

import udf_host as h

PREFIX = "UDF_RUNTIME_OPTION_INVALID: komira/python: "


def refused(env, options, status, message, **kw):
    rt, err = h.Runtime.init(env.lib, options, **kw)
    assert rt is None
    assert (err.code, err.message) == (status, message), err


def init_refuses_each_bad_option_by_name(env):
    base = env.options
    bad = h.ERR_BAD_OPTION
    refused(env, base() + ["frob=1"], bad, PREFIX + "unknown option key 'frob'")
    refused(env, base() + ["frob"], bad, PREFIX + "option 'frob' is not key=value")
    refused(env, base(drop=["interpreter"]), bad, PREFIX + "required option 'interpreter' is missing")
    refused(env, base(drop=["zygote"]), bad, PREFIX + "required option 'zygote' is missing")
    refused(env, base(drop=["abi"]), bad, PREFIX + "required option 'abi' is missing")
    refused(env, base(drop=["scratch"]), bad, PREFIX + "required option 'scratch' is missing")
    refused(env, base(drop=["interpreter", "scratch"]), bad,
            PREFIX + "required option 'interpreter' is missing")
    refused(env, base() + ["abi=cp399"], bad, PREFIX + "option 'abi' is given twice")
    refused(env, base(interpreter="python"), bad, PREFIX + "option 'interpreter': not an absolute path")
    refused(env, base(zygote="zygote.py"), bad, PREFIX + "option 'zygote': not an absolute path")
    refused(env, base(abi="313"), bad, PREFIX + "option 'abi': not cp followed by digits")
    refused(env, base(abi="cp"), bad, PREFIX + "option 'abi': not cp followed by digits")
    refused(env, base(scratch=env.path("no_such_dir")), bad,
            PREFIX + "option 'scratch': not a directory")
    refused(env, base(scratch=env.trace.path), bad, PREFIX + "option 'scratch': not a directory")
    for value in ("-1", "3600001", "ten", "1.5"):
        refused(env, base(grace_ms=value), bad, PREFIX
                + "option 'grace_ms': not a whole number of milliseconds up to 3600000")


def init_accepts_the_optional_options_and_does_not_look_at_the_interpreter(env):
    for extra in ({"grace_ms": "0"}, {"grace_ms": "3600000"}, {"trace": None},
                  {"interpreter": env.path("no_such_python")}):
        rt, err = h.Runtime.init(env.lib, env.options(**extra))
        assert rt is not None, err
        rt.shutdown()
    assert env.trace.events() == [], "init started or traced a process"


def init_without_the_options_field_misses_the_first_required_key(env):
    # A host whose struct ends before `options` gives the runtime no options.
    refused(env, env.options(), h.ERR_BAD_OPTION,
            PREFIX + "required option 'interpreter' is missing",
            struct_size=h.HOST_SIZE_WITHOUT_OPTIONS)


def init_refuses_a_host_it_cannot_read(env):
    rt, err = h.Runtime.init(env.lib, env.options(), struct_size=h.HOST_SIZE_WITHOUT_OPTIONS - 8)
    assert rt is None
    assert (err.code, err.message) == (
        h.ERR_ABI, "komira/python needs a komira_udf_host of ABI 1.0"), err
    rt, err = h.Runtime.init(env.lib, env.options(), abi_major=2)
    assert rt is None and err.code == h.ERR_ABI, err
    rt, err = h.Runtime.init(env.lib, env.options(), null_host=True)
    assert rt is None and err.code == h.ERR_ABI, err


def describe_reports_the_runtime_and_the_table_its_entries(env):
    rt = env.runtime(options=env.options(abi="cp399"))
    caps = rt.describe()
    assert caps == {
        "runtime_id": "komira/python", "runtime_abi": "cp399", "max_descriptor_version": 1,
        "shapes": h.SHAPE_SCALAR | h.SHAPE_MAP_BATCHES_COLUMN, "devices": 1,
        "features": h.FEATURE_CONTAINS_CRASHES | h.FEATURE_FORCED_STOP,
        "udf_class": 2,
    }, caps
    t = rt.table
    assert (t.abi_major, t.abi_minor) == (1, 0)
    assert not t.memory_report, "memory_report must be NULL"


def base_spec(**kw):
    return h.Spec("m:f", **kw)


def check_refused(rt, env, spec, status, message):
    got, err = rt.validate(spec)
    assert (got, err.message if err else None) == (status, message), (got, err)


def validate_accepts_the_built_shapes_and_starts_nothing(env):
    rt = env.runtime()
    code = [(h.ROLE_BUNDLE, bytes(32))]
    ok = [
        base_spec(code=code),
        base_spec(code=code, batch_format=h.ARROW),
        base_spec(code=code, shape=h.SHAPE_MAP_BATCHES_COLUMN, batch_format=h.ARROW),
        base_spec(form=h.FORM_PACKAGE),
        base_spec(code=code, args=[("a", pa.int64()), ("b", pa.int32()), ("c", pa.float64())],
                  result=pa.float64()),
        base_spec(code=code, args=[]),
        base_spec(code=code, args=[("s", pa.string()), ("t", pa.timestamp("us", tz="UTC"))],
                  result=pa.struct([("a", pa.list_(pa.decimal128(10, 2)))])),
    ]
    for spec in ok:
        assert rt.validate(spec) == (h.OK, None), spec.args
    assert "spawn" not in env.trace.names(), env.trace.names()


def validate_refuses_a_descriptor_by_version_and_by_field(env):
    rt = env.runtime()
    code = [(h.ROLE_BUNDLE, bytes(32))]

    def spec(**kw):
        return base_spec(code=code, **kw)

    for v in (0, 2):
        check_refused(rt, env, spec(descriptor_version=v), h.ERR_DESCRIPTOR,
                         "descriptor_version %d: this runtime reads version 1" % v)
    names = {3: "arg_types", 4: "return_type", 5: "state_type", 6: "recorded_fields",
             8: "serializer", 9: "python_abi", 11: "distribution"}
    for num, name in names.items():
        desc = h.descriptor("m:f", 1, extra=[(num, "x")])
        check_refused(rt, env, spec(desc=desc), h.ERR_UNSUPPORTED,
                         "descriptor field %d (%s) is not read by this build of komira/python"
                         % (num, name))
    desc = h.descriptor("m:f", 1, extra=[(12, "x")])
    check_refused(rt, env, spec(desc=desc), h.ERR_DESCRIPTOR,
                     "descriptor field 12 is not a PythonDescriptor field")


def validate_refuses_a_descriptor_that_is_not_canonical(env):
    rt = env.runtime()
    code = [(h.ROLE_BUNDLE, bytes(32))]

    def refuse(fields, message, prefix=False):
        spec = base_spec(code=code, desc=h.encode_fields(fields))
        status, err = rt.validate(spec)
        assert status == h.ERR_DESCRIPTOR, (fields, status, err)
        if prefix:
            assert err.message.startswith(message), err
        else:
            assert err.message == message, err

    refuse([(2, 1), (1, "m:f"), (7, 1)], "fields out of order at field 1")
    refuse([(1, "m:f"), (1, "m:f"), (2, 1), (7, 1)], "field 1 repeated")
    refuse([(1, "m:f"), (2, 1), (7, 1), (10, 0)], "field 10 holds its default")
    refuse([(1, ""), (2, 1), (7, 1)], "field 1 holds its default")
    refuse([(1, "m:f"), (2, b"\x01"), (7, 1)], "field 2 has wire type 2")
    refuse([(1, 5), (2, 1), (7, 1)], "field 1 has wire type 0")
    spec = base_spec(code=code, desc=b"\x0a\x05ab")
    status, err = rt.validate(spec)
    assert status == h.ERR_DESCRIPTOR and err.message.startswith("truncated at byte "), err
    spec = base_spec(code=code, desc=h.encode_fields([(1, "m:f")]) + b"\x10\x81\x00")
    status, err = rt.validate(spec)
    assert status == h.ERR_DESCRIPTOR and err.message.startswith(
        "varint not in shortest form at byte "), err


def validate_refuses_a_descriptor_that_disagrees_with_the_spec(env):
    rt = env.runtime()
    code = [(h.ROLE_BUNDLE, bytes(32))]
    check_refused(rt, env, base_spec(code=code, desc=h.descriptor("m:g", 1)),
                     h.ERR_DESCRIPTOR, "descriptor entry 'm:g' differs from the UDF's entry 'm:f'")
    check_refused(rt, env, base_spec(code=code, desc=h.descriptor("m:f", h.SHAPE_MAP_BATCHES_COLUMN,
                                                                      h.ARROW)),
                     h.ERR_DESCRIPTOR, "the UDF's shape SCALAR is not in the descriptor's shapes")
    status, err = rt.validate(base_spec(code=code, desc=h.descriptor("m:f", 1, batch_format=0)))
    assert status == h.ERR_DESCRIPTOR, err
    status, err = rt.validate(base_spec(code=code, desc=h.descriptor("m:f", 0x4000)))
    assert status == h.ERR_DESCRIPTOR, err


def validate_refuses_what_this_build_does_not_run(env):
    rt = env.runtime()
    code = [(h.ROLE_BUNDLE, bytes(32))]
    row = base_spec(code=code, shape=h.SHAPE_ROW, desc=h.descriptor("m:f", h.SHAPE_ROW, h.VALUES))
    check_refused(rt, env, row, h.ERR_UNSUPPORTED, "shape ROW is not built in komira/python yet")
    check_refused(rt, env, base_spec(code=code, desc=h.descriptor("m:f", 1, h.PANDAS)),
                     h.ERR_UNSUPPORTED, "batch format PANDAS is not built in komira/python yet")
    check_refused(rt, env, base_spec(code=code, desc=h.descriptor("m:f", 1, 4)),
                     h.ERR_UNSUPPORTED, "batch format NUMPY is not built in komira/python yet")
    check_refused(rt, env, base_spec(code=code, desc=h.descriptor("m:f", 1, 5)),
                     h.ERR_UNSUPPORTED, "batch format POLARS is not built in komira/python yet")
    check_refused(rt, env, base_spec(code=code, desc=h.descriptor("m:f", 1, is_async=True)),
                     h.ERR_UNSUPPORTED, "async functions are not built in komira/python yet")
    column = base_spec(code=code, shape=h.SHAPE_MAP_BATCHES_COLUMN,
                       desc=h.descriptor("m:f", h.SHAPE_MAP_BATCHES_COLUMN, h.VALUES))
    check_refused(rt, env, column, h.ERR_DESCRIPTOR,
                     "batch format VALUES does not apply to MAP_BATCHES_COLUMN")
    check_refused(rt, env, base_spec(code=code, form=h.FORM_VALUE), h.ERR_UNSUPPORTED,
                     "code form VALUE is not built in komira/python yet")
    check_refused(rt, env, base_spec(code=code, form=9), h.ERR_DESCRIPTOR,
                     "code form 9 is not PACKAGE, BUNDLE or VALUE")


def validate_refuses_types_entries_and_code_lists(env):
    rt = env.runtime()
    code = [(h.ROLE_BUNDLE, bytes(32))]
    check_refused(rt, env, base_spec(code=code, args=[("s", pa.float16())]), h.ERR_UNSUPPORTED,
                     "type 'e' of s is not built in komira/python yet")
    check_refused(rt, env, base_spec(code=code, result=pa.uint8()), h.ERR_UNSUPPORTED,
                     "type 'C' of the result is not built in komira/python yet")
    check_refused(rt, env, base_spec(code=code, result=pa.map_(pa.string(), pa.int64())),
                     h.ERR_UNSUPPORTED, "type '+m' of the result is not built in komira/python yet")
    many = [("a%d" % i, pa.int64()) for i in range(65)]
    status, err = rt.validate(base_spec(code=code, args=many))
    assert status == h.ERR_UNSUPPORTED, err
    for entry in ("nomodule", "a.b:", ":f", "1x:f", "a..b:f", "m:f g"):
        spec = h.Spec(entry, code=code)
        check_refused(rt, env, spec, h.ERR_DESCRIPTOR, "entry '%s' is not module:qualname" % entry)
    bundle = "a BUNDLE lists exactly one code object of role 'bundle'"
    check_refused(rt, env, base_spec(code=[]), h.ERR_DESCRIPTOR, bundle)
    check_refused(rt, env, base_spec(code=code + code), h.ERR_DESCRIPTOR, bundle)
    check_refused(rt, env, base_spec(code=[("payload", bytes(32))]), h.ERR_DESCRIPTOR, bundle)
    check_refused(rt, env, base_spec(code=code, form=h.FORM_PACKAGE), h.ERR_DESCRIPTOR,
                     "a PACKAGE lists no code object")
    no_digests = base_spec(code=code)
    no_digests.drop_digests = True
    check_refused(rt, env, no_digests, h.ERR_HOST_CONTRACT, "spec lists 1 code objects and no code_sha256")
    assert "spawn" not in env.trace.names(), env.trace.names()


def open_context_before_any_load_is_unsupported(env):
    rt = env.runtime()
    status, ctx, err = rt.open_context()
    assert ctx is None
    assert (status, err.message) == (
        h.ERR_UNSUPPORTED, "no UDF is loaded; open a context after a load"), err
    assert "spawn" not in env.trace.names()


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    me = sys.modules["__main__"]
    cases = [getattr(me, n) for n in dir(me) if n.startswith(("init_", "describe_", "validate_",
                                                               "open_context_"))]
    for case in cases:
        with h.Env(lib_dir) as env:
            case(env)
        print("ok", case.__name__)


if __name__ == "__main__":
    main(sys.argv[1:])
