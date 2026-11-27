"""A Python UDF declared with `@udf` and run by the komira/python runtime of
the installed komira wheel, its answers held to a plain Python loop over the
same rows (python/BUCK, `udf_installed_test`).

    <prefix>/bin/python3.13 -I test_udf_installed.py --site <dir>
        [--host-lib <lib>]... --udf-host <udf_host.py>

Run by wheel_install_run.py, which installed komira, pyarrow and protobuf into
`--site` and starts this from an empty working directory. No engine hosts a
UDF runtime yet, so the runtime is hosted here through its C ABI by
`--udf-host` (python/tests/udf_host.py, the host of the runtime's own tests),
in the engine's place. In order:

- `import komira` is the package installed in `--site`, and the wheel carries
  the runtime at `<site>/komira/_lib/libkomira_udf_python.so`;
- a module of the user's own, written to a new directory that is no
  installed distribution, declares the functions with `komira._capture.udf`;
  each call, over the columns of a frame `komira.read_parquet` made of a
  Parquet file, encodes as a UdfRef whose code is a bundle of that module, and
  a row function's explicit read set (`columns=`) is its UdfRef's read set;
- the runtime opened from the installed wheel starts its zygote with this
  interpreter and the installed `komira._udf.zygote`, forks a worker, and the
  worker's answers over the file's columns equal a Python loop over the same
  rows: a scalar function of two int64 columns (nulls, the int64 edges halved,
  zero and negatives), a scalar string function (empty, non-ASCII, null) and a
  column function over Arrow arrays, and each answers an empty batch with no
  rows;
- a result past int64 is refused by its row, and the instance answers the
  next batch;
- a code object of the same module whose function gives another answer, run
  by a fresh runtime, is found unequal to the loop by the same comparison,
  which names the first row that differs: the check fails on a wrong worker
  answer;
- the row function with the read set is refused by the runtime, which does
  not run that shape yet, with the field it does not read;
- the engine refuses the frame with the UDF column at `materialize()`, and a
  SQL query naming the function at `sql()`, each by its exact message: what
  the engine does with a UDF today;
- no zygote or worker of a runtime outlives its shutdown.

Any failure raises; its last traceback line is what a failing run names.
"""

import ctypes
import hashlib
import importlib
import importlib.util
import os
import sys
import tempfile

_VALUED = ("--site", "--udf-host")

I64_MIN, I64_MAX = -(2**63), 2**63 - 1

# The user's module: the functions a user writes, in a file of their own.
USER_MODULE = "user_udfs"

USER_SOURCE = '''\
import pyarrow.compute as pc

from komira._capture import udf


@udf
def score(a: int, b: int) -> int:
    if a is None or b is None:
        return None
    return a * 3 - b


@udf
def tag(s: str) -> str:
    return None if s is None else "<" + s.upper() + ">"


@udf(kind="map_batches_column", return_dtype="int64")
def shifted(values):
    return pc.subtract(values, 7)


@udf(kind="row", return_dtype="int64", columns=("a", "b"))
def row_total(r):
    return r.a + r.b
'''

# The same module with `score` answering one more than it should.
WRONG_SOURCE = USER_SOURCE.replace("return a * 3 - b", "return a * 3 - b + 1")

# The rows of the Parquet file: nulls in each column, int64's edges halved,
# zero, negatives, and strings empty, non-ASCII and null.
ROWS = {
    "a": [0, 1, -1, 7, I64_MAX // 6, I64_MIN // 6, None, 5, -300],
    "b": [0, 2, -2, 1, 3, -3, 4, None, 300],
    "s": ["", "ab", "Zürich", None, "x y", "ß", "a", "Q", "mixed Case"],
}


def parse(argv):
    opts = {"host_lib": []}
    i = 0
    while i < len(argv):
        flag = argv[i]
        if i + 1 >= len(argv):
            raise SystemExit("test_udf_installed: flag {} needs a value".format(flag))
        if flag == "--host-lib":
            opts["host_lib"].append(argv[i + 1])
        elif flag in _VALUED:
            opts[flag[2:].replace("-", "_")] = argv[i + 1]
        else:
            raise SystemExit("test_udf_installed: unknown flag {}".format(flag))
        i += 2
    for flag in _VALUED:
        if flag[2:].replace("-", "_") not in opts:
            raise SystemExit("test_udf_installed: {} is required".format(flag))
    return opts


def load_path(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def same_as_loop(what, got, want):
    """Raises unless the worker's answer `got` is the loop's `want`, row for
    row, naming the first row that differs."""
    if len(got) != len(want):
        raise AssertionError("{}: the worker answered {} rows, the loop {}".format(what, len(got), len(want)))
    for i, (g, w) in enumerate(zip(got, want)):
        if g != w or type(g) is not type(w):
            raise AssertionError("{}: row {}: the worker answered {!r}, the loop {!r}".format(what, i, g, w))


class Planned:
    """The UdfRefs of one frame's UDF columns, and the spec the runtime is
    given for each, built from the UdfRef alone as an engine would."""

    def __init__(self, h, pa, pb, vocab):
        self.h, self.pa, self.pb, self.vocab = h, pa, pb, vocab
        self.shapes = {
            pb.SCALAR: h.SHAPE_SCALAR,
            pb.ROW: h.SHAPE_ROW,
            pb.MAP_BATCHES_COLUMN: h.SHAPE_MAP_BATCHES_COLUMN,
        }
        self.forms = {pb.PACKAGE: h.FORM_PACKAGE, pb.BUNDLE: h.FORM_BUNDLE}
        self.null_modes = {pb.UDF_NULL_MANUAL: h.NULL_MANUAL, pb.UDF_NULL_PROPAGATE: h.NULL_PROPAGATE}
        self.types = {"int64": pa.int64(), "string": pa.string(), "large_string": pa.large_string()}

    def arrow_type(self, wire_field):
        name = self.vocab.ArrowType.Name(wire_field.arrow_type_id + 1).removeprefix("ARROW_TYPE_").lower()
        assert name in self.types, "the test reads no column of the wire type {}".format(name)
        return self.types[name]

    def spec(self, ref, code_root, code=None):
        return self.h.Spec(
            ref.code.entry,
            shape=self.shapes[ref.kind],
            form=self.forms[ref.code.form],
            args=[("a%d" % i, self.arrow_type(f)) for i, f in enumerate(ref.arg_types)],
            result=self.arrow_type(ref.return_type),
            null_mode=self.null_modes[ref.null_mode],
            code=[(c.role, c.sha256) for c in ref.code.code] if code is None else code,
            code_root=code_root,
            desc=ref.code.descriptor,
            descriptor_version=ref.code.descriptor_version,
        )


def as_args(inst, *columns):
    """The columns as the instance's argument types: what the frame's scan
    reads them as (a Parquet string column is `large_string`)."""
    return [c.cast(t) for c, (_, t) in zip(columns, inst.spec.args)]


def instance(env, planned, ref, code=None):
    rt = env.runtime()
    udf = rt.load_ok(planned.spec(ref, env.code_root, code))
    return rt.open_context_ok().open_instance_ok(udf)


def main(argv):
    opts = parse(argv)
    for lib in opts["host_lib"]:
        ctypes.CDLL(lib, mode=ctypes.RTLD_GLOBAL)

    site = os.path.realpath(opts["site"])
    import komira

    init = os.path.realpath(komira.__file__)
    assert init == os.path.join(site, "komira", "__init__.py"), "komira was imported from {}, not from {}".format(init, site)
    lib_dir = os.path.join(site, "komira", "_lib")
    runtime_lib = os.path.join(lib_dir, "libkomira_udf_python.so")
    assert os.path.isfile(runtime_lib), "the wheel carries no {}: {}".format(runtime_lib, sorted(os.listdir(lib_dir)))

    import pyarrow as pa
    import pyarrow.parquet as pq

    from komira._capture import write_code
    from komira._frame import DataFrame
    from komira._ops import ColRef, Project
    from komira._plan import encode_plan
    from komira.plan.v1 import plan_pb2 as pb
    from komira.plan.v1 import plan_vocabulary_pb2 as vocab

    h = load_path("udf_host", opts["udf_host"])
    zygote = os.path.realpath(h.zygote_path())
    assert zygote == os.path.join(site, "komira", "_udf", "zygote.py"), "the zygote is {}, not the installed one".format(zygote)
    planned = Planned(h, pa, pb, vocab)

    with tempfile.TemporaryDirectory(dir=os.getcwd()) as work:
        user_dir = os.path.join(work, "user")
        os.mkdir(user_dir)
        with open(os.path.join(user_dir, USER_MODULE + ".py"), "w", encoding="utf-8") as f:
            f.write(USER_SOURCE)
        sys.path.insert(0, user_dir)
        user = importlib.import_module(USER_MODULE)

        path = os.path.join(work, "t.parquet")
        table = pa.table({"a": pa.array(ROWS["a"], pa.int64()), "b": pa.array(ROWS["b"], pa.int64()), "s": pa.array(ROWS["s"], pa.string())})
        pq.write_table(table, path)
        frame = komira.read_parquet(path)

        def planned_frame(*items):
            plan = Project(frame._plan, tuple(items))
            return plan, encode_plan(plan, frame._sources)

        # Each function's call over the frame's columns, encoded as the plan
        # door takes it; the code a bundle of the user's module.
        refs = {}
        for name, call in [
            ("score", user.score.expr(ColRef("a"), ColRef("b"))),
            ("tag", user.tag.expr(ColRef("s"))),
            ("shifted", user.shifted.expr(ColRef("a"))),
            ("row_total", user.row_total.expr()),
        ]:
            _, envelope = planned_frame((name, call))
            assert len(envelope.udfs) == 1, "{}: {} UdfRefs".format(name, len(envelope.udfs))
            ref = envelope.udfs[0]
            assert ref.code.runtime == "komira/python", "{}: runtime {}".format(name, ref.code.runtime)
            assert ref.code.form == pb.BUNDLE, "{}: the user's module is not a bundle".format(name)
            refs[name] = ref
        assert refs["score"].kind == pb.SCALAR and len(refs["score"].arg_types) == 2
        assert refs["shifted"].kind == pb.MAP_BATCHES_COLUMN
        assert refs["row_total"].kind == pb.ROW
        assert user.row_total.spec().read_set == ("a", "b"), user.row_total.spec().read_set
        assert refs["row_total"].HasField("read_set") and list(refs["row_total"].read_set.columns) == ["a", "b"], refs["row_total"].read_set
        assert [f.name for f in refs["row_total"].arg_types] == ["a", "b"], [f.name for f in refs["row_total"].arg_types]
        assert not refs["score"].HasField("read_set"), "a scalar function's UdfRef carries a read set"

        # What the engine does with the frame and with SQL naming the function.
        plan, envelope = planned_frame(("a", ColRef("a")), ("score", user.score.expr(ColRef("a"), ColRef("b"))))
        try:
            DataFrame._new(frame._session, plan, frame._sources).materialize()
        except komira.KomiraError as e:
            want = (
                "decode: PLAN_WIRE_UDFS_DROPPED: these bytes carry 1 UdfRef entries (`WirePlanEnvelope.udfs`), and "
                "the plan door runs no user function yet"
            )
            assert str(e) == want, "the frame with a UDF column is refused with {!r} ({}), not {!r}".format(str(e), type(e).__name__, want)
        else:
            raise AssertionError("the engine ran the frame with a UDF column, which it has no operator for")
        with komira.Session() as s:
            s.register_parquet("t", path)
            try:
                s.sql("SELECT score(a, b) AS score FROM t")
            except komira.UnsupportedOperation as e:
                want = (
                    "bind: SQL not supported: scalar function 'score'. No UDFs are declared on this catalog either "
                    "\u2014 a komira session cannot declare a function to SQL yet"
                )
                assert str(e) == want, "SQL naming the UDF is refused with {!r} ({}), not {!r}".format(str(e), type(e).__name__, want)
            else:
                raise AssertionError("SQL naming a Python function ran")

        code_root = os.path.join(work, "code")
        os.mkdir(code_root)
        for fn in (user.score, user.tag, user.shifted, user.row_total):
            write_code(code_root, fn)
        # The worker must import the module from its bundle, as a user's
        # engine would, not from the directory this process imported it from.
        sys.path.remove(user_dir)

        columns = {n: table.column(n).combine_chunks() for n in ROWS}
        # The plain Python computations the worker's answers are held to.
        loop_score = [None if a is None or b is None else a * 3 - b for a, b in zip(ROWS["a"], ROWS["b"])]
        loop_tag = [None if s is None else "<" + s.upper() + ">" for s in ROWS["s"]]
        loop_shifted = [None if a is None else a - 7 for a in ROWS["a"]]
        assert loop_score == [user.score(a, b) for a, b in zip(ROWS["a"], ROWS["b"])]

        with h.Env(lib_dir) as env:
            env.code_root = code_root
            inst = instance(env, planned, refs["score"])
            got = inst.call_ok(as_args(inst, columns["a"], columns["b"]))
            assert got.type == pa.int64(), got.type
            same_as_loop("score", got.to_pylist(), loop_score)
            same_as_loop("score of an empty batch", inst.call_ok([pa.array([], pa.int64()), pa.array([], pa.int64())]).to_pylist(), [])
            over = inst.call([pa.array([1, I64_MAX // 2], pa.int64()), pa.array([0, 0], pa.int64())])
            assert over.status == h.ERR_RETURN_TYPE and over.array is None, over.err
            assert over.err.row == 1, over.err
            assert over.err.message == "row 1 returned int {}, which is not int64 without loss".format((I64_MAX // 2) * 3), over.err
            same_as_loop("score after a refused batch", inst.call_ok([pa.array([2], pa.int64()), pa.array([1], pa.int64())]).to_pylist(), [5])

            tag = instance(env, planned, refs["tag"])
            got = tag.call_ok(as_args(tag, columns["s"]))
            assert got.type == planned.arrow_type(refs["tag"].return_type), (got.type, refs["tag"].return_type)
            same_as_loop("tag", got.to_pylist(), loop_tag)
            same_as_loop("tag of an empty batch", tag.call_ok(as_args(tag, pa.array([], pa.string()))).to_pylist(), [])

            shifted = instance(env, planned, refs["shifted"])
            got = shifted.call_ok([columns["a"]])
            assert got.type == pa.int64(), got.type
            same_as_loop("shifted", got.to_pylist(), loop_shifted)
            same_as_loop("shifted of an empty batch", shifted.call_ok([pa.array([], pa.int64())]).to_pylist(), [])

            rt = env.runtime()
            status, err = rt.validate(planned.spec(refs["row_total"], code_root))
            assert status == h.ERR_UNSUPPORTED, (status, err)
            want = "descriptor field 6 (recorded_fields) is not read by this build of komira/python"
            assert err.message == want, "the row function is refused with {!r}, not {!r}".format(err.message, want)

        # The same module with a wrong `score`, a code object of its own, run
        # by a fresh runtime (a zygote that has not imported the right one).
        wrong = h.make_zip({USER_MODULE + ".py": WRONG_SOURCE})
        digest = hashlib.sha256(wrong)
        with open(os.path.join(code_root, digest.hexdigest()), "wb") as f:
            f.write(wrong)
        with h.Env(lib_dir) as env:
            env.code_root = code_root
            inst = instance(env, planned, refs["score"], code=[(h.ROLE_BUNDLE, digest.digest())])
            got = inst.call_ok(as_args(inst, columns["a"], columns["b"])).to_pylist()
            try:
                same_as_loop("score", got, loop_score)
            except AssertionError as e:
                assert str(e) == "score: row 0: the worker answered 1, the loop 0", str(e)
            else:
                raise AssertionError("a worker answering one more than the loop on every row passed the comparison")


if __name__ == "__main__":
    main(sys.argv[1:])
