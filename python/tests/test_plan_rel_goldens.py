"""The relational encoder of komira._plan against plans the engine built.

Each golden `rel_*` is a plan src/plan_wire/tests/test_plan_wire_rel_goldens.mojo
and test_plan_wire_rel_goldens_join.mojo build with the engine's own plan
factories; `<stem>.canonical.hex` is protoc's serialization of it. The same plan
built here as komira._ops nodes must encode to those bytes. The scan sources are
taken from the golden, as libkomira would give them: a Parquet scan's schema
bytes go through `parquet_source`, a binding's bytes through `binding_source`.
A difference is reported at the first node that differs, by its path from the
root.

    test_plan_rel_goldens.py --golden <directory of the plan_wire goldens>
"""

import argparse
import os
import sys

from komira._ops import (
    Agg,
    Aggregate,
    Arith,
    BoolOp,
    ColRef,
    Compare,
    Distinct,
    Field,
    Filter,
    Frame,
    Join,
    Limit,
    Lit,
    Project,
    Scan,
    Sort,
    SortKey,
    TopN,
    Unary,
    Union,
    WindowExpr,
)
from komira._plan import binding_source, encode_plan, parquet_source
from komira.plan.v1 import plan_pb2


def C(name, side=None):
    return ColRef(name, side)


def table(path, fmt, *columns):
    return Scan(path, fmt, tuple(Field(n, t) for n, t in columns))


ORDERS = table(
    "/data/orders.parquet",
    "parquet",
    ("o_id", "int64"),
    ("c_id", "int64"),
    ("qty", "int32"),
    ("price", "float64"),
    ("amount", "decimal128"),
    ("flag", "bool"),
    ("u", "uint16"),
    ("f32", "float32"),
    ("ts", "timestamp_us"),
    ("s", "string"),
)
CUSTOMERS = table("/data/customers.parquet", "parquet", ("c_id", "int64"), ("name", "string"), ("region", "string"))
REGIONS = table("/data/regions.parquet", "parquet", ("r_name", "string"), ("r_code", "int32"))
NATIONS = table("/data/nations.parquet", "parquet", ("n_name", "string"), ("n_code", "int64"))
EVENTS = (("k", "int64"), ("v", "float64"), ("t", "string"))
EVENTS_PARQUET = table("/data/events.parquet", "parquet", *EVENTS)
EVENTS_CSV = table("/data/events.csv", "csv", *EVENTS)

PRICE_TIMES_QTY = Arith("mul", C("price"), C("qty"))


def agg(func, *args, k=None):
    return Agg(func, tuple(C(a) if isinstance(a, str) else a for a in args), k)


REL_FILTER_PROJECT = Project(
    Filter(
        ORDERS,
        BoolOp("and", Compare("gt", C("qty"), Lit(0)), Unary("is_not_null", C("c_id"))),
    ),
    (
        ("o_id", C("o_id")),
        ("cid", C("c_id")),
        ("total", PRICE_TIMES_QTY),
        ("amt", C("amount")),
        ("one", Lit(1)),
    ),
)

REL_AGGREGATE = Sort(
    Aggregate(
        ORDERS,
        ("c_id", "flag"),
        (
            ("n", agg("count")),
            ("n_s", agg("count", "s")),
            ("sum_qty", agg("sum", "qty")),
            ("sum_u", agg("sum", "u")),
            ("sum_f32", agg("sum", "f32")),
            ("sum_amt", agg("sum", "amount")),
            ("sum_price", agg("sum", "price")),
            ("sum_flag", agg("sum", "flag")),
            ("sum_expr", agg("sum", PRICE_TIMES_QTY)),
            ("avg_price", agg("mean", "price")),
            ("min_ts", agg("min", "ts")),
            ("max_amt", agg("max", "amount")),
            ("first_s", agg("first", "s")),
            ("last_s", agg("last", "s")),
            ("any_o", agg("any_value", "o_id")),
            ("nd", agg("count_distinct", "s")),
            ("med", agg("median", "price")),
            ("sd", agg("stddev_samp", "price")),
            ("kavg", agg("kahan_avg", "price")),
            ("kurt", agg("kurtosis", "price")),
            ("prod", agg("product", "price")),
            ("top2", agg("largest_k", "price", k=2)),
            ("corr", agg("corr", "price", "qty")),
            ("slope", agg("regr_slope", "price", "qty")),
            ("cov", agg("covar_pop", "price", "qty")),
            ("rc", agg("regr_count", "price", "qty")),
            ("n_flag", agg("count_if", "flag")),
            ("all_flag", agg("bool_and", "flag")),
            ("any_flag", agg("bool_or", "flag")),
        ),
    ),
    (SortKey("c_id"), SortKey("n", descending=True, nulls_first=True)),
)

REL_SORT_LIMIT = Limit(
    Distinct(
        TopN(
            Project(ORDERS, (("c_id", C("c_id")), ("price", C("price")), ("s", C("s")))),
            (SortKey("price", descending=True), SortKey("c_id", nulls_first=True)),
            100,
        )
    ),
    10,
    5,
)

REL_UNION = Limit(
    Union(
        (
            Filter(EVENTS_PARQUET, Compare("gt", C("v"), Lit(1.5))),
            EVENTS_CSV,
            Filter(EVENTS_CSV, Unary("is_not_null", C("t"))),
        )
    ),
    3,
)

REL_JOIN_INNER = Join(
    ORDERS,
    CUSTOMERS,
    "inner",
    ("c_id",),
    ("c_id",),
    BoolOp(
        "and",
        Compare("gt", C("price", "left"), Lit(10.0)),
        Compare("ne", C("region", "right"), Lit("x")),
    ),
)

REL_JOIN_KINDS = Join(
    Join(Join(ORDERS, CUSTOMERS, "left", ("c_id",), ("c_id",)), CUSTOMERS, "semi", ("c_id",), ("c_id",)),
    CUSTOMERS,
    "anti",
    ("c_id_right",),
    ("c_id",),
)

REL_JOIN_OUTER = Join(
    Join(ORDERS, CUSTOMERS, "right", ("c_id",), ("c_id",)),
    Join(REGIONS, NATIONS, "cross"),
    "full",
    ("c_id",),
    ("n_code",),
)

BY_O = (SortKey("o_id"),)
BY_C = ("c_id",)

REL_WINDOW = Project(
    ORDERS,
    (
        ("o_id", C("o_id")),
        ("rn", WindowExpr("row_number", partition_by=BY_C, order_by=BY_O)),
        ("rk", WindowExpr("rank", order_by=(SortKey("price", descending=True),))),
        ("drk", WindowExpr("dense_rank", partition_by=BY_C, order_by=(SortKey("qty"),))),
        ("pr", WindowExpr("percent_rank", order_by=BY_O)),
        ("cd", WindowExpr("cume_dist", order_by=BY_O)),
        ("nt", WindowExpr("ntile", offset=4, order_by=BY_O)),
        ("prev", WindowExpr("lag", "price", 1, BY_C, BY_O)),
        ("next2", WindowExpr("lead", "amount", 2, (), BY_O)),
        ("fv", WindowExpr("first_value", "s", 0, BY_C, BY_O)),
        ("lv", WindowExpr("last_value", "ts", 0, BY_C, BY_O, Frame("rows", "unbounded_preceding", "unbounded_following"))),
        ("nv", WindowExpr("nth_value", "o_id", 2, (), BY_O, Frame("rows", "preceding", "following", 1, 1))),
        ("run_qty", WindowExpr("sum", "qty", 0, BY_C, BY_O, Frame("rows", "preceding", "current_row", 2))),
        ("tot_price", WindowExpr("sum", "price", 0, BY_C)),
        ("avg_p", WindowExpr("avg", "price", 0, BY_C, BY_O, Frame("range", "unbounded_preceding", "current_row"))),
        ("cnt", WindowExpr("count", "s", 0, BY_C)),
        ("min_ts", WindowExpr("min", "ts", 0, BY_C)),
        ("price", WindowExpr("max", "price", 0, BY_C)),
        ("total", PRICE_TIMES_QTY),
    ),
)

GOLDENS = {
    "rel_filter_project": REL_FILTER_PROJECT,
    "rel_aggregate": REL_AGGREGATE,
    "rel_sort_limit": REL_SORT_LIMIT,
    "rel_union": REL_UNION,
    "rel_join_inner": REL_JOIN_INNER,
    "rel_join_kinds": REL_JOIN_KINDS,
    "rel_join_outer": REL_JOIN_OUTER,
    "rel_window": REL_WINDOW,
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
    """The source of every scan of `plan`, by path, made from the bytes
    libkomira would have given for it."""
    out = {} if out is None else out
    kind = plan.WhichOneof("node")
    if kind == "scan":
        source = plan.scan.source
        if source.WhichOneof("payload") == "parquet":
            path = source.parquet.paths[0]
            out[path] = parquet_source(path, source.parquet.schema.SerializeToString())
        else:
            out[source.binding.name] = binding_source(source.binding.SerializeToString())
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


def check_golden(directory, stem, plan):
    golden = read_hex(os.path.join(directory, stem + ".canonical.hex"))
    want = plan_pb2.WirePlanEnvelope.FromString(golden)
    got = encode_plan(plan, sources_of(want.plan))
    compare_nodes(stem, "plan", got.plan, want.plan)
    assert got == want, f"{stem}: the envelopes differ outside the plan"
    data = got.SerializeToString(deterministic=True)
    assert data == golden, f"{stem}: {len(data)} bytes that are not the golden's {len(golden)}"


def failure(directory, stem, plan):
    try:
        check_golden(directory, stem, plan)
    except AssertionError as e:
        return str(e)
    raise AssertionError(f"{stem}: a plan unlike the engine's passed the check")


def test_every_relational_golden_is_checked(directory):
    """Every `rel_*` golden of the directory has its plan here, and every plan
    here has its golden."""
    suffix = ".canonical.hex"
    stems = {n[: -len(suffix)] for n in os.listdir(directory) if n.startswith("rel_") and n.endswith(suffix)}
    assert stems == set(GOLDENS), f"goldens without a plan here or the reverse: {sorted(stems ^ set(GOLDENS))}"


def test_each_golden_encodes_to_the_engines_bytes(directory):
    for stem, plan in GOLDENS.items():
        check_golden(directory, stem, plan)


def test_the_check_fails_on_a_different_sort_key(directory):
    """A sort whose second key puts NULLs last fails at the sort node."""
    keys = (SortKey("c_id"), SortKey("n", descending=True))
    message = failure(directory, "rel_aggregate", Sort(REL_AGGREGATE.child, keys))
    assert message.startswith("rel_aggregate: plan (sort) encodes to\n"), message


def test_the_check_fails_on_a_different_aggregate_type(directory):
    """An aggregate whose sum reads a float in place of an int fails on that
    aggregate's output field, which the sort above it carries."""
    node = REL_AGGREGATE.child
    aggs = list(node.aggs)
    aggs[2] = ("sum_qty", agg("sum", "price"))
    plan = Sort(Aggregate(node.child, node.keys, tuple(aggs)), REL_AGGREGATE.keys)
    message = failure(directory, "rel_aggregate", plan)
    assert message.startswith("rel_aggregate: plan (sort) output field 4 is\n"), message


def test_the_check_fails_on_a_different_join_side(directory):
    """A left join where the engine's is a right join fails on the nullability
    of the first left column."""
    inner = REL_JOIN_OUTER.left
    plan = Join(Join(inner.left, inner.right, "left", ("c_id",), ("c_id",)), REL_JOIN_OUTER.right, "full", ("c_id",), ("n_code",))
    message = failure(directory, "rel_join_outer", plan)
    assert message.startswith("rel_join_outer: plan.join.left (join) output field 0 is\n"), message


def test_the_check_fails_on_a_different_frame(directory):
    """A running sum over three rows where the engine's reads four fails at
    its partition-by node."""
    items = list(REL_WINDOW.items)
    items[12] = ("run_qty", WindowExpr("sum", "qty", 0, BY_C, BY_O, Frame("rows", "preceding", "current_row", 3)))
    message = failure(directory, "rel_window", Project(ORDERS, tuple(items)))
    # The six windows from the top are price, min_ts, cnt, avg_p, tot_price
    # and run_qty: the first five equal the engine's.
    path = "plan.project.child" + ".partition_by.child" * 5
    assert message.startswith(f"rel_window: {path} (partition_by) encodes to\n"), message
    assert "start_offset: 3" in message, message


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--golden", required=True)
    directory = parser.parse_args(argv).golden
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f(directory)
    print("plan_rel_goldens: {} tests".format(len(tests)))


if __name__ == "__main__":
    main(sys.argv[1:])
    sys.exit(0)
