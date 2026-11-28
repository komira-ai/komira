"""`DataFrame.resample(rule, on=column)` of the pandas-shaped frame
(komira/_resample.py) with no libkomira: a frame over a Parquet scan whose
schema is made here, on a session stand-in that records the plan bytes it is
given. Checked:

- the plan of every rule over a date32 column and over timestamp columns of
  each unit, by equality with a hand-built node tree: the bucket replaces the
  column in a projection, below the group-by's filter of missing keys and its
  aggregate, with no sort; the right-edge labels (`W`, `ME`, `M`) shift the
  truncated value by whole days through its integer count; a timestamp
  bucket is grouped as its int64 count of ticks and cast back to the
  column's type above the aggregate (the engine groups by no timestamp
  key), for every reduction and after a column subscript;
- the output columns and types: the bucket keeps the column's name and type;
- the encoded plan, down to the casts that shift a label;
- every refusal by its class and its full message: an unknown rule, a
  multiple of a unit, a rule that is not a str, a missing or wrong `on`,
  `level`, edges that are not pandas' default, `origin` and `offset`, a
  column that is no date, a timestamp with a time zone, and the window verbs
  of a resample;
- a resampled frame reaches the session only as plan bytes, at its terminal.

The answers are compared with DuckDB's in
test_frame_resample_duckdb.py (python/tests). The test loads no library. It is of the
`plan/` family (python/tests/BUCK).

    test_frame_resample.py
"""

import os
import sys
import tempfile

from komira import _ops
from komira._errors import UnsupportedOperation
from komira._frame import DataFrame
from komira._ops import Agg, Arith, Cast, ColRef, Extract, Field, Lit, Unary, When
from komira._plan import encode_plan, parquet_source
from komira._plan._wire import arrow_id, field, pb

# Never opened: the scan only names the file, and the schema is given here.
PATH = os.path.join(tempfile.gettempdir(), "frame_resample_test_input.parquet")
FIELDS = (
    ("d", "date32"),
    ("t", "timestamp_us"),
    ("ts", "timestamp_s"),
    ("tm", "timestamp_ms"),
    ("tn", "timestamp_ns"),
    ("v", "float64"),
    ("s", "string"),
)
LISTED = "'D', 'W' (or 'W-SUN'), 'MS' or 'ME' (or 'M')"
DAY = {
    "d": ("int32", 1),
    "ts": ("int64", 86_400),
    "tm": ("int64", 86_400_000),
    "t": ("int64", 86_400_000_000),
    "tn": ("int64", 86_400_000_000_000),
}
ARROW = dict(FIELDS)


class Stub:
    """A session that records what the plan door is given."""

    def __init__(self):
        self.calls = []

    def _plan_stream(self, plan):
        self.calls.append(("plan_stream", plan))
        return object()


class Env:
    def __init__(self, fields=FIELDS, tz=None):
        self.stub = Stub()
        wire = []
        for n, t in fields:
            f = field(n, arrow_id(t), True)
            if tz is not None and t.startswith("timestamp"):
                f.tz = tz
            wire.append(f)
        schema = pb.WireSchema(fields=wire)
        self.sources = {PATH: parquet_source(PATH, schema.SerializeToString())}
        self.scan = _ops.scan(PATH, "parquet", tuple(Field(n, t) for n, t in fields))
        self.df = DataFrame._new(self.stub, self.scan, self.sources)


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def shifted(node, column, days):
    integer, per_day = DAY[column]
    return Cast(Arith("add", Cast(node, integer), Lit(days * per_day)), None, arrow=ARROW[column])


def label(rule, column):
    """The bucket node pandas' label of `rule` asks for, over `column`."""
    ref = ColRef(column)
    if rule == "D":
        return Extract("trunc_day", ref)
    if rule in ("W", "W-SUN"):
        return shifted(Extract("trunc_week", ref), column, 6)
    if rule == "MS":
        return Extract("trunc_month", ref)
    following = Extract("trunc_month", shifted(Extract("trunc_month", ref), column, 31))
    return shifted(following, column, -1)


def summed(scan, column, rule):
    """The plan of `resample(rule, on=column)["v"].sum()`: the bucket set in a
    projection, the rows with no date filtered out, the sum, and its zero. A
    timestamp bucket is grouped as its int64 ticks and cast back on top."""
    key = label(rule, column)
    if column != "d":
        key = Cast(key, "int64")
    plan = _ops.with_columns(scan, ((column, key),))
    plan = _ops.filter_(plan, Unary("is_not_null", ColRef(column)))
    plan = _ops.aggregate(plan, (column,), (("v", Agg("sum", (ColRef("v"),))),))
    zero = When(((Unary("is_not_null", ColRef("v")), ColRef("v")),), Lit(0))
    plan = _ops.with_columns(plan, (("v", zero),))
    if column != "d":
        plan = _ops.with_columns(plan, ((column, Cast(ColRef(column), None, arrow=ARROW[column])),))
    return plan


RULES = ("D", "W", "W-SUN", "MS", "ME", "M")


# --- the plans ------------------------------------------------------------------


def test_every_rule_over_a_date_buckets_the_column_in_place_and_groups_by_it_unsorted():
    env = Env()
    for rule in RULES:
        got = env.df.resample(rule, on="d")["v"].sum()
        assert got._plan == summed(env.scan, "d", rule), (rule, got._plan)
        assert got.columns == ["d", "v"], rule
        assert got.dtypes == {"d": "date32", "v": "float64"}, (rule, got.dtypes)


def test_every_rule_over_a_timestamp_of_each_unit_shifts_by_that_units_day():
    env = Env()
    for column in ("t", "ts", "tm", "tn"):
        for rule in RULES:
            got = env.df.resample(rule, on=column)["v"].sum()
            assert got._plan == summed(env.scan, column, rule), (column, rule, got._plan)
            assert got.dtypes == {column: ARROW[column], "v": "float64"}, (column, rule, got.dtypes)


def test_the_labels_named_by_hand():
    # The Sunday that ends the week, and the day before the first of the month
    # that 31 days after the first of this one falls in.
    d = ColRef("d")
    week = Cast(Arith("add", Cast(Extract("trunc_week", d), "int32"), Lit(6)), None, arrow="date32")
    assert label("W", "d") == week
    inner = Cast(Arith("add", Cast(Extract("trunc_month", d), "int32"), Lit(31)), None, arrow="date32")
    end = Cast(Arith("add", Cast(Extract("trunc_month", inner), "int32"), Lit(-1)), None, arrow="date32")
    assert label("ME", "d") == end
    t = ColRef("t")
    week_t = Cast(
        Arith("add", Cast(Extract("trunc_week", t), "int64"), Lit(518_400_000_000)), None, arrow="timestamp_us"
    )
    assert label("W", "t") == week_t


def test_pandas_default_edges_may_be_named_and_every_reduction_keeps_the_bucket_key():
    env = Env()
    df = env.df
    for rule in RULES:
        one = df.resample("1" + rule, on="d")["v"].sum()
        assert one._plan == df.resample(rule, on="d")["v"].sum()._plan, rule
    for rule in ("W", "ME", "M", "W-SUN"):
        named = df.resample(rule, on="d", closed="right", label="right")["v"].sum()
        assert named._plan == df.resample(rule, on="d")["v"].sum()._plan, rule
    for rule in ("D", "MS"):
        named = df.resample(rule, on="d", closed="left", label="left")["v"].sum()
        assert named._plan == df.resample(rule, on="d")["v"].sum()._plan, rule
    r = df[["d", "v"]].resample("MS", on="d")
    assert r.size().columns == ["d", "size"]
    assert r.mean().dtypes == {"d": "date32", "v": "float64"}
    assert r.agg(n=("v", "count"), hi=("v", "max")).columns == ["d", "n", "hi"]
    assert repr(r) == "<komira.GroupBy by d>"
    # The bucket replaces the column where it stands; the other columns stay.
    by_t = df.resample("D", on="t").max()
    assert by_t.columns == ["t", "d", "ts", "tm", "tn", "v", "s"]
    assert by_t.dtypes["t"] == "timestamp_us"
    back = Cast(ColRef("t"), None, arrow="timestamp_us")
    assert by_t._plan.items[0] == ("t", back), by_t._plan
    assert df.resample("W", on="t")[["v"]].size()._plan.items[0] == ("t", back)
    assert df.resample("W", on="t").size().dtypes == {"t": "timestamp_us", "size": "int64"}


def test_the_encoded_resample_casts_the_label_through_its_day_count():
    env = Env()
    got = env.df.resample("W", on="d")["v"].sum()
    root = encode_plan(got._plan, env.sources).plan
    assert root.WhichOneof("node") == "project", root.WhichOneof("node")
    aggregate = root.project.child
    assert aggregate.WhichOneof("node") == "aggregate"
    assert aggregate.aggregate.child.WhichOneof("node") == "filter"
    project = aggregate.aggregate.child.filter.child
    assert project.WhichOneof("node") == "project"
    assert [(f.name, f.arrow_type_id) for f in root.output_schema.fields] == [
        ("d", arrow_id("date32")),
        ("v", arrow_id("float64")),
    ]


def test_a_resampled_frame_reaches_the_session_only_as_plan_bytes_at_its_terminal():
    env = Env()
    frame = env.df.resample("ME", on="t")["v"].sum()
    assert env.stub.calls == []
    frame.materialize()
    assert env.stub.calls == [("plan_stream", encode_plan(frame._plan, env.sources).SerializeToString())]


# --- refusals ------------------------------------------------------------------------


def test_a_rule_that_is_not_built_is_refused_by_name():
    df = Env().df
    for rule in ("h", "QS", "YE", "W-MON", "B", "d", "SME"):
        refuses(
            lambda: df.resample(rule, on="d"),
            UnsupportedOperation,
            f"resample({rule!r}) is not a rule this release buckets by: use {LISTED}",
        )
    for rule in ("2D", "12W", "3MS", "10D"):
        refuses(
            lambda: df.resample(rule, on="d"),
            UnsupportedOperation,
            f"resample({rule!r}) buckets by a multiple of a unit, and the plan cuts to one whole day, "
            f"week or month: use {LISTED}",
        )
    refuses(lambda: df.resample(7, on="d"), TypeError, "resample() rule must be a str, not int")


def test_the_column_must_be_named_and_be_a_date_or_timestamp_without_a_zone():
    df = Env().df
    refuses(
        lambda: df.resample("D"),
        UnsupportedOperation,
        "resample() buckets a time index, and a komira frame has no index: "
        'name the date or timestamp column with on="column"',
    )
    refuses(
        lambda: df.resample("D", level=0),
        UnsupportedOperation,
        "resample(level=...) names a level of the index, and a komira frame has no index: "
        'name the date column with on="column"',
    )
    refuses(
        lambda: df.resample("D", on=["d"]),
        TypeError,
        "resample() on must be a column name, which is a str, not list",
    )
    e = raised(lambda: df.resample("D", on="nope"))
    assert type(e) is KeyError, repr(e)
    refuses(
        lambda: df.resample("D", on="v"),
        TypeError,
        "resample(on='v') needs a date32 or timestamp column, and 'v' is float64",
    )
    refuses(
        lambda: df.resample("D", on="s"),
        TypeError,
        "resample(on='s') needs a date32 or timestamp column, and 's' is string",
    )
    zoned = Env(tz="Europe/Paris").df
    refuses(
        lambda: zoned.resample("D", on="t"),
        UnsupportedOperation,
        "resample(on='t') of a timestamp with the time zone Europe/Paris is not supported: "
        "pandas buckets it by the local day, which the plan does not compute",
    )
    # A date column of the same frame has no zone, and is bucketed.
    assert zoned.resample("D", on="d")["v"].sum().columns == ["d", "v"]


def test_edges_other_than_pandas_default_and_a_moved_origin_are_refused():
    df = Env().df
    for rule, name, value, default in (
        ("W", "closed", "left", "right"),
        ("W", "label", "left", "right"),
        ("ME", "closed", "left", "right"),
        ("M", "label", "left", "right"),
        ("D", "closed", "right", "left"),
        ("MS", "label", "right", "left"),
    ):
        refuses(
            lambda: df.resample(rule, on="d", **{name: value}),
            UnsupportedOperation,
            f"resample({rule!r}, {name}={value!r}) moves the bucket edges from pandas' default, "
            f"{name}={default!r} for {rule!r}, which is the only one built: leave {name} at its default",
        )
    refuses(
        lambda: df.resample("D", on="d", closed="middle"),
        ValueError,
        "resample() closed must be 'left', 'right' or None, not 'middle'",
    )
    refuses(
        lambda: df.resample("D", on="d", label=1),
        ValueError,
        "resample() label must be 'left', 'right' or None, not 1",
    )
    moved = (
        "resample(origin=..., offset=...) moves where the buckets start, and the buckets here are "
        "whole calendar days, weeks and months: leave both at their default"
    )
    refuses(lambda: df.resample("D", on="d", origin="epoch"), UnsupportedOperation, moved)
    refuses(lambda: df.resample("D", on="d", offset="2h"), UnsupportedOperation, moved)


def test_the_window_verbs_of_a_resample_are_refused():
    r = Env().df.resample("D", on="d")["v"]
    for verb, call in (
        ("transform()", lambda: r.transform("sum")),
        ("cumsum()", lambda: r.cumsum()),
        ("cummin()", lambda: r.cummin()),
        ("rank()", lambda: r.rank()),
    ):
        refuses(
            call,
            UnsupportedOperation,
            f"{verb} of a resample gives one value per row, and a resample's rows are its buckets: "
            "reduce the buckets with agg() or one of the reductions",
        )


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("frame resample: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
