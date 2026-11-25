"""`Series.astype`, `Series.str` and `Series.dt` (komira/_cast.py,
komira/_accessors.py, komira/_series.py) with no libkomira: a frame over a
Parquet scan whose schema is made here, on a session stand-in that records the
plan bytes it is given. Checked:

- the dtype parser, for every accepted spelling (names, pandas spellings,
  builtins, pyarrow types recognised without pyarrow) and every refused one,
  and the cast node each target builds;
- `astype` of a Series: the node, the resulting type, a cast to the type it
  has already, and the `copy` and `errors` arguments;
- each `.str` method: the node it builds by equality with a hand-built tree,
  the type of the result, and every refusal by class and full message;
- each `.dt` property and `floor`: the same, for a timestamp and a date32
  column, with the parts a date has no value for refused;
- the accessor attribute rules: `hasattr` is False on a Series of the wrong
  type with the accessor's message, every row of the STRING and DATETIME tables,
  Python's own message for any other name, no attribute can be set, `dir` lists
  the defined members only, and a stale Series is refused;
- a `.str` result used as a filter and as an assigned column builds the
  expected plan, and the encoded plan reaches the session only at the terminal.

    test_series_accessors.py
"""

import os
import re
import sys
import tempfile

from komira import _cast, _ops, _refusals
from komira._accessors import DatetimeMethods, StringMethods
from komira._errors import UnsupportedOperation
from komira._frame import DataFrame
from komira._ops import Arith, Cast, ColRef, Compare, Extract, Field, Lit, Regexp, StringFn, StringFnN, StringOp, Substring, When
from komira._plan import encode_plan, parquet_source
from komira._plan._wire import arrow_id, field, pb

# Never opened: the scan only names the file, and the schema is given here.
PATH = os.path.join(tempfile.gettempdir(), "series_accessors_test_input.parquet")
FIELDS = (
    ("a", "int64"),
    ("n", "int32"),
    ("f", "float32"),
    ("s", "string"),
    ("t", "timestamp_us"),
    ("d", "date32"),
    ("ok", "bool"),
)
SCAN = _ops.scan(PATH, "parquet", tuple(Field(name, dtype) for name, dtype in FIELDS))
LISTED = "bool, int8, int16, int32, int64, uint8, uint16, uint32, uint64, float32, float64, string, binary, date32"
S, T, D = ColRef("s"), ColRef("t"), ColRef("d")


class Stub:
    """A session that records what the plan door and the renderer are given."""

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
    def __init__(self, fields=FIELDS):
        self.stub = Stub()
        schema = pb.WireSchema(fields=[field(n, arrow_id(t), True) for n, t in fields])
        self.sources = {PATH: parquet_source(PATH, schema.SerializeToString())}
        self.scan = _ops.scan(PATH, "parquet", tuple(Field(n, t) for n, t in fields))
        self.df = DataFrame._new(self.stub, self.scan, self.sources)


class FakeArrowType:
    """What the parser sees of a pyarrow type: a class of a pyarrow module, and the type's text."""

    __module__ = "pyarrow.lib"

    def __init__(self, text):
        self.text = text

    def __str__(self):
        return self.text


class NotArrow:
    """A class of another module whose text looks like an Arrow type."""

    def __str__(self):
        return "int64"


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def series(name):
    return Env().df[name]


def check(result, node, dtype):
    """`result`, a Series, holds `node` and has the type `dtype`."""
    assert result._node == node, (result._node, node)
    assert result.dtype == dtype, (result.dtype, dtype)


# --- the dtype parser -----------------------------------------------------------


def test_every_accepted_dtype_spelling_names_its_arrow_type():
    accepted = {
        **{n: n for n in LISTED.split(", ")},
        **{f"Int{b}": f"int{b}" for b in (8, 16, 32, 64)},
        **{f"UInt{b}": f"uint{b}" for b in (8, 16, 32, 64)},
        "Float32": "float32",
        "Float64": "float64",
        "boolean": "bool",
        "str": "string",
        bool: "bool",
        int: "int64",
        float: "float64",
        str: "string",
    }
    for spelled, name in accepted.items():
        assert _cast.parse_dtype(spelled, "astype") == name, spelled
    arrow = {
        "bool": "bool",
        "int8": "int8",
        "int16": "int16",
        "int32": "int32",
        "int64": "int64",
        "uint8": "uint8",
        "uint16": "uint16",
        "uint32": "uint32",
        "uint64": "uint64",
        "float": "float32",
        "double": "float64",
        "string": "string",
        "utf8": "string",
        "binary": "binary",
        "date32[day]": "date32",
    }
    for text, name in arrow.items():
        assert _cast.parse_dtype(FakeArrowType(text), "astype") == name, text


def test_object_and_category_name_no_one_arrow_type():
    tail = f" names no one Arrow type, and a komira column has exactly one: cast to one of {LISTED}"
    refuses(lambda: _cast.parse_dtype("object", "astype"), UnsupportedOperation, "astype('object')" + tail)
    refuses(lambda: _cast.parse_dtype("category", "astype"), UnsupportedOperation, "astype('category')" + tail)
    refuses(lambda: _cast.parse_dtype(object, "astype"), UnsupportedOperation, "astype(object)" + tail)


def test_an_unknown_dtype_text_or_object_is_a_type_error_and_another_arrow_type_is_refused_by_name():
    refuses(
        lambda: _cast.parse_dtype("integer", "astype"),
        TypeError,
        f"data type 'integer' not understood: astype() takes {LISTED}, a pandas spelling such as 'Int64', or a pyarrow type",
    )
    for value, name in ((3.5, "float"), (None, "NoneType"), (["int64"], "list"), (NotArrow(), "NotArrow")):
        refuses(
            lambda value=value: _cast.parse_dtype(value, "astype"),
            TypeError,
            f"astype() takes a dtype name or a pyarrow type, not a {name}: it casts to {LISTED}",
        )
    refuses(
        lambda: _cast.parse_dtype(FakeArrowType("timestamp[us]"), "astype"),
        UnsupportedOperation,
        f"astype() cannot cast to the Arrow type timestamp[us]: it casts to {LISTED}",
    )


def test_a_cast_node_is_a_primitive_cast_or_an_arrow_cast_and_none_for_the_same_type():
    node = ColRef("a")
    assert _cast.cast_node(node, "int64", "int32", "astype") == Cast(node, "int32")
    assert _cast.cast_node(node, "int64", "uint8", "astype") == Cast(node, "uint8")
    assert _cast.cast_node(node, "int64", "string", "astype") == Cast(node, None, arrow="string")
    assert _cast.cast_node(node, "int64", "binary", "astype") == Cast(node, None, arrow="binary")
    assert _cast.cast_node(node, "string", "date32", "astype") == Cast(node, None, arrow="date32")
    assert _cast.cast_node(node, "int64", "Int64", "astype") is None
    assert _cast.cast_node(node, "string", str, "astype") is None
    assert _cast.cast_node(node, "large_string", "string", "astype") == Cast(node, None, arrow="string")
    for cast in (_cast.cast_node(node, "int64", "string", "astype"), _cast.cast_node(node, "int64", "int8", "astype")):
        assert cast.try_cast is False


# --- astype -----------------------------------------------------------------------


def test_astype_builds_a_cast_with_the_type_of_the_target():
    df = Env().df
    check(df["n"].astype("int64"), Cast(ColRef("n"), "int64"), "int64")
    check(df["a"].astype(float), Cast(ColRef("a"), "float64"), "float64")
    check(df["f"].astype("Float64"), Cast(ColRef("f"), "float64"), "float64")
    check(df["a"].astype(str), Cast(ColRef("a"), None, arrow="string"), "string")
    check(df["s"].astype("date32"), Cast(S, None, arrow="date32"), "date32")
    check(df["a"].astype(FakeArrowType("double")), Cast(ColRef("a"), "float64"), "float64")


def test_astype_to_the_type_it_has_returns_a_series_of_the_same_node():
    df = Env().df
    same = df["a"].astype("int64")
    assert same._node == ColRef("a") and same.dtype == "int64" and same is not df["a"]
    assert df["s"].astype(str)._node == S


def test_astype_of_a_computed_series_casts_the_expression_and_stays_usable_in_assign():
    df = Env().df
    doubled = (df["a"] * 2).astype("string")
    assert doubled._node == Cast(Arith("mul", ColRef("a"), Lit(2)), None, arrow="string")
    got = df.assign(u=doubled)
    assert got._plan == _ops.with_columns(SCAN, (("u", doubled._node),))
    assert got.dtypes["u"] == "string"


def test_astype_arguments_copy_is_ignored_and_errors_other_than_raise_is_refused():
    df = Env().df
    assert df["n"].astype("int64", copy=False)._node == Cast(ColRef("n"), "int64")
    assert df["n"].astype("int64", copy=True)._node == Cast(ColRef("n"), "int64")
    assert df["n"].astype("int64", errors="raise")._node == Cast(ColRef("n"), "int64")
    refuses(
        lambda: df["n"].astype("int64", copy="yes"),
        TypeError,
        "astype() copy must be a bool or None, not a str",
    )
    refuses(
        lambda: df["n"].astype("int64", errors="ignore"),
        UnsupportedOperation,
        'astype(errors="ignore") would return the column uncast when a value does not convert, '
        'which a plan cannot decide before it runs: use errors="raise", the default',
    )
    for errors in ("coerce", None, 3):
        refuses(
            lambda errors=errors: df["n"].astype("int64", errors=errors),
            ValueError,
            f"Expected value of kwarg 'errors' to be one of ['raise', 'ignore']. Supplied value is {errors!r}",
        )


def test_astype_refuses_a_dtype_the_parser_refuses_and_a_stale_series():
    df = Env().df
    s = df["a"]
    refuses(
        lambda: s.astype("object"),
        UnsupportedOperation,
        f"astype('object') names no one Arrow type, and a komira column has exactly one: cast to one of {LISTED}",
    )
    refuses(
        lambda: s.astype("integer"),
        TypeError,
        f"data type 'integer' not understood: astype() takes {LISTED}, a pandas spelling such as 'Int64', or a pyarrow type",
    )
    df["z"] = 1
    refuses(
        lambda: s.astype("int32"),
        UnsupportedOperation,
        'this Series was taken from its frame before df["name"] = ... replaced the frame\'s columns: '
        "take it from the frame again",
    )


# --- .str ---------------------------------------------------------------------------


def test_lower_upper_and_len_build_string_functions_and_len_is_int64():
    s = series("s")
    check(s.str.lower(), StringFn("lower", S), "string")
    check(s.str.upper(), StringFn("upper", S), "string")
    check(s.str.len(), StringFn("length", S), "int64")
    assert series("s").str.lower().str.upper()._node == StringFn("upper", StringFn("lower", S))


def test_startswith_and_endswith_build_string_tests_and_refuse_a_tuple_a_non_str_and_na():
    s = series("s")
    check(s.str.startswith("ab"), StringOp("starts_with", S, "ab"), "bool")
    check(s.str.endswith("yz", na=None), StringOp("ends_with", S, "yz"), "bool")
    refuses(
        lambda: s.str.startswith(("a", "b")),
        UnsupportedOperation,
        "str.startswith() of a tuple of prefixes is not supported: combine one str.startswith() per value with |",
    )
    refuses(
        lambda: s.str.endswith(("a", "b")),
        UnsupportedOperation,
        "str.endswith() of a tuple of suffixes is not supported: combine one str.endswith() per value with |",
    )
    refuses(lambda: s.str.startswith(1), TypeError, "str.startswith(): pat must be a str, not int")
    refuses(lambda: s.str.endswith(None), TypeError, "str.endswith(): pat must be a str, not NoneType")
    refuses(
        lambda: s.str.startswith("a", na=True),
        UnsupportedOperation,
        "str.startswith(na=True) would give a chosen value for a missing value, and a komira result stays "
        "missing there: leave na out, and a filter df[cond] drops the rows where it is missing",
    )


def test_contains_is_a_regular_expression_search_or_a_text_test():
    s = series("s")
    check(s.str.contains("a.c"), Regexp("like", S, "a.c"), "bool")
    check(s.str.contains("a.c", case=False), Regexp("like", S, "a.c", flags="i"), "bool")
    check(s.str.contains("a.c", regex=False), StringOp("contains", S, "a.c"), "bool")
    check(s.str.contains("a.c", case=True, flags=0, na=None, regex=False), StringOp("contains", S, "a.c"), "bool")


def test_contains_refusals_by_message():
    s = series("s")
    refuses(
        lambda: s.str.contains("a", case=False, regex=False),
        UnsupportedOperation,
        "str.contains(case=False, regex=False) is not supported: the text test is case-sensitive; "
        "escape the text with re.escape() and use regex=True with case=False",
    )
    refuses(
        lambda: s.str.contains("a", flags=2),
        UnsupportedOperation,
        "str.contains(flags=2) is not supported: the engine's regular expressions take no Python flags; "
        "pass case=False to ignore case",
    )
    refuses(lambda: s.str.contains(re.compile("a")), TypeError, "str.contains(): pat must be a str, not Pattern")
    refuses(lambda: s.str.contains("a", case="no"), TypeError, "str.contains(): case must be a bool, not str")
    refuses(lambda: s.str.contains("a", regex=1), TypeError, "str.contains(): regex must be a bool, not int")
    refuses(lambda: s.str.contains("a", flags=True), TypeError, "str.contains(): flags must be an int, not bool")
    refuses(
        lambda: s.str.contains("a", na=False),
        UnsupportedOperation,
        "str.contains(na=False) would give a chosen value for a missing value, and a komira result stays "
        "missing there: leave na out, and a filter df[cond] drops the rows where it is missing",
    )


def test_match_is_anchored_at_the_start_and_fullmatch_at_both_ends():
    s = series("s")
    check(s.str.match("ab|c"), Regexp("like", S, "^(?:ab|c)"), "bool")
    check(s.str.match("ab", case=False), Regexp("like", S, "^(?:ab)", flags="i"), "bool")
    check(s.str.fullmatch("[a-z]+"), Regexp("full_match", S, "[a-z]+"), "bool")
    check(s.str.fullmatch("x", case=False), Regexp("full_match", S, "x", flags="i"), "bool")
    refuses(lambda: s.str.match(2), TypeError, "str.match(): pat must be a str, not int")
    refuses(lambda: s.str.fullmatch(2), TypeError, "str.fullmatch(): pat must be a str, not int")
    refuses(
        lambda: s.str.match("a", flags=2),
        UnsupportedOperation,
        "str.match(flags=2) is not supported: the engine's regular expressions take no Python flags; "
        "pass case=False to ignore case",
    )
    refuses(
        lambda: s.str.fullmatch("a", na=1),
        UnsupportedOperation,
        "str.fullmatch(na=1) would give a chosen value for a missing value, and a komira result stays "
        "missing there: leave na out, and a filter df[cond] drops the rows where it is missing",
    )


def test_replace_of_text_replaces_every_occurrence_and_a_regex_replace_has_the_global_flag():
    s = series("s")
    check(s.str.replace("a", "b"), StringFnN("replace", (S, Lit("a"), Lit("b"))), "string")
    check(s.str.replace("a", "b", n=-1, case=None, flags=0, regex=False), StringFnN("replace", (S, Lit("a"), Lit("b"))), "string")
    check(s.str.replace("a+", "b", regex=True), Regexp("replace", S, "a+", replacement="b", flags="g"), "string")
    check(
        s.str.replace("a+", "", regex=True, case=False),
        Regexp("replace", S, "a+", replacement="", flags="gi"),
        "string",
    )
    check(s.str.replace("a+", "b", regex=True, case=True), Regexp("replace", S, "a+", replacement="b", flags="g"), "string")


def test_replace_refusals_by_message():
    s = series("s")
    refuses(
        lambda: s.str.replace("a", "b", n=1),
        UnsupportedOperation,
        "str.replace(n=1) replaces the first n occurrences, and the engine replaces every one: use n=-1",
    )
    refuses(
        lambda: s.str.replace("a", str.upper),
        UnsupportedOperation,
        "str.replace() with a function as repl is not supported: the plan has no node that calls it; pass a str",
    )
    refuses(
        lambda: s.str.replace("a", "b", case=False),
        UnsupportedOperation,
        "str.replace(case=False, regex=False) is not supported: the text replacement is case-sensitive; "
        "escape the text with re.escape() and use regex=True with case=False",
    )
    refuses(
        lambda: s.str.replace("", "b"),
        UnsupportedOperation,
        "str.replace() of the empty text inserts repl between every two characters in pandas, "
        "and the engine's replace leaves the string as it is: give a pat with a character in it",
    )
    refuses(
        lambda: s.str.replace("a", "b", flags=2, regex=True),
        UnsupportedOperation,
        "str.replace(flags=2) is not supported: the engine's regular expressions take no Python flags; "
        "pass case=False to ignore case",
    )
    refuses(lambda: s.str.replace("a", 1), TypeError, "str.replace(): repl must be a str, not int")
    refuses(lambda: s.str.replace(1, "b"), TypeError, "str.replace(): pat must be a str, not int")
    refuses(lambda: s.str.replace("a", "b", n="1"), TypeError, "str.replace(): n must be an int, not str")
    refuses(lambda: s.str.replace("a", "b", case=1), TypeError, "str.replace(): case must be a bool, not int")
    refuses(lambda: s.str.replace("a", "b", regex=None), TypeError, "str.replace(): regex must be a bool, not NoneType")


def test_slice_is_a_one_based_substring_of_the_given_length():
    s = series("s")
    check(s.str.slice(1, 3), Substring(S, 2, 2), "string")
    check(s.str.slice(2), Substring(S, 3, None), "string")
    check(s.str.slice(None, 2), Substring(S, 1, 2), "string")
    check(s.str.slice(), Substring(S, 1, None), "string")
    check(s.str.slice(3, 1), Substring(S, 4, 0), "string")
    check(s.str.slice(0, 0, 1), Substring(S, 1, 0), "string")


def test_slice_refuses_a_step_a_bound_from_the_end_and_a_non_int():
    s = series("s")
    refuses(
        lambda: s.str.slice(0, 3, 2),
        UnsupportedOperation,
        "str.slice(step=2) is not supported: take every character, with step=None",
    )
    refuses(
        lambda: s.str.slice(-1),
        UnsupportedOperation,
        "str.slice(start=-1) counts from the end of each string, which needs each value's length: "
        "give a start of 0 or more",
    )
    refuses(
        lambda: s.str.slice(0, -2),
        UnsupportedOperation,
        "str.slice(stop=-2) counts from the end of each string, which needs each value's length: "
        "give a stop of 0 or more",
    )
    refuses(lambda: s.str.slice("a"), TypeError, "str.slice(): start must be an int, not str")
    refuses(lambda: s.str.slice(0, 1.5), TypeError, "str.slice(): stop must be an int, not float")
    refuses(lambda: s.str.slice(0, 1, True), TypeError, "str.slice(): step must be an int, not bool")


def test_pad_keeps_a_string_at_least_as_long_as_the_width_and_pads_the_others():
    s = series("s")
    long_enough = Compare("ge", StringFn("length", S), Lit(5))
    left = When(((long_enough, S),), StringFnN("lpad", (S, Lit(5), Lit(" "))))
    right = When(((long_enough, S),), StringFnN("rpad", (S, Lit(5), Lit("0"))))
    check(s.str.pad(5), left, "string")
    check(s.str.pad(5, side="left", fillchar=" "), left, "string")
    check(s.str.pad(5, "right", "0"), right, "string")


def test_pad_refusals_by_message():
    s = series("s")
    refuses(
        lambda: s.str.pad(5, side="both"),
        UnsupportedOperation,
        "str.pad(side='both') centres the string, which this release does not build: "
        "pad to one side with side='left' or side='right'",
    )
    refuses(lambda: s.str.pad(5, side="up"), ValueError, "str.pad() side must be 'left', 'right' or 'both', not 'up'")
    refuses(lambda: s.str.pad(5, fillchar="ab"), TypeError, "fillchar must be a character, not str")
    refuses(lambda: s.str.pad(5, fillchar=1), TypeError, "fillchar must be a character, not int")
    refuses(lambda: s.str.pad("5"), TypeError, "str.pad(): width must be an int, not str")
    refuses(lambda: s.str.pad(5, side=1), TypeError, "str.pad(): side must be a str, not int")


def test_extract_of_one_group_with_expand_false_is_a_regexp_extract_of_group_one():
    s = series("s")
    check(s.str.extract(r"(\d+)", expand=False), Regexp("extract", S, r"(\d+)", group=1), "string")
    check(s.str.extract(r"a(?:b)(c)", 0, False), Regexp("extract", S, r"a(?:b)(c)", group=1), "string")


def test_extract_refusals_by_message():
    s = series("s")
    refuses(
        lambda: s.str.extract(r"(\d+)"),
        UnsupportedOperation,
        "str.extract(expand=True) returns a frame with a column per group: pass expand=False for one group as a Series",
    )
    refuses(
        lambda: s.str.extract(r"(a)(b)", expand=False),
        UnsupportedOperation,
        "str.extract() of a pattern with 2 capture groups is not supported: "
        "use a pattern with exactly one, and extract each group in its own call",
    )
    refuses(
        lambda: s.str.extract(r"ab", expand=False),
        UnsupportedOperation,
        "str.extract() of a pattern with 0 capture groups is not supported: "
        "use a pattern with exactly one, and extract each group in its own call",
    )
    refuses(
        lambda: s.str.extract(r"(a)", flags=2, expand=False),
        UnsupportedOperation,
        "str.extract(flags=2) is not supported: the engine's regular expressions take no Python flags",
    )
    refuses(lambda: s.str.extract(1, expand=False), TypeError, "str.extract(): pat must be a str, not int")
    refuses(lambda: s.str.extract("(a)", expand=0), TypeError, "str.extract(): expand must be a bool, not int")
    assert type(raised(lambda: s.str.extract("(", expand=False))) is re.error


def test_a_string_result_is_a_filter_and_an_assigned_column_over_the_frame():
    env = Env()
    df = env.df
    kept = df[df["s"].str.startswith("a")]
    assert kept._plan == _ops.filter_(SCAN, StringOp("starts_with", S, "a"))
    assert kept.dtypes == df.dtypes
    both = df[df["s"].str.contains("x") & (df["a"] > 1)]
    assert both._plan == _ops.filter_(
        SCAN, _ops.BoolOp("and", Regexp("like", S, "x"), Compare("gt", ColRef("a"), Lit(1)))
    )
    got = df.assign(u=df["s"].str.upper(), k=df["s"].str.len())
    assert got._plan == _ops.with_columns(SCAN, (("u", StringFn("upper", S)), ("k", StringFn("length", S))))
    assert got.dtypes["u"] == "string" and got.dtypes["k"] == "int64"
    got.materialize()
    assert [name for name, _ in env.stub.calls] == ["plan_stream"]
    assert env.stub.calls[0][1] == encode_plan(got._plan, env.sources).SerializeToString()


# --- .dt ----------------------------------------------------------------------------


def test_the_calendar_parts_of_a_timestamp_and_a_date_are_extracts_of_int64():
    for name, col in (("t", T), ("d", D)):
        s = series(name)
        check(s.dt.year, Extract("year", col), "int64")
        check(s.dt.quarter, Extract("quarter", col), "int64")
        check(s.dt.month, Extract("month", col), "int64")
        check(s.dt.day, Extract("day", col), "int64")
        check(s.dt.dayofyear, Extract("dayofyear", col), "int64")
        check(s.dt.day_of_year, Extract("dayofyear", col), "int64")
        monday_is_zero = Arith("sub", Extract("isodow", col), Lit(1))
        check(s.dt.dayofweek, monday_is_zero, "int64")
        check(s.dt.day_of_week, monday_is_zero, "int64")
        check(s.dt.weekday, monday_is_zero, "int64")


def test_the_time_of_day_parts_of_a_timestamp_and_the_part_of_the_second_of_a_microsecond():
    s = series("t")
    check(s.dt.hour, Extract("hour", T), "int64")
    check(s.dt.minute, Extract("minute", T), "int64")
    check(s.dt.second, Extract("second", T), "int64")
    # The engine's microsecond counts the whole seconds: 30123456 for :30.123456.
    check(s.dt.microsecond, Arith("mod", Extract("microsecond", T), Lit(1_000_000)), "int64")


def test_the_time_of_day_of_a_date_is_refused_by_name():
    s = series("d")
    for name in ("hour", "minute", "second", "microsecond"):
        refuses(
            lambda name=name: getattr(s.dt, name),
            UnsupportedOperation,
            f".dt.{name} reads the time of day, and a date32 column has none: use year, month and day",
        )


def test_floor_cuts_a_timestamp_to_one_fixed_unit():
    s = series("t")
    units = {
        "D": "day",
        "h": "hour",
        "H": "hour",
        "min": "minute",
        "T": "minute",
        "s": "second",
        "S": "second",
        "ms": "millisecond",
        "L": "millisecond",
        "us": "microsecond",
        "U": "microsecond",
    }
    for freq, unit in units.items():
        check(s.dt.floor(freq), Extract("trunc_" + unit, T), "timestamp_us")
    check(s.dt.floor("D", ambiguous="raise", nonexistent="raise"), Extract("trunc_day", T), "timestamp_us")


def test_floor_refusals_by_message():
    s = series("t")
    listed = "'D', 'h', 'min', 's', 'ms' or 'us'"
    refuses(
        lambda: s.dt.floor("2h"),
        UnsupportedOperation,
        f".dt.floor('2h') cuts to a multiple of a unit, and the plan cuts to one fixed unit: use {listed}",
    )
    refuses(
        lambda: s.dt.floor("W"),
        UnsupportedOperation,
        f".dt.floor('W') is not a unit this release cuts to: use {listed}",
    )
    refuses(lambda: s.dt.floor(5), TypeError, ".dt.floor() freq must be a str, not int")
    refuses(
        lambda: s.dt.floor("D", ambiguous="NaT"),
        UnsupportedOperation,
        ".dt.floor(ambiguous=..., nonexistent=...) is for time zones, and a komira timestamp has none: "
        "leave both at their default",
    )
    refuses(
        lambda: s.dt.floor("D", nonexistent="shift_forward"),
        UnsupportedOperation,
        ".dt.floor(ambiguous=..., nonexistent=...) is for time zones, and a komira timestamp has none: "
        "leave both at their default",
    )
    refuses(
        lambda: series("d").dt.floor("D"),
        UnsupportedOperation,
        ".dt.floor() cuts the time of day off a timestamp, and a date32 column has none: a date is whole days already",
    )


def test_a_date_part_used_in_a_filter_and_in_assign_builds_the_expected_plan():
    df = Env().df
    kept = df[df["t"].dt.year == 2024]
    assert kept._plan == _ops.filter_(SCAN, Compare("eq", Extract("year", T), Lit(2024)))
    got = df.assign(w=df["d"].dt.dayofweek)
    assert got._plan == _ops.with_columns(SCAN, (("w", Arith("sub", Extract("isodow", D), Lit(1))),))
    assert got.dtypes["w"] == "int64"


# --- the attribute rules --------------------------------------------------------------


def test_str_and_dt_are_missing_on_a_series_of_the_wrong_type_with_the_accessors_message():
    df = Env().df
    for name in ("a", "n", "f", "t", "d", "ok"):
        s = df[name]
        e = raised(lambda s=s: s.str)
        assert type(e) is AttributeError and e.name == "str", repr(e)
        assert e.args[0] == f"Can only use .str accessor with string values, not {s.dtype}", e.args[0]
        assert not hasattr(s, "str")
        assert getattr(s, "str", None) is None
    for name in ("a", "n", "f", "s", "ok"):
        s = df[name]
        e = raised(lambda s=s: s.dt)
        assert type(e) is AttributeError and e.name == "dt", repr(e)
        assert e.args[0] == f"Can only use .dt accessor with datetimelike values, not {s.dtype}", e.args[0]
        assert not hasattr(s, "dt")
    assert hasattr(df["s"], "str") and not hasattr(df["s"], "dt")
    assert hasattr(df["t"], "dt") and hasattr(df["d"], "dt") and not hasattr(df["t"], "str")
    assert type(df["s"].str) is StringMethods and type(df["t"].dt) is DatetimeMethods and type(df["d"].dt) is DatetimeMethods


def test_a_large_string_series_has_str_and_every_timestamp_unit_has_dt():
    fields = (("big", "large_string"), ("ts", "timestamp_s"), ("tn", "timestamp_ns"), ("tm", "timestamp_ms"))
    df = Env(fields).df
    assert type(df["big"].str) is StringMethods
    for name in ("ts", "tn", "tm"):
        assert type(df[name].dt) is DatetimeMethods, name
    check(df["big"].str.upper(), StringFn("upper", ColRef("big")), "string")
    check(df["tn"].dt.floor("s"), Extract("trunc_second", ColRef("tn")), "timestamp_ns")


def test_every_row_of_the_string_and_datetime_tables_raises_its_message():
    s, t = series("s"), series("t")
    assert len(_refusals.STRING) > 30 and len(_refusals.DATETIME) > 25
    for table, accessor in ((_refusals.STRING, s.str), (_refusals.DATETIME, t.dt)):
        for name, message in table.items():
            e = raised(lambda name=name: getattr(accessor, name))
            assert type(e) is AttributeError and e.args[0] == message.format(name=name), (name, repr(e))
            assert e.name == name
            assert not hasattr(accessor, name), name
    assert _refusals.refused(_refusals.STRING, "strip") == (
        ".str.strip() is not supported yet: the engine trims spaces only, and pandas trims all whitespace"
    )
    assert _refusals.refused(_refusals.STRING, "split") == ".str.split() is not supported yet: the plan has no node for it"
    assert _refusals.refused(_refusals.DATETIME, "strftime") == (
        ".dt.strftime() is not supported yet: the engine does not format a timestamp as text"
    )
    assert _refusals.refused(_refusals.DATETIME, "nanosecond") == (
        ".dt.nanosecond is not supported yet: the plan's extract has no nanosecond part"
    )


def test_no_defined_member_is_in_a_refusal_table():
    s, t = series("s"), series("t")
    assert not set(dir(s.str)) & set(_refusals.STRING)
    assert not set(dir(t.dt)) & set(_refusals.DATETIME)


def test_a_name_in_no_table_gets_pythons_own_message_on_each_accessor():
    s, t = series("s"), series("t")
    for accessor, cls in ((s.str, "StringMethods"), (t.dt, "DatetimeMethods")):
        for name in ("nothing_here", "_nothing_here", "__array_interface__"):
            e = raised(lambda name=name: getattr(accessor, name))
            assert type(e) is AttributeError and e.args[0] == f"'{cls}' object has no attribute '{name}'", repr(e)
            assert e.name == name and not hasattr(accessor, name)


def test_an_accessor_refuses_every_attribute_assignment_and_construction():
    s, t = series("s"), series("t")
    for accessor, cls in ((s.str, "StringMethods"), (t.dt, "DatetimeMethods")):
        for name in ("lower", "year", "other", "_series"):
            e = raised(lambda name=name: setattr(accessor, name, 1))
            assert type(e) is AttributeError, repr(e)
            assert e.args[0] == (
                f"cannot set the attribute '{name}' of a komira {cls}: an accessor is part of a plan and does not change"
            ), e.args[0]
    refuses(lambda: StringMethods(s), TypeError, "an accessor is taken from a Series: s.str or s.dt")
    refuses(lambda: DatetimeMethods(), TypeError, "an accessor is taken from a Series: s.str or s.dt")
    assert raised(lambda: setattr(s, "str", 1)).args[0].startswith("cannot set the attribute 'str' of a komira Series")


def test_dir_lists_only_the_defined_members_of_each_accessor():
    s, t = series("s"), series("t")
    assert dir(s.str) == sorted(
        ["contains", "endswith", "extract", "fullmatch", "len", "lower", "match", "pad", "replace", "slice", "startswith", "upper"]
    )
    assert dir(t.dt) == sorted(
        [
            "day",
            "day_of_week",
            "day_of_year",
            "dayofweek",
            "dayofyear",
            "floor",
            "hour",
            "microsecond",
            "minute",
            "month",
            "quarter",
            "second",
            "weekday",
            "year",
        ]
    )


def test_no_dunder_of_an_accessor_runs_a_query():
    env = Env()
    accessor = env.df["s"].str
    assert bool(accessor) is True
    assert raised(lambda: len(accessor)).__class__ is TypeError
    assert raised(lambda: iter(accessor)).__class__ is TypeError
    assert repr(accessor) == "<komira.StringMethods>" and repr(env.df["t"].dt) == "<komira.DatetimeMethods>"
    assert env.stub.calls == []


def test_a_series_taken_before_a_column_was_set_is_refused_by_its_accessors_and_their_methods():
    df = Env().df
    s = df["s"]
    methods = s.str
    df["z"] = 1
    stale = (
        'this Series was taken from its frame before df["name"] = ... replaced the frame\'s columns: '
        "take it from the frame again"
    )
    refuses(lambda: s.str, UnsupportedOperation, stale)
    refuses(lambda: s.dt, UnsupportedOperation, stale)
    refuses(lambda: methods.lower(), UnsupportedOperation, stale)
    refuses(lambda: methods.pad(3), UnsupportedOperation, stale)
    assert type(df["s"].str) is StringMethods


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("series accessors: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
