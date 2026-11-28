"""komira.pl's `Expr.dt.truncate(every)` and `LazyFrame.group_by_dynamic` as
plans, with no library (komira/pl/_dt.py).

Frames are scans of a stand-in session whose file schema is written here as
the engine's `WireSchema` bytes, with a Date, Datetimes of three units and one
with a time zone. Checked:

- `dt.truncate("1d" | "1w" | "1mo")` is the EXTRACT of `trunc_day`,
  `trunc_week` or `trunc_month` of its input, keeps the input's name and
  type (a Date stays a Date, a Datetime its unit), and lowers the same in
  `select`, `with_columns` and `filter`;
- `group_by_dynamic(index, every=...)` is `group_by` of the frame with the
  rows of a null index filtered out and the index replaced by its
  truncation: the plans are equal, the key is the index's name after the
  `group_by` keys, and the output is the keys, then the aggregates; over a
  Datetime the window is grouped as its int64 ticks and cast back above the
  aggregate (the engine groups by no timestamp key), keeping the unit;
- polars' defaults may be named (`period=every`, `closed="left"`,
  `label="left"`, `start_by="window"`, `include_boundaries=False`), and an
  index given as `col(...)` is the same as its name;
- each refusal raises its class with its full message: a multiple of a unit,
  a unit that is not built, a duration that is not a str, an input that is
  not a Date or a Datetime, a Datetime with a time zone, every window option
  other than polars' default, an index that is also a group_by key, an index
  that is not a column name, an unknown column;
- `collect()` hands the session the plan bytes of the frame.

The values are compared with polars' in pl_oracle/test_pl_oracle_dynamic.py.
The test loads no library and is of the `pl/` family (python/tests/BUCK).

    test_pl_dynamic.py
"""

import os
import tempfile

import pyarrow as pa

import komira.pl as kpl
from komira import Session, UnsupportedOperation
from komira._ops import Agg, Aggregate, Cast, ColRef, Extract, Field, Filter, Scan, Unary, with_columns
from komira._plan import encode_plan
from komira._plan._wire import arrow_id, field, pb

# Never opened: the stand-in answers its schema.
PATH = os.path.join(tempfile.gettempdir(), "dynamic.parquet")
TYPES = [
    ("id", "int64"),
    ("x", "int64"),
    ("g", "string"),
    ("d", "date32"),
    ("ts", "timestamp_us"),
    ("tms", "timestamp_ms"),
    ("tns", "timestamp_ns"),
    ("zoned", "timestamp_us"),
]
T = Scan(PATH, "parquet", tuple(Field(n, t) for n, t in TYPES))
LISTED = "'1d', '1w' or '1mo'"
UNITS = {"1d": "trunc_day", "1w": "trunc_week", "1mo": "trunc_month"}


class StandIn(Session):
    """A session with no library: the schema of TYPES, `zoned` in UTC, and
    the plans it is given recorded."""

    def __init__(self):
        self.ran = []

    def _parquet_schema(self, path):
        fields = []
        for n, t in TYPES:
            f = field(n, arrow_id(t), True)
            if n == "zoned":
                f.tz = "UTC"
            fields.append(f)
        return pb.WireSchema(fields=fields).SerializeToString()

    def _plan_stream(self, plan):
        self.ran.append(plan)
        return "result"

    def close(self):
        pass


SESSION = StandIn()


def frame():
    return kpl.scan_parquet(PATH, session=SESSION)


def raised(call):
    try:
        call()
    except BaseException as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refused(call, cls, message):
    e = raised(call)
    assert type(e) is cls, (type(e), e)
    text = e.args[0] if isinstance(e, KeyError) else str(e)
    assert text == message, text


def c(name):
    return ColRef(name)


# ---- dt.truncate ---------------------------------------------------------------


def test_truncate_is_the_extract_of_its_unit_and_keeps_name_and_type():
    for every, unit in UNITS.items():
        for column in ("d", "ts", "tms", "tns"):
            lf = frame().with_columns(kpl.col(column).dt.truncate(every))
            assert lf._plan == with_columns(T, ((column, Extract(unit, c(column))),)), (every, column)
            assert lf.schema == frame().schema, (every, column)
    lf = frame().select(kpl.col("d").dt.truncate("1w").alias("week"), "x")
    assert lf.schema == {"week": pa.date32(), "x": pa.int64()}
    assert lf._plan.items[0] == ("week", Extract("trunc_week", c("d")))
    assert frame().select(kpl.col("tns").dt.truncate("1mo")).schema == {"tns": pa.timestamp("ns")}


def test_truncate_in_a_filter_compares_the_truncated_value():
    lf = frame().filter(kpl.col("d").dt.truncate("1mo") == kpl.col("d"))
    assert isinstance(lf._plan, Filter)
    assert lf._plan.predicate.left == Extract("trunc_month", c("d"))


def test_truncate_refusals():
    refused(
        lambda: kpl.col("d").dt.truncate("2d"),
        UnsupportedOperation,
        f"dt.truncate: every='2d' is a multiple of a unit, and the plan cuts to one whole day, week or month: use {LISTED}",
    )
    refused(
        lambda: kpl.col("d").dt.truncate("3mo"),
        UnsupportedOperation,
        f"dt.truncate: every='3mo' is a multiple of a unit, and the plan cuts to one whole day, week or month: use {LISTED}",
    )
    for every in ("1h", "1q", "1y", "1D", "week", ""):
        refused(
            lambda: kpl.col("d").dt.truncate(every),
            UnsupportedOperation,
            f"dt.truncate: every={every!r} is not a duration this release truncates to: use {LISTED}",
        )
    refused(
        lambda: kpl.col("d").dt.truncate(7),
        TypeError,
        "dt.truncate: every must be a duration string such as '1w', not int",
    )
    refused(
        lambda: frame().select(kpl.col("x").dt.truncate("1d")),
        TypeError,
        "dt.truncate needs a Date or a Datetime expression, and this one is of type int64",
    )
    refused(
        lambda: frame().select(kpl.col("g").dt.truncate("1d")),
        TypeError,
        "dt.truncate needs a Date or a Datetime expression, and this one is of type string",
    )
    refused(
        lambda: frame().select(kpl.col("zoned").dt.truncate("1d")),
        UnsupportedOperation,
        "dt.truncate of a Datetime with the time zone UTC is not supported: polars truncates it by the "
        "local day, which the plan does not compute",
    )


# ---- group_by_dynamic ---------------------------------------------------------


def by_hand(index, every, keys=()):
    """The frame group_by_dynamic groups, built from its parts by hand."""
    lf = frame().filter(kpl.col(index).is_not_null())
    return lf.with_columns(kpl.col(index).dt.truncate(every)).group_by(*keys, index)


def test_group_by_dynamic_is_group_by_of_the_truncated_index_with_nulls_left_out():
    for every in UNITS:
        got = frame().group_by_dynamic("d", every=every).agg(kpl.col("x").sum(), kpl.len())
        want = by_hand("d", every).agg(kpl.col("x").sum(), kpl.len())
        assert got._plan == want._plan, every
        assert list(got.schema) == ["d", "x", "len"], got.schema


def test_a_datetime_window_is_grouped_as_its_ticks_and_cast_back():
    # The engine groups by no timestamp key: the window's start is grouped as
    # its int64 count of ticks, and the key is cast back above the aggregate.
    for every, unit in UNITS.items():
        for index, unit_name in (("ts", "us"), ("tms", "ms"), ("tns", "ns")):
            arrow = "timestamp_" + unit_name
            got = frame().group_by_dynamic(index, every=every).agg(kpl.col("x").max())
            start = Cast(Extract(unit, c(index)), "int64")
            inner = with_columns(Filter(T, Unary("is_not_null", c(index))), ((index, start),))
            aggregate = Aggregate(inner, (index,), (("x", Agg("max", (c("x"),))),))
            want = with_columns(aggregate, ((index, Cast(c(index), None, arrow=arrow)),))
            assert got._plan == want, (every, index, got._plan)
            assert got.schema == {index: pa.timestamp(unit_name), "x": pa.int64()}, got.schema
    keyed = frame().group_by_dynamic("ts", every="1w", group_by="g").len()
    assert list(keyed.schema) == ["g", "ts", "len"]
    assert keyed.schema["ts"] == pa.timestamp("us")
    got = frame().group_by_dynamic("d", every="1w").agg(kpl.col("x").max())
    aggregate = got._plan
    assert aggregate.keys == ("d",)
    assert aggregate.aggs == (("x", Agg("max", (c("x"),))),)
    child = aggregate.child
    assert child.items[3] == ("d", Extract("trunc_week", c("d"))), child.items
    assert child.child == Filter(T, Unary("is_not_null", c("d")))
    assert got.schema == {"d": pa.date32(), "x": pa.int64()}


def test_group_by_keys_come_before_the_index_and_defaults_may_be_named():
    got = frame().group_by_dynamic("d", every="1mo", group_by="g").agg(kpl.col("x").sum())
    assert got._plan == by_hand("d", "1mo", ("g",)).agg(kpl.col("x").sum())._plan
    assert list(got.schema) == ["g", "d", "x"]
    two = frame().group_by_dynamic("ts", every="1d", group_by=["g", kpl.col("id")]).agg(kpl.len())
    assert list(two.schema) == ["g", "id", "ts", "len"]
    named = frame().group_by_dynamic(
        kpl.col("d"),
        every="1w",
        period="1w",
        offset=None,
        include_boundaries=False,
        closed="left",
        label="left",
        start_by="window",
    )
    assert named.agg(kpl.len())._plan == frame().group_by_dynamic("d", every="1w").agg(kpl.len())._plan
    assert repr(named) == "<komira.pl.LazyGroupBy by [d]>"


def test_group_by_dynamic_refusals():
    lf = frame()
    for name, value, default in (
        ("closed", "right", "'left'"),
        ("closed", "both", "'left'"),
        ("label", "right", "'left'"),
        ("label", "datapoint", "'left'"),
        ("start_by", "datapoint", "'window'"),
        ("start_by", "monday", "'window'"),
        ("include_boundaries", True, "False"),
        ("include_boundaries", 0, "False"),
    ):
        refused(
            lambda: lf.group_by_dynamic("d", every="1d", **{name: value}),
            UnsupportedOperation,
            f"group_by_dynamic: {name}={value!r} is not supported; the windows built are polars' default, "
            f"{name}={default}",
        )
    moved = (
        "group_by_dynamic: period and offset move the windows off whole days, weeks and months, which is "
        "not supported; leave them at their default"
    )
    refused(lambda: lf.group_by_dynamic("d", every="1d", period="2d"), UnsupportedOperation, moved)
    refused(lambda: lf.group_by_dynamic("d", every="1d", offset="1h"), UnsupportedOperation, moved)
    refused(
        lambda: lf.group_by_dynamic("d", every="1h"),
        UnsupportedOperation,
        f"group_by_dynamic: every='1h' is not a duration this release truncates to: use {LISTED}",
    )
    refused(
        lambda: lf.group_by_dynamic("d", every="2w"),
        UnsupportedOperation,
        "group_by_dynamic: every='2w' is a multiple of a unit, and the plan cuts to one whole day, week or "
        f"month: use {LISTED}",
    )
    refused(
        lambda: lf.group_by_dynamic("x", every="1d"),
        TypeError,
        "group_by_dynamic needs a Date or a Datetime expression, and this one is of type int64",
    )
    refused(
        lambda: lf.group_by_dynamic("zoned", every="1d"),
        UnsupportedOperation,
        "group_by_dynamic of a Datetime with the time zone UTC is not supported: polars truncates it by the "
        "local day, which the plan does not compute",
    )
    refused(
        lambda: lf.group_by_dynamic("d", every="1d", group_by=["g", "d"]),
        ValueError,
        "group_by_dynamic: the column 'd' is both the index and a group_by key",
    )
    refused(
        lambda: lf.group_by_dynamic(["d"], every="1d"),
        TypeError,
        "group_by_dynamic: index_column is a column name or komira.pl.col(...), not list",
    )
    assert type(raised(lambda: lf.group_by_dynamic("nope", every="1d"))) is KeyError


def test_collect_hands_the_session_the_plan_bytes():
    SESSION.ran.clear()
    lf = frame().group_by_dynamic("d", every="1mo").agg(kpl.col("x").sum())
    assert SESSION.ran == []
    lf.collect()
    assert SESSION.ran == [encode_plan(lf._plan, lf._sources).SerializeToString()]


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("pl_dynamic: {} tests passed".format(len(tests)))


if __name__ == "__main__":
    main()
