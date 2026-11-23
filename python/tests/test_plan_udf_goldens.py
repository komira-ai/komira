"""The user-function encoder of komira._plan against plans the engine built.

Each golden `udf_*` is a plan src/plan_wire/tests/test_plan_wire_udf_goldens.mojo
builds with the engine's own plan factories, with the UdfRefs of its functions;
`<stem>.canonical.hex` is protoc's serialization of it, and the engine's decoder
accepts those bytes, UDF checks included. The same plan built here as
komira._ops nodes, over UdfSpec values that carry the same fixed code digest, must
encode to those bytes: the UdfRef of each function, its position in the table and
every node that calls it. A difference is reported at the first node that
differs, by its path from the root, or at the UdfRef that differs, by its index.

    test_plan_udf_goldens.py --golden <directory of the plan_wire goldens>
"""

import argparse
import os
import sys

from komira._ops import (
    Arith,
    ColRef,
    Field,
    Lit,
    MapBatches,
    Project,
    Scan,
    UdfCall,
    UdfSpec,
)
from komira._plan import encode_plan, parquet_source
from komira.plan.v1 import plan_pb2


def C(name):
    return ColRef(name)


EVENTS = Scan(
    "/data/udf_events.parquet",
    "parquet",
    (Field("a", "int64"), Field("b", "int32"), Field("c", "float64")),
)

# A fixed stand-in for the sha256 of a bundle: the engine holds it as opaque bytes.
DIGEST = bytes(range(32))


def spec(name, kind, entry, return_type, stability, null_mode, batch_format, form="bundle", read_set=None):
    return UdfSpec(
        name=name,
        kind=kind,
        form=form,
        entry=entry,
        code=(("bundle", DIGEST),) if form == "bundle" else (),
        return_type=return_type,
        stability=stability,
        null_mode=null_mode,
        batch_format=batch_format,
        read_set=read_set,
    )


INC = spec("m.inc", "scalar", "m:inc", "int64", "immutable", "propagate", "values")
NORM = spec("m.norm", "map_batches_column", "m:norm", "float64", "stable", "propagate", "arrow", form="package")
TOT = spec("m.tot", "row", "m:tot", "float64", "volatile", "manual", "values", read_set=("a", "c"))
FRAME = spec(
    "m.frame",
    "map_batches_frame",
    "m:frame",
    (("x", "int64"), ("y", "float64")),
    "stable",
    "propagate",
    "arrow",
    read_set=("a", "c"),
)


def udf_project(inc=INC, tot=TOT):
    return Project(
        EVENTS,
        (
            ("a", C("a")),
            ("inc1", UdfCall(inc, (C("b"),))),
            ("inc2", UdfCall(inc, (C("b"),))),
            ("norm", UdfCall(NORM, (C("c"),))),
            ("tot", UdfCall(tot, (C("a"), C("c")))),
        ),
    )


def udf_frame(frame=FRAME):
    return Project(
        MapBatches(EVENTS, frame),
        (("x", C("x")), ("y2", Arith("mul", C("y"), Lit(2.0)))),
    )


UDF_PROJECT = udf_project()
UDF_FRAME = udf_frame()

GOLDENS = {
    "udf_project": UDF_PROJECT,
    "udf_frame": UDF_FRAME,
}


def read_hex(path):
    with open(path, encoding="ascii") as f:
        return bytes.fromhex(f.read())


def children(plan):
    """The inputs of a `WirePlan`, in order: (slot, child)."""
    node = getattr(plan, plan.WhichOneof("node"))
    out = []
    for desc, value in node.ListFields():
        if desc.message_type is not None and desc.message_type.name == "WirePlan":
            values = [value] if hasattr(value, "ListFields") else list(value)
            out.extend((f"{desc.name}[{i}]" if len(values) > 1 else desc.name, v) for i, v in enumerate(values))
    return out


def without_inputs(plan):
    """The node of `plan` with its inputs cleared: what the node itself says."""
    kind = plan.WhichOneof("node")
    node = type(getattr(plan, kind))()
    node.CopyFrom(getattr(plan, kind))
    for desc, _ in node.ListFields():
        if desc.message_type is not None and desc.message_type.name == "WirePlan":
            node.ClearField(desc.name)
    return node


def sources_of(plan, out=None):
    """The Parquet source of every scan of `plan`, by path, made from the bytes
    libkomira would have given for it."""
    out = {} if out is None else out
    if plan.WhichOneof("node") == "scan":
        source = plan.scan.source
        path = source.parquet.paths[0]
        out[path] = parquet_source(path, source.parquet.schema.SerializeToString())
    for _, child in children(plan):
        sources_of(child, out)
    return out


def compare_nodes(stem, path, got, want):
    """Raise at the first node, in pre-order, where `got` differs from `want`."""
    gk, wk = got.WhichOneof("node"), want.WhichOneof("node")
    assert gk == wk, f"{stem}: {path} is a {gk} node, and the engine's is a {wk}"
    gf, wf = got.output_schema.fields, want.output_schema.fields
    assert len(gf) == len(wf), f"{stem}: {path} ({gk}) has {len(gf)} output fields, the engine's {len(wf)}"
    for i, (g, w) in enumerate(zip(gf, wf)):
        assert g == w, f"{stem}: {path} ({gk}) output field {i} is\n{g}\nand the engine derives\n{w}"
    g, w = without_inputs(got), without_inputs(want)
    assert g == w, f"{stem}: {path} ({gk}) encodes to\n{g}\nand the engine's is\n{w}"
    gc, wc = children(got), children(want)
    assert [s for s, _ in gc] == [s for s, _ in wc], f"{stem}: {path} ({gk}) has inputs {gc} and the engine's {wc}"
    for (slot, g), (_, w) in zip(gc, wc):
        compare_nodes(stem, f"{path}.{gk}.{slot}", g, w)


def compare_udfs(stem, got, want):
    """Raise at the first UdfRef, by index, that differs."""
    assert len(got) == len(want), f"{stem}: {len(got)} UdfRefs, and the engine's list holds {len(want)}"
    for i, (g, w) in enumerate(zip(got, want)):
        assert g == w, f"{stem}: udfs[{i}] is\n{g}\nand the engine's is\n{w}"


def check_golden(directory, stem, plan):
    golden = read_hex(os.path.join(directory, stem + ".canonical.hex"))
    want = plan_pb2.WirePlanEnvelope.FromString(golden)
    got = encode_plan(plan, sources_of(want.plan))
    compare_nodes(stem, "plan", got.plan, want.plan)
    compare_udfs(stem, got.udfs, want.udfs)
    assert got == want, f"{stem}: the envelopes differ outside the plan and its UdfRefs"
    data = got.SerializeToString(deterministic=True)
    assert data == golden, f"{stem}: {len(data)} bytes that are not the golden's {len(golden)}"


def failure(directory, stem, plan):
    try:
        check_golden(directory, stem, plan)
    except AssertionError as e:
        return str(e)
    raise AssertionError(f"{stem}: a plan unlike the engine's passed the check")


def replace(s, **over):
    fields = {f: getattr(s, f) for f in UdfSpec.__dataclass_fields__}
    fields.update(over)
    return UdfSpec(**fields)


def test_every_udf_golden_is_checked(directory):
    """Every `udf_*` golden of the directory has its plan here, and every plan
    here has its golden."""
    suffix = ".canonical.hex"
    stems = {n[: -len(suffix)] for n in os.listdir(directory) if n.startswith("udf_") and n.endswith(suffix)}
    assert stems == set(GOLDENS), f"goldens without a plan here or the reverse: {sorted(stems ^ set(GOLDENS))}"


def test_each_golden_encodes_to_the_engines_bytes(directory):
    for stem, plan in GOLDENS.items():
        check_golden(directory, stem, plan)


def test_the_project_golden_holds_one_ref_per_function(directory):
    """The scalar function called twice is one UdfRef, and the table is in the
    order the calls are first met."""
    env = plan_pb2.WirePlanEnvelope.FromString(read_hex(os.path.join(directory, "udf_project.canonical.hex")))
    assert [u.code.entry for u in env.udfs] == ["m:inc", "m:norm", "m:tot"]
    assert [e.alias.child.udf_apply.udf_index for e in env.plan.project.exprs[1:]] == [0, 0, 1, 2]


def test_the_check_fails_on_a_different_read_set(directory):
    """A row function that reads one column where the engine's reads two fails
    at the project node whose call carries the argument list."""
    narrow = replace(TOT, read_set=("a",))
    plan = Project(UDF_PROJECT.child, UDF_PROJECT.items[:4] + (("tot", UdfCall(narrow, (C("a"),))),))
    message = failure(directory, "udf_project", plan)
    assert message.startswith("udf_project: plan (project) encodes to\n"), message


def test_the_check_fails_on_a_different_frame_read_set(directory):
    """A frame function that reads one column where the engine's reads two
    keeps every node equal, since a node names its UdfRef by index, and fails at
    udfs[0]."""
    message = failure(directory, "udf_frame", udf_frame(replace(FRAME, read_set=("a",))))
    assert message.startswith("udf_frame: udfs[0] is\n"), message


def test_the_check_fails_on_a_different_stability(directory):
    """A scalar function declared stable where the engine's is immutable keeps
    every node equal and fails at udfs[0]."""
    message = failure(directory, "udf_project", udf_project(inc=replace(INC, stability="stable")))
    assert message.startswith("udf_project: udfs[0] is\n"), message


def test_the_check_fails_on_a_different_null_mode(directory):
    """A row function that propagates nulls where the engine's takes them
    manually fails at udfs[2]."""
    message = failure(directory, "udf_project", udf_project(tot=replace(TOT, null_mode="propagate")))
    assert message.startswith("udf_project: udfs[2] is\n"), message


def test_the_check_fails_on_a_different_return_type(directory):
    """A frame whose second column is an int64 where the engine's is a float64
    fails at the map_batches node, on that output field."""
    frame = replace(FRAME, return_type=(("x", "int64"), ("y", "int64")))
    message = failure(directory, "udf_frame", udf_frame(frame))
    assert message.startswith("udf_frame: plan.project.child (map_batches) output field 1 is\n"), message


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--golden", required=True)
    directory = parser.parse_args(argv).golden
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f(directory)
    print("plan_udf_goldens: {} tests".format(len(tests)))


if __name__ == "__main__":
    main(sys.argv[1:])
    sys.exit(0)
