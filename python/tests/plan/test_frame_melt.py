"""`DataFrame.melt` and `komira.melt` (komira/_frame.py, komira/_verbs.py,
komira/_unpivot.py) with no libkomira: a frame over a Parquet scan whose
schema is made here, on a session stand-in that records the plan bytes it is
given. Checked:

- the plan: a union of one projection per value column, in the order of
  `value_vars`, each keeping the id columns and adding the column's name as a
  string literal and the column under the value name; one value column is its
  projection alone; the frame has no row order and its types are the engine's;
- pandas' defaults and argument forms: `var_name` "variable", `value_name`
  "value", every column not in `id_vars` when `value_vars` is None, a str for
  one column, a tuple, a `value_vars` column also in `id_vars` (an id column),
  one named twice (melted once), no `id_vars`; a missing value stays a row (no
  filter in the plan);
- value columns of one type that differ in allowing missing values: the one
  that never holds one is read through a `try_cast` to its own type, for an
  integer and for a string; for another type it is refused by name;
- every refusal, by type and full message: pandas' own errors (`value_name`
  that is a column, `id_vars` with a column twice, a name the frame lacks, a
  `var_name` that is a list), value columns of two types (an int and a float,
  int32 and int64, two decimal precisions, a timestamp's zone), no value
  column, `var_name` equal to an id column or to `value_name`, the row index
  (`ignore_index=False`), a column MultiIndex (`col_level`, a tuple name), and
  arguments of the wrong type; any iterable of names is taken, as pandas
  takes one;
- `komira.melt(frame, ...)` builds the plan `frame.melt(...)` does and is no
  longer in the module's refusal table, `melt` no longer in the frame's, and
  the other reshaping names still refused;
- the frame reaches the session only as plan bytes, at its terminal, and the
  encoded plan is a union of projections.

    test_frame_melt.py
"""

import os
import sys
import tempfile

import komira
from komira import _ops, _refusals
from komira._errors import UnsupportedOperation
from komira._frame import DataFrame
from komira._ops import Cast, ColRef, Field, Lit, Project, Union
from komira._plan import encode_plan, parquet_source
from komira._plan._wire import arrow_id, field, pb


# Never opened: the scan only names the file, and the schema is given here.
PATH = os.path.join(tempfile.gettempdir(), "frame_melt_test_input.parquet")
FIELDS = (("name", "string"), ("q1", "int64"), ("q2", "int64"), ("q3", "int64"), ("x", "float64"))


class Stub:
    """A session that records what the plan door is given."""

    def __init__(self):
        self.calls = []

    def _plan_stream(self, plan):
        self.calls.append(("plan_stream", plan))
        return "result"


class Env:
    """A frame over a scan of `fields`; `required` names the columns that
    never hold a missing value, and `edit` changes a field of the schema
    (a decimal's precision, a zone) by name."""

    def __init__(self, fields=FIELDS, required=(), edit=None):
        self.stub = Stub()
        wire = [field(n, arrow_id(t), n not in required) for n, t in fields]
        for f in wire:
            if edit and f.name in edit:
                edit[f.name](f)
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


def block(scan, ids, column, variable="variable", value="value", read=None):
    """The projection of one value column: the ids, the column's name, and the
    column (or `read`, the expression that reads it)."""
    items = tuple((n, ColRef(n)) for n in ids)
    return Project(scan, items + ((variable, Lit(column)), (value, read or ColRef(column))))


# --- the plan -----------------------------------------------------------------


def test_melt_is_a_union_of_one_projection_per_value_column_in_the_order_of_value_vars():
    env = Env()
    got = env.df.melt(id_vars=["name"], value_vars=["q3", "q1"], var_name="quarter", value_name="score")
    assert got._plan == Union(
        (block(env.scan, ["name"], "q3", "quarter", "score"), block(env.scan, ["name"], "q1", "quarter", "score"))
    )
    assert got.columns == ["name", "quarter", "score"]
    assert got.dtypes == {"name": "string", "quarter": "string", "score": "int64"}
    assert got._order() is None and got._session is env.stub and got._sources == env.sources


def test_melt_defaults_are_variable_and_value_and_every_column_not_an_id():
    env = Env(FIELDS[:4])
    got = env.df.melt(id_vars="name")
    assert got._plan == Union(tuple(block(env.scan, ["name"], c) for c in ("q1", "q2", "q3")))
    assert got.columns == ["name", "variable", "value"]


def test_melt_with_no_id_vars_melts_every_column_and_keeps_no_id():
    env = Env((("q1", "int64"), ("q2", "int64")))
    got = env.df.melt()
    assert got._plan == Union((block(env.scan, [], "q1"), block(env.scan, [], "q2")))
    assert got.columns == ["variable", "value"]


def test_melt_of_a_value_vars_subset_leaves_the_other_columns_out():
    env = Env()
    got = env.df.melt(id_vars=("name",), value_vars=("q2",))
    assert got._plan == block(env.scan, ["name"], "q2")
    assert got.columns == ["name", "variable", "value"] and got._order() is None
    one = env.df.melt(id_vars="name", value_vars="q2")
    assert one._plan == got._plan


def test_melt_takes_a_value_vars_column_that_is_an_id_as_an_id_and_a_twice_named_column_once():
    env = Env()
    got = env.df.melt(id_vars=["name"], value_vars=["name", "q1", "q2", "q1"])
    assert got._plan == Union((block(env.scan, ["name"], "q1"), block(env.scan, ["name"], "q2")))


def test_melt_keeps_missing_values_as_rows_and_keeps_two_id_columns_in_order():
    env = Env((("k", "int64"), ("name", "string"), ("q1", "int64"), ("q2", "int64")))
    got = env.df.melt(id_vars=["name", "k"])
    assert got._plan == Union((block(env.scan, ["name", "k"], "q1"), block(env.scan, ["name", "k"], "q2")))
    assert got.columns == ["name", "k", "variable", "value"]


def test_melt_of_a_sorted_or_filtered_frame_melts_its_plan():
    env = Env()
    df = env.df
    sorted_df = df.sort_values("q1")
    got = sorted_df.melt(id_vars="name", value_vars=["q1", "q2"])
    assert got._plan == Union(tuple(block(sorted_df._plan, ["name"], c) for c in ("q1", "q2")))
    assert got._order() is None
    kept = df[df["q1"] > 0]
    assert kept.melt(id_vars="name", value_vars="q1")._plan == block(kept._plan, ["name"], "q1")


def test_melt_reads_a_value_column_that_never_holds_a_missing_value_through_a_try_cast():
    env = Env(required=("q1", "q3"))
    got = env.df.melt(id_vars="name", value_vars=["q1", "q2", "q3"])
    assert got._plan == Union(
        (
            block(env.scan, ["name"], "q1", read=Cast(ColRef("q1"), "int64", True)),
            block(env.scan, ["name"], "q2"),
            block(env.scan, ["name"], "q3", read=Cast(ColRef("q3"), "int64", True)),
        )
    )
    assert got.dtypes["value"] == "int64"
    assert [f.nullable for f in got._fields] == [True, False, True]


def test_melt_of_value_columns_that_all_never_hold_a_missing_value_casts_none():
    env = Env(required=("q1", "q2"))
    got = env.df.melt(id_vars="name", value_vars=["q1", "q2"])
    assert got._plan == Union((block(env.scan, ["name"], "q1"), block(env.scan, ["name"], "q2")))
    assert [f.nullable for f in got._fields] == [True, False, False]


def test_melt_casts_a_string_column_that_never_holds_a_missing_value_by_its_arrow_type():
    env = Env((("k", "int64"), ("a", "string"), ("b", "string")), required=("b",))
    got = env.df.melt(id_vars="k")
    assert got._plan == Union(
        (block(env.scan, ["k"], "a"), block(env.scan, ["k"], "b", read=Cast(ColRef("b"), None, True, arrow="string")))
    )


def test_melt_refuses_a_type_it_cannot_cast_to_allow_missing_values():
    env = Env((("k", "int64"), ("a", "date32"), ("b", "date32")), required=("a",))
    refuses(
        lambda: env.df.melt(id_vars="k"),
        UnsupportedOperation,
        "melt(): the value column 'a' never holds a missing value and 'b' can, and the engine stacks only "
        "columns that allow missing values alike, which komira cannot make date32 columns do yet",
    )


# --- the refusals --------------------------------------------------------------


def test_melt_refuses_value_columns_of_two_types_naming_both():
    df = Env().df
    refuses(
        lambda: df.melt(id_vars="name", value_vars=["q1", "x"]),
        UnsupportedOperation,
        "melt(): the value columns 'q1' and 'x' are of two types, int64 and float64, and the value column "
        "holds one type: cast them to one type first",
    )
    refuses(
        lambda: df.melt(id_vars="q1"),
        UnsupportedOperation,
        "melt(): the value columns 'name' and 'q2' are of two types, string and int64, and the value column "
        "holds one type: cast them to one type first",
    )
    narrow = Env((("a", "int32"), ("b", "int64"))).df
    refuses(
        lambda: narrow.melt(),
        UnsupportedOperation,
        "melt(): the value columns 'a' and 'b' are of two types, int32 and int64, and the value column "
        "holds one type: cast them to one type first",
    )


def _precision(p):
    def edit(f):
        f.decimal_precision, f.decimal_scale = p, 2

    return edit


def _zone(tz):
    def edit(f):
        f.tz = tz

    return edit


def test_melt_refuses_decimals_of_two_precisions_and_timestamps_of_two_zones():
    decimals = Env((("a", "decimal128"), ("b", "decimal128")), edit={"a": _precision(10), "b": _precision(12)}).df
    refuses(
        lambda: decimals.melt(),
        UnsupportedOperation,
        "melt(): the value columns 'a' and 'b' are of two types, decimal128(10, 2) and decimal128(12, 2), "
        "and the value column holds one type: cast them to one type first",
    )
    same = Env((("a", "decimal128"), ("b", "decimal128")), edit={"a": _precision(10), "b": _precision(10)}).df
    assert same.melt().columns == ["variable", "value"]
    zones = Env((("a", "timestamp"), ("b", "timestamp")), edit={"a": _zone("UTC")}).df
    stamp = zones.dtypes["b"]
    refuses(
        lambda: zones.melt(),
        UnsupportedOperation,
        f"melt(): the value columns 'a' and 'b' are of two types, {stamp} (UTC) and {stamp}, "
        "and the value column holds one type: cast them to one type first",
    )


def test_melt_raises_pandas_own_errors_with_pandas_messages():
    df = Env().df
    refuses(
        lambda: df.melt(id_vars="name", value_name="q1"),
        ValueError,
        "value_name (q1) cannot match an element in the DataFrame columns.",
    )
    refuses(lambda: df.melt(id_vars=["name", "name"]), ValueError, "id_vars cannot contain duplicate columns.")
    refuses(
        lambda: df.melt(id_vars=["name", "zz"], value_vars=["q1", "yy"]),
        KeyError,
        "The following id_vars or value_vars are not present in the DataFrame: ['zz', 'yy']",
    )
    refuses(lambda: df.melt(id_vars="name", var_name=["v"]), ValueError, "var_name=['v'] must be a scalar.")
    refuses(lambda: df.melt(id_vars="name", var_name=("v",)), ValueError, "var_name=('v',) must be a scalar.")


def test_melt_refuses_no_value_column_by_name():
    df = Env().df
    message = (
        "melt() with no value column gives no rows and a value column of no type, which a komira frame "
        "cannot hold: name at least one column in value_vars that is not in id_vars"
    )
    refuses(lambda: df.melt(id_vars="name", value_vars=[]), UnsupportedOperation, message)
    refuses(lambda: df.melt(id_vars="name", value_vars=["name"]), UnsupportedOperation, message)
    refuses(lambda: df.melt(id_vars=["name", "q1", "q2", "q3", "x"]), UnsupportedOperation, message)


def test_melt_refuses_a_var_name_that_is_an_id_column_or_the_value_name():
    df = Env().df
    refuses(
        lambda: df.melt(id_vars="name", value_vars="q1", var_name="name"),
        UnsupportedOperation,
        "melt(var_name='name') is an id column's name too, and pandas would give two columns of one name, "
        "which a komira frame cannot hold: pick another var_name",
    )
    refuses(
        lambda: df.melt(id_vars="name", value_vars="q1", var_name="value"),
        UnsupportedOperation,
        "melt(var_name='value') is value_name's name too, and pandas would give two columns of one name, "
        "which a komira frame cannot hold: pick another var_name",
    )
    named_variable = Env((("variable", "string"), ("q1", "int64"))).df
    refuses(
        lambda: named_variable.melt(id_vars="variable"),
        UnsupportedOperation,
        "melt(var_name='variable') is an id column's name too, and pandas would give two columns of one name, "
        "which a komira frame cannot hold: pick another var_name",
    )
    assert df.melt(id_vars="name", value_vars="q1", var_name="q1").columns == ["name", "q1", "value"]


def test_melt_refuses_the_row_index_and_a_column_multiindex_by_name():
    df = Env().df
    refuses(
        lambda: df.melt(id_vars="name", ignore_index=False),
        UnsupportedOperation,
        "melt(ignore_index=False) repeats the row index, and komira frames have no index: leave ignore_index out",
    )
    refuses(
        lambda: df.melt(id_vars="name", col_level=0),
        UnsupportedOperation,
        "melt(col_level=...) picks a level of a column MultiIndex, and a komira frame's columns have one level "
        "of names: leave col_level out",
    )
    refuses(
        lambda: df.melt(id_vars=[("name", "a")]),
        UnsupportedOperation,
        "melt(id_vars=...) names ('name', 'a'), a column of a column MultiIndex, and a komira frame's columns "
        "have one level of names: name the columns as strings",
    )
    refuses(
        lambda: df.melt(id_vars="name", value_vars=[("q1", "b")]),
        UnsupportedOperation,
        "melt(value_vars=...) names ('q1', 'b'), a column of a column MultiIndex, and a komira frame's columns "
        "have one level of names: name the columns as strings",
    )
    assert df.melt(id_vars="name", value_vars="q1", ignore_index=True).columns == ["name", "variable", "value"]


def test_melt_takes_any_iterable_of_names_and_refuses_arguments_of_the_wrong_type():
    df = Env().df
    refuses(lambda: df.melt(id_vars="name", ignore_index=1), TypeError, "melt ignore_index must be a bool, not int")
    assert df.melt(id_vars={"name"}, value_vars=iter(["q1"]))._plan == df.melt("name", "q1")._plan
    assert df.melt(id_vars=df.columns[:1], value_vars=df.columns[1:4]).columns == ["name", "variable", "value"]
    refuses(
        lambda: df.melt(id_vars="name", value_vars=1),
        TypeError,
        "melt() takes value_vars as a column name or a list of them, not int",
    )
    refuses(lambda: df.melt(id_vars="name", var_name=1), TypeError, "melt() takes var_name as a str, not int")
    refuses(lambda: df.melt(id_vars="name", value_name=None), TypeError, "melt() takes value_name as a str, not NoneType")
    refuses(
        lambda: df.melt(id_vars=[1]),
        KeyError,
        "The following id_vars or value_vars are not present in the DataFrame: [1]",
    )


# --- komira.melt and the refusal tables -------------------------------------------


def test_komira_melt_builds_the_plan_of_the_frame_verb():
    env = Env()
    got = komira.melt(env.df, id_vars=["name"], value_vars=["q1", "q2"], var_name="quarter", value_name="score")
    want = env.df.melt(id_vars=["name"], value_vars=["q1", "q2"], var_name="quarter", value_name="score")
    assert got._plan == want._plan and got.columns == want.columns
    assert komira.melt(env.df, "name", "q1")._plan == env.df.melt("name", "q1")._plan
    refuses(lambda: komira.melt(env.df["q1"]), TypeError, "melt() takes a komira DataFrame, not Series")
    assert "melt" in komira.__all__


def test_melt_is_in_no_refusal_table_and_the_other_reshaping_names_still_are():
    assert "melt" not in _refusals.FRAME and "melt" not in _refusals.MODULE
    for name in ("pivot", "pivot_table", "stack", "unstack", "explode", "transpose", "T"):
        assert _refusals.FRAME[name] == ".{name}() is not supported yet: the plan has no node for it", name
    for name in ("pivot_table", "crosstab", "get_dummies"):
        assert _refusals.MODULE[name] == "komira.{name}() is not supported yet: the plan has no node for it", name
    df = Env().df
    assert callable(df.melt) and callable(komira.melt)
    refuses(lambda: df.pivot, AttributeError, ".pivot() is not supported yet: the plan has no node for it")
    refuses(
        lambda: komira.crosstab,
        AttributeError,
        "komira.crosstab() is not supported yet: the plan has no node for it",
    )


# --- the terminal and the wire -----------------------------------------------------


def test_melt_reaches_the_session_only_as_plan_bytes_and_encodes_as_a_union_of_projections():
    env = Env(required=("q1",))
    got = env.df.melt(id_vars="name", value_vars=["q1", "q2"])
    assert env.stub.calls == []
    got.materialize()
    encoded = encode_plan(got._plan, env.sources)
    assert env.stub.calls == [("plan_stream", encoded.SerializeToString())]
    plan = encoded.plan
    assert plan.WhichOneof("node") == "union_all"
    children = plan.union_all.children
    assert [c.WhichOneof("node") for c in children] == ["project", "project"]
    for child in children:
        assert [(f.name, f.nullable) for f in child.output_schema.fields] == [
            ("name", True),
            ("variable", False),
            ("value", True),
        ]


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("frame melt: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
