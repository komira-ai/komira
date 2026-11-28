"""komira.pl's `LazyFrame.unpivot` as plans, with no library (komira/pl/_frame.py,
komira/_unpivot.py). Frames are scans of a stand-in session whose file
schemas are written here as the engine's `WireSchema` bytes and whose
terminals record the plan bytes they are given. Checked:

- the plan: a union of one projection per column of `on`, in its order, each
  keeping the `index` columns and adding the column's name as a string literal
  and the column under the value name; one column is its projection alone; the
  frame is unordered, also when made from a sorted frame, and its schema is the
  engine's (pyarrow types);
- polars' defaults and argument forms: `variable_name` "variable",
  `value_name` "value", every column not in `index` when `on` is None, no
  index, a str for one column, a tuple; nulls stay rows (no filter);
- columns of one type that differ in allowing nulls: the one that never holds
  one is read through a `try_cast` to its own type;
- every refusal, by type and full message: columns of two types (an int and a
  float, int32 and int64), a column the frame lacks (the frame's `KeyError`),
  a column named twice in `on` or in `index`, a column in both, an `on` of no
  column, an output name used twice, a selector or expression in place of a
  name, and a name that is not a str;
- `collect()` hands the session the plan bytes, whose plan is a union of
  projections.

    test_pl_unpivot.py
"""

import os
import tempfile

import pyarrow as pa

import komira.pl as kpl
from komira import Session, UnsupportedOperation
from komira._ops import Cast, ColRef, Field, Lit, Project, Scan, Sort, SortKey, Union
from komira._plan import encode_plan
from komira._plan._wire import arrow_id, field, pb

# Never opened: the stand-in answers its schema.
PATH = os.path.join(tempfile.gettempdir(), "pl_unpivot_t.parquet")
REQUIRED_PATH = os.path.join(tempfile.gettempdir(), "pl_unpivot_required.parquet")
# (name, type, allows nulls)
TYPES = [
    ("name", "string", True),
    ("q1", "int64", True),
    ("q2", "int64", True),
    ("q3", "int64", True),
    ("x", "float64", True),
    ("i32", "int32", True),
]
REQUIRED = [("name", "string", True), ("q1", "int64", False), ("q2", "int64", True)]
T = Scan(PATH, "parquet", tuple(Field(n, t) for n, t, _ in TYPES))
TR = Scan(REQUIRED_PATH, "parquet", tuple(Field(n, t) for n, t, _ in REQUIRED))


class StandIn(Session):
    """A session with no library: schemas from `schemas`, plans recorded."""

    def __init__(self, schemas):
        self.schemas = schemas
        self.ran = []

    def _parquet_schema(self, path):
        fields = [field(n, arrow_id(t), nullable) for n, t, nullable in self.schemas[path]]
        return pb.WireSchema(fields=fields).SerializeToString()

    def _plan_stream(self, plan):
        self.ran.append(plan)
        return "result"

    def close(self):
        pass


SESSION = StandIn({PATH: TYPES, REQUIRED_PATH: REQUIRED})


def frame(path=PATH):
    return kpl.scan_parquet(path, session=SESSION)


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


def block(scan, index, column, variable="variable", value="value", read=None):
    items = tuple((n, ColRef(n)) for n in index)
    return Project(scan, items + ((variable, Lit(column)), (value, read or ColRef(column))))


# ---- the plan -----------------------------------------------------------------


def test_unpivot_is_a_union_of_one_projection_per_on_column_in_its_order():
    lf = frame().unpivot(["q3", "q1"], index="name", variable_name="quarter", value_name="score")
    assert lf._plan == Union((block(T, ["name"], "q3", "quarter", "score"), block(T, ["name"], "q1", "quarter", "score")))
    assert lf.columns == ["name", "quarter", "score"]
    assert lf.schema == {"name": pa.string(), "quarter": pa.string(), "score": pa.int64()}
    assert lf._order is None and lf._session is SESSION


def test_unpivot_defaults_are_variable_and_value_and_every_column_not_in_index():
    lf = frame().select("name", "q1", "q2").unpivot(index="name")
    base = Project(T, (("name", ColRef("name")), ("q1", ColRef("q1")), ("q2", ColRef("q2"))))
    assert lf._plan == Union((block(base, ["name"], "q1"), block(base, ["name"], "q2")))
    assert lf.columns == ["name", "variable", "value"]


def test_unpivot_with_no_index_unpivots_every_on_column_and_with_neither_every_column():
    lf = frame().unpivot(["q1", "q2"])
    assert lf._plan == Union((block(T, [], "q1"), block(T, [], "q2")))
    assert lf.columns == ["variable", "value"]
    every = frame().select("q1", "q2").unpivot()
    base = Project(T, (("q1", ColRef("q1")), ("q2", ColRef("q2"))))
    assert every._plan == Union((block(base, [], "q1"), block(base, [], "q2")))


def test_unpivot_of_one_column_is_its_projection_and_takes_tuples_and_two_index_columns():
    lf = frame().unpivot("q2", index=("name", "q1"))
    assert lf._plan == block(T, ["name", "q1"], "q2")
    assert lf.columns == ["name", "q1", "variable", "value"]
    assert frame().unpivot(("q2",), index=["name", "q1"])._plan == lf._plan
    assert frame().unpivot(["q1", "q2"], index=[])._plan == Union((block(T, [], "q1"), block(T, [], "q2")))


def test_unpivot_of_a_sorted_frame_is_unordered_and_keeps_nulls_as_rows():
    s = frame().sort("q1")
    lf = s.unpivot(["q1", "q2"], index="name")
    sorted_scan = Sort(T, (SortKey("q1", False, True),))
    assert s._plan == sorted_scan
    assert lf._plan == Union((block(sorted_scan, ["name"], "q1"), block(sorted_scan, ["name"], "q2")))
    assert lf._order is None


def test_unpivot_reads_a_column_that_never_holds_a_null_through_a_try_cast():
    lf = frame(REQUIRED_PATH).unpivot(["q1", "q2"], index="name")
    assert lf._plan == Union(
        (block(TR, ["name"], "q1", read=Cast(ColRef("q1"), "int64", True)), block(TR, ["name"], "q2"))
    )
    assert [f.nullable for f in lf._wire_fields()] == [True, False, True]
    alone = frame(REQUIRED_PATH).unpivot("q1", index="name")
    assert alone._plan == block(TR, ["name"], "q1")


# ---- the refusals ---------------------------------------------------------------


def test_unpivot_refuses_columns_of_two_types_naming_both():
    refused(
        lambda: frame().unpivot(["q1", "x"], index="name"),
        UnsupportedOperation,
        "unpivot: the value columns 'q1' and 'x' are of two types, int64 and double, and the value column "
        "holds one type: cast them to one type first",
    )
    refused(
        lambda: frame().unpivot(["q1", "i32"]),
        UnsupportedOperation,
        "unpivot: the value columns 'q1' and 'i32' are of two types, int64 and int32, and the value column "
        "holds one type: cast them to one type first",
    )
    refused(
        lambda: frame().unpivot(index="q1"),
        UnsupportedOperation,
        "unpivot: the value columns 'name' and 'q2' are of two types, string and int64, and the value column "
        "holds one type: cast them to one type first",
    )


def test_unpivot_refuses_a_column_the_frame_lacks_with_the_frames_key_error():
    listed = "name, q1, q2, q3, x, i32"
    refused(
        lambda: frame().unpivot(["q1", "q11"]),
        KeyError,
        f"no column named 'q11' in this frame; the closest is 'q1'; the frame's columns are: {listed}",
    )
    refused(
        lambda: frame().unpivot(["q1"], index="zzz"),
        KeyError,
        f"no column named 'zzz' in this frame; the frame's columns are: {listed}",
    )


def test_unpivot_refuses_a_column_named_twice_or_in_both_on_and_index():
    refused(
        lambda: frame().unpivot(["q1", "q2", "q1"]),
        UnsupportedOperation,
        "unpivot: on names the column 'q1' twice; name each column once",
    )
    refused(
        lambda: frame().unpivot(["q1"], index=["name", "name"]),
        UnsupportedOperation,
        "unpivot: index names the column 'name' twice; name each column once",
    )
    refused(
        lambda: frame().unpivot(["q1", "name"], index="name"),
        UnsupportedOperation,
        "unpivot: the column 'name' is in both on and index; a column is either unpivoted or kept beside the values",
    )


def test_unpivot_refuses_an_on_of_no_column():
    message = (
        "unpivot: on names no column, and polars would give no rows and a value column of type Null, "
        "which a komira.pl frame cannot hold; name at least one column"
    )
    refused(lambda: frame().unpivot([], index="name"), UnsupportedOperation, message)
    refused(lambda: frame().select("name").unpivot(index="name"), UnsupportedOperation, message)


def test_unpivot_refuses_an_output_name_used_twice():
    refused(
        lambda: frame().unpivot(["q1"], index="name", variable_name="name"),
        ValueError,
        "unpivot: the output name 'name' is given to more than one column; pick another variable_name or value_name",
    )
    refused(
        lambda: frame().unpivot(["q1"], index="name", value_name="name"),
        ValueError,
        "unpivot: the output name 'name' is given to more than one column; pick another variable_name or value_name",
    )
    refused(
        lambda: frame().unpivot(["q1"], variable_name="v", value_name="v"),
        ValueError,
        "unpivot: the output name 'v' is given to more than one column; pick another variable_name or value_name",
    )
    assert frame().unpivot(["q1"], index="name", value_name="q1").columns == ["name", "variable", "q1"]


def test_unpivot_takes_names_as_str_only():
    refused(lambda: frame().unpivot(kpl.col("q1")), TypeError, "unpivot takes column names, not Expr")
    refused(lambda: frame().unpivot(["q1"], index=[1]), TypeError, "unpivot takes column names, not int")
    refused(lambda: frame().unpivot(["q1"], variable_name=1), TypeError, "unpivot: variable_name must be a str, not int")
    refused(lambda: frame().unpivot(["q1"], value_name=b"v"), TypeError, "unpivot: value_name must be a str, not bytes")


def test_unpivot_is_a_verb_and_not_in_the_refusal_table():
    from komira.pl import _names

    assert "unpivot" not in _names.TABLES["LazyFrame"]
    assert callable(frame().unpivot)
    refused(lambda: frame().explode, AttributeError, ".explode() is not supported yet: the plan has no node for it")


# ---- the terminal ------------------------------------------------------------------


def test_collect_hands_the_session_the_plan_bytes_of_a_union_of_projections():
    before = len(SESSION.ran)
    lf = frame(REQUIRED_PATH).unpivot(["q1", "q2"], index="name")
    assert len(SESSION.ran) == before
    lf.collect()
    encoded = encode_plan(lf._plan, lf._sources)
    assert SESSION.ran[before:] == [encoded.SerializeToString()]
    plan = encoded.plan
    assert plan.WhichOneof("node") == "union_all"
    assert [c.WhichOneof("node") for c in plan.union_all.children] == ["project", "project"]


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("pl_unpivot: {} tests passed".format(len(tests)))


if __name__ == "__main__":
    main()
