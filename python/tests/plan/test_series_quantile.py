"""`Series.quantile` (komira/_series.py) with no libkomira: a frame over a
Parquet scan whose schema is made here, on a session stand-in that records the
plan bytes it is given and answers with one row. Checked:

- the plan it runs: one AGGREGATE, over the frame's plan and no keys, of
  `quantile_cont` of the Series' expression and the fraction as a float
  literal, with a boolean Series cast to float64 first; a computed Series reads
  its expression;
- the answer is a Python float; no value (a missing answer) is NaN;
- the fraction: an int or a float from 0 to 1 is served, a bool or a
  non-number is a `TypeError`, one outside the interval is a `ValueError` with
  pandas' words, and a list-like of fractions is refused by name;
- `interpolation` other than "linear" is refused by name;
- a Series that is not numeric or boolean, and one that reads windows, are
  refused by name;
- a refused call runs nothing; a Series taken before `df["x"] = ...` replaced
  the frame's columns is refused.

The test loads no library. It is of the `plan/` family (python/tests/BUCK), on
the same runtimes as `frame_test`.

    test_series_quantile.py
"""

import math
import os
import sys
import tempfile

from komira import _ops
from komira._errors import UnsupportedOperation
from komira._frame import DataFrame
from komira._ops import Agg, Cast, ColRef, Field, Lit
from komira._plan import parquet_source
from komira._plan._wire import arrow_id, field, pb

PATH = os.path.join(tempfile.gettempdir(), "series_quantile_test_input.parquet")
FIELDS = (("n", "int64"), ("x", "float64"), ("s", "string"), ("ok", "bool"))


class Column:
    def __init__(self, values):
        self.values = values

    def to_pylist(self):
        return self.values


class Table:
    def __init__(self, value):
        self.value = value

    def column(self, index):
        assert index == 0
        return Column([self.value])


class Rows:
    def __init__(self, value):
        self.value = value

    def to_arrow(self):
        return Table(self.value)


class Stub:
    """A session that records what the plan door is given and answers `answer`."""

    def __init__(self, answer):
        self.calls = []
        self.answer = answer

    def _plan_stream(self, plan):
        self.calls.append(plan)
        return Rows(self.answer)


class Env:
    def __init__(self, answer=2.5):
        self.stub = Stub(answer)
        schema = pb.WireSchema(fields=[field(n, arrow_id(t), True) for n, t in FIELDS])
        sources = {PATH: parquet_source(PATH, schema.SerializeToString())}
        self.scan = _ops.scan(PATH, "parquet", tuple(Field(n, t) for n, t in FIELDS))
        self.df = DataFrame._new(self.stub, self.scan, sources)


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def sent(env, node):
    """The frame whose plan is the one-row aggregate of `node`: its bytes are
    what the session must have been given."""
    plan = _ops.aggregate(env.scan, (), (("q", Agg("quantile_cont", node)),))
    return env.df._derive(plan)._plan_bytes()


def test_quantile_runs_one_aggregate_of_quantile_cont_and_returns_a_float():
    env = Env(2.5)
    got = env.df["x"].quantile(0.25)
    assert got == 2.5 and type(got) is float
    assert env.stub.calls == [sent(env, (ColRef("x"), Lit(0.25)))]


def test_quantile_defaults_to_the_median_by_linear_interpolation():
    env = Env()
    env.df["n"].quantile()
    env.df["n"].quantile(q=0.5, interpolation="linear")
    assert env.stub.calls == [sent(env, (ColRef("n"), Lit(0.5)))] * 2


def test_quantile_accepts_the_ends_of_the_interval_and_an_int_fraction():
    env = Env()
    for q in (0, 1, 0.0, 1.0):
        env.df["x"].quantile(q)
    assert env.stub.calls == [sent(env, (ColRef("x"), Lit(float(q)))) for q in (0, 1, 0.0, 1.0)]
    assert all(type(c) is bytes for c in env.stub.calls)


def test_quantile_of_a_computed_series_reads_its_expression():
    env = Env()
    df = env.df
    doubled = df["x"] * 2
    doubled.quantile(0.5)
    assert env.stub.calls == [sent(env, (doubled._node, Lit(0.5)))]


def test_quantile_of_a_boolean_series_reads_it_as_float64():
    env = Env()
    env.df["ok"].quantile(0.5)
    assert env.stub.calls == [sent(env, (Cast(ColRef("ok"), "float64"), Lit(0.5)))]


def test_quantile_with_no_value_is_nan():
    env = Env(None)
    got = env.df["x"].quantile(0.5)
    assert type(got) is float and math.isnan(got)


def test_quantile_of_an_int_answer_is_a_float():
    env = Env(3)
    got = env.df["n"].quantile(0.5)
    assert got == 3.0 and type(got) is float


def test_a_fraction_outside_zero_to_one_is_a_value_error_with_pandas_words():
    env = Env()
    for q in (-0.1, 1.5, 2, -1, float("nan"), float("inf")):
        refuses(
            lambda: env.df["x"].quantile(q), ValueError, "percentiles should all be in the interval [0, 1]"
        )
    assert env.stub.calls == []


def test_a_fraction_that_is_not_a_number_is_a_type_error():
    env = Env()
    refuses(lambda: env.df["x"].quantile("0.5"), TypeError, "quantile q must be a number from 0 to 1, not str")
    refuses(lambda: env.df["x"].quantile(None), TypeError, "quantile q must be a number from 0 to 1, not NoneType")
    refuses(lambda: env.df["x"].quantile(True), TypeError, "quantile q must be a number from 0 to 1, not bool")
    assert env.stub.calls == []


def test_several_fractions_are_refused_by_name():
    env = Env()
    message = (
        "quantile() of several fractions gives a Series indexed by them in pandas, and a komira Series "
        "has no index: ask for one fraction at a time, as s.quantile(0.25)"
    )
    for q in ([0.25, 0.75], (0.5,), [], range(2)):
        refuses(lambda: env.df["x"].quantile(q), UnsupportedOperation, message)
    assert env.stub.calls == []


def test_an_interpolation_other_than_linear_is_refused_by_name():
    env = Env()
    for how in ("lower", "higher", "nearest", "midpoint", "bogus"):
        refuses(
            lambda: env.df["x"].quantile(0.5, interpolation=how),
            UnsupportedOperation,
            f"quantile(interpolation={how!r}) is not supported: only 'linear' is, which is SQL's quantile_cont",
        )
    assert env.stub.calls == []


def test_a_series_that_is_not_numeric_is_refused_by_name():
    env = Env()
    refuses(
        lambda: env.df["s"].quantile(0.5),
        UnsupportedOperation,
        "quantile() needs a numeric or boolean Series, and this one is string",
    )
    assert env.stub.calls == []


def test_a_series_that_reads_windows_is_refused_by_name():
    env = Env()
    running = env.df.sort_values("n")["x"].cumsum()
    refuses(
        lambda: running.quantile(0.5),
        UnsupportedOperation,
        "quantile() of a Series that reads windows is not supported: assign it as a column first, "
        'as df.assign(x=...), then take df["x"]',
    )
    assert env.stub.calls == []


def test_a_series_taken_before_the_frame_changed_is_refused():
    env = Env()
    old = env.df["x"]
    env.df["y"] = env.df["x"] + 1
    e = raised(lambda: old.quantile(0.5))
    assert type(e) is UnsupportedOperation and "was taken from its frame before" in e.args[0], repr(e)
    assert env.stub.calls == []


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("series quantile: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
