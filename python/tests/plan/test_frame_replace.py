"""`DataFrame.replace` and `Series.replace` of the pandas-shaped skin
(komira/_replace.py) with no libkomira: a frame over a Parquet scan whose
schema is made here, on a session stand-in that runs nothing. Checked:

- the plan each form builds, by equality with a hand-built node tree: a CASE
  per changed column, `WHEN x = old THEN new ... ELSE x END`, computed in int64
  or float64 and cast back for an int32 or float32 column, the values with one
  replacement joined by OR into one case, a NULL of the column's own type
  where the replacement is None, and `x IS NULL` (and NaN, in a float column)
  where the value looked for is None or NaN;
- the forms of pandas' arguments: a scalar, a list with one value or with a
  list of values, `{column: value}` with a value, `{column: {old: new}}` and
  `{old: new}` with no value, and a dict value per column; a column a dict
  does not name, or that holds none of the values a value of its type could
  be, is the same column with its own type, and a column a dict names that the
  frame does not have is skipped, as pandas skips it;
- which values meet which column, as pandas 3 decides: an int meets an int
  or float column and a whole float an int column, a str only a string
  column, a bool none of them, a value outside an int column's range nothing,
  and a float32 column the value rounded to float32; NaN looked for is NULL,
  and NaN too in a float column, and None is NULL in a column that is not a
  float column and nothing in one; a value given twice takes its last
  replacement;
- that a sorted frame stays sorted unless a sort key is replaced;
- every refusal by its class and its full message: `regex=` and
  `inplace=True`, a replacement that would change a column's type, a bool or
  other column type the engine's CASE does not give, too many values, and the
  argument shapes pandas 3 refuses (`value` left out with a value or list,
  `limit=` and `method=`, which it does not have, `to_replace=None`), with
  pandas' class.

    test_frame_replace.py
"""

import math
import os
import sys
import tempfile

from komira import _ops
from komira._errors import UnsupportedOperation
from komira._frame import DataFrame
from komira._ops import BoolOp, Cast, ColRef, Compare, Field, Lit, SortKey, Unary, When
from komira._plan import parquet_source
from komira._plan._wire import arrow_id, field, pb

# Never opened: the scan only names the file, and the schema is given here.
PATH = os.path.join(tempfile.gettempdir(), "frame_replace_test_input.parquet")
FIELDS = (("a", "int64"), ("n", "int32"), ("x", "float64"), ("f", "float32"), ("s", "string"), ("ok", "bool"))
COLS = tuple(name for name, _ in FIELDS)
INF = Lit(float("inf"))
MINUS_INF = Lit(float("-inf"))
WIDE = {"int32": "int64", "float32": "float64"}
TYPES = dict(FIELDS)


class Env:
    """A frame over a scan of `fields` at `PATH`."""

    def __init__(self, fields=FIELDS):
        schema = pb.WireSchema(fields=[field(n, arrow_id(t), True) for n, t in fields])
        sources = {PATH: parquet_source(PATH, schema.SerializeToString())}
        self.scan = _ops.scan(PATH, "parquet", tuple(Field(n, t) for n, t in fields))
        self.columns = tuple(n for n, _ in fields)
        self.df = DataFrame._new(object(), self.scan, sources)

    def project(self, changed):
        """The projection that keeps every column, with `changed` swapped in by name."""
        return _ops.Project(self.scan, tuple((n, changed.get(n, ColRef(n))) for n in self.columns))


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def wide(name, dtype=None):
    """The column `name` as the CASE computes it: int64 or float64."""
    dtype = dtype or TYPES[name]
    column = ColRef(name)
    return Cast(column, WIDE[dtype]) if dtype in WIDE else column


def eq(name, value, dtype=None):
    return Compare("eq", wide(name, dtype), Lit(value))


def any_of(*preds):
    out = preds[0]
    for pred in preds[1:]:
        out = BoolOp("or", out, pred)
    return out


def missing(name, dtype=None):
    """The test that the column holds no value: NULL, and NaN in a float column."""
    dtype = dtype or TYPES[name]
    column = ColRef(name)
    if dtype not in ("float32", "float64"):
        return Unary("is_null", column)
    x = column if dtype == "float64" else Cast(column, "float64")
    finite = BoolOp("and", Compare("gt", x, MINUS_INF), Compare("lt", x, INF))
    not_nan = BoolOp("or", BoolOp("or", finite, Compare("eq", x, INF)), Compare("eq", x, MINUS_INF))
    return Unary("not", BoolOp("and", Unary("is_not_null", column), not_nan))


def null(dtype):
    """The NULL a replacement of None puts in a column of `dtype`."""
    return Cast(Lit(None), None, arrow="string") if dtype == "string" else Lit(None)


def replaced(name, cases, dtype=None):
    """The column `name` with its CASE: `cases` in order, else the column."""
    dtype = dtype or TYPES[name]
    built = When(tuple(cases), wide(name, dtype))
    return Cast(built, dtype) if dtype in WIDE else built


# ---- the forms ------------------------------------------------------------


def test_a_list_to_none_turns_each_listed_text_into_a_null_of_the_string_column():
    env = Env()
    got = env.df.replace(["N/A", "n/a", "-"], None)
    expected = env.project({"s": replaced("s", [(any_of(eq("s", "N/A"), eq("s", "n/a"), eq("s", "-")), null("string"))])})
    assert got._plan == expected
    assert got.dtypes == env.df.dtypes


def test_a_scalar_to_none_changes_only_the_columns_whose_type_can_hold_it():
    env = Env()
    got = env.df.replace(-1, None)
    expected = env.project(
        {
            "a": replaced("a", [(eq("a", -1), null("int64"))]),
            "n": replaced("n", [(eq("n", -1), null("int32"))]),
            "x": replaced("x", [(eq("x", -1.0), null("float64"))]),
            "f": replaced("f", [(eq("f", -1.0), null("float32"))]),
        }
    )
    assert got._plan == expected
    assert got.dtypes == env.df.dtypes


def test_a_column_that_can_hold_none_of_the_values_is_the_same_column_with_its_type():
    env = Env()
    assert env.df.replace("N/A", None)._plan == env.project(
        {"s": replaced("s", [(eq("s", "N/A"), null("string"))])}
    )
    # Nothing in the frame can hold the values: the plan is a projection of
    # the columns as they are, and every type stays.
    # A float that is not whole, and an int outside int64, meet only the
    # float columns.
    got = env.df.replace([2.5, 2**70], None)
    big = float(2**70)
    assert got._plan == env.project(
        {
            "x": replaced("x", [(any_of(eq("x", 2.5), eq("x", big)), null("float64"))]),
            "f": replaced("f", [(any_of(eq("f", 2.5), eq("f", big)), null("float32"))]),
        }
    )
    assert got.dtypes == env.df.dtypes
    # Nothing in the frame can hold the value: the plan is the frame's own.
    only_int = Env((("a", "int64"), ("s", "string")))
    untouched = only_int.df.replace(2.5, None)
    assert untouched._plan == only_int.scan
    assert untouched.dtypes == {"a": "int64", "s": "string"}


def test_a_dict_of_columns_with_a_value_replaces_each_columns_own_values():
    env = Env()
    got = env.df.replace({"s": ["N/A", "-"], "a": -1}, None)
    expected = env.project(
        {
            "a": replaced("a", [(eq("a", -1), null("int64"))]),
            "s": replaced("s", [(any_of(eq("s", "N/A"), eq("s", "-")), null("string"))]),
        }
    )
    assert got._plan == expected
    # A column the frame does not have is skipped, as pandas skips it.
    assert env.df.replace({"s": "N/A", "nope": 1}, None)._plan == env.project(
        {"s": replaced("s", [(eq("s", "N/A"), null("string"))])}
    )


def test_a_nested_dict_with_no_value_maps_old_to_new_per_column():
    env = Env()
    got = env.df.replace({"s": {"N/A": None, "yes": "y"}, "a": {0: None}})
    expected = env.project(
        {
            "a": replaced("a", [(eq("a", 0), null("int64"))]),
            "s": replaced("s", [(eq("s", "N/A"), null("string")), (eq("s", "yes"), Lit("y"))]),
        }
    )
    assert got._plan == expected


def test_a_flat_dict_with_no_value_maps_old_to_new_in_every_column():
    env = Env((("a", "int64"), ("s", "string")))
    got = env.df.replace({"N/A": None, -1: None, 0: 10})
    expected = env.project(
        {
            "a": replaced("a", [(eq("a", -1), null("int64")), (eq("a", 0), Lit(10))], "int64"),
            "s": replaced("s", [(eq("s", "N/A"), null("string"))], "string"),
        }
    )
    assert got._plan == expected


def test_a_dict_value_names_the_replacement_per_column_and_leaves_the_others():
    env = Env()
    got = env.df.replace(-1, {"a": None, "x": 0})
    expected = env.project(
        {
            "a": replaced("a", [(eq("a", -1), null("int64"))]),
            "x": replaced("x", [(eq("x", -1.0), Lit(0.0))]),
        }
    )
    assert got._plan == expected
    both = env.df.replace({"a": [1, 2], "s": "N/A", "x": 1}, {"a": 0, "s": None})
    assert both._plan == env.project(
        {
            "a": replaced("a", [(any_of(eq("a", 1), eq("a", 2)), Lit(0))]),
            "s": replaced("s", [(eq("s", "N/A"), null("string"))]),
        }
    )


def test_two_lists_replace_pairwise_and_values_with_one_replacement_share_a_case():
    env = Env((("a", "int64"),))
    got = env.df.replace([1, 2, 3, 4], [None, 20, None, 20])
    expected = env.project(
        {
            "a": replaced(
                "a",
                [(any_of(eq("a", 1), eq("a", 3)), null("int64")), (any_of(eq("a", 2), eq("a", 4)), Lit(20))],
                "int64",
            )
        }
    )
    assert got._plan == expected
    # A tuple is a list.
    assert env.df.replace((1, 3), None)._plan == env.project(
        {"a": replaced("a", [(any_of(eq("a", 1), eq("a", 3)), null("int64"))], "int64")}
    )


def test_an_empty_list_or_dict_changes_nothing():
    env = Env()
    assert env.df.replace([], None)._plan == env.scan
    assert env.df.replace({}, None)._plan == env.scan
    assert env.df.replace({})._plan == env.scan


# ---- ints and floats ----------------------------------------------------------


def test_an_int_column_meets_ints_in_its_range_and_whole_floats_and_keeps_its_type():
    env = Env((("a", "int64"), ("n", "int32")))
    got = env.df.replace([7, 8.0, 8.5, 2**40, True, "7"], None)
    expected = env.project(
        {
            "a": replaced("a", [(any_of(eq("a", 7), eq("a", 8), eq("a", 2**40)), null("int64"))], "int64"),
            "n": replaced("n", [(any_of(eq("n", 7), eq("n", 8)), null("int32"))], "int32"),
        }
    )
    assert got._plan == expected
    assert got.dtypes == {"a": "int64", "n": "int32"}
    # A whole float replacement of an int column is an int.
    assert env.df.replace(7, 70.0)._plan == env.project(
        {"a": replaced("a", [(eq("a", 7), Lit(70))], "int64"), "n": replaced("n", [(eq("n", 7), Lit(70))], "int32")}
    )


def test_a_float_column_meets_ints_and_floats_and_an_int_replacement_is_a_float():
    env = Env((("x", "float64"), ("f", "float32")))
    got = env.df.replace([1, 0.5], 2)
    expected = env.project(
        {
            "x": replaced("x", [(any_of(eq("x", 1.0), eq("x", 0.5)), Lit(2.0))], "float64"),
            "f": replaced("f", [(any_of(eq("f", 1.0), eq("f", 0.5)), Lit(2.0))], "float32"),
        }
    )
    assert got._plan == expected
    assert got.dtypes == {"x": "float64", "f": "float32"}


def test_a_float32_column_meets_the_value_rounded_to_float32_and_gets_its_replacement_rounded():
    env = Env((("f", "float32"),))
    f32 = 0.10000000149011612
    got = env.df.replace(0.1, 0.2)
    assert got._plan == env.project({"f": replaced("f", [(eq("f", f32), Lit(0.20000000298023224))], "float32")})
    # Two values that round to one float32 are one value, with the last
    # replacement; one beyond float32's range is an infinity, as numpy rounds.
    assert env.df.replace([0.1, f32], [5, 6])._plan == env.project(
        {"f": replaced("f", [(eq("f", f32), Lit(6.0))], "float32")}
    )
    assert env.df.replace(1e300, -1e300)._plan == env.project(
        {"f": replaced("f", [(eq("f", math.inf), Lit(-math.inf))], "float32")}
    )


def test_nan_looked_for_is_a_missing_value_and_none_is_null_outside_a_float_column():
    env = Env()
    # In a float column NaN looked for is NULL or NaN, and None makes each a
    # NULL; in any other column it is NULL already, and the column stays.
    assert env.df.replace(math.nan, None)._plan == env.project(
        {"x": replaced("x", [(missing("x"), null("float64"))]), "f": replaced("f", [(missing("f"), null("float32"))])}
    )
    # None looked for meets NULL in a column that is not a float column, and
    # nothing in a float column, as pandas has no None in one.
    assert env.df.replace([None], None)._plan == env.scan
    numbers = Env((("a", "int64"), ("x", "float64")))
    assert numbers.df.replace([None], 0)._plan == numbers.project({"a": replaced("a", [(missing("a"), Lit(0))])})
    assert env.df.replace({"x": [None, 1]}, 0)._plan == env.project({"x": replaced("x", [(eq("x", 1.0), Lit(0.0))])})
    # With a value, the missing values get it, NULL and NaN alike.
    got = env.df.replace({"x": [math.nan, -1], "s": [None], "a": math.nan}, {"x": 0, "s": "", "a": 0})
    expected = env.project(
        {
            "a": replaced("a", [(missing("a"), Lit(0))]),
            "x": replaced("x", [(any_of(missing("x"), eq("x", -1.0)), Lit(0.0))]),
            "s": replaced("s", [(missing("s"), Lit(""))]),
        }
    )
    assert got._plan == expected
    # A NaN replacement of a float column is NaN.
    nan = env.df.replace({"x": -1}, math.nan)._plan
    assert nan == env.project({"x": replaced("x", [(eq("x", -1.0), Lit(math.nan))])})


def test_a_bool_value_or_a_number_meets_no_text_and_a_str_no_number():
    env = Env((("a", "int64"), ("x", "float64"), ("s", "string")))
    assert env.df.replace([True, False], None)._plan == env.scan
    assert env.df.replace({"s": 1, "a": "1", "x": "1.0"}, None)._plan == env.scan


# ---- order -------------------------------------------------------------------


def test_a_sorted_frame_stays_sorted_unless_a_sort_key_is_replaced():
    env = Env()
    ordered = env.df.sort_values("a")
    other = ordered.replace({"s": "N/A"}, None)
    assert other._plan == _ops.Sort(env.project({"s": replaced("s", [(eq("s", "N/A"), null("string"))])}), (SortKey("a"),))
    # The sort key's values change: the projection is over the sort, and
    # the frame is no longer sorted.
    key = ordered.replace({"a": 1}, None)
    a = replaced("a", [(eq("a", 1), null("int64"))])
    assert key._plan == _ops.Project(ordered._plan, tuple((n, a if n == "a" else ColRef(n)) for n in COLS))
    assert key._order() is None


# ---- Series.replace ------------------------------------------------------------


def test_series_replace_of_a_list_scalar_and_dict_is_the_columns_case():
    env = Env()
    s = env.df["s"]
    listed = s.replace(["N/A", "-"], None)
    assert listed._node == replaced("s", [(any_of(eq("s", "N/A"), eq("s", "-")), null("string"))])
    assert listed.dtype == "string"
    assert s.replace("N/A", None)._node == replaced("s", [(eq("s", "N/A"), null("string"))])
    assert s.replace({"N/A": None, "yes": "y"})._node == replaced(
        "s", [(eq("s", "N/A"), null("string")), (eq("s", "yes"), Lit("y"))]
    )
    n = env.df["n"].replace([1, 2], [None, 3])
    assert n._node == replaced("n", [(eq("n", 1), null("int32")), (eq("n", 2), Lit(3))])
    assert n.dtype == "int32"
    # Nothing of the Series' type: the same Series.
    assert env.df["a"].replace("N/A", None)._node == ColRef("a")


def test_series_replace_assigns_and_filters_as_any_series():
    env = Env()
    df = env.df
    got = df.assign(s=df["s"].replace("N/A", None))
    assert got._plan == env.project({"s": replaced("s", [(eq("s", "N/A"), null("string"))])})
    # Over an expression the CASE repeats the expression.
    a1 = (df["a"] + 1)._node
    plus = (df["a"] + 1).replace(0, None)
    assert plus._node == When(((Compare("eq", a1, Lit(0)), Lit(None)),), a1)


# ---- refusals --------------------------------------------------------------------


def test_series_replace_of_a_series_taken_before_the_frame_changed_is_refused():
    df = Env().df
    s = df["a"]
    df["b"] = df["a"] + 1
    refuses(
        lambda: s.replace(1, 2),
        UnsupportedOperation,
        'this Series was taken from its frame before df["name"] = ... replaced the frame\'s columns: '
        "take it from the frame again",
    )


def test_patterns_and_inplace_are_refused_by_name_and_a_missing_value_as_pandas_3_refuses_it():
    df = Env().df
    s = df["s"]
    # pandas 3 has no pad fill: a value or list with no value is its
    # ValueError, and limit= and method= are no arguments of it.
    no_value = "{}.replace must specify either 'value', a dict-like 'to_replace', or dict-like 'regex'."
    refuses(lambda: df.replace("N/A"), ValueError, no_value.format("DataFrame"))
    refuses(lambda: df.replace(["N/A"]), ValueError, no_value.format("DataFrame"))
    refuses(lambda: df.replace(), ValueError, no_value.format("DataFrame"))
    refuses(lambda: s.replace("N/A"), ValueError, no_value.format("Series"))
    refuses(
        lambda: df.replace("N/A", None, limit=1),
        TypeError,
        "DataFrame.replace() got an unexpected keyword argument 'limit'",
    )
    refuses(
        lambda: s.replace("N/A", None, method="pad"),
        TypeError,
        "Series.replace() got an unexpected keyword argument 'method'",
    )
    regex = (
        "replace(regex={}) matches by regular expression, and replace() matches exact values only: "
        "leave regex out, or use s.str.replace(pattern, repl, regex=True) on a string column"
    )
    refuses(lambda: df.replace("N.A", None, regex=True), UnsupportedOperation, regex.format("True"))
    refuses(lambda: s.replace("N.A", None, regex="N.A"), UnsupportedOperation, regex.format("'N.A'"))
    refuses(
        lambda: df.replace("N/A", None, inplace=True),
        UnsupportedOperation,
        "replace(inplace=True) changes the frame in place, and komira frames do not change: "
        "use the frame replace returns",
    )
    refuses(
        lambda: s.replace("N/A", None, inplace=True),
        UnsupportedOperation,
        "replace(inplace=True) changes the Series in place, and a komira Series does not change: "
        "use the Series replace returns",
    )


def test_a_replacement_that_would_change_a_columns_type_is_refused_by_name():
    env = Env()
    refuses(
        lambda: env.df.replace(-1, "missing"),
        UnsupportedOperation,
        "replace() cannot put a str in the int64 column 'a': the column keeps its type, so replace with "
        "None or an int, or cast the column first with astype(), or pass a dict to replace in some columns only",
    )
    refuses(
        lambda: env.df.replace({"a": 1}, 1.5),
        UnsupportedOperation,
        "replace() cannot put 1.5 in the int64 column 'a': the column keeps its type, so replace with "
        "None or an int, or cast the column first with astype()",
    )
    refuses(
        lambda: env.df.replace({"n": 1}, 2**40),
        UnsupportedOperation,
        "replace() cannot put 1099511627776 in the int32 column 'n': it is out of the range of int32, "
        "so replace with a value in range, or cast the column first with astype()",
    )
    refuses(
        lambda: env.df.replace({"x": 1}, 2**1100),
        UnsupportedOperation,
        "replace() cannot put an int too large for a float in the float64 column 'x': replace with a smaller value",
    )
    refuses(
        lambda: env.df.replace({"s": "N/A"}, 0),
        UnsupportedOperation,
        "replace() cannot put an int in the string column 's': the column keeps its type, so replace with "
        "None or a str, or cast the column first with astype()",
    )
    refuses(
        lambda: env.df["a"].replace(1, True),
        UnsupportedOperation,
        "replace() cannot put a bool in the int64 Series: the Series keeps its type, so replace with "
        "None or an int, or cast it first with astype()",
    )
    refuses(
        lambda: env.df.replace({"a": 1}, math.nan),
        UnsupportedOperation,
        "replace() cannot put a float in the int64 column 'a': the column keeps its type, so replace with "
        "None or an int, or cast the column first with astype()",
    )


def test_a_column_type_the_case_does_not_give_is_refused_when_a_value_could_meet_it():
    env = Env((("ok", "bool"), ("s", "string"), ("t", "timestamp_us"), ("k", "int8"), ("d", "decimal128")))
    refuses(
        lambda: env.df.replace(True, None),
        UnsupportedOperation,
        "replace() changes int32, int64, float32, float64 and string columns, and the column 'ok' is bool: "
        "cast it first with astype(), or pass a dict to replace in some columns only",
    )
    refuses(
        lambda: env.df.replace("N/A", None),
        UnsupportedOperation,
        "replace() changes int32, int64, float32, float64 and string columns, and the column 't' is "
        "timestamp_us: cast it first with astype(), or pass a dict to replace in some columns only",
    )
    refuses(
        lambda: env.df.replace({"k": 1}, None),
        UnsupportedOperation,
        "replace() changes int32, int64, float32, float64 and string columns, and the column 'k' is int8: "
        "cast it first with astype()",
    )
    refuses(
        lambda: env.df["d"].replace(1.5, None),
        UnsupportedOperation,
        "replace() changes int32, int64, float32, float64 and string columns, and the Series is decimal128: "
        "cast it first with astype()",
    )
    refuses(
        lambda: env.df.replace({"ok": math.nan}, 0),
        UnsupportedOperation,
        "replace() changes int32, int64, float32, float64 and string columns, and the column 'ok' is bool: "
        "cast it first with astype()",
    )
    refuses(
        lambda: env.df.replace({"ok": [None]}, False),
        UnsupportedOperation,
        "replace() changes int32, int64, float32, float64 and string columns, and the column 'ok' is bool: "
        "cast it first with astype()",
    )
    # None looked for and None put back changes nothing, in any column; a
    # value that cannot be in a column leaves it alone.
    assert env.df.replace([None], None)._plan == env.scan
    assert env.df.replace({"t": 1, "ok": "x", "k": "1"}, None)._plan == env.scan
    # A narrow int column meets only a value in its range.
    assert env.df.replace({"k": [300, 1.5]}, None)._plan == env.scan


def test_a_value_given_twice_takes_its_last_replacement_and_a_replacement_is_not_looked_for_again():
    env = Env((("a", "int64"), ("x", "float64")))
    # 1 and 1.0 are one value of an int column: the last replacement wins.
    assert env.df.replace([1, 1.0], [5, 6])._plan == env.project(
        {
            "a": replaced("a", [(eq("a", 1), Lit(6))], "int64"),
            "x": replaced("x", [(eq("x", 1.0), Lit(6.0))], "float64"),
        }
    )
    # None and NaN are both the NULL of a string column: the last, None,
    # leaves it NULL.
    s = Env((("s", "string"),)).df["s"]
    assert s.replace([None, math.nan], ["x", None])._node == ColRef("s")
    assert s.replace([None, math.nan], [None, "x"])._node == replaced("s", [(missing("s", "string"), Lit("x"))], "string")
    x = env.df["x"].replace([math.nan, math.nan], [0, 1])
    assert x._node == replaced("x", [(missing("x"), Lit(1.0))], "float64")
    # 1 becomes 2 and 2 becomes 3: each case tests the column's own value,
    # so a 1 ends as 2, not 3.
    assert env.df["a"].replace([1, 2], [2, 3])._node == replaced(
        "a", [(eq("a", 1), Lit(2)), (eq("a", 2), Lit(3))], "int64"
    )


def test_more_values_than_a_case_takes_are_refused():
    env = Env((("a", "int64"), ("x", "float64")))
    refuses(
        lambda: env.df.replace(list(range(65)), None),
        UnsupportedOperation,
        "replace() looks for at most 64 values in a column, and the column 'a' is given 65",
    )


def test_argument_shapes_pandas_refuses_are_refused_with_its_class():
    df = Env().df
    s = df["s"]
    refuses(
        lambda: df.replace([1, 2], [3]),
        ValueError,
        "Replacement lists must match in length. Expecting 2 got 1 ",
    )
    refuses(
        lambda: df.replace({"a": {1: 2}, "s": "x"}),
        TypeError,
        "If a nested mapping is passed, all values of the top level mapping must be mappings",
    )
    refuses(lambda: df.replace(1, [2]), TypeError, "Invalid \"to_replace\" type: 'int'")
    refuses(lambda: df.replace({"a": 1}, [2]), TypeError, "value argument must be scalar, dict, or Series")
    refuses(lambda: df.replace([1], {"a": 2}), TypeError, "replace() takes a dict value with one to_replace value, not a list")
    refuses(
        lambda: s.replace({"N/A": "x"}, None),
        ValueError,
        "Series.replace cannot specify both a dict-like 'to_replace' and a 'value'",
    )
    refuses(lambda: s.replace("N/A", {"s": None}), ValueError, "Series.replace cannot use dict-value and non-None to_replace")
    refuses(
        lambda: s.replace({"s": {"N/A": None}}),
        ValueError,
        "to_replace and value cannot be dict-like for Series.replace",
    )
    refuses(
        lambda: df.replace({"a": {1: 2}}, None),
        ValueError,
        "Series.replace cannot specify both a dict-like 'to_replace' and a 'value'",
    )
    none = (
        "replace(None, ...) is pandas' form that looks for the patterns of regex=, and replace() matches exact "
        "values only: fill missing values with fillna(value)"
    )
    refuses(lambda: df.replace(None, 0), TypeError, none)
    refuses(lambda: df.replace({"s": None}, ""), TypeError, none)
    refuses(lambda: df.replace(None, {"a": 0}), TypeError, none)
    refuses(lambda: s.replace(None, ""), TypeError, none)
    refuses(
        lambda: df.replace(object(), None),
        UnsupportedOperation,
        "replace() looks for None, bool, int, float and str values, not a object",
    )
    refuses(
        lambda: df.replace("N/A", [None]),
        TypeError,
        "Invalid \"to_replace\" type: 'str'",
    )
    refuses(
        lambda: df.replace(["N/A"], [b"x"]),
        UnsupportedOperation,
        "replace() replaces with None, bool, int, float and str values, not a bytes",
    )
    refuses(
        lambda: df.replace(["N/A"], df),
        UnsupportedOperation,
        "replace() replaces with None, bool, int, float and str values, not a DataFrame",
    )


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("frame replace: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
