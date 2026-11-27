"""`komira.to_datetime` (komira/_to_datetime.py) with no libkomira: a frame over
a Parquet scan whose schema is made here, on a session stand-in that records
the plan bytes it is given. Checked:

- each unit ("s", "ms", "us", "ns", and no unit, which pandas reads as "ns")
  builds the node SQL's make_timestamp builds, by equality with a hand-built
  tree, and the result's dtype;
- a narrower integer is widened to int64 first, and every integer dtype that
  fits in int64 is accepted;
- the result is a Series of the same frame: it can be assigned as a column and
  the plan reaches the session only at the terminal;
- every refusal by class and full message: a non-integer Series, a value that
  is not a Series, an unknown unit, and each pandas argument for parsing text
  or for zones, a non-unix origin and errors other than "raise";
- a stale Series is refused.

    test_to_datetime.py
"""

import os
import sys
import tempfile

import komira
from komira import _ops
from komira._errors import UnsupportedOperation
from komira._frame import DataFrame
from komira._ops import Arith, Cast, ColRef, Field, Lit
from komira._plan import parquet_source
from komira._plan._wire import arrow_id, field, pb

# Never opened: the scan only names the file, and the schema is given here.
PATH = os.path.join(tempfile.gettempdir(), "to_datetime_test_input.parquet")
FIELDS = (
    ("a", "int64"),
    ("i8", "int8"),
    ("i16", "int16"),
    ("n", "int32"),
    ("u8", "uint8"),
    ("u16", "uint16"),
    ("u32", "uint32"),
    ("u64", "uint64"),
    ("f", "float64"),
    ("s", "string"),
    ("t", "timestamp_us"),
    ("ok", "bool"),
)
A = ColRef("a")


class Stub:
    """A session that records what the plan door is given."""

    def __init__(self):
        self.calls = []
        self.stream = object()

    def _plan_stream(self, plan):
        self.calls.append(("plan_stream", plan))
        return self.stream

    def _plan_render(self, plan):
        self.calls.append(("plan_render", plan))
        return "rendered plan"


class Env:
    def __init__(self):
        self.stub = Stub()
        schema = pb.WireSchema(fields=[field(n, arrow_id(t), True) for n, t in FIELDS])
        self.sources = {PATH: parquet_source(PATH, schema.SerializeToString())}
        self.scan = _ops.scan(PATH, "parquet", tuple(Field(n, t) for n, t in FIELDS))
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


def check(result, node, dtype):
    assert result._node == node, (result._node, node)
    assert result.dtype == dtype, (result.dtype, dtype)


def test_seconds_and_milliseconds_are_scaled_to_microseconds_by_a_checked_multiply():
    a = Env().df["a"]
    check(komira.to_datetime(a, unit="s"), Cast(Arith("mul", A, Lit(1_000_000)), None, arrow="timestamp_us"), "timestamp_us")
    check(komira.to_datetime(a, unit="ms"), Cast(Arith("mul", A, Lit(1_000)), None, arrow="timestamp_us"), "timestamp_us")


def test_microseconds_and_nanoseconds_are_relabelled():
    a = Env().df["a"]
    check(komira.to_datetime(a, unit="us"), Cast(A, None, arrow="timestamp_us"), "timestamp_us")
    check(komira.to_datetime(a, unit="ns"), Cast(A, None, arrow="timestamp_ns"), "timestamp_ns")


def test_no_unit_means_nanoseconds_as_in_pandas():
    a = Env().df["a"]
    check(komira.to_datetime(a), Cast(A, None, arrow="timestamp_ns"), "timestamp_ns")


def test_every_integer_that_fits_in_int64_is_widened_first():
    df = Env().df
    for name in ("i8", "i16", "n", "u8", "u16", "u32"):
        wide = Cast(ColRef(name), "int64")
        check(komira.to_datetime(df[name], unit="s"), Cast(Arith("mul", wide, Lit(1_000_000)), None, arrow="timestamp_us"), "timestamp_us")
        check(komira.to_datetime(df[name], unit="us"), Cast(wide, None, arrow="timestamp_us"), "timestamp_us")


def test_an_expression_series_is_converted_too():
    a = Env().df["a"]
    check(
        komira.to_datetime(a + 1, unit="us"),
        Cast(Arith("add", A, Lit(1)), None, arrow="timestamp_us"),
        "timestamp_us",
    )


def test_the_result_is_a_column_of_the_same_frame_and_runs_nothing():
    env = Env()
    df = env.df
    df["ts"] = komira.to_datetime(df["a"], unit="ms")
    assert df.dtypes["ts"] == "timestamp_us"
    assert df["ts"].dt.year._node == _ops.Extract("year", ColRef("ts"))
    assert env.stub.calls == []


def test_a_series_that_is_not_an_integer_count_is_refused_by_its_dtype():
    df = Env().df
    for name, dtype in (("u64", "uint64"), ("f", "float64"), ("s", "string"), ("t", "timestamp_us"), ("ok", "bool")):
        refuses(
            lambda: komira.to_datetime(df[name], unit="s"),
            UnsupportedOperation,
            f"komira.to_datetime(<a {dtype} Series>) is not supported: it takes a Series of integer counts of "
            "unit='s'; a float, uint64, text or temporal Series is not served",
        )


def test_a_value_that_is_not_a_series_is_refused():
    for value, kind in ((1788220800, "int"), ([1788220800], "list"), ("2026-09-01", "str")):
        refuses(
            lambda: komira.to_datetime(value, unit="s"),
            UnsupportedOperation,
            f"komira.to_datetime(<{kind}>) is not supported: it takes a komira Series of integers, "
            'as komira.to_datetime(df["column"], unit="s")',
        )


def test_an_unknown_unit_is_refused():
    a = Env().df["a"]
    for unit in ("D", "h", "m", "seconds", 1):
        refuses(
            lambda: komira.to_datetime(a, unit=unit),
            UnsupportedOperation,
            f'komira.to_datetime(unit={unit!r}) is not supported: unit is one of "s", "ms", "us" and "ns"',
        )


def test_the_text_parsing_arguments_are_refused_by_name():
    a = Env().df["a"]
    refuses(
        lambda: komira.to_datetime(a, format="%Y-%m-%d"),
        UnsupportedOperation,
        "komira.to_datetime(format=...) is not supported: parsing text into timestamps is not served; "
        "it takes integer counts with unit=",
    )
    for kwargs, name in (
        ({"dayfirst": True}, "dayfirst"),
        ({"yearfirst": True}, "yearfirst"),
        ({"exact": True}, "exact"),
        ({"infer_datetime_format": True}, "infer_datetime_format"),
    ):
        refuses(
            lambda: komira.to_datetime(a, unit="s", **kwargs),
            UnsupportedOperation,
            f"komira.to_datetime({name}=...) is not supported: it is for parsing text, which is not served",
        )


def test_utc_origin_and_errors_are_refused_by_name():
    a = Env().df["a"]
    refuses(
        lambda: komira.to_datetime(a, unit="s", utc=True),
        UnsupportedOperation,
        "komira.to_datetime(utc=True) is not supported: the answer is a naive timestamp; "
        "a zone-aware timestamp is not served",
    )
    for errors in ("coerce", "ignore"):
        refuses(
            lambda: komira.to_datetime(a, unit="s", errors=errors),
            UnsupportedOperation,
            f"komira.to_datetime(errors={errors!r}) is not supported: a value that does not convert raises; "
            'use errors="raise", the default',
        )
    for origin in ("julian", 0):
        refuses(
            lambda: komira.to_datetime(a, unit="s", origin=origin),
            UnsupportedOperation,
            f"komira.to_datetime(origin={origin!r}) is not supported: the counts are since the Unix epoch, "
            'origin="unix", the default',
        )


def test_cache_is_accepted_and_must_be_a_bool():
    a = Env().df["a"]
    check(komira.to_datetime(a, unit="us", cache=False), Cast(A, None, arrow="timestamp_us"), "timestamp_us")
    refuses(lambda: komira.to_datetime(a, unit="us", cache="no"), TypeError, "to_datetime() cache must be a bool, not a str")


def test_a_stale_series_is_refused():
    df = Env().df
    a = df["a"]
    df["z"] = 1
    refuses(
        lambda: komira.to_datetime(a, unit="s"),
        UnsupportedOperation,
        'this Series was taken from its frame before df["name"] = ... replaced the frame\'s columns: '
        "take it from the frame again",
    )


def test_the_name_is_public_and_no_longer_a_module_refusal():
    assert "to_datetime" in komira.__all__
    assert komira.to_datetime.__module__ == "komira._to_datetime"


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("to_datetime: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
